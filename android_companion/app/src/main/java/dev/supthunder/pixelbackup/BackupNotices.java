package dev.supthunder.pixelbackup;

import java.util.Arrays;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Only the English backup-specific fields understood by this version of the companion. */
final class BackupNotices {
    private BackupNotices() {}

    enum Channel { BACKUP, PROGRESS, OTHER }

    static final class Reading {
        final PhotosNotifications.State state;
        final int remaining;

        Reading(PhotosNotifications.State state, int remaining) {
            this.state = state;
            this.remaining = remaining;
        }
    }

    private static final String QUANTITY = "(0|[1-9][0-9]{0,9}|[1-9][0-9]{0,2}(?:,[0-9]{3}){1,3}) ";
    private static final String REMAINING = "(?:left|remaining)(?: to (?:back up|backup))?|to upload|pending upload";
    private static final Pattern ITEMS = Pattern.compile(QUANTITY + "(item|items) (?:" + REMAINING + ")");
    private static final Pattern SUBSET = Pattern.compile(QUANTITY + "(photo|photos|video|videos) (?:" + REMAINING + ")");
    private static final Pattern UPLOADING = Pattern.compile("uploading " + QUANTITY + "(item|items|video|videos)");
    private static final Pattern UNRELATED_CHANNEL = Pattern.compile(
            "(?:^|[^a-z0-9])(?:shar(?:e|ed|ing)|downloads?|memories|social|comments?|messages?|people|promotions?|miscellaneous|default)(?:$|[^a-z0-9])");

    // A source with a different ID can still supply an explicit backup channel label via Ranking.
    static boolean backupChannel(String channel) {
        return "backup".equals(channel) || "photos_backup".equals(channel)
                || "auto_backup".equals(channel) || "autobackup".equals(channel)
                || "backup_status".equals(channel)
                || "com.google.android.apps.photos.backup".equals(channel);
    }

    static Channel rankedChannel(String id, CharSequence name) {
        if (!canUseChannelName(id)) return Channel.OTHER;
        String label = field(name);
        if ("backup".equals(label) || "backup status".equals(label) || "backup progress".equals(label)
                || "backup & sync".equals(label) || "backup and sync".equals(label)
                || "back up & sync".equals(label) || "back up and sync".equals(label)) return Channel.BACKUP;
        return "progress".equals(label) ? Channel.PROGRESS : Channel.OTHER;
    }

    static boolean canUseChannelName(String channel) {
        return channel != null && !channel.isEmpty() && channel.length() <= 180
                && !UNRELATED_CHANNEL.matcher(channel.toLowerCase(Locale.ROOT)).find();
    }

    static Reading parse(Locale locale, Channel channel, CharSequence title, CharSequence text,
                         CharSequence bigText) {
        if (locale == null || !"en".equals(locale.getLanguage()) || channel == Channel.OTHER) return null;
        String heading = field(title);
        if (heading == null || heading.isEmpty()) return null;
        String detail = field(text);
        String expanded = field(bigText);
        if (detail == null || expanded == null) return null;
        if (detail.isEmpty()) detail = expanded;
        if (!expanded.isEmpty() && !expanded.equals(detail)) return null;

        if (heading.equals("google photos")) {
            heading = detail;
            detail = "";
        }
        int count = -1;
        // The English resources of Photos 8.1 include this bullet and the two spellings of "back up".
        boolean inlineBullet = heading.startsWith("backing up \u2022 ");
        for (String prefix : new String[]{"backing up \u2022 ", "backing up: ", "backing up... "}) {
            if (heading.startsWith(prefix)) {
                count = quantity(ITEMS, heading.substring(prefix.length()));
                if (count < 0) return null;
                heading = "backing up";
                break;
            }
        }
        int detailCount = quantity(ITEMS, detail);
        if (channel == Channel.PROGRESS) {
            // Photos also uses the generic label "Progress". Require an explicit backup and remaining count.
            if (inlineBullet && (detail.isEmpty() || count == detailCount)) return new Reading(PhotosNotifications.State.BACKING_UP, count);
            if (heading.equals("backing up photos") && detailCount >= 0) return new Reading(PhotosNotifications.State.BACKING_UP, detailCount);
            return null;
        }
        if (quantity(UPLOADING, heading) >= 0) heading = "backing up";
        switch (heading) {
            case "backing up":
            case "backing up...":
            case "backing up photos":
            case "backing up photos and videos":
            case "backup in progress":
                if (!detail.isEmpty()) {
                    if (detailCount >= 0) {
                        if (count >= 0 && count != detailCount) return null;
                        count = detailCount;
                    } else if (count >= 0 || (quantity(UPLOADING, detail) < 0 && quantity(SUBSET, detail) < 0)) {
                        return null;
                    }
                }
                return new Reading(PhotosNotifications.State.BACKING_UP, count);
            case "backup paused":
                if (!detail.isEmpty() && !detail.equals("waiting for wi-fi")
                        && !detail.equals("waiting for connection")) return null;
                return new Reading(PhotosNotifications.State.PAUSED, -1);
            case "backup complete":
                if (!detail.isEmpty()) return null;
                return new Reading(PhotosNotifications.State.COMPLETE, -1);
            default:
                return null;
        }
    }

    private static String field(CharSequence input) {
        if (input == null) return "";
        // Restrict layout, integer digits and punctuation before interpreting any text.
        if (input.length() > 128) return null;
        StringBuilder result = new StringBuilder(input.length());
        for (int i = 0; i < input.length(); i++) {
            char ch = input.charAt(i);
            if (ch == '\u00a0' || ch == '\u202f') result.append(' ');
            else if (ch == '\u2011') result.append('-');
            else if (ch == '\u2022') result.append(ch);
            else if (ch == '\u2026') result.append("...");
            else if (ch >= 0x20 && ch <= 0x7e) result.append(ch);
            else return null;
        }
        return result.toString().trim().toLowerCase(Locale.ROOT);
    }

    private static int quantity(Pattern pattern, String field) {
        Matcher match = pattern.matcher(field);
        if (!match.matches()) return -1;
        try {
            int count = Integer.parseInt(match.group(1).replace(",", ""));
            boolean singular = !match.group(2).endsWith("s");
            return (count == 1) == singular ? count : -1;
        } catch (NumberFormatException tooLarge) {
            return -1;
        }
    }

    /** Converts the OS posting wall time once. Unknown or pre-boot timing cannot seed an ETA. */
    static long elapsedPostTime(long postedWall, long nowWall, long nowElapsed) {
        if (postedWall <= 0 || nowWall < postedWall || nowElapsed <= 0) return 0;
        long age = nowWall - postedWall;
        return age < nowElapsed ? nowElapsed - age : 0;
    }

    /** The sole active candidate's opaque key and projected fields stay only in process memory. */
    static final class Tracker {
        private byte[] source;
        private byte[] sourceChannel;
        private long nextStream;
        private PhotosNotifications.Snapshot snapshot = new PhotosNotifications.Snapshot(
                false, PhotosNotifications.State.UNAVAILABLE, -1, 0, 0);

        PhotosNotifications.Snapshot snapshot() { return snapshot; }

        void removed(byte[] identity) {
            if (Arrays.equals(source, identity)) clear(true);
        }

        PhotosNotifications.Snapshot clear(boolean connected) {
            source = null;
            sourceChannel = null;
            if (snapshot.connected != connected || snapshot.state != PhotosNotifications.State.UNAVAILABLE) {
                snapshot = new PhotosNotifications.Snapshot(connected, PhotosNotifications.State.UNAVAILABLE, -1, 0, 0);
            }
            return snapshot;
        }

        PhotosNotifications.Snapshot accept(byte[] identity, byte[] channel, Reading reading, long postedElapsed) {
            boolean sameStream = Arrays.equals(source, identity) && Arrays.equals(sourceChannel, channel)
                    && snapshot.state == reading.state;
            if (sameStream && snapshot.remaining == reading.remaining) return snapshot;
            long stream = sameStream ? snapshot.streamId : ++nextStream;
            source = identity;
            sourceChannel = channel;
            snapshot = new PhotosNotifications.Snapshot(true, reading.state, reading.remaining, postedElapsed, stream);
            return snapshot;
        }
    }
}
