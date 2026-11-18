#Requires -Version 5.1
<#
.SYNOPSIS
    Build and install the native Pixel Backup desktop app for the current Windows user.
.EXAMPLE
    .\windows\Build-PixelBackup.ps1 -InstallDesktopShortcut -Launch
.EXAMPLE
    .\windows\Build-PixelBackup.ps1 -Destination .\dist\app -PackagePath .\dist\Pixel-Backup-Windows-x64.zip
.OUTPUTS
    Absolute path of the installed Pixel Backup.exe.
#>
param(
    [ValidateNotNullOrEmpty()]
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'PixelBackup\app'),
    [string]$PackagePath,
    [switch]$InstallDesktopShortcut,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$repo = (Get-Item -LiteralPath $PSScriptRoot).Parent.FullName
$app = Join-Path $PSScriptRoot 'app'
$exeName = 'Pixel Backup.exe'
$receiptName = 'pixel-backup-build.json'
$product = 'supthunder.pixelbackup.desktop'

function Get-TextHash([string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-FileDigest([string]$Path) {
    if ([IO.File]::Exists($Path)) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}

function New-WorkDirectory([string]$Parent) {
    [IO.Directory]::CreateDirectory((Join-Path $Parent ('.pixelbackup-' + [guid]::NewGuid().ToString('N')))).FullName
}

function Remove-WorkDirectory([string]$Parent, [string]$Stage) {
    $work = Get-Item -LiteralPath $Stage -Force
    if ($work.Parent.FullName -eq $Parent -and $work.Name -match '^\.pixelbackup-[a-f0-9]{32}$' -and
        -not ($work.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-Item -LiteralPath $work.FullName -Recurse -Force }
}

function Publish-StagedFiles([string]$Stage, [string]$Parent, [string[]]$Names) {
    $changes = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($name in $Names) {
            $target = Join-Path $Parent $name
            $source = Join-Path $Stage $name
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $backup = $null
            if ([IO.File]::Exists($target)) {
                $backup = Join-Path $Stage ('old-' + $changes.Count)
                [IO.File]::Replace($source, $target, $backup)
            } else { [IO.File]::Move($source, $target) }
            $changes.Add(@{Target=$target; Backup=$backup})
        }
    } catch {
        for ($i = $changes.Count - 1; $i -ge 0; $i--) {
            $change = $changes[$i]
            if ($change.Backup) { [IO.File]::Copy($change.Backup, $change.Target, $true) }
            else { [IO.File]::Delete($change.Target) }
        }
        throw
    }
}

function Compile-Desktop([string]$Output, [string[]]$Sources) {
    $release = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release).Release
    if ($release -lt 528040) { throw 'Pixel Backup requires .NET Framework 4.8 or later.' }
    $framework = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
    $compiler = Join-Path $framework 'csc.exe'
    if (-not [IO.File]::Exists($compiler)) { throw 'The Windows 64-bit .NET Framework compiler is missing.' }
    $arguments = @('/nologo', '/target:winexe', '/platform:x64', '/langversion:5', '/codepage:65001', '/optimize+',
        '/main:PixelBackup.Program', "/out:$Output", '/win32manifest:app.manifest', '/win32icon:PixelBackup.ico',
        '/resource:MainWindow.xaml,PixelBackup.MainWindow.xaml', '/resource:PixelBackup.ico,PixelBackup.PixelBackup.ico')
    $references = @('System', 'System.Core', 'System.Configuration', 'System.Data', 'System.Drawing', 'System.IO.Compression',
        'System.IO.Compression.FileSystem', 'System.Management', 'System.Net.Http', 'System.Runtime.Serialization', 'System.Security',
        'System.Web', 'System.Web.Extensions', 'System.Windows.Forms', 'System.Xaml', 'System.Xml', 'System.Xml.Linq',
        'WPF\WindowsBase', 'WPF\PresentationCore', 'WPF\PresentationFramework', 'WPF\WindowsFormsIntegration')
    foreach ($reference in $references) { $arguments += '/reference:' + (Join-Path $framework ($reference + '.dll')) }
    Push-Location -LiteralPath $app
    try {
        & $compiler @arguments @Sources | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'The Windows C# compiler could not build Pixel Backup.' }
    } finally { Pop-Location }
}

function Save-DesktopShortcut([string]$Exe) {
    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    $path = Join-Path $desktop 'Pixel Backup.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $exists = [IO.File]::Exists($path)
    if ($exists) {
        $shortcut = $shell.CreateShortcut($path)
        $oldPicker = [IO.Path]::GetFileName($shortcut.TargetPath) -eq 'Select-PixelFolder.cmd' -and
            ($shortcut.TargetPath -eq (Join-Path $PSScriptRoot 'Select-PixelFolder.cmd') -or
             $shortcut.Description -eq 'Select a folder for the paired Pixel to back up')
        $ourApp = $shortcut.TargetPath -eq $Exe -or ([IO.Path]::GetFileName($shortcut.TargetPath) -eq $exeName -and
            $shortcut.Description -eq 'Open the Pixel Backup desktop app')
        if ($shortcut.Arguments -or (-not $oldPicker -and -not $ourApp)) {
            Write-Warning "The existing shortcut at $path points elsewhere. You can launch $Exe directly."
            return
        }
    }
    # A fresh link also drops any administrator flag inherited from the old picker.
    $tempLink = Join-Path $desktop ('.pixelbackup-' + [guid]::NewGuid().ToString('N') + '.lnk')
    try {
        $shortcut = $shell.CreateShortcut($tempLink)
        $shortcut.TargetPath = $Exe
        $shortcut.Description = 'Open the Pixel Backup desktop app'
        $shortcut.WorkingDirectory = [IO.Path]::GetDirectoryName($Exe)
        $shortcut.IconLocation = "$Exe,0"
        $shortcut.WindowStyle = 1
        $shortcut.Save()
        if ($exists) { [IO.File]::Replace($tempLink, $path, [NullString]::Value) }
        else { [IO.File]::Move($tempLink, $path) }
    } finally { [IO.File]::Delete($tempLink) }
}

function Write-ReleaseZip([string]$Path, [string[]]$Files) {
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
    $zipPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ([IO.Path]::GetExtension($zipPath) -ne '.zip') { throw 'PackagePath must end in .zip.' }
    $zipParent = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($zipPath)).FullName
    $zipName = [IO.Path]::GetFileName($zipPath)
    $stage = New-WorkDirectory $zipParent
    $tempZip = Join-Path $stage $zipName
    try {
        $archive = [IO.Compression.ZipFile]::Open($tempZip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in $Files) {
                $name = $file.Replace('\', '/')
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $outputDir $file), $name)
            }
        } finally { $archive.Dispose() }
        $hashLine = (Get-FileDigest $tempZip).ToLowerInvariant() + '  ' + $zipName + "`n"
        [IO.File]::WriteAllText("$tempZip.sha256", $hashLine, [Text.Encoding]::ASCII)
        Publish-StagedFiles $stage $zipParent @($zipName, "$zipName.sha256")
        Write-Host "Created $zipPath and $zipPath.sha256"
    } finally { Remove-WorkDirectory $zipParent $stage }
}

$outputDir = [IO.Directory]::CreateDirectory($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)).FullName
$exe = Join-Path $outputDir $exeName
$receipt = Join-Path $outputDir $receiptName
$sources = @(Get-ChildItem -LiteralPath $app -File -Filter '*.cs' | Sort-Object Name)
$buildInputs = @($sources.FullName) + @($PSCommandPath, (Join-Path $app 'MainWindow.xaml'), (Join-Path $app 'PixelBackup.ico'), (Join-Path $app 'app.manifest'))
$payload = [ordered]@{ 'Pixel Backup.exe.config' = (Join-Path $app 'App.config') }
$backend = @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.Name -notmatch '^(Build|Package)-PixelBackup\.psm?1$' })
$helpFiles = @(Get-ChildItem -LiteralPath (Join-Path $repo 'docs') -Recurse -File | Where-Object { $_.Extension -in '.md', '.png', '.jpg' })
foreach ($file in @($backend + $helpFiles | Sort-Object FullName)) { $payload[$file.FullName.Substring($repo.Length + 1)] = $file.FullName }
foreach ($script in @('mount_pc_folder.sh','watch_pc_folders.sh','start_pc_watcher.sh')) {
    $name = "android_client\$script"
    $payload[$name] = Join-Path $repo $name
}
$assetHashes = @{}
$hashLines = @(foreach ($inputPath in $buildInputs) {
    $digest = Get-FileDigest $inputPath
    if (-not $digest) { throw "Missing desktop app build input: $inputPath" }
    $inputPath.Substring($repo.Length + 1) + ' ' + $digest
})
foreach ($name in $payload.Keys) {
    $assetHashes[$name] = Get-FileDigest $payload[$name]
    if (-not $assetHashes[$name]) { throw "Missing desktop app support file: $($payload[$name])" }
    $hashLines += $name + ' ' + $assetHashes[$name]
}
$fingerprint = Get-TextHash ($hashLines -join "`n")
$mutex = [Threading.Mutex]::new($false, ('Local\PixelBackup.Build.' + (Get-TextHash $outputDir.ToUpperInvariant())))
$held = $false
try {
    try { $held = $mutex.WaitOne(90000) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another Pixel Backup installation is still running.' }
    $previous = $null
    if ([IO.File]::Exists($receipt)) { $previous = [IO.File]::ReadAllText($receipt) | ConvertFrom-Json }
    $managed = $previous -and $previous.product -ceq $product
    $ready = $managed -and $previous.inputs -ceq $fingerprint -and (Get-FileDigest $exe) -eq $previous.executable
    if ($ready) {
        foreach ($name in $payload.Keys) {
            if ((Get-FileDigest (Join-Path $outputDir $name)) -ne $assetHashes[$name]) { $ready = $false; break }
        }
    }
    if (-not $ready) {
        $names = @($payload.Keys) + @($exeName, $receiptName)
        if (-not $managed) {
            foreach ($name in $names) {
                if (Test-Path -LiteralPath (Join-Path $outputDir $name)) { throw "An existing file occupies $name in $outputDir. Choose a dedicated installation folder." }
            }
        }
        $stage = New-WorkDirectory $outputDir
        try {
            Compile-Desktop (Join-Path $stage $exeName) $sources.Name
            foreach ($name in $payload.Keys) {
                $target = Join-Path $stage $name
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                [IO.File]::Copy($payload[$name], $target)
            }
            $info = [ordered]@{ product = $product; inputs = $fingerprint; executable = (Get-FileDigest (Join-Path $stage $exeName)) }
            [IO.File]::WriteAllText((Join-Path $stage $receiptName), ($info | ConvertTo-Json))
            Publish-StagedFiles $stage $outputDir $names
        } finally { Remove-WorkDirectory $outputDir $stage }
    }
    if ($PackagePath) { Write-ReleaseZip $PackagePath (@($exeName, $receiptName) + @($payload.Keys)) }
    if ($InstallDesktopShortcut) { Save-DesktopShortcut $exe }
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if ($Launch) { Start-Process -FilePath $exe -WorkingDirectory $outputDir }
$exe
