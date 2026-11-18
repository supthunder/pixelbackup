# Shared by the two USB commands. Dot-source this after validating local inputs.
param([Parameter(Mandatory)][string]$Adb)
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$adbPath = (Get-Item -LiteralPath $Adb).FullName

function Get-AdbText([string[]]$Arguments) {
    $result = & $adbPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "ADB failed during $($Arguments[0]). Check the USB cable and authorization on the Pixel." }
    ($result -join "`n").Trim()
}

# Pin all later operations to the initial USB transport, even if another
# phone connects, disconnects or reuses its serial during provisioning.
$serial = Get-AdbText @('-d', 'get-serialno')
if ($serial -notmatch '^[A-Za-z0-9_.-]+$' -or $serial -eq 'unknown') { throw 'Connect one authorized physical Pixel over USB.' }
$listing = Get-AdbText @('devices', '-l')
$deviceLine = [regex]::Match($listing, '(?m)^' + [regex]::Escape($serial) + '\s+device\b[^\r\n]*\btransport_id:(\d+)\s*$')
if (-not $deviceLine.Success) { throw 'ADB could not pin the authorized USB device. Update Android Platform Tools and reconnect.' }
$transport = $deviceLine.Groups[1].Value

function Invoke-Phone([string]$Command, [byte[]]$InputBytes, [int]$TimeoutSeconds = 120) {
    # These are fixed command templates. ADB gets one remote command and the
    # stdin bytes directly, independent of PowerShell's native-pipeline encoding.
    if ($Command.Contains('"') -or $Command.Contains("`n")) { throw 'Invalid internal ADB command.' }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $adbPath
    $info.Arguments = "-t $transport shell -T `"$Command`""
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = $info
    try {
        if (-not $p.Start()) { throw 'Could not start USB ADB.' }
        $output = $p.StandardOutput.ReadToEndAsync()
        $errors = $p.StandardError.ReadToEndAsync()
        try {
            if ($InputBytes.Length) { $p.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length) }
        } catch [IO.IOException] {
            # A read-only check can finish (or reject the device) before adb
            # consumes an entire update payload. Inspect its exit status below.
        } finally {
            $p.StandardInput.BaseStream.Close()
        }
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            $p.Kill()
            throw 'The Pixel did not finish the USB operation. Check the phone for a Magisk authorization prompt.'
        }
        $stdout = $output.GetAwaiter().GetResult()
        $stderr = $errors.GetAwaiter().GetResult()
        if ($p.ExitCode -ne 0) {
            # Only our own fixed diagnostics are suitable for printing during credential setup.
            $diagnostic = (($stderr + "`n" + $stdout) -split '\r?\n' | Where-Object { $_ -like 'Pixel pairing: *' } | Select-Object -Last 1)
            if ($diagnostic) { throw $diagnostic }
            throw 'The USB operation failed. Check device connectivity and grant Magisk root to Shell.'
        }
        $stdout.Trim()
    } finally { $p.Dispose() }
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
