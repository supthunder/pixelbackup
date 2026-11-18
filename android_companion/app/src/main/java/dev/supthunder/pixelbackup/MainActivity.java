package dev.supthunder.pixelbackup;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.NotificationManager;
import android.content.ActivityNotFoundException;
import android.content.ComponentName;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.text.InputFilter;
import android.text.InputType;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.Toast;

import java.text.NumberFormat;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity implements DashboardView.Actions {
    private static final String PHOTOS = "com.google.android.apps.photos";
    private static final long INTERVAL_MS = 2_000L;
    private static final long MAX_NOTICE_AGE_MS = 120_000L;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final TransferEstimates rate = new TransferEstimates();
    private final TransferEstimates queue = new TransferEstimates();
    private final Runnable onPhotosChanged = this::refreshPhotosAccess;
    private final Runnable closeCoveredMeter = this::stopLiveMeter;
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (!visible) return;
            if (traffic != null && !reading) readTraffic(false);
            renderQueue();
            main.postDelayed(this, INTERVAL_MS);
        }
    };

    private DashboardView dashboard;
    private ManualQueue manual;
    private PhotosTraffic traffic;
    private boolean visible;
    private boolean reading;
    private boolean awaitingGrant;
    private boolean notificationAccess;

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Object retained = getLastNonConfigurationInstance();
        manual = retained instanceof ManualQueue ? (ManualQueue) retained : new ManualQueue();
        dashboard = new DashboardView(this, this);
        dashboard.installSystemBars(this);
        setContentView(dashboard);
        dashboard.setAccessDescriptions(getString(R.string.photos_access_description),
                getString(R.string.rate_access_description));
        displayMeter(R.string.meter_off, true);
    }

    @Override public Object onRetainNonConfigurationInstance() { return manual; }

    @Override protected void onStart() {
        super.onStart();
        visible = true;
        main.removeCallbacks(closeCoveredMeter);
        PhotosNotifications.addListener(onPhotosChanged);
        main.post(tick);
    }

    @Override protected void onResume() {
        super.onResume();
        refreshPhotosAccess();
    }

    private void refreshPhotosAccess() {
        notificationAccess = getSystemService(NotificationManager.class)
                .isNotificationListenerAccessGranted(new ComponentName(this, PhotosNotifications.class));
        renderQueue();
    }

    @Override protected void onStop() {
        visible = false;
        main.removeCallbacks(tick);
        PhotosNotifications.removeListener(onPhotosChanged);
        queue.reset();
        // Magisk may briefly cover the entire activity while the owner answers its prompt.
        // No sampling is scheduled while covered; an unanswered request has its own timeout.
        if (awaitingGrant) main.postDelayed(closeCoveredMeter, 42_000L);
        else stopLiveMeter();
        super.onStop();
    }

    @Override protected void onDestroy() {
        main.removeCallbacksAndMessages(null);
        stopLiveMeter();
        worker.shutdownNow();
        super.onDestroy();
    }

    @Override public void connectLiveMeter() {
        if (traffic != null) return;
        new AlertDialog.Builder(this).setTitle(R.string.meter_consent_title)
                .setMessage(R.string.rate_access_description)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.meter_consent_action, (dialog, which) -> {
                    if (!visible || traffic != null) return;
                    traffic = new PhotosTraffic(getApplicationContext());
                    awaitingGrant = true;
                    displayMeter(R.string.meter_connecting, false);
                    dashboard.setMeterActive(true);
                    readTraffic(true);
                }).show();
    }

    private void readTraffic(boolean enable) {
        final PhotosTraffic source = traffic;
        reading = true;
        worker.execute(() -> {
            PhotosTraffic.Sample sample = enable ? source.enable() : source.read();
            main.post(() -> {
                if (traffic != source) return; // A late result from a stopped session.
                reading = false;
                awaitingGrant = false;
                if (sample.status != PhotosTraffic.Status.OK) {
                    stopLiveMeter();
                    displayMeter(meterMessage(sample.status), true);
                    return;
                }
                if (!visible) {
                    main.removeCallbacks(closeCoveredMeter);
                    main.postDelayed(closeCoveredMeter, 1_000L);
                }
                TransferEstimates.Snapshot estimate = rate.update(sample.elapsedRealtimeMillis,
                        sample.txBytes, false, -1);
                long speed = estimate.bytesPerSecond;
                dashboard.addRateSample(sample.elapsedRealtimeMillis, speed < 0 ? Double.NaN : speed);
                if (speed < 0) displayMeter(R.string.meter_collecting, false);
                else dashboard.setMeter(getString(R.string.per_second, formatBytes(speed)),
                        getString(R.string.meter_observed_bytes, formatBytes(estimate.observedBytes)), false);
            });
        });
    }

    @Override public void stopLiveMeter() {
        PhotosTraffic old = traffic;
        traffic = null;
        awaitingGrant = false;
        reading = false;
        if (old != null) old.close();
        rate.reset();
        dashboard.clearRateHistory();
        dashboard.setMeterActive(false);
        displayMeter(R.string.meter_off, true);
    }

    private void displayMeter(int message, boolean offerAccess) {
        dashboard.setMeter(getString(R.string.empty_metric), getString(message), offerAccess);
    }

    private int meterMessage(PhotosTraffic.Status status) {
        switch (status) {
            case PHOTOS_MISSING: return R.string.meter_missing_photos;
            case ROOT_UNAVAILABLE: return R.string.meter_denied;
            case COUNTER_UNAVAILABLE: return R.string.meter_unavailable;
            case TIMED_OUT: return R.string.meter_timeout;
            default: return R.string.meter_off;
        }
    }

    private String formatBytes(long bytes) {
        double amount = bytes;
        String[] units = { "B", "kB", "MB", "GB", "TB" };
        int unit = 0;
        while (amount >= 1000 && unit < units.length - 1) { amount /= 1000; unit++; }
        NumberFormat number = NumberFormat.getNumberInstance();
        number.setMaximumFractionDigits(unit > 0 && amount < 10 ? 1 : 0);
        return getString(R.string.byte_amount, number.format(amount), units[unit]);
    }

    @Override public void connectPhotosStatus() {
        if (notificationAccess) { openNotificationSettings(); return; }
        new AlertDialog.Builder(this).setTitle(R.string.photos_consent_title)
                .setMessage(R.string.photos_access_description)
                .setNegativeButton(android.R.string.cancel, null)
                .setPositiveButton(R.string.photos_consent_action, (dialog, which) -> openNotificationSettings())
                .show();
    }

    private void openNotificationSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Intent detail = new Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                    .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                            new ComponentName(this, PhotosNotifications.class).flattenToString());
            if (open(detail)) return;
        }
        if (!open(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))) toast(R.string.photos_settings_unavailable);
    }

    @Override public void openGooglePhotos() {
        Intent intent = getPackageManager().getLaunchIntentForPackage(PHOTOS);
        if (intent == null || !open(intent)) toast(R.string.photos_unavailable);
    }

    private boolean open(Intent intent) {
        try { startActivity(intent); return true; }
        catch (ActivityNotFoundException | SecurityException ignored) { return false; }
    }

    private void toast(int message) { Toast.makeText(this, message, Toast.LENGTH_LONG).show(); }

    private void renderQueue() {
        if (!visible) return;
        long now = SystemClock.elapsedRealtime();
        PhotosNotifications.Snapshot source = PhotosNotifications.snapshot();
        boolean hasNotice = notificationAccess && source.connected
                && source.state != PhotosNotifications.State.UNAVAILABLE;
        long noticeAge = now - source.observedElapsedMs;
        boolean recent = hasNotice && source.observedElapsedMs > 0
                && noticeAge >= 0 && noticeAge <= MAX_NOTICE_AGE_MS;
        boolean active = recent && source.state == PhotosNotifications.State.BACKING_UP;
        TransferEstimates.Snapshot estimate = queue.update(now, -1L, active, source.remaining,
                source.observedElapsedMs, source.streamId);
        String none = getString(R.string.empty_metric);
        String remaining = none;
        String eta = none;
        String detail;
        boolean canRecord = true;
        if (active && source.remaining >= 0) {
            manual.clear();
            canRecord = false;
            remaining = countText(source.remaining);
            eta = formatEta(estimate.etaMillis);
            detail = getString(estimate.etaMillis < 0 ? R.string.queue_active : R.string.queue_estimated);
        } else if (recent && (source.state == PhotosNotifications.State.COMPLETE
                || source.state == PhotosNotifications.State.PAUSED)) {
            manual.clear();
            canRecord = false;
            boolean complete = source.state == PhotosNotifications.State.COMPLETE;
            remaining = getString(complete ? R.string.queue_complete_value : R.string.queue_paused_value);
            detail = getString(complete ? R.string.queue_complete : R.string.queue_paused);
        } else {
            ManualQueue.Snapshot entry = manual.snapshot(now);
            if (entry.hasObservation) {
                remaining = countText(entry.remaining);
                eta = formatEta(entry.etaMillis);
                String observed = entry.ageMillis < 60_000L ? getString(R.string.manual_now)
                        : getString(R.string.manual_aged, duration(entry.ageMillis));
                int message = entry.stale ? R.string.manual_stale : entry.remaining == 0
                        ? R.string.manual_zero : entry.etaMillis < 0
                        ? R.string.manual_another : R.string.manual_estimated;
                detail = observed + " " + getString(message);
            } else if (active) detail = getString(R.string.queue_active_no_count);
            else if (hasNotice) {
                if (source.remaining >= 0 && source.observedElapsedMs > 0 && noticeAge > MAX_NOTICE_AGE_MS) {
                    remaining = countText(source.remaining);
                    detail = getString(R.string.queue_last_update, duration(noticeAge));
                } else detail = getString(R.string.queue_stale);
            } else if (notificationAccess && source.connected) detail = getString(R.string.queue_waiting);
            else detail = getString(notificationAccess ? R.string.queue_reconnecting : R.string.queue_disconnected);
        }
        dashboard.setPhotos(remaining, eta, detail, !notificationAccess);
        dashboard.setManualCountVisible(canRecord);
    }

    private String countText(int count) { return NumberFormat.getIntegerInstance().format(count); }

    private String formatEta(long milliseconds) {
        if (milliseconds < 0) return getString(R.string.empty_metric);
        long rounded = milliseconds >= 60_000L && milliseconds <= Long.MAX_VALUE - 30_000L
                ? milliseconds + 30_000L : milliseconds;
        return getString(R.string.estimated_time, duration(rounded));
    }

    private String duration(long milliseconds) {
        if (milliseconds < 60_000L) return getString(R.string.time_under_minute);
        long minutes = milliseconds / 60_000L;
        if (minutes < 60) return getString(R.string.time_minutes, minutes);
        if (minutes < 24 * 60) return minutes % 60 == 0 ? getString(R.string.time_hours, minutes / 60)
                : getString(R.string.time_hours_minutes, minutes / 60, minutes % 60);
        long days = minutes / (24 * 60);
        long hours = minutes / 60 % 24;
        return hours == 0 ? getString(R.string.time_days, days) : getString(R.string.time_days_hours, days, hours);
    }

    @Override public void recordCount() {
        EditText input = new EditText(this);
        input.setInputType(InputType.TYPE_CLASS_NUMBER);
        input.setSingleLine();
        input.setFilters(new InputFilter[] { new InputFilter.LengthFilter(10) });
        input.setSaveEnabled(false);
        input.setImportantForAutofill(EditText.IMPORTANT_FOR_AUTOFILL_NO);
        input.setHint(R.string.count_hint);
        FrameLayout frame = new FrameLayout(this);
        int inset = Math.round(24 * getResources().getDisplayMetrics().density);
        frame.setPadding(inset, 0, inset, 0);
        frame.addView(input);
        AlertDialog.Builder builder = new AlertDialog.Builder(this).setTitle(R.string.count_title)
                .setMessage(R.string.count_prompt).setView(frame)
                .setNegativeButton(android.R.string.cancel, null).setPositiveButton(R.string.count_save, null);
        if (manual.snapshot(SystemClock.elapsedRealtime()).hasObservation) {
            builder.setNeutralButton(R.string.count_clear, (dialog, which) -> { manual.clear(); renderQueue(); });
        }
        AlertDialog dialog = builder.create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                .setOnClickListener(view -> {
                    try {
                        int count = Integer.parseInt(input.getText().toString().trim());
                        if (count < 0) throw new NumberFormatException();
                        manual.record(count, SystemClock.elapsedRealtime());
                    } catch (NumberFormatException invalid) { input.setError(getString(R.string.count_error)); return; }
                    dialog.dismiss();
                    renderQueue();
                }));
        dialog.show();
    }
}
