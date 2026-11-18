#Requires -Version 5.1
<#
.SYNOPSIS
    Pair the desktop app, a selected local photo folder and an original Pixel.
.EXAMPLE
    powershell.exe -NoProfile -STA -File .\windows\Pair-PixelDesktop.ps1 -Adb 'C:\platform-tools\adb.exe' -LibraryPath 'D:\Pictures' -ComputerAddress 192.168.1.10
.NOTES
    Launch from the ordinary Windows session. Only creating the dedicated
    Windows account needs same-user administrator consent.
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

function Request-ReaderPassword([string]$Account) {
    Add-Type -AssemblyName PresentationFramework
    $window = [Windows.Window]::new()
    $window.Title = 'Pair Pixel Backup'
    $window.SizeToContent = 'WidthAndHeight'
    $window.ResizeMode = 'NoResize'
    $window.WindowStartupLocation = 'CenterScreen'
    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Margin = [Windows.Thickness]::new(18)
    $label = [Windows.Controls.TextBlock]::new()
    $label.Text = "Enter the existing Windows password for $Account."
    $field = [Windows.Controls.PasswordBox]::new()
    $field.Margin = [Windows.Thickness]::new(0, 10, 0, 12)
    $buttons = [Windows.Controls.StackPanel]::new()
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    $ok = [Windows.Controls.Button]::new()
    $ok.Content = 'Continue'
    $ok.Padding = [Windows.Thickness]::new(10, 3, 10, 3)
    $ok.IsDefault = $true
    $ok.Add_Click({ $window.DialogResult = $true })
    $cancel = [Windows.Controls.Button]::new()
    $cancel.Content = 'Cancel'
    $cancel.Padding = $ok.Padding
    $cancel.Margin = [Windows.Thickness]::new(8, 0, 0, 0)
    $cancel.IsCancel = $true
    [void]$buttons.Children.Add($ok)
    [void]$buttons.Children.Add($cancel)
    [void]$panel.Children.Add($label)
    [void]$panel.Children.Add($field)
    [void]$panel.Children.Add($buttons)
    $window.Content = $panel
    $window.Add_ContentRendered({ [void]$field.Focus() })
    try {
        if ($window.ShowDialog() -ne $true) { throw [OperationCanceledException]::new('Pairing canceled.') }
        [pscredential]::new($Account, $field.SecurePassword)
    } finally { $field.Clear() }
}

function New-ApprovedWindowsReader([string]$Stored, [Security.Principal.SecurityIdentifier]$CallerSid) {
    # The ordinary process holds and fingerprints its existing DPAPI recovery file.
    # The UAC process receives only that digest and a SID. It opens a fixed profile
    # path and performs one fixed-name SAM operation using system PowerShell modules.
    $inputLock = [IO.File]::Open($Stored, 'Open', 'Read', 'Read')
    try {
        if ($inputLock.Length -gt 65536) { throw 'Invalid recovery file.' }
        $digest = (Get-FileHash -InputStream $inputLock -Algorithm SHA256).Hash
        $command = @'
$ErrorActionPreference = 'Stop'
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
$env:PATH = [Environment]::SystemDirectory + ';' + $PSHOME
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne '__SID__') { exit 21 }
try {
    $file = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'PixelBackup-Pairing', 'PixelReader.clixml')
    $inputFile = [IO.File]::Open($file, 'Open', 'Read', 'Read')
    try {
        if ($inputFile.Length -gt 65536) { exit 22 }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($inputFile)).Replace('-', '') } finally { $sha.Dispose() }
        if ($hash -cne '__SHA256__') { exit 22 }
        $inputFile.Position = 0
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = 'Prohibit'
        $settings.XmlResolver = $null
        $settings.MaxCharactersInDocument = 65536
        $xml = [Xml.XmlReader]::Create($inputFile, $settings)
        try {
            while ($xml.Read()) {
                if ($xml.NodeType -eq 'Element' -and $xml.LocalName -ceq 'SS' -and $xml.GetAttribute('N') -ceq 'Password') {
                    $secret = Microsoft.PowerShell.Security\ConvertTo-SecureString -String ($xml.ReadElementContentAsString())
                    break
                }
            }
        } finally { $xml.Dispose() }
    } finally { $inputFile.Dispose() }
    if (-not $secret -or -not $secret.Length) { exit 22 }
    if (Microsoft.PowerShell.LocalAccounts\Get-LocalUser -Name 'PixelReader' -ErrorAction SilentlyContinue) { exit 23 }
    $null = Microsoft.PowerShell.LocalAccounts\New-LocalUser -Name 'PixelReader' -Password $secret -Description 'Pixel Backup dedicated reader'
    exit 0
} catch { exit 24 } finally { if ($secret) { $secret.Dispose() } }
'@
        $command = $command.Replace('__SID__', $CallerSid.Value).Replace('__SHA256__', $digest)
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.WorkingDirectory = [Environment]::SystemDirectory
        $startInfo.FileName = [IO.Path]::Combine($startInfo.WorkingDirectory, 'WindowsPowerShell', 'v1.0', 'powershell.exe')
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $startInfo.UseShellExecute = $true
        $startInfo.Verb = 'runas'
        $startInfo.WindowStyle = 'Hidden'
        try { $process = [Diagnostics.Process]::Start($startInfo) } catch {
            $cause = $_.Exception.GetBaseException()
            if ($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -eq 1223) { throw [OperationCanceledException]::new('Windows approval canceled.') }
            throw
        }
        try {
            $process.WaitForExit()
            switch ($process.ExitCode) {
                0 { return }
                21 { $script:pairingFailure = 'Approve with the Windows account that opened Pixel Backup, or ask an administrator to prepare PixelReader first using the pairing guide.' }
                22 { $script:pairingFailure = 'Windows could not read the pairing credential. Retry from the Windows account that created it.' }
                23 { $script:pairingFailure = 'PixelReader was created by another operation. Retry pairing to check the existing account.' }
            }
            $failed = [InvalidOperationException]::new($script:pairingFailure)
            if ($process.ExitCode -in @(21, 22, 23)) { $failed.Data['ReaderNotCreated'] = $true }
            throw $failed
        } finally { $process.Dispose() }
    } finally { $inputLock.Dispose() }
}

$script:pairingFailure = 'Launch Pixel Backup from your normal 64-bit Windows session and retry setup.'
try {
    if ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $script:pairingFailure = 'Open Pixel Backup normally, without Run as administrator, then pair the Pixel again.'
        throw $script:pairingFailure
    }
    if (-not [Environment]::Is64BitProcess) { throw 'Launch the 64-bit Windows PowerShell host.' }
    $script:pairingFailure = 'Select this PC''s assigned Wi-Fi or Ethernet IPv4 address in Setup.'
    $address = $null
    if (-not [Net.IPAddress]::TryParse($ComputerAddress, [ref]$address) -or $address.AddressFamily -ne 'InterNetwork' -or
        $address.ToString() -ne $ComputerAddress -or $address.GetAddressBytes()[0] -in @(0, 127) -or
        $address.GetAddressBytes()[0] -ge 224 -or
        -not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ComputerAddress -ErrorAction SilentlyContinue)) {
        throw "Choose this PC's assigned LAN IPv4 address, reachable by the Pixel."
    }
    $script:pairingFailure = 'In Setup, open Advanced options and choose Prepare USB tools. Then try pairing again.'
    $adbFile = Get-Item -LiteralPath (Get-CheckedLocalPath $Adb) -Force
    if ($adbFile -isnot [IO.FileInfo] -or $adbFile.Name -ne 'adb.exe') { throw 'Select adb.exe from Android Platform Tools.' }
    $script:pairingFailure = 'Choose a photo folder on a local NTFS, FAT or exFAT drive outside the private pairing files.'
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
    $script:pairingFailure = 'Another pairing may already be open. Close it and retry.'
    $mutex = [Threading.Mutex]::new($false, 'Global\PixelBackupGang.DesktopPairing')
    $held = $false
    $credential = $null
    $saveAfterSignIn = $false
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Another desktop pairing is in progress.' }
        $script:pairingFailure = 'Windows could not open the private pairing credential for this Windows login. Check the pairing guide.'
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
        if (-not $reader) {
            $newCredentialHash = $null
            if (-not $credential) {
                $credential = New-ReaderCredential $account
                # The same password remains recoverable if account creation succeeds
                # and the process stops before writing phone files or opening SMB.
                Save-ReaderCredential $credential $stored
                $newCredentialHash = (Get-FileHash -LiteralPath $stored -Algorithm SHA256).Hash
            }
            $script:pairingFailure = 'Windows could not create PixelReader. Check that this Windows account can approve local account setup, then retry.'
            try { New-ApprovedWindowsReader $stored $ownerSid } catch {
                # A canceled UAC, wrong approving login or an already-existing
                # account never consumed the new password. Preserve any earlier
                # credential and any uncertain possibly-completed creation.
                $cause = $_.Exception.GetBaseException()
                if ($newCredentialHash -and ($cause -is [OperationCanceledException] -or $cause.Data['ReaderNotCreated']) -and
                    [IO.File]::Exists($stored) -and (Get-FileHash -LiteralPath $stored -Algorithm SHA256).Hash -ceq $newCredentialHash) {
                    [IO.File]::Delete($stored)
                }
                throw
            }
        }
        $script:pairingFailure = 'Select this folder in Backup, open Connection details and choose Allow folder access. Then retry pairing. You can also choose a folder you own.'
        try { $null = & $initialize -LibraryPath $library.FullName -ExistingReaderOnly } catch {
            if ($_.Exception.Message -like 'PixelReader already exists*' -or $_.Exception.Message -like 'PixelReader belongs to*') {
                $script:pairingFailure = 'The Windows account named PixelReader is disabled or differs from the dedicated pairing account. Check the reader in Setup.'
            }
            throw
        }
        if (-not $credential) {
            $script:pairingFailure = 'Enter the existing Windows password for this PC''s PixelReader account.'
            $credential = Request-ReaderPassword $account
            Assert-ReaderCredential $credential $account
            $saveAfterSignIn = $true
        }
        $script:pairingFailure = 'The verified Android tools are unavailable. Check the PC internet connection and retry setup.'
        $tools = & (Join-Path $PSScriptRoot 'Get-PixelTools.ps1') -Destination $toolsPath
        $script:pairingFailure = 'Unlock the connected original Pixel, approve USB debugging and Magisk for Shell, and check it can reach the PC over Wi-Fi. Then retry pairing.'
        & (Join-Path $PSScriptRoot 'Install-PixelWatcher.ps1') -Adb $adbFile.FullName -ToolsDirectory $tools -ComputerAddress $ComputerAddress -Credential $credential
        # A user-entered existing password is saved only after the Pixel authenticated.
        $script:pairingFailure = 'The phone paired, but Windows could not save its private credential. Check access to the pairing folder and retry.'
        if ($saveAfterSignIn) { Save-ReaderCredential $credential $stored }
    } finally {
        if ($credential -is [pscredential]) { $credential.Password.Dispose() }
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
} catch {
    if ($_.Exception.GetBaseException() -is [OperationCanceledException]) {
        [Console]::Error.WriteLine('PixelBackupError: Setup canceled.')
        exit 1223
    }
    $usbMessage = $_.Exception.GetBaseException().Data['PixelBackupUsbMessage']
    if ($usbMessage) { $script:pairingFailure = $usbMessage }
    [Console]::Error.WriteLine('PixelBackupError: ' + $script:pairingFailure)
    throw $script:pairingFailure
}
