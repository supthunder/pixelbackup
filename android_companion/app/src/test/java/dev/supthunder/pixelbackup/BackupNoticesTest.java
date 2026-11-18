package dev.supthunder.pixelbackup;

import java.util.Locale;

import org.junit.Test;

import static dev.supthunder.pixelbackup.BackupNotices.Channel.BACKUP;
import static dev.supthunder.pixelbackup.BackupNotices.Channel.OTHER;
import static dev.supthunder.pixelbackup.BackupNotices.Channel.PROGRESS;
import static dev.supthunder.pixelbackup.PhotosNotifications.State.BACKING_UP;
import static dev.supthunder.pixelbackup.PhotosNotifications.State.COMPLETE;
import static dev.supthunder.pixelbackup.PhotosNotifications.State.PAUSED;
import static dev.supthunder.pixelbackup.PhotosNotifications.State.UNAVAILABLE;
import static org.junit.Assert.*;

public final class BackupNoticesTest {
    private static BackupNotices.Reading parse(String title, String text, String expanded) {
        return BackupNotices.parse(Locale.US, BACKUP, title, text, expanded);
    }

    @Test public void readsOnlyExplicitEnglishRemainingItems() {
        assertEquals(1, parse("Backing up", "1 item left", null).remaining);
        assertEquals(1_234, parse("Backing up photos", "1,234 items remaining", null).remaining);
        assertEquals(12, parse("Backing up\u2026 12 items left", null, null).remaining);
        assertEquals(12, parse("Google Photos", "Backing up: 12 items left to back up", null).remaining);
        assertEquals(Integer.MAX_VALUE, parse("Backing up", null, "2,147,483,647 items remaining").remaining);
        assertEquals(2, parse("Backing up", "2\u00a0items\u202fleft", "2 items left").remaining);
    }

    @Test public void countsNeverSupplyCompletionOrAStatusByThemselves() {
        assertEquals(BACKING_UP, parse("Backing up", "0 items left", null).state);
        assertEquals(-1, parse("Backing up", null, null).remaining);
        assertEquals(COMPLETE, parse("Backup complete", null, null).state);
        assertEquals(-1, parse("Backup complete", null, null).remaining);
        assertEquals(PAUSED, parse("Backup paused", "Waiting for Wi\u2011Fi", null).state);
        assertNull(parse("0 items left", null, null));
        assertNull(parse("Backup complete", "Uploading files", null));
        assertNull(parse("Backup paused", "Your friend shared an album", null));
    }

    @Test public void ignoresOtherChannelsLocalesAndNonBackupActivity() {
        for (String unrelated : new String[]{null, "", "sharing", "downloads", "backup_news", "group/backup"}) {
            assertFalse(BackupNotices.backupChannel(unrelated));
            assertNull(BackupNotices.parse(Locale.US, OTHER, "Backup complete", null, null));
            assertNull(BackupNotices.parse(Locale.US, OTHER, "Backing up", "20 items left", null));
        }
        for (Locale unsupported : new Locale[]{null, Locale.ROOT, Locale.FRENCH, Locale.JAPANESE}) {
            assertNull(BackupNotices.parse(unsupported, BACKUP, "Backing up", "1 item left", null));
        }
        assertNull(parse("Sharing photos", "Backup complete", null));
        assertNull(parse("Downloading photos", "12 items left", null));
        assertNull(parse("Google Photos", "8 items left", null));
        assertNull(parse("Backup completed for your shared album", null, null));
    }

    @Test public void acceptsOnlyAnExplicitEnglishBackupChannelLabelForAnOpaqueId() {
        assertTrue(BackupNotices.canUseChannelName("channel_48"));
        assertEquals(BACKUP, BackupNotices.rankedChannel("channel_48", "Backup status"));
        assertEquals(BACKUP, BackupNotices.rankedChannel("channel_48", "BACK UP & SYNC"));
        assertEquals(BACKUP, BackupNotices.rankedChannel("channel_48", "Backup & sync"));
        assertEquals(PROGRESS, BackupNotices.rankedChannel("channel_48", "Progress"));
        assertEquals(OTHER, BackupNotices.rankedChannel("channel_48", "Backup offers"));
        assertEquals(OTHER, BackupNotices.rankedChannel("channel_48", "Download backup"));
        assertEquals(OTHER, BackupNotices.rankedChannel("channel_48", "Sauvegarde"));
        assertEquals(OTHER, BackupNotices.rankedChannel("com.example.photos.sharing", "Progress"));
        assertFalse(BackupNotices.canUseChannelName("com.example.photos.sharing"));
        assertFalse(BackupNotices.canUseChannelName("downloads"));
        assertFalse(BackupNotices.canUseChannelName("default"));
    }

    @Test public void installedPhotos81ResourcesNeedBothBackupWordingAndExplicitCountOnProgressChannel() {
        for (String label : new String[]{"3 items left to backup", "3 items left to back up", "3 items to upload", "3 items pending upload"}) {
            BackupNotices.Reading q = BackupNotices.parse(Locale.US, PROGRESS, "Backing up photos", label, null);
            assertEquals(label, BACKING_UP, q.state);
            assertEquals(label, 3, q.remaining);
        }
        assertEquals(1, BackupNotices.parse(Locale.US, PROGRESS, "Google Photos", "Backing up \u2022 1 item left", null).remaining);
        assertNull(BackupNotices.parse(Locale.US, PROGRESS, "Backing up \u2022 6 items left", "5 items left", null));
        assertNull(BackupNotices.parse(Locale.US, PROGRESS, "Backup complete", null, null));
        assertNull(BackupNotices.parse(Locale.US, PROGRESS, "Uploading 3 items", "3 items left", null));
        assertNull(BackupNotices.parse(Locale.US, PROGRESS, "Downloading photos", "3 items to upload", null));
        assertNull(BackupNotices.parse(Locale.US, PROGRESS, "Backing up photos", "3 videos to upload", null));
        assertNull(BackupNotices.parse(Locale.US, PROGRESS, "Backing up photos", null, null));
    }

    @Test public void uploadSizesAndMediaSubsetsNeverTurnIntoAQueueCount() {
        assertEquals(BACKING_UP, parse("Uploading 12 items", null, null).state);
        assertEquals(-1, parse("Uploading 12 items", null, null).remaining);
        assertEquals(-1, parse("Backing up photos", "Uploading 12 videos", null).remaining);
        assertEquals(-1, parse("Backing up photos", "12 videos to upload", null).remaining);
        assertEquals(-1, parse("Backing up photos", "12 photos left to back up", null).remaining);
        assertNull(parse("Uploading 3 of 12", null, null));
        assertNull(parse("Uploading 1 items", null, null));
    }

    @Test public void rejectsUnlabelledMetricsMalformedCountsAndConflictingFields() {
        String[] unknown = {"", "5 of 10", "48%", "12 MB left", "12 photos", "12 files left",
                "2 item left", "1 items left", "000 items left", "-1 items left", "+2 items left",
                "1.5 items left", "2,00 items left", "22,,000 items left", "2147483648 items left",
                "\u0661 item left", "2 items\nleft", "\u202e1 item left", "1 item left\u0000",
                "1 item left in a shared album"};
        for (String value : unknown) {
            BackupNotices.Reading reading = parse("Backing up", value, null);
            assertTrue(value, reading == null || reading.remaining == -1);
        }
        assertNull(parse("Backing up", "5 items left", "4 items left"));
        assertNull(parse("Backing up: 5 items left", "4 items left", null));
        assertNull(parse("Backing up", new String(new char[129]).replace('\0', 'a'), null));
        assertNull(parse(null, null, null));
    }

    @Test public void numbersOnlyAgeOnDistinctStateAndStreamResetsOnReplacementOrLoss() {
        BackupNotices.Tracker tracker = new BackupNotices.Tracker();
        assertFalse(tracker.snapshot().connected);
        assertEquals(UNAVAILABLE, tracker.clear(true).state);
        byte[] first = {1};
        byte[] channel = {11};
        PhotosNotifications.Snapshot initial = tracker.accept(first, channel, parse("Backing up", "8 items left", null), 100);
        assertNotEquals(0, initial.streamId);
        assertSame(initial, tracker.accept(new byte[]{1}, channel, parse("Backing up", "8 items left", null), 120));
        assertEquals(100, tracker.snapshot().observedElapsedMs);
        PhotosNotifications.Snapshot updated = tracker.accept(first, channel, parse("Backing up", "7 items left", null), 160);
        assertEquals(initial.streamId, updated.streamId);
        assertEquals(160, updated.observedElapsedMs);
        channel = new byte[]{12};
        PhotosNotifications.Snapshot moved = tracker.accept(first, channel, parse("Backing up", "7 items left", null), 170);
        assertNotEquals(updated.streamId, moved.streamId);
        tracker.removed(new byte[]{42});
        assertSame(moved, tracker.snapshot());
        tracker.removed(first);
        PhotosNotifications.Snapshot repost = tracker.accept(first, channel, parse("Backing up", "7 items left", null), 180);
        assertNotEquals(moved.streamId, repost.streamId);
        PhotosNotifications.Snapshot replaced = tracker.accept(new byte[]{2}, channel, parse("Backing up", "7 items left", null), 190);
        assertNotEquals(repost.streamId, replaced.streamId);
        PhotosNotifications.Snapshot paused = tracker.accept(new byte[]{2}, channel, parse("Backup paused", null, null), 210);
        assertNotEquals(replaced.streamId, paused.streamId);
        PhotosNotifications.Snapshot lost = tracker.clear(true); // none, unreadable or ambiguous
        assertTrue(lost.connected);
        assertEquals(UNAVAILABLE, lost.state);
        assertEquals(-1, lost.remaining);
        assertEquals(0, lost.observedElapsedMs);
        assertEquals(0, lost.streamId);
        assertFalse(tracker.clear(false).connected);
        assertNotEquals(paused.streamId, tracker.accept(new byte[]{2}, channel, parse("Backup paused", null, null), 210).streamId);
    }

    @Test public void retainsActualAgeForExistingNotificationAndRejectsUnusablePostingClocks() {
        assertEquals(500, BackupNotices.elapsedPostTime(1500, 1800, 800));
        assertEquals(0, BackupNotices.elapsedPostTime(2000, 1800, 800));
        assertEquals(0, BackupNotices.elapsedPostTime(200, 1800, 800));
        assertEquals(0, BackupNotices.elapsedPostTime(0, 1800, 800));
    }
}
