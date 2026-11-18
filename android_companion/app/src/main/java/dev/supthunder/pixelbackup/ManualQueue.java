package dev.supthunder.pixelbackup;

/** In-memory estimates based solely on counts the user sees in Google Photos. */
final class ManualQueue {
    private static final long MIN_SAMPLE_INTERVAL_MILLIS = 30_000L;
    private static final long MAX_SAMPLE_AGE_MILLIS = 5 * 60_000L;
    private static final long UNKNOWN = -1L;

    private long observedAtMillis = UNKNOWN;
    private int remaining = -1;
    private long estimateMillis = UNKNOWN;

    /** Pass elapsed realtime from the same monotonic clock to record and snapshot. */
    void record(int count, long nowMillis) {
        if (count < 0 || nowMillis < 0) {
            throw new IllegalArgumentException("The remaining count and elapsed time must be nonnegative.");
        }

        estimateMillis = UNKNOWN;
        if (observedAtMillis != UNKNOWN && nowMillis >= observedAtMillis) {
            long interval = nowMillis - observedAtMillis;
            if (count > 0 && count < remaining
                    && interval >= MIN_SAMPLE_INTERVAL_MILLIS && interval <= MAX_SAMPLE_AGE_MILLIS) {
                int completed = remaining - count;
                estimateMillis = (count * interval + completed - 1L) / completed;
            }
        }
        remaining = count;
        observedAtMillis = nowMillis;
    }

    Snapshot snapshot(long nowMillis) {
        if (observedAtMillis == UNKNOWN) {
            return new Snapshot(false, false, -1, UNKNOWN, UNKNOWN);
        }
        if (nowMillis < observedAtMillis) {
            return new Snapshot(true, true, remaining, UNKNOWN, UNKNOWN);
        }

        long age = nowMillis - observedAtMillis;
        boolean stale = age > MAX_SAMPLE_AGE_MILLIS;
        long estimate = !stale && estimateMillis > age ? estimateMillis : UNKNOWN;
        return new Snapshot(true, stale, remaining, age, estimate);
    }

    void clear() {
        observedAtMillis = UNKNOWN;
        remaining = -1;
        estimateMillis = UNKNOWN;
    }

    static final class Snapshot {
        public final boolean hasObservation;
        public final boolean stale;
        public final int remaining;
        public final long ageMillis;
        /** Estimated duration at the last count, or -1 when no estimate can be shown. */
        public final long etaMillis;

        private Snapshot(boolean hasObservation, boolean stale, int remaining, long ageMillis, long etaMillis) {
            this.hasObservation = hasObservation;
            this.stale = stale;
            this.remaining = remaining;
            this.ageMillis = ageMillis;
            this.etaMillis = etaMillis;
        }
    }
}
