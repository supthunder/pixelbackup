package dev.supthunder.pixelbackup;

import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.SystemClock;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.function.LongSupplier;

/** On-demand Google Photos Wi-Fi transmit counters on stock 2016 Pixels. */
public final class PhotosTraffic implements AutoCloseable {
    public enum Status {
        OK, DISABLED, PHOTOS_MISSING, ROOT_UNAVAILABLE, COUNTER_UNAVAILABLE, TIMED_OUT
    }

    /** txBytes is the cumulative network-layer total, or -1 when the counter was unavailable. */
    public static final class Sample {
        public final Status status;
        public final long txBytes;
        public final long elapsedRealtimeMillis;

        private Sample(Status status, long txBytes, long elapsedRealtimeMillis) {
            this.status = status;
            this.txBytes = txBytes;
            this.elapsedRealtimeMillis = elapsedRealtimeMillis;
        }
    }

    private static final String PHOTOS = "com.google.android.apps.photos";
    private static final String END = "!end", CLOSED = "!closed", BAD = "!bad";
    private static final long GRANT_SECONDS = 40, SAMPLE_SECONDS = 4;

    // Tag zero already includes each child tag. Sum both counter sets, only on wlan0.
    // Add in base 10^9 so awk's floating point cannot round a large byte counter.
    static final String COUNTER_PROGRAM =
            "NR == 1 { good = ($1 == \"idx\" && $2 == \"iface\" && $3 == \"acct_tag_hex\"" +
            " && $4 == \"uid_tag_int\" && $5 == \"cnt_set\" && $8 == \"tx_bytes\"); next }\n" +
            "$2 == \"wlan0\" && $3 ~ /^0x0+$/ && $4 == uid {\n" +
            "  if ($8 !~ /^[0-9]+$/) { bad = 1; next }\n" +
            "  splitAt = length($8) - 9\n" +
            "  if (splitAt > 0) high += substr($8, 1, splitAt)\n" +
            "  low += substr($8, splitAt > 0 ? splitAt + 1 : 1)\n" +
            "  if (low >= 1000000000) { high++; low -= 1000000000 }\n" +
            "}\n" +
            "END { if (!good || bad) exit 1; if (high) printf \"%.0f%09d\\n\", high, low;" +
            " else printf \"%d\\n\", low }";

    private final PackageManager packages;
    private final LongSupplier elapsedClock;
    private final Object stateLock = new Object();
    private Session current;
    private boolean disposed;

    private static final class Session {
        final ArrayBlockingQueue<String> replies = new ArrayBlockingQueue<>(2);
        volatile boolean closed;
        Process process;
        boolean ready;
    }

    public PhotosTraffic(Context context) {
        this(context.getApplicationContext().getPackageManager(), SystemClock::elapsedRealtime);
    }

    PhotosTraffic(PackageManager packages, LongSupplier elapsedClock) {
        this.packages = packages;
        this.elapsedClock = elapsedClock;
    }

    private Sample sample(Status status, long bytes) {
        return new Sample(status, bytes, elapsedClock.getAsLong());
    }

    /** Call on a worker in direct response to the user's enable action. Only this method starts su. */
    public Sample enable() {
        final Session session;
        synchronized (stateLock) {
            if (disposed) return sample(Status.DISABLED, -1);
            if (current == null) current = new Session();
            session = current;
        }
        synchronized (session) {
            if (session.closed) return sample(Status.DISABLED, -1);
            if (session.ready) return requestSample(session);
            try {
                if (Build.VERSION.SDK_INT != Build.VERSION_CODES.Q ||
                        !("sailfish".equals(Build.DEVICE) || "marlin".equals(Build.DEVICE))) {
                    return end(session, Status.COUNTER_UNAVAILABLE);
                }
                int uid = packages.getApplicationInfo(PHOTOS, 0).uid;
                String[] owners = packages.getPackagesForUid(uid);
                if (uid < android.os.Process.FIRST_APPLICATION_UID || owners == null ||
                        owners.length != 1 || !PHOTOS.equals(owners[0])) {
                    return end(session, Status.COUNTER_UNAVAILABLE);
                }
                synchronized (stateLock) {
                    if (disposed || current != session) return sample(Status.DISABLED, -1);
                    session.process = new ProcessBuilder("su", "-c", command(uid))
                            .redirectError(new File("/dev/null")).start();
                }
                Thread output = new Thread(() -> readReplies(session), "PixelBackup-traffic");
                output.setDaemon(true);
                output.start();
                String hello = session.replies.poll(GRANT_SECONDS, TimeUnit.SECONDS);
                if (hello == null) return end(session, Status.TIMED_OUT);
                if ("UNAVAILABLE".equals(hello)) return end(session, Status.COUNTER_UNAVAILABLE);
                if (!"READY".equals(hello)) return end(session, Status.ROOT_UNAVAILABLE);
                session.ready = true;
                return requestSample(session);
            } catch (PackageManager.NameNotFoundException e) {
                return end(session, Status.PHOTOS_MISSING);
            } catch (IOException | SecurityException e) {
                return end(session, Status.ROOT_UNAVAILABLE);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return end(session, Status.DISABLED);
            }
        }
    }

    /** Sample on a worker. No process starts and no permission prompt opens from a periodic read. */
    public Sample read() {
        final Session session;
        synchronized (stateLock) { session = disposed ? null : current; }
        if (session == null) return sample(Status.DISABLED, -1);
        synchronized (session) {
            if (session.closed || !session.ready) return sample(Status.DISABLED, -1);
            return requestSample(session);
        }
    }

    private static String command(int uid) {
        // The only variable in the command is an integer resolved locally for the fixed package.
        return "[ \"$(/system/bin/id -u)\" = 0 ] || exit 1\n" +
                "stats=/proc/net/xt_qtaguid/stats\n" +
                "[ -x /system/bin/awk ] && [ -r \"$stats\" ] && [ -d /sys/class/net/wlan0 ]" +
                " || { echo UNAVAILABLE; exit 1; }\n" +
                "echo READY\n" +
                "while IFS= read -r request && [ \"$request\" = R ]; do\n" +
                "  [ -d /sys/class/net/wlan0 ] && /system/bin/awk -v uid=" + uid + " '" + COUNTER_PROGRAM +
                "' \"$stats\" || { echo UNAVAILABLE; exit 1; }\n" +
                "done";
    }

    private Sample requestSample(Session session) {
        try {
            OutputStream input = session.process.getOutputStream();
            input.write('R');
            input.write('\n');
            input.flush();
            String line = session.replies.poll(SAMPLE_SECONDS, TimeUnit.SECONDS);
            if (line == null) return end(session, Status.TIMED_OUT);
            if (END.equals(line)) return end(session, Status.ROOT_UNAVAILABLE);
            long bytes = Long.parseLong(line);
            if (bytes < 0) return end(session, Status.COUNTER_UNAVAILABLE);
            return session.closed ? sample(Status.DISABLED, -1) : sample(Status.OK, bytes);
        } catch (NumberFormatException e) {
            return end(session, Status.COUNTER_UNAVAILABLE);
        } catch (IOException e) {
            return end(session, Status.ROOT_UNAVAILABLE);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return end(session, Status.DISABLED);
        }
    }

    private static void readReplies(Session session) {
        try (BufferedInputStream input = new BufferedInputStream(session.process.getInputStream(), 128)) {
            StringBuilder line = new StringBuilder(24);
            int value;
            while (!session.closed && (value = input.read()) != -1) {
                if (value == '\n') {
                    if (!session.replies.offer(line.toString())) {
                        session.replies.clear();
                        session.replies.offer(BAD);
                        break;
                    }
                    line.setLength(0);
                } else if (value >= 32 && value <= 126 && line.length() < 24) {
                    line.append((char) value);
                } else {
                    session.replies.offer(BAD);
                    break;
                }
            }
        } catch (IOException ignored) {
            // A closed pipe, including a revoked root session, wakes the waiting worker below.
        } finally {
            session.replies.offer(END);
        }
    }

    private Sample end(Session session, Status reason) {
        final Process process;
        synchronized (stateLock) {
            if (current != session) return sample(Status.DISABLED, -1);
            current = null;
            session.closed = true;
            process = session.process;
        }
        session.replies.clear();
        session.replies.offer(CLOSED);
        if (process != null) {
            // EOF also ends the privileged shell if the Magisk proxy is closed during authorization.
            try { process.getOutputStream().close(); } catch (IOException ignored) { }
            process.destroyForcibly();
        }
        return sample(reason, -1);
    }

    /** Permanently seals this instance, including an enable action still queued on its worker. */
    @Override public void close() {
        final Session session;
        synchronized (stateLock) {
            disposed = true;
            session = current;
        }
        if (session != null) end(session, Status.DISABLED);
    }
}
