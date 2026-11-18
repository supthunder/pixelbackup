package dev.supthunder.pixelbackup;

import android.app.Notification;
import android.app.NotificationChannel;
import android.content.res.Configuration;
import android.os.Bundle;
import android.os.Process;
import android.os.SystemClock;
import android.os.UserHandle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.concurrent.CopyOnWriteArrayList;

/** Optional, process-local projection of an active Google Photos backup notification. */
public class PhotosNotifications extends NotificationListenerService {
    public enum State { UNAVAILABLE, BACKING_UP, PAUSED, COMPLETE }

    public static final class Snapshot {
        public final boolean connected;
        public final State state;
        /** Items left in the reported Photos backup job, or -1 without an explicit count. */
        public final int remaining;
        /** elapsedRealtime of the last distinct observation. Zero means its time is unknown. */
        public final long observedElapsedMs;
        /** Opaque continuity token. Zero means there is no attributable active source. */
        public final long streamId;

        Snapshot(boolean connected, State state, int remaining, long observedElapsedMs, long streamId) {
            this.connected = connected;
            this.state = state;
            this.remaining = remaining;
            this.observedElapsedMs = observedElapsedMs;
            this.streamId = streamId;
        }
    }

    private static final String PHOTOS = "com.google.android.apps.photos";
    private static final BackupNotices.Tracker TRACKER = new BackupNotices.Tracker();
    private static final CopyOnWriteArrayList<Runnable> LISTENERS = new CopyOnWriteArrayList<>();
    private static volatile Snapshot current = TRACKER.snapshot();
    // Android 10 delivers service lifecycle and notification callbacks on the main thread.
    private static PhotosNotifications activeService;

    public static Snapshot snapshot() { return current; }

    /** Change callbacks run on the main thread. Read snapshot() for the initial value. */
    public static void addListener(Runnable listener) { LISTENERS.addIfAbsent(listener); }

    public static void removeListener(Runnable listener) { LISTENERS.remove(listener); }

    @Override public void onListenerConnected() {
        super.onListenerConnected();
        activeService = this;
        TRACKER.clear(false);
        refresh();
    }

    @Override public void onListenerDisconnected() {
        disconnect();
        super.onListenerDisconnected();
    }

    @Override public void onDestroy() {
        disconnect();
        super.onDestroy();
    }

    @Override public void onNotificationPosted(StatusBarNotification notice) {
        if (activeService == this && forOwnerPhotos(notice)) refresh();
    }

    @Override public void onNotificationRemoved(StatusBarNotification notice) {
        if (activeService == this && forOwnerPhotos(notice)) {
            // The same key may already have been re-posted by the time this callback arrives.
            if (notice.getKey() != null) TRACKER.removed(opaqueKey(notice.getKey()));
            refresh();
        }
    }

    @Override public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        if (activeService == this) refresh();
    }

    private void disconnect() {
        if (activeService == this) {
            activeService = null;
            publish(TRACKER.clear(false));
        }
    }

    private static void publish(Snapshot next) {
        if (current == next) return;
        current = next;
        for (Runnable listener : LISTENERS) listener.run();
    }

    private static boolean forOwnerPhotos(StatusBarNotification notice) {
        // A delegated replacement also invalidates an earlier directly posted Photos record.
        return notice != null && PHOTOS.equals(notice.getPackageName())
                && UserHandle.getUserHandleForUid(0).equals(notice.getUser())
                && Process.myUserHandle().equals(notice.getUser());
    }

    private void refresh() {
        Snapshot next;
        try {
            next = readCurrent();
        } catch (RuntimeException unavailable) {
            // Revoked access, an inaccessible record or an unparcelable field supplies no signal.
            next = TRACKER.clear(true);
        }
        publish(next);
    }

    private Snapshot readCurrent() {
        Locale locale = getResources().getConfiguration().getLocales().get(0);
        if (locale == null || !"en".equals(locale.getLanguage())) return TRACKER.clear(true);
        StatusBarNotification[] active = getActiveNotifications();
        if (active == null) return TRACKER.clear(true);
        BackupNotices.Reading reading = null;
        StatusBarNotification source = null;
        for (StatusBarNotification notice : active) {
            if (!forOwnerPhotos(notice) || !PHOTOS.equals(notice.getOpPkg())) continue;
            Notification n = notice.getNotification();
            if (n == null || (n.flags & Notification.FLAG_GROUP_SUMMARY) != 0) continue;
            if (n.category != null && !Notification.CATEGORY_PROGRESS.equals(n.category)
                    && !Notification.CATEGORY_STATUS.equals(n.category)
                    && !Notification.CATEGORY_SERVICE.equals(n.category)) continue;
            BackupNotices.Channel channel = sourceChannel(n.getChannelId(), notice.getKey());
            if (channel == BackupNotices.Channel.OTHER) continue;
            BackupNotices.Reading candidate = n.extras == null ? null : BackupNotices.parse(locale, channel,
                    textField(n.extras, Notification.EXTRA_TITLE), textField(n.extras, Notification.EXTRA_TEXT),
                    textField(n.extras, Notification.EXTRA_BIG_TEXT));
            if (candidate == null && channel == BackupNotices.Channel.PROGRESS) continue;
            // Multiple backup notifications can represent different accounts. Never combine them.
            if (source != null || candidate == null || notice.getKey() == null) return TRACKER.clear(true);
            reading = candidate;
            source = notice;
        }
        if (source == null) return TRACKER.clear(true);
        long posted = BackupNotices.elapsedPostTime(source.getPostTime(), System.currentTimeMillis(),
                SystemClock.elapsedRealtime());
        return TRACKER.accept(opaqueKey(source.getKey()), opaqueKey(source.getNotification().getChannelId()), reading, posted);
    }

    private BackupNotices.Channel sourceChannel(String channelId, String key) {
        if (BackupNotices.backupChannel(channelId)) return BackupNotices.Channel.BACKUP;
        if (key == null || !BackupNotices.canUseChannelName(channelId)) return BackupNotices.Channel.OTHER;
        RankingMap rankings = getCurrentRanking();
        Ranking record = new Ranking();
        if (rankings == null || !rankings.getRanking(key, record)) return BackupNotices.Channel.OTHER;
        NotificationChannel channel = record.getChannel();
        if (channel == null || !channelId.equals(channel.getId())) return BackupNotices.Channel.OTHER;
        return BackupNotices.rankedChannel(channelId, channel.getName());
    }

    @SuppressWarnings("deprecation") // Android 10 has no typed Bundle.get overload.
    private static CharSequence textField(Bundle extras, String key) {
        Object value = extras.get(key);
        if (value == null || value instanceof CharSequence) return (CharSequence) value;
        throw new IllegalArgumentException("Unsupported notification field type");
    }

    private static byte[] opaqueKey(String key) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(key.getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException impossible) {
            throw new AssertionError(impossible);
        }
    }
}
