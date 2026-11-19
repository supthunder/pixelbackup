# TODO

## Back up directly from a USB drive

Copy a photo folder onto a USB drive on Windows, eject it, and plug it into the Pixel. Google Photos should read the originals from the drive and back them up over Wi-Fi, even with the PC turned off. Only the selected folder needs to appear in the phone’s shared storage.

Vivek Revankar (@master-hax) documented this mount on a rooted 2016 Pixel running stock Android 10. It uses the stock kernel. This project has verified uploads from a Windows share on that build. The next milestone is a backup from a disk physically plugged into the phone. [Upstream USB guide](https://github.com/master-hax/pixel-backup-gang/blob/7c7c311/docs/EXTERNAL_DRIVES.md) · [Existing hardware tests](docs/STORAGE_REVIEW.md#on-device-result)

### Prove it on one drive

- [ ] **Try a FAT32 flash drive first.** From Windows, put a fresh JPEG and a short MP4 under `the_binding`, including one in a subfolder. Keep the originals on the PC. Test a USB-C OTG adapter, then check that a powered dock can charge the Pixel and keep the drive connected throughout an upload. FAT32’s limit is 4 GiB minus one byte per file.
- [ ] **Find the simplest path Photos can read.** Check whether Photos already offers the removable folder for backup. If needed, mount just `the_binding` at `/storage/emulated/0/the_binding` as upstream does. Confirm Android indexes both files, their hashes match the drive, and Photos sees one copy of each. Keep SELinux enforcing.
- [ ] **Verify the cloud copies.** Enable backup for the test folder in the intended account, with the PC disconnected. For both items, check **Backed up**, **Original quality**, and whether Photos reports zero account storage used. Eject the drive and reopen both items from that account on another device. [Google Photos backup checks](https://support.google.com/photos/answer/6193313?co=GENIE.Platform%3DAndroid&hl=en)
- [ ] **Measure internal flash writes.** Compare `userdata` bytes written during a large video backup with an idle interval of similar duration. Allow for delayed writes and check for a full-size temporary copy. Thumbnails, indexes and caches can still generate writes. Then try a batch larger than the phone’s free space and recheck the drive’s file hashes. [Flash measurement notes](docs/STORAGE_REVIEW.md#what-google-documents)

### Make it work without a terminal

- [ ] **Add a USB source to the Android companion.** Let the owner choose a drive and folder once. Recognize the volume by UUID after unlock or reconnect, present a read-only view to Photos, and request a scan when new files arrive. Keep the Windows share at its own path. Show the drive name and mount status beside the existing Photos meter.
- [ ] **Handle eject and interruptions.** Release Photos’ view, then eject the underlying volume before showing “Safe to unplug.” Test a busy file, a pulled cable, a different drive and a reboot. If the drive disappears, pause immediately so incoming files cannot land in the empty mount folder on internal flash.
- [ ] **Support large videos.** Test a video over 4 GiB from a dedicated ext4 drive with SELinux enforcing and the source permissions intact. The bundled legacy helper changes permissions and disables enforcement. Evaluate exFAT separately for Windows users on this exact build. [Docked-drive notes](docs/STORAGE_REVIEW.md#using-a-docked-drive)
- [ ] **Later, feed the dock from Windows.** Let the PC send a folder while the drive stays attached to the Pixel. Write partial files outside the indexed folder on that same drive, then move them into view once complete. A missing or full drive must pause the transfer and preserve the PC originals.
