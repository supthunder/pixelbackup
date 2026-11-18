#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Pair the desktop app, a selected local photo folder and an original Pixel.
.EXAMPLE
    powershell.exe -NoProfile -STA -File .\windows\Pair-PixelDesktop.ps1 -Adb 'C:\platform-tools\adb.exe' -LibraryPath 'D:\Pictures' -ComputerAddress 192.168.1.10
.NOTES
    Launch with normal same-user administrator consent. Existing readers without
    a saved credential use the standard Windows PowerShell credential prompt.
#>
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Adb,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LibraryPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComputerAddress
)

$ErrorActionPreference = 'Stop'

function Get-CheckedLocalPath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw 'Choose an absolute path on a local drive.' }
    $full = [IO.Path]::GetFullPath($Path)
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))
    if ($drive.DriveType -notin @('Fixed', 'Removable')) { throw 'Choose a drive attached to this PC.' }
    for ($part = $full; $part; $part = [IO.Path]::GetDirectoryName($part)) {
        try { $item = Get-Item -LiteralPath $part -Force } catch {
            if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { continue }
            throw
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) {
            throw "The pairing path crosses a link or junction at $part."
        }
    }
    $full
}

function Assert-PrivatePairingItem($Item) {
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $Item.LinkType) {
        throw 'The private pairing directory and credential cannot be links.'
    }
    $acl = Get-Acl -LiteralPath $Item.FullName
    $sidType = [Security.Principal.SecurityIdentifier]
    $allowed = @($ownerSid.Value, 'S-1-5-18', 'S-1-5-32-544')
    $rules = @($acl.GetAccessRules($true, $true, $sidType))
    $userRead = $rules | Where-Object {
        $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -eq $ownerSid.Value -and
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadData) -and
        -not ($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)
    }
    if (-not $userRead -or $acl.GetOwner($sidType).Value -notin $allowed -or -not $acl.AreAccessRulesCanonical -or
        ($Item.PSIsContainer -and -not $acl.AreAccessRulesProtected) -or
        ($rules | Where-Object {
            $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $allowed
        })) {
        throw "Pairing needs a private location owned by this Windows user, SYSTEM or Administrators. Check the permissions at $($Item.FullName)."
    }
}

function Open-PairingDirectory([string]$Path) {
    $directory = [IO.DirectoryInfo]::new($Path)
    if (-not $directory.Exists) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($ownerSid)
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        foreach ($sid in @($ownerSid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inherit, 'None', 'Allow'))
        }
        if ($PSVersionTable.PSEdition -eq 'Core') { [IO.FileSystemAclExtensions]::Create($directory, $acl) }
        else { $directory.Create($acl) }
    }
    Assert-PrivatePairingItem (Get-Item -LiteralPath $Path -Force)
}

function New-ReaderCredential([string]$UserName) {
    $secret = [Security.SecureString]::new()
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new(40)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
    try {
        $random.GetBytes($bytes)
        # Four required character classes plus 240 independent bits of entropy.
        foreach ($character in 'Aa9-'.ToCharArray()) { $secret.AppendChar($character) }
        foreach ($byte in $bytes) { $secret.AppendChar($alphabet[$byte -band 63]) }
        $secret.MakeReadOnly()
        [pscredential]::new($UserName, $secret)
    } catch {
        $secret.Dispose()
        throw
    } finally {
        $random.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Save-ReaderCredential([pscredential]$Credential, [string]$Path) {
    # Windows Export-Clixml uses the current user's DPAPI key. The private
    # directory protects the file from creation until its atomic publication.
    $temp = Join-Path ([IO.Path]::GetDirectoryName($Path)) ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Credential | Export-Clixml -LiteralPath $temp -NoClobber -Depth 2
        Assert-PrivatePairingItem (Get-Item -LiteralPath $temp -Force)
        [IO.File]::Move($temp, $Path)
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Assert-ReaderCredential($Credential, [string]$Account) {
    if ($Credential -isnot [pscredential] -or $Credential.UserName -ne $Account -or $Credential.Password.Length -eq 0) {
        throw "Pairing requires the existing password for $Account on this PC."
    }
}

if (-not [Environment]::Is64BitProcess) { throw 'Launch the 64-bit Windows PowerShell host.' }
$address = $null
if (-not [Net.IPAddress]::TryParse($ComputerAddress, [ref]$address) -or $address.AddressFamily -ne 'InterNetwork' -or
    $address.ToString() -ne $ComputerAddress -or $address.GetAddressBytes()[0] -in @(0, 127) -or
    $address.GetAddressBytes()[0] -ge 224 -or
    -not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ComputerAddress -ErrorAction SilentlyContinue)) {
    throw "Choose this PC's assigned LAN IPv4 address, reachable by the Pixel."
}
$adbFile = Get-Item -LiteralPath (Get-CheckedLocalPath $Adb) -Force
if ($adbFile -isnot [IO.FileInfo] -or $adbFile.Name -ne 'adb.exe') { throw 'Select adb.exe from Android Platform Tools.' }
$library = Get-Item -LiteralPath (Get-CheckedLocalPath $LibraryPath) -Force
if ($library -isnot [IO.DirectoryInfo] -or -not $library.Parent -or
    [IO.DriveInfo]::new($library.Root.FullName).DriveFormat -notin @('NTFS','FAT','FAT32','exFAT')) {
    throw 'Choose a photo folder inside a local NTFS, FAT or exFAT drive.'
}
$local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$private = Get-CheckedLocalPath (Join-Path $local 'PixelBackup-Pairing')
if ($private -eq $library.FullName -or $private.StartsWith($library.FullName.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $library.FullName.StartsWith($private + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose a photo folder outside the private Windows pairing directory and its parents.'
}
if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($private)).DriveFormat -ne 'NTFS') { throw 'The pairing credential needs a private NTFS profile.' }
$stored = Get-CheckedLocalPath (Join-Path $private 'PixelReader.clixml')
$toolsPath = Get-CheckedLocalPath (Join-Path $local 'PixelBackup\tools')
foreach ($name in @('rclone', 'fusermount3')) { $null = Get-CheckedLocalPath (Join-Path $toolsPath $name) }
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$account = "$env:COMPUTERNAME\PixelReader"
$mutex = [Threading.Mutex]::new($false, 'Global\PixelBackupGang.DesktopPairing')
$held = $false
$credential = $null
$saveAfterSignIn = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another desktop pairing is in progress.' }
    Open-PairingDirectory $private
    if (Test-Path -LiteralPath $stored) {
        $file = Get-Item -LiteralPath $stored -Force
        if ($file -isnot [IO.FileInfo] -or $file.Length -gt 65536) { throw 'The saved pairing credential is invalid.' }
        Assert-PrivatePairingItem $file
        try { $credential = Import-Clixml -LiteralPath $stored } catch {
            throw 'This Windows login could not decrypt the saved PixelReader credential.'
        }
        Assert-ReaderCredential $credential $account
    }
    $reader = $null
    try { $reader = Get-LocalUser -Name PixelReader } catch {
        if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
    }
    $initialize = Join-Path $PSScriptRoot 'Initialize-PixelReader.ps1'
    if ($reader) {
        # The initializer verifies its dedicated standard account before changing
        # the selected folder's permissions or asking for a reader password.
        $null = & $initialize -LibraryPath $library.FullName -ExistingReaderOnly
        if (-not $credential) {
            $credential = Get-Credential -UserName $account -Message 'Enter the existing PixelReader password to pair this Pixel.'
            Assert-ReaderCredential $credential $account
            $saveAfterSignIn = $true
        }
    } else {
        if (-not $credential) {
            $credential = New-ReaderCredential $account
            # The same password remains recoverable if account creation succeeds
            # and the process stops before writing phone files or opening SMB.
            Save-ReaderCredential $credential $stored
        }
        $setup = & $initialize -LibraryPath $library.FullName -Password $credential.Password
        if (-not $setup.AccountCreated) { throw 'The reader account changed during pairing. Check its existing credential.' }
    }
    $tools = & (Join-Path $PSScriptRoot 'Get-PixelTools.ps1') -Destination $toolsPath
    & (Join-Path $PSScriptRoot 'Install-PixelWatcher.ps1') -Adb $adbFile.FullName -ToolsDirectory $tools -ComputerAddress $ComputerAddress -Credential $credential
    # A user-entered existing password is saved only after the Pixel authenticated.
    if ($saveAfterSignIn) { Save-ReaderCredential $credential $stored }
} finally {
    if ($credential -is [pscredential]) { $credential.Password.Dispose() }
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
