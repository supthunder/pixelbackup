#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Publish a read-only source and its selection manifest for the desktop app.
.NOTES
    The app supplies private sibling plan and control directories. The broker
    writes status.json atomically and runs until the parent exits or creates
    the control file named stop. The app owns removal of its staging directory.
#>
param(
    [Parameter(Mandatory)][string]$Folder,
    [Parameter(Mandatory)][string]$PlanDirectory,
    [Parameter(Mandatory)][string]$ControlDirectory,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ParentProcessId,
    [Parameter(Mandatory)][long]$ParentStartTicks
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PixelShares.ps1')

function Get-LocalPlanDirectory([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]') { throw 'An absolute local Windows directory is required.' }
    $dir = Get-Item -LiteralPath ([IO.Path]::GetFullPath($Path)) -Force
    if ($dir -isnot [IO.DirectoryInfo] -or [IO.DriveInfo]::new($dir.Root.FullName).DriveType -notin @('Fixed', 'Removable')) {
        throw "Choose a directory on a locally attached drive. $Path"
    }
    for ($part = $dir; $null -ne $part; $part = $part.Parent) {
        if ($part.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "The path crosses a reparse point at $($part.FullName)." }
    }
    $dir
}

function Test-PathWithin([string]$Path, [string]$Root) {
    $Path -eq $Root -or $Path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-PrivateStageAcl($Item, [string[]]$Trusted) {
    $acl = Get-Acl -LiteralPath $Item.FullName
    $type = [Security.Principal.SecurityIdentifier]
    $rules = $acl.GetAccessRules($true, $true, $type)
    if ($acl.GetOwner($type).Value -notin $Trusted -or -not $acl.AreAccessRulesCanonical -or -not $rules.Count -or
        ($rules | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $Trusted })) {
        throw "The app needs a fresh staging location private to this Windows user. Check $($Item.FullName)."
    }
    $acl
}

function Add-PlanReadAccess($Item, $ReaderSid, [string[]]$Trusted, $Receipts) {
    $acl = Get-PrivateStageAcl $Item $Trusted
    $rights = if ($Item.PSIsContainer) { 'ReadAndExecute' } else { 'Read' }
    # Each rule applies to this single object. New files never inherit the grant.
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($ReaderSid, [Security.AccessControl.FileSystemRights]$rights, 'Allow')
    $Receipts.Add([pscustomobject]@{ Path = $Item.FullName; Rule = $rule })
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Item.FullName -AclObject $acl
}

function Remove-PlanReadAccess($Receipt) {
    $item = Get-Item -LiteralPath $Receipt.Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType -eq 'HardLink') {
        throw "The staging object at $($Receipt.Path) has changed. Inspect its NTFS access."
    }
    $acl = Get-Acl -LiteralPath $item.FullName
    $readerRules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
        Where-Object { $_.IdentityReference -eq $Receipt.Rule.IdentityReference -and $_.AccessControlType -eq 'Allow' })
    if (-not $readerRules.Count) { return }
    if ($readerRules.Count -ne 1 -or $readerRules[0].IsInherited -or $readerRules[0].InheritanceFlags -ne 'None' -or
        $readerRules[0].PropagationFlags -ne 'None' -or $readerRules[0].FileSystemRights -ne $Receipt.Rule.FileSystemRights) {
        throw "The reader permissions on $($Receipt.Path) have changed. Inspect this staging object."
    }
    $acl.RemoveAccessRuleSpecific($Receipt.Rule)
    Set-Acl -LiteralPath $item.FullName -AclObject $acl
}

function Read-PlanSelection($ListStream, $HashStream) {
    if ($ListStream.Length -lt 1 -or $ListStream.Length -gt 33554432 -or $HashStream.Length -ne 65) {
        throw 'The plan needs a nonempty manifest of at most 32 MiB and its 65-byte checksum file.'
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $expected = [BitConverter]::ToString($sha.ComputeHash($ListStream)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $ListStream.Position = 0
    $list = [IO.StreamReader]::new($ListStream, $utf8, $false, 4096, $true)
    $hash = [IO.StreamReader]::new($HashStream, $utf8, $false, 128, $true)
    try {
        if ($hash.ReadToEnd() -cne "$expected`n") { throw 'The selection manifest checksum does not match.' }
        $contents = $list.ReadToEnd()
    } finally { $hash.Dispose(); $list.Dispose() }
    if (-not $contents.EndsWith("`n") -or $contents[0] -eq [char]0xfeff -or $contents -match '[\x00-\x09\x0b-\x1f\x7f\\:<>"|?*]') {
        throw 'The manifest must contain LF-terminated relative Windows media paths in UTF-8 without a BOM.'
    }
    if ($contents -match '(?m)^/|/$|//|(^|/)\.{1,2}(/|$)|^\n') { throw 'Invalid relative path in the selection manifest.' }
    # An SMB observation needs only one whole-line match. Avoid allocating an
    # object per file before publishing a large plan.
    "`n" + $contents.Replace('/', '\')
}

function Test-ReaderFileOpen([string]$Account, [string]$Source, [string[]]$ManifestFiles, [string]$Selection) {
    $prefix = $Source.TrimEnd('\') + '\'
    foreach ($open in Get-SmbOpenFile -ErrorAction Stop) {
        if ($open.ClientUserName -notin @($Account, 'PixelReader')) { continue }
        $path = [string]$open.Path
        if ($path.StartsWith('\\?\') -or $path.StartsWith('\??\')) { $path = $path.Substring(4) }
        if ($path -in $ManifestFiles) { return $true }
        if ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $entry = "`n" + $path.Substring($prefix.Length) + "`n"
            if ($Selection.IndexOf($entry, [StringComparison]::Ordinal) -ge 0 -and [IO.File]::Exists($path)) { return $true }
        }
    }
    $false
}

function Write-BrokerStatus([string]$Directory, $Status) {
    $target = Join-Path $Directory 'status.json'
    $temp = Join-Path $Directory ('status-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Status -Compress), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($target)) { [IO.File]::Replace($temp, $target, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $target) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

$reportDirectory = $null
$parent = $null
$pickerLock = $null
$ownsLock = $false
$registrations = [Collections.Generic.List[object]]::new()
$permissions = [Collections.Generic.List[object]]::new()
$streams = [Collections.Generic.List[IO.FileStream]]::new()
$problems = [Collections.Generic.List[string]]::new()
$status = [ordered]@{ State = 'Closed'; Message = 'Sharing stopped.'; PixelSeen = $false; ShareName = ''; PlanShareName = ''; CleanupComplete = $false }

try {
    $control = Get-LocalPlanDirectory $ControlDirectory
    $trusted = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
    if (-not $control.Parent -or [IO.DriveInfo]::new($control.Root.FullName).DriveFormat -ne 'NTFS') { throw 'Control staging must be a private NTFS subdirectory.' }
    $null = Get-PrivateStageAcl $control $trusted
    $null = Get-PrivateStageAcl $control.Parent $trusted
    foreach ($entry in Get-ChildItem -LiteralPath $control.FullName -Force) {
        if ($entry.Name -ne 'stop' -or $entry.PSIsContainer -or $entry.LinkType) { throw 'Use a fresh, private control directory.' }
    }
    $reportDirectory = $control.FullName
    $stopFile = Join-Path $reportDirectory 'stop'
    if ([IO.File]::Exists($stopFile)) { return }
    $source = Get-LocalPlanDirectory $Folder
    $plan = Get-LocalPlanDirectory $PlanDirectory
    if (-not $plan.Parent -or $plan.Parent.FullName -ne $control.Parent.FullName -or $plan.FullName -eq $control.FullName -or
        (Test-PathWithin $source.FullName $plan.FullName) -or (Test-PathWithin $plan.FullName $source.FullName) -or
        (Test-PathWithin $source.FullName $control.FullName) -or (Test-PathWithin $control.FullName $source.FullName)) {
        throw 'The private plan and control staging folders must be separate siblings outside the selected source.'
    }
    $parent = [Diagnostics.Process]::GetProcessById($ParentProcessId)
    if ($parent.StartTime.ToUniversalTime().Ticks -ne $ParentStartTicks) { throw 'The process that requested sharing is no longer running.' }
    $pickerLock = [Threading.Mutex]::new($true, 'Global\PixelBackupGang.FolderPicker', [ref]$ownsLock)
    if (-not $ownsLock) { throw 'Another PixelBackup picker is already open on this PC.' }
    $existing = @(Get-PixelSessionShares)
    if ($existing.Count) { throw "An existing PixelBackup share needs inspection before starting ($($existing.Name -join ', '))." }
    $user = Get-LocalUser -Name 'PixelReader' -ErrorAction Stop
    if (-not $user.Enabled -or $user.PrincipalSource -ne 'Local' -or
        $user.Description -cnotin @('Pixel Backup dedicated reader', 'Pixel Backup Gang dedicated reader')) {
        throw 'Run the Windows pairing setup for the dedicated PixelReader account.'
    }
    $account = "$env:COMPUTERNAME\$($user.Name)"
    $items = @(Get-ChildItem -LiteralPath $plan.FullName -Force)
    $names = @('files.txt', 'files.sha256')
    if ($items.Count -ne 2 -or ($items | Where-Object { $_.Name -cnotin $names -or $_.PSIsContainer -or $_.LinkType -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })) {
        throw 'The private plan directory must contain only regular files named files.txt and files.sha256.'
    }
    $manifestPaths = @($names | ForEach-Object { Join-Path $plan.FullName $_ })
    foreach ($path in $manifestPaths) { $streams.Add([IO.File]::Open($path, 'Open', 'Read', 'Read')) }
    $selection = Read-PlanSelection $streams[0] $streams[1]
    if (-not $parent.HasExited -and -not [IO.File]::Exists($stopFile)) {
        foreach ($item in @($plan) + $items) { Add-PlanReadAccess $item $user.SID $trusted $permissions }
        $id = [guid]::NewGuid().ToString('N')
        $status.ShareName = 'PixelBackupData-' + $id
        $status.PlanShareName = 'PixelBackupPlan-' + $id
        $data = New-PixelShareRegistration $status.ShareName $source.FullName
        $signal = New-PixelShareRegistration $status.PlanShareName $plan.FullName
        foreach ($registration in @($data, $signal)) {
            if ($parent.HasExited -or [IO.File]::Exists($stopFile)) { break }
            $registrations.Add($registration)
            $null = Open-PixelReadShare $registration $account
        }
        if ($registrations.Count -eq 2 -and -not $parent.HasExited -and -not [IO.File]::Exists($stopFile)) {
            $status.State = 'Ready'
            $status.Message = 'Sharing the selected plan read-only.'
            Write-BrokerStatus $reportDirectory $status
            while (-not $parent.HasExited -and -not [IO.File]::Exists($stopFile)) {
                if (-not [IO.Directory]::Exists($reportDirectory)) { throw 'The control directory disappeared.' }
                if (-not $status.PixelSeen) {
                    try { $status.PixelSeen = Test-ReaderFileOpen $account $source.FullName $manifestPaths $selection }
                    catch { Write-Verbose "SMB open-file observations are unavailable. $($_.Exception.Message)" }
                    if ($status.PixelSeen) {
                        $status.Message = 'Windows observed PixelReader open a file in this plan.'
                        Write-BrokerStatus $reportDirectory $status
                    }
                }
                [void]$parent.WaitForExit(400)
            }
        }
    }
} catch { $problems.Add($_.Exception.Message) }
finally {
    $cleanupComplete = $true
    for ($i = $registrations.Count - 1; $i -ge 0; $i--) {
        try { Close-PixelReadShare $registrations[$i] }
        catch { $cleanupComplete = $false; $problems.Add($_.Exception.Message) }
    }
    for ($i = $permissions.Count - 1; $i -ge 0; $i--) {
        try { Remove-PlanReadAccess $permissions[$i] }
        catch { $cleanupComplete = $false; $problems.Add($_.Exception.Message) }
    }
    foreach ($stream in $streams) { $stream.Dispose() }
    if ($parent) { $parent.Dispose() }
    if ($ownsLock) { $pickerLock.ReleaseMutex() }
    if ($pickerLock) { $pickerLock.Dispose() }
    $status.CleanupComplete = $cleanupComplete
    $status.State = 'Closed'
    $status.Message = 'Sharing stopped.'
    if ($problems.Count) { $status.State = 'Error'; $status.Message = $problems -join ' ' }
    if ($reportDirectory) { Write-BrokerStatus $reportDirectory $status }
}
if ($problems.Count) { throw $status.Message }
