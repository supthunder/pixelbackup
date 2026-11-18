package dev.supthunder.pixelbackup;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public final class ManualQueueTest {
    @Test public void startsEmptyAndKeepsTheFirstCountWithoutAnEstimate() {
        ManualQueue queue = new ManualQueue();
        ManualQueue.Snapshot empty = queue.snapshot(0L);
        assertFalse(empty.hasObservation);
        assertEquals(-1, empty.remaining);
        assertEquals(-1L, empty.ageMillis);
        assertEquals(-1L, empty.etaMillis);

        queue.record(120, 0L);
        ManualQueue.Snapshot first = queue.snapshot(1_000L);
        assertTrue(first.hasObservation);
        assertFalse(first.stale);
        assertEquals(120, first.remaining);
        assertEquals(1_000L, first.ageMillis);
        assertEquals(-1L, first.etaMillis);
    }

    @Test public void estimatesFromTwoFallingCountsAndDoesNotFakeACountdown() {
        ManualQueue queue = new ManualQueue();
        queue.record(100, 10_000L);
        queue.record(80, 70_000L);

        ManualQueue.Snapshot latest = queue.snapshot(100_000L);
        assertEquals(80, latest.remaining);
        assertEquals(30_000L, latest.ageMillis);
        assertEquals(240_000L, latest.etaMillis);
        assertEquals(-1L, queue.snapshot(310_000L).etaMillis);
    }

    @Test public void suppressesCloselySpacedStalledAndIncreasingSamples() {
        ManualQueue queue = new ManualQueue();
        queue.record(100, 0L);
        queue.record(90, 29_999L);
        assertEquals(-1L, queue.snapshot(29_999L).etaMillis);
        queue.record(85, 59_999L);
        assertEquals(510_000L, queue.snapshot(59_999L).etaMillis);
        queue.record(85, 89_999L);
        assertEquals(-1L, queue.snapshot(89_999L).etaMillis);
        queue.record(100, 119_999L);
        assertEquals(-1L, queue.snapshot(119_999L).etaMillis);
        queue.record(95, 149_999L);
        assertEquals(570_000L, queue.snapshot(149_999L).etaMillis);
    }

    @Test public void oldCountsRemainVisibleWithAgeButDoNotSupportAnEstimate() {
        ManualQueue queue = new ManualQueue();
        queue.record(100, 0L);
        queue.record(99, 300_000L);
        assertEquals(29_700_000L, queue.snapshot(300_000L).etaMillis);
        ManualQueue.Snapshot expired = queue.snapshot(600_001L);
        assertTrue(expired.hasObservation);
        assertTrue(expired.stale);
        assertEquals(99, expired.remaining);
        assertEquals(300_001L, expired.ageMillis);
        assertEquals(-1L, expired.etaMillis);
        queue.record(90, 600_001L);
        assertEquals(-1L, queue.snapshot(600_001L).etaMillis);
    }

    @Test public void zeroDoesNotCreateAnEtaAndClearStartsASeparateQueue() {
        ManualQueue queue = new ManualQueue();
        queue.record(10, 50_000L);
        queue.record(0, 80_000L);
        assertEquals(0, queue.snapshot(80_000L).remaining);
        assertEquals(-1L, queue.snapshot(80_000L).etaMillis);
        queue.clear();
        assertFalse(queue.snapshot(81_000L).hasObservation);
        queue.record(6, 100_000L);
        assertEquals(-1L, queue.snapshot(100_000L).etaMillis);
    }

    @Test public void aBackwardClockCannotMakeAnOldEstimateFresh() {
        ManualQueue queue = new ManualQueue();
        queue.record(100, 40_000L);
        queue.record(90, 70_000L);
        assertTrue(queue.snapshot(10_000L).stale);
        assertEquals(-1L, queue.snapshot(10_000L).etaMillis);
        queue.record(80, 10_000L);
        assertEquals(-1L, queue.snapshot(10_000L).etaMillis);
    }

    @Test public void estimatesLargeCountsWithoutIntegerOverflow() {
        ManualQueue queue = new ManualQueue();
        queue.record(Integer.MAX_VALUE, 0L);
        queue.record(Integer.MAX_VALUE - 1, 300_000L);
        assertEquals(644_245_093_800_000L, queue.snapshot(300_000L).etaMillis);
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsNegativeCounts() {
        new ManualQueue().record(-1, 0L);
    }
}
