#Requires -Version 5.1
<#
.SYNOPSIS
    Sign a Pixel Backup companion release on the maintainer's Windows account.
.DESCRIPTION
    Enroll once with -Enroll. The vault under LocalAppData\PixelBackup\signing
    holds a password-encrypted PKCS12 file and its CurrentUser DPAPI-protected
    password. Keep an independently recoverable encrypted backup, since a lost
    Windows profile can make its DPAPI data unavailable. Every subsequent release
    must match the public release-cert.sha256 kept with the source.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$UnsignedApk,
    [Parameter(Mandatory)][string]$OutputApk,
    [Parameter(Mandatory)][string]$SdkRoot,
    [Parameter(Mandatory)][string]$JdkRoot,
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$BuildToolsVersion = '35.0.0',
    [ValidatePattern('^dev\.supthunder\.pixelbackup$')][string]$ExpectedPackage = 'dev.supthunder.pixelbackup',
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ExpectedVersionCode,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._+-]+$')][string]$ExpectedVersionName,
    [string]$CertificatePin,
    [switch]$Enroll
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
$system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$aliasName = 'pixel-backup-companion'
$passVariable = 'PIXEL_BACKUP_RELEASE_PRIVATE_INPUT'

function Get-FullPath([string]$Path) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Assert-UnlinkedPath([string]$Path) {
    for ($part = $Path; $part; $part = [IO.Path]::GetDirectoryName($part)) {
        $entry = Get-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        if ($entry -and (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $entry.LinkType)) {
            throw 'Signing paths must use ordinary files and directories without links or junctions.'
        }
    }
}

function Assert-PrivateItem([string]$Path, [switch]$RequireProtected) {
    $entry = Get-Item -LiteralPath $Path -Force
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $entry.LinkType) { throw 'Unexpected link in the signing vault.' }
    $acl = Get-Acl -LiteralPath $entry.FullName
    $sidType = [Security.Principal.SecurityIdentifier]
    $allowed = @($identity.Value, $system.Value)
    if ($acl.GetOwner($sidType).Value -ne $identity.Value -or ($RequireProtected -and -not $acl.AreAccessRulesProtected)) {
        throw 'The signing vault must be owned by this Windows user and its root must have protected access rules.'
    }
    $ownerCanRead = $false
    foreach ($rule in $acl.GetAccessRules($true, $true, $sidType)) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed) {
            throw 'The signing vault permits another Windows identity. Inspect its permissions before signing.'
        }
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -eq $identity.Value -and
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadData) -and
            -not ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) {
            $ownerCanRead = $true
        }
    }
    if (-not $ownerCanRead) { throw 'The signing vault requires an explicit or inherited access rule for its Windows owner.' }
}

function Open-PrivateRoot([string]$Path) {
    Assert-UnlinkedPath $Path
    $dir = [IO.DirectoryInfo]::new($Path)
    if (-not $dir.Exists) {
        [void][IO.Directory]::CreateDirectory($dir.Parent.FullName)
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($identity)
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($identity, $system)) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        if ($PSVersionTable.PSEdition -eq 'Core') { [IO.FileSystemAclExtensions]::Create($dir, $acl) }
        else { $dir.Create($acl) }
    }
    Assert-PrivateItem $Path -RequireProtected
}

function Invoke-Tool([string]$Exe, [string[]]$Arguments, [string]$Password) {
    $quoted = foreach ($arg in $Arguments) {
        if ($arg -match '["\x00-\x1f]') { throw 'Invalid tool argument.' }
        '"' + ($arg -replace '(\\+)$','$1$1') + '"'
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Exe
    $start.WorkingDirectory = [IO.Path]::GetDirectoryName($Exe)
    $start.Arguments = $quoted -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # Keep runtime injection options out of the process that handles the signer.
    foreach ($name in @('JDK_JAVA_OPTIONS','JAVA_TOOL_OPTIONS','_JAVA_OPTIONS','CLASSPATH',$passVariable)) {
        $start.EnvironmentVariables.Remove($name)
    }
    if ($Password) { $start.EnvironmentVariables[$passVariable] = $Password }
    $proc = [Diagnostics.Process]::new()
    try {
        $proc.StartInfo = $start
        if (-not $proc.Start()) { throw 'Could not start the Android release tools.' }
        $start.EnvironmentVariables.Remove($passVariable)
        $out = $proc.StandardOutput.ReadToEndAsync()
        $err = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(120000)) { $proc.Kill(); throw 'An Android release tool timed out.' }
        $stdout = $out.GetAwaiter().GetResult()
        $stderr = $err.GetAwaiter().GetResult()
        # Output from tools handling the password never leaves this function.
        if ($Password) { $stdout = ''; $stderr = '' }
        [pscustomobject]@{ Code = $proc.ExitCode; Text = $stdout + [Environment]::NewLine + $stderr }
    } finally { $start.EnvironmentVariables.Remove($passVariable); $proc.Dispose() }
}

function Read-Pin([string]$Path) {
    $file = Get-Item -LiteralPath $Path -Force
    if ($file -isnot [IO.FileInfo] -or $file.Length -lt 64 -or $file.Length -gt 128) { throw 'Invalid public signing pin file.' }
    $pin = [IO.File]::ReadAllText($Path).Trim()
    if ($pin -cnotmatch '^[0-9a-f]{64}$') { throw 'The public signing pin must contain one lowercase SHA-256 certificate digest.' }
    $pin
}

function Assert-ApkMetadata([string]$Path) {
    $result = Invoke-Tool $aapt @('dump','badging',$Path)
    if ($result.Code -ne 0) { throw 'aapt2 could not inspect the APK manifest.' }
    $pkg = [regex]::Match($result.Text, "(?m)^package: name='([^']+)' versionCode='(\d+)' versionName='([^']*)'")
    if (-not $pkg.Success -or $pkg.Groups[1].Value -cne $ExpectedPackage -or
        $pkg.Groups[2].Value -cne [string]$ExpectedVersionCode -or $pkg.Groups[3].Value -cne $ExpectedVersionName) {
        throw 'The APK application ID, versionCode or versionName differs from the requested release.'
    }
    if ($result.Text -notmatch "(?im)^(?:minSdkVersion|sdkVersion):'29'\r?$" -or $result.Text -match '(?m)^application-debuggable') {
        throw 'Expected a non-debuggable Android release variant with minimum SDK 29.'
    }
}

function Save-StagedFile([string]$From, [string]$To) {
    if ([IO.File]::Exists($To)) { [IO.File]::Replace($From, $To, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($From,$To) }
}

if ($env:OS -ne 'Windows_NT') { throw 'The release vault requires Windows CurrentUser DPAPI.' }
Add-Type -AssemblyName System.Security
$source = Get-FullPath $UnsignedApk
$output = Get-FullPath $OutputApk
$publicPin = Join-Path $PSScriptRoot 'release-cert.sha256'
$root = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'),'PixelBackup','signing')
$vault = Join-Path $root 'android-companion'
$checksum = $output + '.sha256'
if ([IO.Path]::GetExtension($source) -ine '.apk' -or [IO.Path]::GetExtension($output) -ine '.apk' -or $source -ieq $output) {
    throw 'Provide two distinct APK paths for the unsigned input and the signed release.'
}
foreach ($path in @($source,$output,$checksum,$publicPin)) {
    Assert-UnlinkedPath $path
    if ($path.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Keep APKs and public pins outside the private vault.' }
}
$expectedPins = @()
if ([IO.File]::Exists($publicPin)) { $expectedPins += Read-Pin $publicPin }
if ($CertificatePin) {
    $extra = Get-FullPath $CertificatePin
    Assert-UnlinkedPath $extra
    $expectedPins += Read-Pin $extra
}
if (($expectedPins | Select-Object -Unique | Measure-Object).Count -gt 1) { throw 'Public signing pins disagree.' }
if (-not $expectedPins.Count -and -not $Enroll) { throw 'No public certificate pin exists. First enrollment requires -Enroll.' }
if (-not [IO.Directory]::Exists($vault) -and ($expectedPins.Count -or -not $Enroll)) {
    throw 'The recorded Android release signer is unavailable. Restore its original vault or encrypted keystore backup.'
}

$buildTools = [IO.Path]::Combine((Get-FullPath $SdkRoot),'build-tools',$BuildToolsVersion)
$aapt = [IO.Path]::Combine($buildTools,'aapt2.exe')
$align = [IO.Path]::Combine($buildTools,'zipalign.exe')
$signerJar = [IO.Path]::Combine($buildTools,'lib','apksigner.jar')
$java = [IO.Path]::Combine((Get-FullPath $JdkRoot),'bin','java.exe')
$keytool = [IO.Path]::Combine((Get-FullPath $JdkRoot),'bin','keytool.exe')
foreach ($file in @($source,$aapt,$align,$signerJar,$java,$keytool)) {
    if (-not [IO.File]::Exists($file)) { throw "Missing required file: $file" }
}
$version = Invoke-Tool $java @('-version')
if ($version.Code -ne 0 -or $version.Text -notmatch '\bversion "17(?:\.|")') { throw 'Use JDK 17 to sign this release.' }
Assert-ApkMetadata $source
if ((Invoke-Tool $align @('-c','-P','16','4',$source)).Code -ne 0) { throw 'The unsigned APK failed zipalign verification.' }
if ((Invoke-Tool $java @('-jar',$signerJar,'verify',$source)).Code -eq 0) { throw 'Choose the unsigned release APK from the build.' }

$targetDir = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($output)).FullName
$token = [guid]::NewGuid().ToString('N')
$tempApk = Join-Path $targetDir ('.' + $token + '.apk')
$tempSum = Join-Path $targetDir ('.' + $token + '.sha256')
$tempPin = Join-Path $PSScriptRoot ('.release-cert-' + $token + '.tmp')
$pending = $null
$storeName = 'identity.p12'
$passName = 'password.dpapi'
$certName = 'certificate.der'
$entropy = $utf8.GetBytes('Pixel Backup Android companion signer v1')
$secretBytes = $null
$passBytes = $null
$password = $null
$lock = $null
try {
    Open-PrivateRoot $root
    $lockPath = Join-Path $root 'android-companion.lock'
    Assert-UnlinkedPath $lockPath
    try { $lock = [IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None') }
    catch { throw 'Another signing operation is active or the signing lock is inaccessible.' }
    if ([IO.Directory]::Exists($vault)) {
        Assert-PrivateItem $vault
    } else {
        if (-not $Enroll -or $expectedPins.Count -or [IO.File]::Exists($publicPin)) { throw 'Restore the enrolled signer before continuing.' }
        $pending = Join-Path $root ('.android-companion-' + $token)
        [void][IO.Directory]::CreateDirectory($pending)
        Assert-PrivateItem $pending
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        $secretBytes = [byte[]]::new(32)
        try { $rng.GetBytes($secretBytes) } finally { $rng.Dispose() }
        $password = [Convert]::ToBase64String($secretBytes)
        $passBytes = $utf8.GetBytes($password)
        $blob = [Security.Cryptography.ProtectedData]::Protect($passBytes,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes((Join-Path $pending $passName),$blob)
        $ks = Join-Path $pending $storeName
        $cert = Join-Path $pending $certName
        $keyArgs = @('-genkeypair','-noprompt','-storetype','PKCS12','-keystore',$ks,'-alias',$aliasName,
            '-storepass:env',$passVariable,'-keypass:env',$passVariable,'-keyalg','RSA','-keysize','3072',
            '-sigalg','SHA256withRSA','-validity','18262','-dname','CN=Pixel Backup Android Companion, O=Pixel Backup')
        if ((Invoke-Tool $keytool $keyArgs $password).Code -ne 0) { throw 'Could not generate the dedicated Android signing identity.' }
        $exportArgs = @('-exportcert','-storetype','PKCS12','-keystore',$ks,'-alias',$aliasName,'-storepass:env',$passVariable,'-file',$cert)
        if ((Invoke-Tool $keytool $exportArgs $password).Code -ne 0) { throw 'Could not export the new public signing certificate.' }
        foreach ($entry in @($storeName,$passName,$certName)) { Assert-PrivateItem (Join-Path $pending $entry) }
        [IO.Directory]::Move($pending,$vault)
        $pending = $null
    }
    foreach ($entry in @($storeName,$passName,$certName)) { Assert-PrivateItem (Join-Path $vault $entry) }
    $keystore = Join-Path $vault $storeName
    $digest = (Get-FileHash -LiteralPath (Join-Path $vault $certName) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expectedPins.Count -and $expectedPins[0] -cne $digest) { throw 'The vault certificate differs from the public release pin.' }
    if ($passBytes) { [Array]::Clear($passBytes,0,$passBytes.Length) }
    $protected = [IO.File]::ReadAllBytes((Join-Path $vault $passName))
    $passBytes = [Security.Cryptography.ProtectedData]::Unprotect($protected,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $password = $utf8.GetString($passBytes)
    $argsSign = @('-jar',$signerJar,'sign','--ks',$keystore,'--ks-type','PKCS12','--ks-key-alias',$aliasName,
        '--ks-pass',('env:'+$passVariable),'--key-pass',('env:'+$passVariable),'--v4-signing-enabled','false','--out',$tempApk,$source)
    if ((Invoke-Tool $java $argsSign $password).Code -ne 0) { throw 'APK signing failed with the enrolled keystore.' }
    $verify = Invoke-Tool $java @('-jar',$signerJar,'verify','--verbose','--print-certs','--min-sdk-version','29',$tempApk)
    $signers = [regex]::Matches($verify.Text,'(?im)^Signer #\d+ certificate SHA-256 digest:\s*([a-f0-9]{64})\s*$')
    if ($verify.Code -ne 0 -or $signers.Count -ne 1 -or $signers[0].Groups[1].Value.ToLowerInvariant() -cne $digest -or
        $verify.Text -notmatch '(?im)^Verified using v[23] scheme [^:\r\n]+:\s*true\s*$') {
        throw 'The signed APK failed Android 10 verification with the expected single release certificate.'
    }
    Assert-ApkMetadata $tempApk
    if ([IO.File]::Exists($publicPin)) {
        if ((Read-Pin $publicPin) -cne $digest) { throw 'The checked-in release pin changed while signing.' }
    } else {
        if (-not $Enroll -and -not $expectedPins.Count) { throw 'A public release pin is required.' }
        [IO.File]::WriteAllText($tempPin,$digest + [char]10,$utf8)
        [IO.File]::Move($tempPin,$publicPin)
    }
    $apkHash = (Get-FileHash -LiteralPath $tempApk -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($tempSum,($apkHash + '  ' + [IO.Path]::GetFileName($output) + [char]10),$utf8)
    # A crash between these two renames can leave the checksum missing. A stale
    # checksum must never accompany a different APK. Rerunning completes both.
    [IO.File]::Delete($checksum)
    Save-StagedFile $tempApk $output
    Save-StagedFile $tempSum $checksum
    [pscustomobject]@{ Apk=$output; Checksum=$checksum; ApkSha256=$apkHash; CertificateSha256=$digest; Package=$ExpectedPackage; VersionCode=$ExpectedVersionCode; VersionName=$ExpectedVersionName }
} finally {
    $password = $null
    if ($secretBytes) { [Array]::Clear($secretBytes,0,$secretBytes.Length) }
    if ($passBytes) { [Array]::Clear($passBytes,0,$passBytes.Length) }
    if ($pending) {
        foreach ($entry in @($storeName,$passName,$certName)) { [IO.File]::Delete((Join-Path $pending $entry)) }
        if ([IO.Directory]::Exists($pending)) { [IO.Directory]::Delete($pending) }
    }
    if ($lock) { $lock.Dispose() }
    foreach ($file in @($tempApk,$tempSum,$tempPin,($tempApk + '.idsig'))) { [IO.File]::Delete($file) }
}
