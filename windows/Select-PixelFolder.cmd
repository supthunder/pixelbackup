@echo off
setlocal DisableDelayedExpansion
set "PIXELBACKUP_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PIXELBACKUP_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PIXELBACKUP_PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Build-PixelBackup.ps1" -InstallDesktopShortcut -Launch
if errorlevel 1 (
    echo Pixel Backup could not start. See the error above.
    pause
    exit /b 1
)
