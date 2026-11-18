#Requires -Version 5.1
<#
.SYNOPSIS
    Upgrade an already paired 2016 Pixel to the duplicate-filtering watcher over USB.
.EXAMPLE
    .\windows\Update-PixelWatcher.ps1 -Adb 'C:\platform-tools\adb.exe'
.NOTES
    Close the PC picker and active Photos previews, unlock the Pixel and use its paired USB cable.
    Run the same command again after an interruption. The existing SMB credential stays on the phone.
#>
param([Parameter(Mandatory)][string]$Adb)

$ErrorActionPreference = 'Stop'
# The first pair identifies the original, hardware-tested f7b02b1 release.
$release = @(
    @{
        File = 'mount_pc_folder.sh'
        Previous = '25f9f7d5c4e6df99c5db1bfd9c2bfbb7c9e2c6d555c755c34fa3dae15f2e6d9f'
        Current = '38f03085221a764d72df5bb7b290e370a2c296161bba93f66f872a82ab3ddb2d'
    },
    @{
        File = 'watch_pc_folders.sh'
        Previous = '7807699769c07b2a5ab16e24550e2c813b0eaf6cd9090199e2373da1795df7a1'
        Current = '4d70419c7d3ab1b61adbc4ec021673bc2f25f82b48822a2c6eabdc62f2215f7c'
    }
)
foreach ($entry in $release) {
    $source = Join-Path (Join-Path $PSScriptRoot '..\android_client') $entry.File
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.Current) {
        throw "The local $($entry.File) differs from the pinned v2 release. Use the complete release checkout."
    }
    $entry.Payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
}
. (Join-Path $PSScriptRoot 'PixelWatcherUsb.ps1') -Adb $Adb
if ($mode -ne 'CHECK') { throw 'Pair this Pixel first with Install-PixelWatcher.ps1.' }

$upgrade = @'
set -eu
umask 077
export PATH=/system/bin:/system/xbin
unset LD_PRELOAD
base=/data/adb/pixel-backup
hook=/data/adb/service.d/80-pixel-backup.sh
tx=$base/.watcher-update-v2
marker=$base/.watcher-update-v2.pending
starter=$base/start_pc_watcher.sh
boot_lock=/mnt/.pixel-backup-boot.lock
watch_lock=/mnt/.pixel-backup-watcher.lock
mount_lock=/mnt/.pixel-backup-folder.lock
old_mount=__OLD_MOUNT__
old_watch=__OLD_WATCH__
new_mount=__NEW_MOUNT__
new_watch=__NEW_WATCH__
fail() { echo "Pixel pairing: $*" >&2; exit 1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
digest() { result=$(sha256sum "$1") || return 1; echo "${result%% *}"; }
private_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%g:%a' "$1")" = "0:0:$2" ]; }
private_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%g:%a' "$1")" = '0:0:700' ]; }
protected_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%g' "$1")" = 0:0 ] || return 1
    case "$(stat -c %a "$1")" in *[2367][0-7]|*[2367]) return 1 ;; esac
}
file_id() { stat -L -c '%d:%i' "$1"; }
verified() { private_file "$1" "$2" && [ "$(digest "$1")" = "$3" ]; }
owned_hook() {
    private_file "$hook" 700 || return 1
    case "$(digest "$hook")" in
        e569ef27345984b920476dc6c9a53cff6568868bd6a7c73f11d5db5cec2fe9c7|97dd2f356a5a9a1b7705c5d2fa4d63c841553dd36115eb1daf4b0a336d8c05e5) return 0 ;;
        *) return 1 ;;
    esac
}
__WATCHER_READBACK__

worker_identity() {
    pid=$(watcher_pid) || return 1
    # Only the Magisk starter passes its locked boot descriptor to this worker.
    [ -f "$boot_lock" ] && [ "$(file_id "/proc/$pid/fd/7" 2>/dev/null)" = "$(file_id "$boot_lock")" ] || return 1
    IFS= read -r record <"/proc/$pid/stat" || return 1
    set -- ${record##*) }
    [ "$1" != Z ] && printf '%s %s\n' "$pid" "${20}"
}
quiesce() {
    [ "$locked" -eq 0 ] || return 0
    exec 7>>"$boot_lock" 8>>"$watch_lock"
    if ! flock -n 0 <&8; then
        identity=$(worker_identity) || return 1
        [ "$(worker_identity)" = "$identity" ] || return 1
        kill -TERM "${identity%% *}" || return 1
    fi
    tries=0
    until flock -n 0 <&7 && flock -n 0 <&8; do
        [ "$tries" -lt 30 ] || return 1
        sleep 1
        tries=$((tries + 1))
    done
    locked=1
}
start_worker() {
    exec 7>&- 8>&-
    locked=0
    /system/bin/sh "$starter" 5>&- 6>&- 7>&- 8>&- || return 1
    tries=0
    until worker_identity >/dev/null; do
        [ "$tries" -lt 20 ] || return 1
        sleep 1
        tries=$((tries + 1))
    done
}

[ "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)" ] || fail 'Enter the global mount namespace for the USB update.'
exec 5>>/mnt/.pixel-backup-pair.lock
flock -n 0 <&5 || fail 'Another Pixel pairing or update is in progress.'
protected_dir /data/adb && protected_dir /data/adb/service.d && private_dir "$base" && private_dir "$base/bin" && private_file "$base/.pairing-receipt" 600 &&
    private_file "$base/rclone.conf" 600 || fail 'The original private pairing receipt or configuration is missing.'
{
    IFS= read -r format && IFS= read -r config_sha && IFS= read -r proof && ! IFS= read -r extra && [ -z "${extra:-}" ]
} <"$base/.pairing-receipt" || fail 'The pairing receipt format differs from the original installation.'
case "$proof" in ''|*[!0-9a-f]*) fail 'The pairing receipt is invalid.' ;; esac
[ "$format" = pixel-backup-v1 ] && [ "${#proof}" -eq 64 ] &&
    [ "$config_sha" = "$(digest "$base/rclone.conf")" ] || fail 'The original pairing configuration differs from its receipt.'
unset proof
verified "$starter" 700 d7e30481f3bf2a09c6af11b3b5722d8effe3ccb511f8a68b31d75775d80ede3b &&
    owned_hook &&
    verified "$base/bin/rclone" 700 2a99217da4e2e19c737fcc2cb42b41c3f679720aba12371684d498cab96e055e &&
    verified "$base/bin/fusermount3" 700 1b9dcc24088a2643cae4b2d723c5e9fe384dec74a49f562f1a2f789b5e1dac8c ||
    fail 'The existing boot launcher, boot hook or verified tools differ from the paired release.'
private_file "$base/mount_pc_folder.sh" 700 && private_file "$base/watch_pc_folders.sh" 700 ||
    fail 'One of the original private watcher scripts is missing or has unexpected permissions.'
mount_sha=$(digest "$base/mount_pc_folder.sh")
watch_sha=$(digest "$base/watch_pc_folders.sh")
guard_text() { printf '#!/system/bin/sh\n# Pixel Backup update pending. Run Update-PixelWatcher.ps1 to finish.\nexit 0\n'; }
guard_sha=$(guard_text | sha256sum)
guard_sha=${guard_sha%% *}
legacy_guard_sha=4825e5ffc363ea46a4471d32c391d753fb601ca8f97a505ebe7a79a12b2a31a2
pending=0
if exists "$marker"; then
    private_file "$marker" 700 && [ "$(file_id "$marker")" = "$(file_id "$starter")" ] ||
        fail 'The update marker belongs to a different installation.'
    pending=1
    case "$mount_sha" in "$old_mount"|"$new_mount") ;; *) fail 'The mount helper is outside the recorded update.' ;; esac
    case "$watch_sha" in "$old_watch"|"$new_watch"|"$guard_sha"|"$legacy_guard_sha") ;; *) fail 'The watcher is outside the recorded update.' ;; esac
else
    ! exists "$tx" || fail 'An unrelated directory occupies the update workspace.'
    case "$mount_sha/$watch_sha" in "$old_mount/$old_watch"|"$new_mount/$new_watch") ;;
        *) fail 'The installed scripts do not match a supported complete release.' ;; esac
fi
if exists "$tx"; then
    private_dir "$tx" || fail 'Unexpected update workspace permissions.'
    for path in "$tx"/* "$tx"/.[!.]* "$tx"/..?*; do
        exists "$path" || continue
        case "${path##*/}" in old.mount|old.watch|new.mount|new.watch|guard|publish) ;;
            *) fail 'Unexpected file in the private update workspace.' ;; esac
        private_file "$path" 700 || private_file "$path" 600 || fail 'Unexpected staged file type or permissions.'
    done
fi
complete=0
if [ "$mount_sha/$watch_sha" = "$new_mount/$new_watch" ]; then complete=1; fi
if [ "$complete:$pending" = 1:0 ] && worker_identity >/dev/null; then echo CURRENT; exit 0; fi

# Hold the mount lock through startup verification. A share selected halfway
# through an upgrade cannot begin a new read on either version of the helper.
exec 6>>"$mount_lock"
flock -n 0 <&6 || fail 'A folder mount is active. Close the PC picker and let the Pixel detach first.'
if grep -Eq ' /(mnt/runtime/(default|read|write|full)/emulated/0/PixelBackup|storage/emulated/0/PixelBackup|mnt/pixel-backup\.[^ /]+) | - fuse(\.rclone)? pixelbackup-' /proc/self/mountinfo; then
    fail 'Android still has a PixelBackup mount. Detach it before updating.'
fi
locked=0
clear_transaction() {
    if exists "$tx"; then
        rm -f "$tx/old.mount" "$tx/old.watch" "$tx/new.mount" "$tx/new.watch" "$tx/guard" "$tx/publish" && rmdir "$tx" || return 1
    fi
    rm -f "$marker"
}
if [ "$complete" -eq 1 ]; then
    if worker_identity >/dev/null || { quiesce && start_worker; }; then
        if [ "$pending" -eq 1 ]; then clear_transaction || fail 'Could not finish cleanup of the verified update.'; fi
        echo CURRENT
        exit 0
    fi
    [ "$pending" -eq 1 ] || fail 'The v2 files are present but the owned watcher could not be verified.'
fi
if [ -f "$watch_lock" ] && ! flock -n 0 <"$watch_lock"; then
    worker_identity >/dev/null || fail 'A different watcher owns the lock. End that session before updating.'
fi
created_transaction=0
discard_unpublished() {
    if [ "$created_transaction" -eq 1 ] && verified "$base/mount_pc_folder.sh" 700 "$old_mount" &&
        verified "$base/watch_pc_folders.sh" 700 "$old_watch"; then clear_transaction; fi
}
trap 'discard_unpublished' EXIT
if [ "$pending" -eq 0 ]; then ln "$starter" "$marker"; created_transaction=1; fi
if ! exists "$tx"; then mkdir "$tx"; fi
save_previous() {
    if ! exists "$tx/old.$1"; then verified "$base/$2" 700 "$3" && ln "$base/$2" "$tx/old.$1" || return 1; fi
    verified "$tx/old.$1" 700 "$3"
}
save_previous mount mount_pc_folder.sh "$old_mount" && save_previous watch watch_pc_folders.sh "$old_watch" ||
    fail 'The recoverable original scripts do not match the previous release.'
# An interrupted publish may leave a candidate hard-linked to the installed
# script. Unlink the private name before writing a fresh candidate.
rm -f "$tx/new.mount" "$tx/new.watch" "$tx/guard"
base64 -d >"$tx/new.mount" <<'MOUNT'
__MOUNT_PAYLOAD__
MOUNT
base64 -d >"$tx/new.watch" <<'WATCH'
__WATCH_PAYLOAD__
WATCH
guard_text >"$tx/guard"
chmod 700 "$tx/new.mount" "$tx/new.watch" "$tx/guard"
verified "$tx/new.mount" 700 "$new_mount" && verified "$tx/new.watch" 700 "$new_watch" &&
    verified "$tx/guard" 700 "$guard_sha" || fail 'The staged update failed verification.'

# Rename a complete file into place. Keep rollback links usable after every
# rename. The short watcher guard also prevents boot from using a mixed pair.
publish() {
    from=$(file_id "$tx/$1") && to=$(file_id "$base/$2") || return 1
    [ "$from" != "$to" ] || return 0
    rm -f "$tx/publish" && ln "$tx/$1" "$tx/publish" && mv -f "$tx/publish" "$base/$2"
}
armed=0
finish() {
    status=$1
    trap - EXIT
    trap '' HUP INT TERM
    if [ "$armed" -eq 1 ] && [ "$status" -ne 0 ]; then
        if quiesce && publish guard watch_pc_folders.sh && publish old.mount mount_pc_folder.sh &&
            publish old.watch watch_pc_folders.sh && start_worker && clear_transaction; then
            echo 'Pixel pairing: Update failed; the verified previous watcher was restored and restarted.' >&2
        else
            echo 'Pixel pairing: The private update transaction is retained. Close any picker and run Update-PixelWatcher.ps1 again.' >&2
        fi
    elif [ "$status" -ne 0 ]; then discard_unpublished; fi
    exit "$status"
}
trap 'finish $?' EXIT
trap 'exit 1' HUP INT TERM
quiesce || fail 'Could not stop and lock the exact idle paired watcher. Close other watcher sessions and retry.'
armed=1
publish guard watch_pc_folders.sh
publish new.mount mount_pc_folder.sh
publish new.watch watch_pc_folders.sh
verified "$base/mount_pc_folder.sh" 700 "$new_mount" && verified "$base/watch_pc_folders.sh" 700 "$new_watch" ||
    fail 'The published Android scripts failed verification.'
start_worker || fail 'The v2 watcher did not start.'
armed=0
clear_transaction || fail 'The v2 watcher is running; rerun the update to finish cleanup.'
echo UPDATED
'@
$upgrade = $upgrade.Replace('__OLD_MOUNT__', $release[0].Previous).Replace('__NEW_MOUNT__', $release[0].Current)
$upgrade = $upgrade.Replace('__OLD_WATCH__', $release[1].Previous).Replace('__NEW_WATCH__', $release[1].Current)
$upgrade = $upgrade.Replace('__MOUNT_PAYLOAD__', $release[0].Payload).Replace('__WATCH_PAYLOAD__', $release[1].Payload)
$upgrade = $upgrade.Replace('__WATCHER_READBACK__', $watcherReadback)
$result = Invoke-Phone "su -c 'nsenter -t 1 -m -- /system/bin/sh'" (ConvertTo-ShellBytes $upgrade) 180
if ($result -notin @('CURRENT', 'UPDATED')) { throw 'The Pixel returned an unexpected update status.' }
Write-Output 'Verified the running Pixel watcher v2 with duplicate filtering.'
