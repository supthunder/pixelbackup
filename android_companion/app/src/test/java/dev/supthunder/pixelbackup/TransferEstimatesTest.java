package dev.supthunder.pixelbackup;

import org.junit.Test;

import static dev.supthunder.pixelbackup.TransferEstimates.RateState.*;
import static org.junit.Assert.*;

public class TransferEstimatesTest {
    private final TransferEstimates model = new TransferEstimates();

    @Test public void rateUsesOnlyByteDeltasAndWeightsByActualInterval() {
        assertEquals(-1, model.update(0, 900_000, true, 100).bytesPerSecond);
        assertEquals(MEASURING, model.update(300, 900_500, true, 100).rateState);
        assertEquals(1_000, model.update(4_000, 904_000, true, 100).bytesPerSecond);
        TransferEstimates.Snapshot faster = model.update(8_000, 916_000, true, 100);
        assertEquals(ACTIVE, faster.rateState);
        assertEquals(Math.round(1_000 + (1 - Math.exp(-0.5)) * 2_000), faster.bytesPerSecond);
        assertEquals(-1, faster.etaMillis);
    }

    @Test public void duplicateTimeCannotCreateInfiniteRateOrConsumeNewBytes() {
        model.update(1_000, 100, false, -1);
        assertEquals(MEASURING, model.update(1_000, 600, false, -1).rateState);
        assertEquals(1_000, model.update(2_000, 1_100, false, -1).bytesPerSecond);
    }

    @Test public void rollbackBetweenSubsecondSamplesStillInvalidatesTheRate() {
        model.update(0, 100, false, -1);
        model.update(1_000, 300, false, -1);
        model.update(1_200, 800, false, -1);
        assertEquals(RESET, model.update(1_400, 450, false, -1).rateState);
        assertEquals(100, model.update(2_400, 550, false, -1).bytesPerSecond);
    }

    @Test public void counterRollbackAndMissingObservationsNeedANewBaseline() {
        model.update(0, 10_000, false, -1);
        model.update(1_000, 15_000, false, -1);
        TransferEstimates.Snapshot reset = model.update(2_000, 0, false, -1);
        assertEquals(RESET, reset.rateState);
        assertEquals(-1, reset.bytesPerSecond);
        assertEquals(100, model.update(3_000, 100, false, -1).bytesPerSecond);
        TransferEstimates.Snapshot missing = model.update(4_000, -1, false, -1);
        assertEquals(UNAVAILABLE, missing.rateState);
        assertEquals(-1, missing.bytesPerSecond);
        assertEquals(MEASURING, model.update(5_000, 100_000, false, -1).rateState);
        assertEquals(250, model.update(7_000, 100_500, false, -1).bytesPerSecond);
    }

    @Test public void observedBytesCountOnlyTheCurrentUninterruptedMeasurement() {
        assertEquals(-1, model.update(0, -1, false, -1).observedBytes);
        assertEquals(0, model.update(100, 4_000_000_000L, false, -1).observedBytes);
        assertEquals(256, model.update(300, 4_000_000_256L, false, -1).observedBytes);
        assertEquals(1_024, model.update(2_100, 4_000_001_024L, false, -1).observedBytes);
        TransferEstimates.Snapshot idle = model.update(8_200, 4_000_001_024L, false, -1);
        assertEquals(IDLE, idle.rateState);
        assertEquals(1_024, idle.observedBytes);
        assertEquals(0, model.update(45_000, 5_000_000_000L, false, -1).observedBytes);
        assertEquals(100, model.update(46_000, 5_000_000_100L, false, -1).observedBytes);
        assertEquals(0, model.update(47_000, 800, false, -1).observedBytes);
        assertEquals(75, model.update(48_000, 875, false, -1).observedBytes);
        assertEquals(-1, model.update(49_000, -1, false, -1).observedBytes);
        assertEquals(0, model.update(50_000, 8_000, false, -1).observedBytes);
    }

    @Test public void ordinaryIdleAndAnActiveQueueWithNoRecentTrafficAreDistinct() {
        model.update(0, 100, false, -1);
        model.update(2_000, 300, false, -1);
        assertEquals(ACTIVE, model.update(4_000, 300, false, -1).rateState);
        TransferEstimates.Snapshot idle = model.update(8_000, 300, false, -1);
        assertEquals(0, idle.bytesPerSecond);
        assertEquals(IDLE, idle.rateState);
        model.update(30_000, 300, false, -1);
        assertEquals(IDLE, model.update(50_000, 300, true, 8).rateState);
        model.update(75_000, 300, true, 8);
        assertEquals(STALLED, model.update(95_000, 300, true, 8).rateState);
        assertEquals(IDLE, model.update(95_000, 300, false, -1).rateState);
        assertEquals(ACTIVE, model.update(96_000, 1_300, true, 8).rateState);
    }

    @Test public void rateAndEtaRebaselineAfterClockRollbackOrLongPollGap() {
        ready();
        TransferEstimates.Snapshot gap = model.update(50_001, 50_000, true, 3);
        assertEquals(GAP, gap.rateState);
        assertEquals(-1, gap.bytesPerSecond);
        assertEquals(-1, gap.etaMillis);
        assertEquals(200, model.update(52_001, 50_400, true, 2).bytesPerSecond);
        TransferEstimates.Snapshot earlier = model.update(1_000, 0, true, 3);
        assertEquals(RESET, earlier.rateState);
        assertEquals(-1, earlier.etaMillis);
        assertEquals(-1, earlier.bytesPerSecond);
        assertEquals(UNAVAILABLE, model.update(-1, 70, true, 3).rateState);
    }

    private TransferEstimates.Snapshot ready() {
        assertEquals(-1, model.update(1_000, 0, true, 12).etaMillis);
        assertEquals(-1, model.update(6_000, 10, true, 11).etaMillis);
        TransferEstimates.Snapshot result = model.update(11_000, 80, true, 10);
        assertEquals(50_000, result.etaMillis, 1);
        return result;
    }

    @Test public void etaRequiresRepeatedDropsOverTimeAndToleratesUnknownBytes() {
        model.update(0, -1, true, 50);
        model.update(1_000, -1, true, 40);
        assertEquals(-1, model.update(2_000, -1, true, 30).etaMillis);
        // Time passing with the same count does not extend the span of the progress evidence.
        assertEquals(-1, model.update(11_000, -1, true, 30).etaMillis);
        TransferEstimates.Snapshot progress = model.update(12_000, -1, true, 29);
        assertEquals(UNAVAILABLE, progress.rateState);
        assertTrue(progress.etaMillis > 0);
    }

    @Test public void sameQueueHasSameEtaAcrossDifferentTrafficVolumes() {
        TransferEstimates other = new TransferEstimates();
        TransferEstimates.Snapshot normal = ready();
        other.update(1_000, -1, true, 12);
        other.update(6_000, Long.MAX_VALUE / 2, true, 11);
        assertEquals(normal.etaMillis, other.update(11_000, Long.MAX_VALUE, true, 10).etaMillis);
        assertEquals(-1, new TransferEstimates().update(1_000, Long.MAX_VALUE, true, -1).etaMillis);
    }

    @Test public void queueIncreasePauseEndAndMissingCountImmediatelyHideEta() {
        ready();
        assertEquals(-1, model.update(12_000, 900, true, 15).etaMillis);
        assertEquals(-1, model.update(17_000, 950, true, 14).etaMillis);
        assertTrue(model.update(22_000, 990, true, 13).etaMillis > 0);
        assertEquals(-1, model.update(22_000, 990, false, 13).etaMillis);
        assertEquals(-1, model.update(23_000, 995, true, 9).etaMillis);
        model.update(28_000, 1_000, true, 8);
        assertTrue(model.update(33_000, 1_001, true, 7).etaMillis > 0);
        assertEquals(-1, model.update(34_000, 1_100, true, 0).etaMillis);
        assertEquals(-1, model.update(35_000, 1_110, true, 7).etaMillis);
        model.update(40_000, 1_200, true, 6);
        assertTrue(model.update(45_000, 1_210, true, 5).etaMillis > 0);
        assertEquals(-1, model.update(45_000, 1_210, true, -1).etaMillis);
        assertEquals(-1, model.update(46_000, 1_215, true, 3).etaMillis);
    }

    @Test public void notificationUsesEventTimeAndReplaysDoNotRefreshItsAge() {
        model.update(10_000, 0, true, 12, 9_000, 7);
        model.update(23_000, 100, true, 11, 15_000, 7);
        TransferEstimates.Snapshot actual = model.update(27_000, 200, true, 10, 20_000, 7);
        assertEquals(50_000, actual.etaMillis, 1);
        assertEquals(actual.etaMillis, model.update(45_000, 250, true, 10, 20_000, 7).etaMillis);
        assertEquals(-1, model.update(65_000, 300, true, 10, 20_000, 7).etaMillis);
        assertEquals(-1, model.update(66_000, 350, true, 8, 66_000, 7).etaMillis);
    }

    @Test public void streamSwitchOrInvalidTimingCannotReuseAnotherQueue() {
        model.update(1_000, 0, true, 12, 1_000, 1);
        model.update(6_000, 10, true, 11, 6_000, 1);
        assertTrue(model.update(11_000, 20, true, 10, 11_000, 1).etaMillis > 0);
        assertEquals(-1, model.update(12_000, 30, true, 9, 12_000, 2).etaMillis);
        model.update(17_000, 40, true, 8, 17_000, 2);
        assertTrue(model.update(22_000, 50, true, 7, 22_000, 2).etaMillis > 0);
        assertEquals(-1, model.update(23_000, 55, true, 6, 16_000, 2).etaMillis);
        assertEquals(-1, model.update(24_000, 60, true, 4, 25_500, 2).etaMillis);
        assertEquals(-1, model.update(25_000, 65, true, 2, 0, 2).etaMillis);
        assertEquals(-1, model.update(26_000, 70, true, 1, 26_000, 0).etaMillis);
    }

    @Test public void freshButUnchangedCountsEventuallyLoseTheirEstimate() {
        ready();
        assertTrue(model.update(31_000, 100, true, 10).etaMillis > 0);
        assertTrue(model.update(51_000, 120, true, 10).etaMillis > 0);
        assertEquals(-1, model.update(56_000, 160, true, 10).etaMillis);
        assertEquals(-1, model.update(57_000, 190, true, 9).etaMillis);
        model.reset();
        TransferEstimates.Snapshot fresh = model.update(58_000, 200, true, 8);
        assertEquals(MEASURING, fresh.rateState);
        assertEquals(-1, fresh.etaMillis);
    }
}
