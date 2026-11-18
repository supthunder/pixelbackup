package dev.supthunder.pixelbackup;

/** A single observer's Photos UID traffic and confirmed Photos queue history. */
public final class TransferEstimates {
    public enum RateState { UNAVAILABLE, MEASURING, ACTIVE, IDLE, STALLED, RESET, GAP }

    public static final class Snapshot {
        public final RateState rateState;
        /** Rounded Photos UID sent bytes per second, or -1 before a rate is available. */
        public final long bytesPerSecond;
        /** Photos Wi-Fi bytes sent since this uninterrupted measurement began, or -1 when unavailable. */
        public final long observedBytes;
        /** Approximate time for the observed Photos queue, or -1 without a recent trend. */
        public final long etaMillis;

        private Snapshot(RateState rateState, long bytesPerSecond, long observedBytes, long etaMillis) {
            this.rateState = rateState;
            this.bytesPerSecond = bytesPerSecond;
            this.observedBytes = observedBytes;
            this.etaMillis = etaMillis;
        }
    }

    private static final long GAP_MS = 30_000;
    private static final long IDLE_MS = 6_000;
    private static final long STALL_MS = 45_000;
    private static final long COUNT_STALE_MS = 45_000;

    private long lastUpdateMs = -1;
    private long activeSinceMs = -1;
    private long sampleMs = -1;
    private long sampleBytes;
    private long firstObservedBytes;
    private long lastObservedBytes;
    private long lastTrafficMs;
    private double smoothedBytesPerSecond = -1;
    private RateState rateState = RateState.UNAVAILABLE;

    private int lastRemaining = -1;
    private long countStream;
    private long lastCountObservationMs;
    private long countStartMs;
    private long lastCountChangeMs;
    private int decreases;
    private double weightedItems;
    private double weightedDurationMs;

    /** Call when the observer, UID, account or backup session changes. */
    public void reset() {
        lastUpdateMs = -1;
        activeSinceMs = -1;
        sampleMs = -1;
        smoothedBytesPerSecond = -1;
        rateState = RateState.UNAVAILABLE;
        lastRemaining = -1;
    }

    /**
     * Use when the count is freshly observed at this time. Supply -1 for unknown
     * bytes or item count. Clear active on pause, completion or loss of the
     * Google Photos backup observation. Call on one polling thread.
     */
    public Snapshot update(long elapsedRealtimeMs, long photosUidTxBytes, boolean active,
                           int confirmedRemainingItems) {
        return updateAt(elapsedRealtimeMs, photosUidTxBytes, active, confirmedRemainingItems, elapsedRealtimeMs, 1);
    }

    /**
     * Use for cached notification snapshots. Both clocks are elapsedRealtime.
     * A zero stream ID or a missing observation time suppresses the queue ETA.
     * Re-reading an old notification does not create another progress sample.
     */
    public Snapshot update(long elapsedRealtimeMs, long photosUidTxBytes, boolean active,
                           int confirmedRemainingItems, long observedElapsedMs, long streamId) {
        return updateAt(elapsedRealtimeMs, photosUidTxBytes, active, confirmedRemainingItems,
                observedElapsedMs > 0 ? observedElapsedMs : -1, streamId);
    }

    private Snapshot updateAt(long elapsedRealtimeMs, long photosUidTxBytes, boolean active,
                              int remaining, long observationMs, long stream) {
        if (elapsedRealtimeMs < 0) {
            reset();
            return new Snapshot(RateState.UNAVAILABLE, -1, -1, -1);
        }
        RateState baseline = RateState.MEASURING;
        if (lastUpdateMs >= 0 && elapsedRealtimeMs < lastUpdateMs) {
            reset();
            baseline = RateState.RESET;
        } else if (lastUpdateMs >= 0 && elapsedRealtimeMs - lastUpdateMs > GAP_MS) {
            reset();
            baseline = RateState.GAP;
        }
        lastUpdateMs = elapsedRealtimeMs;
        if (!active || remaining == 0) activeSinceMs = -1;
        else if (activeSinceMs < 0) activeSinceMs = elapsedRealtimeMs;

        updateRate(elapsedRealtimeMs, photosUidTxBytes, baseline);
        long observedBytes = sampleMs < 0 ? -1 : lastObservedBytes - firstObservedBytes;
        long eta = updateQueue(elapsedRealtimeMs, active, remaining, observationMs, stream);
        return new Snapshot(rateState, Math.round(smoothedBytesPerSecond), observedBytes, eta);
    }

    private void updateRate(long now, long bytes, RateState baseline) {
        if (bytes < 0) {
            sampleMs = -1;
            smoothedBytesPerSecond = -1;
            rateState = RateState.UNAVAILABLE;
            return;
        }
        boolean rolledBack = sampleMs >= 0 && bytes < lastObservedBytes;
        lastObservedBytes = bytes;
        if (sampleMs < 0 || rolledBack) {
            rateState = sampleMs < 0 ? baseline : RateState.RESET;
            sampleMs = lastTrafficMs = now;
            firstObservedBytes = bytes;
            sampleBytes = bytes;
            smoothedBytesPerSecond = -1;
            return;
        }

        long duration = now - sampleMs;
        // Keep bytes for the next measurement if two UI reads occurred very close together.
        if (duration < 1_000) {
            if (rateState == RateState.STALLED && activeSinceMs < 0) rateState = RateState.IDLE;
            return;
        }
        long transferred = bytes - sampleBytes;
        sampleMs = now;
        sampleBytes = bytes;
        if (transferred == 0 && (smoothedBytesPerSecond <= 0 || now - lastTrafficMs >= IDLE_MS)) {
            smoothedBytesPerSecond = 0;
            boolean stalled = activeSinceMs >= 0 && now - Math.max(activeSinceMs, lastTrafficMs) >= STALL_MS;
            rateState = stalled ? RateState.STALLED : RateState.IDLE;
            return;
        }
        double instantaneous = transferred * 1_000.0 / duration;
        // An eight-second time constant gives irregular polling intervals consistent weight.
        double weight = -Math.expm1(-duration / 8_000.0);
        smoothedBytesPerSecond = smoothedBytesPerSecond <= 0 ? instantaneous
                : smoothedBytesPerSecond + weight * (instantaneous - smoothedBytesPerSecond);
        if (transferred > 0) lastTrafficMs = now;
        rateState = RateState.ACTIVE;
    }

    private long updateQueue(long now, boolean active, int remaining, long observed, long stream) {
        if (!active || remaining <= 0 || stream == 0 || observed < 0 || observed > now
                || now - observed >= COUNT_STALE_MS) {
            lastRemaining = -1;
            return -1;
        }
        if (lastRemaining < 0 || stream != countStream || remaining > lastRemaining
                || now - lastCountChangeMs >= COUNT_STALE_MS || observed < lastCountObservationMs
                || (remaining < lastRemaining && observed <= lastCountChangeMs)) {
            lastRemaining = remaining;
            countStream = stream;
            lastCountObservationMs = observed;
            // A fresh observer cannot attribute earlier time to this measurement.
            countStartMs = lastCountChangeMs = now;
            decreases = 0;
            weightedItems = weightedDurationMs = 0;
            return -1;
        }
        lastCountObservationMs = observed;
        if (remaining < lastRemaining) {
            long duration = observed - lastCountChangeMs;
            // Weight recent completed items more heavily when the size mix changes.
            double keep = Math.exp(-duration / 60_000.0);
            weightedItems = keep * weightedItems + (lastRemaining - remaining);
            weightedDurationMs = keep * weightedDurationMs + duration;
            lastRemaining = remaining;
            lastCountChangeMs = observed;
            decreases++;
        }
        if (decreases < 2 || lastCountChangeMs - countStartMs < 10_000) return -1;
        return (long) Math.ceil(remaining * weightedDurationMs / weightedItems);
    }
}
