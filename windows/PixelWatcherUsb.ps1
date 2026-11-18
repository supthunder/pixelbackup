# Shared by the two USB commands. Dot-source this after validating local inputs.
param([Parameter(Mandatory)][string]$Adb)

function Stop-UsbSetup([string]$Message) {
    # Only call with messages authored here. The GUI never displays raw ADB output.
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['PixelBackupUsbMessage'] = $Message
    throw $exception
}

if ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Stop-UsbSetup 'Close the administrator window and run USB setup from your normal Windows session.'
}
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$toolUnavailable = 'In Setup, open Advanced options and choose Prepare USB tools. Then retry the USB operation.'
try { $adbPath = (Get-Item -LiteralPath $Adb -ErrorAction Stop).FullName } catch { Stop-UsbSetup $toolUnavailable }
$disconnected = 'Reconnect one original Pixel over USB, unlock it, approve USB debugging and retry.'

function Get-UsbFailure([string]$Output) {
    # Match our device-side diagnostics and return fixed, customer-facing text.
    # A device can write anything to either stream, including credential content.
    if ($Output -match '(?m)^Pixel pairing: Update failed; the verified previous watcher was restored') {
        return 'The previous watcher was restored and restarted. Keep the Pixel connected and retry Update backup helper.'
    }
    if ($Output -match '(?m)^Pixel pairing: The private update transaction is retained') {
        return 'The update was interrupted. Stop sharing, keep the Pixel connected and run Update backup helper again to finish recovery.'
    }
    foreach ($line in ($Output -split '\r?\n')) {
        if (-not $line.StartsWith('Pixel pairing: ', [StringComparison]::Ordinal)) { continue }
        switch -Regex ($line.Substring(15)) {
            '^Grant Magisk root|^Expected the Magisk' { return 'On the Pixel, grant Magisk root to Shell, then retry USB setup.' }
            '^Expected (a 2016 Pixel|a physical Google Pixel|the stock Google Android)|^The phone needs enforcing' { return 'Use a rooted 2016 Pixel or Pixel XL running stock Android 10 with enforcing SELinux and FUSE.' }
            '^Unlock the owner profile' { return 'Unlock the owner profile on the Pixel, then retry USB setup.' }
            '^SMB sign-in or share discovery' { return 'The Pixel could not sign in to Windows. Check the PC address, the PixelReader password, file sharing and the private-network firewall.' }
            '^The paired PC, reader credential|^Existing Pixel Backup files have no matching' { return 'The existing Pixel pairing differs. Check that you are using the original PC address and PixelReader password.' }
            '^A folder mount is active|^Android still has a PixelBackup mount' { return 'Stop the current share, close open Photos previews, wait for the Pixel to detach, then update again.' }
            '^Another Pixel pairing|^A different watcher owns|^Could not stop and lock' { return 'Another pairing or watcher session is active. Finish it and retry the USB operation.' }
            '^Could not finish cleanup|^The v2 watcher is running|^The v2 watcher did not start' { return 'The watcher update needs another pass. Leave the Pixel connected and unlocked and run Update backup helper again.' }
            '^The original (private pairing|pairing configuration)|^The pairing receipt|^The existing boot launcher|^The installed scripts do not match|^The update marker|^The recoverable original scripts' { return 'The installed pairing or watcher differs from a supported release. Check the pairing guide before retrying.' }
        }
    }
    'The USB operation was interrupted. Reconnect the Pixel, unlock it, check the Magisk prompt for Shell and retry.'
}

function Invoke-AdbProcess([string[]]$Arguments, [byte[]]$InputBytes, [int]$TimeoutSeconds) {
    # All inputs are fixed ADB/shell tokens or local Windows filenames. Quote
    # each argument for Win32, doubling trailing slashes before its closing quote.
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '["\x00-\x1f]') { throw 'Invalid internal ADB argument.' }
        '"' + ($argument -replace '(\\+)$', '$1$1') + '"'
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $adbPath
    $info.WorkingDirectory = [IO.Path]::GetDirectoryName($adbPath)
    $info.Arguments = $quoted -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = $info
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $limit = $TimeoutSeconds * 1000
    $timeout = 'USB setup timed out. Reconnect the Pixel, check for a USB debugging or Magisk prompt and retry.'
    try {
        try { $started = $p.Start() } catch { Stop-UsbSetup $toolUnavailable }
        if (-not $started) { Stop-UsbSetup $toolUnavailable }
        $output = $p.StandardOutput.ReadToEndAsync()
        $errors = $p.StandardError.ReadToEndAsync()
        try {
            if ($InputBytes.Length) {
                $write = $p.StandardInput.BaseStream.WriteAsync($InputBytes, 0, $InputBytes.Length)
                if (-not $write.Wait($limit)) { $p.Kill(); Stop-UsbSetup $timeout }
            }
        } catch {
            # A device can reject the request before reading its entire payload.
            if ($_.Exception.GetBaseException() -isnot [IO.IOException]) { throw }
        } finally {
            $p.StandardInput.BaseStream.Close()
        }
        if (-not $p.WaitForExit([int][Math]::Max(0L, $limit - $timer.ElapsedMilliseconds))) {
            $p.Kill()
            Stop-UsbSetup $timeout
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($output, $errors), [int][Math]::Max(0L, $limit - $timer.ElapsedMilliseconds))) {
            Stop-UsbSetup $timeout
        }
        $stdout = $output.GetAwaiter().GetResult()
        if ($p.ExitCode -ne 0) {
            if ($Arguments -notcontains 'shell') { Stop-UsbSetup $disconnected }
            Stop-UsbSetup (Get-UsbFailure ($errors.GetAwaiter().GetResult() + "`n" + $stdout))
        }
        $stdout.Trim()
    } finally { $p.Dispose() }
}

# Pin later operations to the same USB transport, including binary pushes.
function Get-AdbText([string[]]$Arguments) {
    $seconds = if ($Arguments -contains 'push') { 180 } else { 15 }
    Invoke-AdbProcess $Arguments @() $seconds
}
$serial = Get-AdbText @('-d', 'get-serialno')
if ($serial -notmatch '^[A-Za-z0-9_.-]+$' -or $serial -eq 'unknown') { Stop-UsbSetup $disconnected }
$listing = Get-AdbText @('devices', '-l')
$deviceLine = [regex]::Match($listing, '(?m)^' + [regex]::Escape($serial) + '\s+device\b[^\r\n]*\btransport_id:(\d+)\s*$')
if (-not $deviceLine.Success) { Stop-UsbSetup $disconnected }
$transport = $deviceLine.Groups[1].Value

function Invoke-Phone([string]$Command, [byte[]]$InputBytes, [int]$TimeoutSeconds = 120) {
    Invoke-AdbProcess @('-t', $transport, 'shell', '-T', $Command) $InputBytes $TimeoutSeconds
}

function ConvertTo-ShellBytes([string]$Text) {
    ,$utf8.GetBytes(($Text.Replace("`r`n", "`n").TrimEnd("`r", "`n")) + "`n")
}

$preflight = @'
set -eu
fail() { echo "Pixel pairing: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] && magisk -V >/dev/null 2>&1 || fail 'Grant Magisk root to the USB Shell.'
device=$(getprop ro.product.device)
case "$device/$(getprop ro.product.model)" in 'sailfish/Pixel'|'marlin/Pixel XL') ;; *) fail 'Expected a 2016 Pixel or Pixel XL.' ;; esac
[ "$(getprop ro.product.brand)" = google ] && [ "$(getprop ro.product.manufacturer)" = Google ] &&
    [ "$(getprop ro.product.cpu.abi)" = arm64-v8a ] && [ "$(getprop ro.build.version.sdk)" = 29 ] &&
    [ "$(getprop ro.kernel.qemu)" != 1 ] && [ "$(getprop ro.boot.qemu)" != 1 ] ||
    fail 'Expected a physical Google Pixel running stock Android 10.'
case "$(getprop ro.build.fingerprint)" in "google/$device/$device:10/"*":user/release-keys") ;; *) fail 'Expected the stock Google Android 10 build fingerprint.' ;; esac
[ "$(getenforce)" = Enforcing ] && [ -c /dev/fuse ] || fail 'The phone needs enforcing SELinux and FUSE.'
[ "$(getprop sys.boot_completed)" = 1 ] && [ "$(am get-current-user)" = 0 ] &&
    [ "$(am get-started-user-state 0)" = RUNNING_UNLOCKED ] || fail 'Unlock the owner profile on the Pixel.'
[ -d /data/adb ] && [ ! -L /data/adb ] && [ "$(stat -c %u /data/adb)" = 0 ] || fail 'Expected the Magisk root data directory.'
if [ -e /data/adb/pixel-backup ] || [ -L /data/adb/pixel-backup ]; then echo CHECK; else echo NEW; fi
'@
$mode = Invoke-Phone 'su -c /system/bin/sh' (ConvertTo-ShellBytes $preflight)
if ($mode -notin @('NEW', 'CHECK')) { throw 'Unexpected response from the rooted Pixel preflight.' }

$watcherReadback = @'
watcher_pid() {
    # Magisk may place this installer in a different namespace. Inspect
    # PID 1's lock and the descriptor the genuine watcher keeps open.
    lock=/proc/1/root/mnt/.pixel-backup-watcher.lock
    [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
    if flock -n 0 <"$lock"; then return 1; fi
    inode=$(stat -L -c '%d:%i' "$lock") || return 1
    global=$(readlink /proc/1/ns/mnt) || return 1
    for pid in $(pgrep -f 'watch_pc_folders[.]sh'); do
        [ "$(stat -c %u "/proc/$pid" 2>/dev/null)" = 0 ] &&
            [ "$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)" = "$global" ] &&
            [ "$(stat -L -c '%d:%i' "/proc/$pid/fd/8" 2>/dev/null)" = "$inode" ] || continue
        args=$(tr '\000' '\n' <"/proc/$pid/cmdline" 2>/dev/null) || continue
        case "$args" in
            "/system/bin/sh
$base/watch_pc_folders.sh"|"sh
$base/watch_pc_folders.sh") echo "$pid"; return 0 ;;
        esac
    done
    return 1
}
watcher_ready() { watcher_pid >/dev/null; }
'@
