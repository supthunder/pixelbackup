package dev.supthunder.pixelbackup;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.concurrent.TimeUnit;

import org.junit.Assume;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public final class PhotosTrafficTest {
    private static final String HEADER =
            "idx iface acct_tag_hex uid_tag_int cnt_set rx_bytes rx_packets tx_bytes tx_packets\n";

    @Rule public final TemporaryFolder temporary = new TemporaryFolder();

    private void assertOnlyOutput(String rows, String total) throws Exception {
        File program = temporary.newFile();
        Files.write(program.toPath(), PhotosTraffic.COUNTER_PROGRAM.getBytes(StandardCharsets.US_ASCII));
        ProcessBuilder command = new ProcessBuilder("awk", "-v", "uid=10047", "-f", program.getAbsolutePath());
        command.environment().put("LC_ALL", "C");
        command.redirectErrorStream(true);
        Process process;
        try {
            process = command.start();
        } catch (IOException missingAwk) {
            Assume.assumeNoException("This host needs awk to run the kernel-counter fixture", missingAwk);
            return;
        }
        try {
            try (OutputStream input = process.getOutputStream()) {
                input.write((HEADER + rows).getBytes(StandardCharsets.US_ASCII));
            }
            assertTrue("Counter filter timed out", process.waitFor(5, TimeUnit.SECONDS));
            try (BufferedReader output = new BufferedReader(new InputStreamReader(
                    process.getInputStream(), StandardCharsets.US_ASCII))) {
                assertEquals(total, output.readLine());
                assertNull("The app should receive only the aggregate", output.readLine());
            }
            assertEquals(0, process.exitValue());
        } finally {
            process.destroyForcibly();
        }
    }

    @Test public void sumsOnlyPhotosParentTagOnWifiWithoutSharingRawRows() throws Exception {
        assertOnlyOutput(
                "2 wlan0 0x0 10047 0 100 1 91 2\n" +
                "3 wlan0 0x0 10047 1 100 1 23 2\n" +
                "4 wlan0 0x100 10047 0 100 1 44 2\n" +
                "5 wlan0 0x0 10101 0 100 1 580 2\n" +
                "6 rmnet0 0x0 10047 0 100 1 639 2\n", "114");
        assertOnlyOutput("2 wlan0 0x0 10101 0 10 1 89 1\n", "0");
    }

    @Test public void largeCountersKeepExactDecimalPrecision() throws Exception {
        assertOnlyOutput("2 wlan0 0x0 10047 0 64 1 9007199254740992 2\n" +
                         "3 wlan0 0x0 10047 1 64 1 1 2\n", "9007199254740993");
    }

    @Test public void closingBeforeTheQueuedEnableSealsTheMeter() {
        PhotosTraffic meter = new PhotosTraffic(null, () -> 23);
        assertEquals(PhotosTraffic.Status.DISABLED, meter.read().status);
        meter.close();
        PhotosTraffic.Sample delayed = meter.enable();
        assertEquals(PhotosTraffic.Status.DISABLED, delayed.status);
        assertEquals(-1, delayed.txBytes);
        assertEquals(23, delayed.elapsedRealtimeMillis);
        assertEquals(PhotosTraffic.Status.DISABLED, meter.read().status);
    }
}
