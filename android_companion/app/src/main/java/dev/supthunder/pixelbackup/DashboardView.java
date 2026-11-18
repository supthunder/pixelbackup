package dev.supthunder.pixelbackup;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Shader;
import android.os.Build;
import android.os.SystemClock;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.TextUtils;
import android.text.format.Formatter;
import android.text.style.RelativeSizeSpan;
import android.util.TypedValue;
import android.view.DisplayCutout;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.ArrayDeque;

/** Foreground dashboard. The activity owns every permission, measurement and inference. */
public final class DashboardView extends ScrollView {
    public interface Actions {
        void connectPhotosStatus();
        void connectLiveMeter();
        void stopLiveMeter();
        void openGooglePhotos();
        void recordCount();
    }

    private static final int MATCH = LayoutParams.MATCH_PARENT;
    private static final int WRAP = LayoutParams.WRAP_CONTENT;

    private final Actions actions;
    private final LinearLayout body;
    private final LinearLayout header;
    private final LinearLayout panels;
    private final LinearLayout stats;
    private final TextView rate;
    private final TextView meterDetail;
    private final TextView remaining;
    private final TextView eta;
    private final TextView photosDetail;
    private final Button connectMeter;
    private final FrameLayout chartHost;
    private final View chartAxis;
    private final Button manualCount;
    private final RateChart chart;
    private int lastContentWidth = -1;
    private float lastFontScale;

    private boolean offerPhotos = true;
    private boolean offerMeter = true;
    private boolean meterActive;
    private String photosAccessDescription;
    private String meterAccessDescription;
    private AlertDialog accessDialog;
    private TextView photosExplanation;
    private TextView meterExplanation;
    private Button photosAction;
    private Button meterAction;

    public DashboardView(Context context, Actions actions) {
        super(context);
        this.actions = actions;
        setFillViewport(true);
        setBackgroundColor(context.getColor(R.color.dash_paper));
        setForceDarkAllowed(false);
        LayoutInflater.from(context).inflate(R.layout.dashboard_content, this, true);
        body = findViewById(R.id.dash_body);
        header = findViewById(R.id.dash_header);
        panels = findViewById(R.id.dash_panels);
        stats = findViewById(R.id.dash_stats);
        rate = findViewById(R.id.dash_rate);
        meterDetail = findViewById(R.id.dash_meter_detail);
        remaining = findViewById(R.id.dash_remaining_value);
        eta = findViewById(R.id.dash_eta_value);
        photosDetail = findViewById(R.id.dash_photos_detail);
        connectMeter = findViewById(R.id.dash_connect_rate);
        chartHost = findViewById(R.id.dash_chart_host);
        chartAxis = findViewById(R.id.dash_chart_axis);
        manualCount = findViewById(R.id.dash_manual);
        chart = new RateChart(context);
        chartHost.addView(chart, new FrameLayout.LayoutParams(MATCH, MATCH));
        ImageView mark = findViewById(R.id.dash_mark);
        mark.setImageDrawable(context.getApplicationInfo().loadIcon(context.getPackageManager()));
        findViewById(R.id.dash_sources).setOnClickListener(v -> showAccessDialog());
        findViewById(R.id.dash_open).setOnClickListener(v -> actions.openGooglePhotos());
        connectMeter.setOnClickListener(v -> actions.connectLiveMeter());
        manualCount.setOnClickListener(v -> actions.recordCount());
        setAccessDescriptions(null, null);
    }

    /** Call once before or after setContentView. Preserve touchable space around every system bar. */
    @SuppressWarnings("deprecation")
    public void installSystemBars(Activity activity) {
        Window window = activity.getWindow();
        window.setStatusBarColor(Color.TRANSPARENT);
        window.setNavigationBarColor(Color.TRANSPARENT);
        window.setStatusBarContrastEnforced(false);
        window.setNavigationBarContrastEnforced(false);
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false);
            WindowInsetsController controller = window.getInsetsController();
            if (controller != null) {
                int lightBars = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                        | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                controller.setSystemBarsAppearance(lightBars, lightBars);
            }
        } else {
            View decor = window.getDecorView();
            decor.setSystemUiVisibility(decor.getSystemUiVisibility()
                    | View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
                    | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
        }
        setOnApplyWindowInsetsListener((v, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars()
                        | WindowInsets.Type.displayCutout());
                v.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            } else {
                DisplayCutout cutout = insets.getDisplayCutout();
                int left = Math.max(insets.getSystemWindowInsetLeft(), cutout == null ? 0 : cutout.getSafeInsetLeft());
                int top = Math.max(insets.getSystemWindowInsetTop(), cutout == null ? 0 : cutout.getSafeInsetTop());
                int right = Math.max(insets.getSystemWindowInsetRight(), cutout == null ? 0 : cutout.getSafeInsetRight());
                int bottom = Math.max(insets.getSystemWindowInsetBottom(), cutout == null ? 0 : cutout.getSafeInsetBottom());
                v.setPadding(left, top, right, bottom);
            }
            return insets;
        });
        requestApplyInsets();
    }

    /** rateText already includes the unit. A real zero remains a measurement. */
    public void setMeter(String rateText, String sourceText, boolean showAccessButton) {
        String reading = orDefault(rateText, R.string.dash_missing);
        if (!TextUtils.equals(rate.getText(), reading)) {
            SpannableString styled = new SpannableString(reading);
            int space = reading.indexOf(' ');
            if (space > 0 && space + 1 < reading.length() && Character.isDigit(reading.charAt(0))) {
                styled.setSpan(new RelativeSizeSpan(0.56f), space + 1, reading.length(),
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
            rate.setText(styled);
            describeMissing(rate);
        }
        setText(meterDetail, orDefault(sourceText, R.string.dash_wait_meter));
        if (offerMeter != showAccessButton) {
            offerMeter = showAccessButton;
            updateMeterControls();
        }
    }

    public void setMeterActive(boolean active) {
        if (meterActive != active) {
            meterActive = active;
            updateMeterControls();
        }
    }

    private void updateMeterControls() {
        boolean showConnect = offerMeter && !meterActive;
        connectMeter.setVisibility(showConnect ? VISIBLE : GONE);
        chartHost.setVisibility(showConnect ? GONE : VISIBLE);
        chartAxis.setVisibility(showConnect ? GONE : VISIBLE);
        updateAccessDialog();
    }

    /** Reads timestamps in the same monotonic clock domain as SystemClock.elapsedRealtime(). */
    public void addRateSample(long elapsedRealtimeMs, double bytesPerSecond) {
        chart.add(elapsedRealtimeMs, bytesPerSecond);
    }

    public void clearRateHistory() {
        chart.clear();
    }

    public void setPhotos(String remainingText, String etaText, String detailText, boolean showAccessButton) {
        setText(remaining, orDefault(remainingText, R.string.dash_missing));
        setText(eta, orDefault(etaText, R.string.dash_missing));
        describeMissing(remaining);
        describeMissing(eta);
        setText(photosDetail, orDefault(detailText, R.string.dash_wait_photos));
        if (offerPhotos != showAccessButton) {
            offerPhotos = showAccessButton;
            updateAccessDialog();
        }
    }

    public void setManualCountVisible(boolean visible) {
        manualCount.setVisibility(visible ? VISIBLE : GONE);
    }

    public void setAccessDescriptions(String photosAccessDescription, String meterAccessDescription) {
        this.photosAccessDescription = orDefault(photosAccessDescription, R.string.dash_photos_description);
        this.meterAccessDescription = orDefault(meterAccessDescription, R.string.dash_meter_description);
        updateAccessDialog();
    }

    /** Informational until the user explicitly chooses a source's action. */
    public void showAccessDialog() {
        if (accessDialog != null && accessDialog.isShowing()) {
            return;
        }
        Context context = getContext();
        ScrollView scroll = new ScrollView(context);
        scroll.setForceDarkAllowed(false);
        LinearLayout content = new LinearLayout(context);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(24), dp(8), dp(24), dp(2));
        scroll.addView(content);
        addDialogHeading(content, R.string.dash_notices_title);
        photosExplanation = addDialogDetail(content);
        photosAction = addDialogAction(content, R.string.dash_connect_photos, actions::connectPhotosStatus);

        View rule = new View(context);
        rule.setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        rule.setBackgroundColor(context.getColor(R.color.dash_line));
        LinearLayout.LayoutParams ruleParams = new LinearLayout.LayoutParams(MATCH, dp(1));
        ruleParams.setMargins(0, dp(12), 0, dp(12));
        content.addView(rule, ruleParams);
        addDialogHeading(content, R.string.dash_meter_title);
        meterExplanation = addDialogDetail(content);
        meterAction = addDialogAction(content, R.string.dash_connect_meter, () -> {
            if (meterActive) {
                actions.stopLiveMeter();
            } else {
                actions.connectLiveMeter();
            }
        });
        accessDialog = new AlertDialog.Builder(context, android.R.style.Theme_Material_Light_Dialog_Alert)
                .setTitle(R.string.dash_access)
                .setView(scroll)
                .setNegativeButton(R.string.dash_done, null)
                .create();
        accessDialog.setOnDismissListener(dialog -> {
            accessDialog = null;
            photosExplanation = null;
            meterExplanation = null;
            photosAction = null;
            meterAction = null;
        });
        updateAccessDialog();
        accessDialog.show();
    }

    private void addDialogHeading(LinearLayout content, int stringId) {
        TextView text = new TextView(getContext());
        text.setTextAppearance(R.style.DashHeading);
        text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18);
        text.setText(stringId);
        text.setAccessibilityHeading(true);
        content.addView(text);
    }

    private TextView addDialogDetail(LinearLayout content) {
        TextView text = new TextView(getContext());
        text.setTextAppearance(R.style.DashText);
        text.setTextColor(getContext().getColor(R.color.dash_muted));
        text.setPadding(0, dp(5), 0, dp(2));
        content.addView(text);
        return text;
    }

    private Button addDialogAction(LinearLayout content, int label, Runnable action) {
        Button button = new Button(getContext(), null, 0, R.style.DashAction);
        button.setText(label);
        button.setOnClickListener(v -> {
            if (accessDialog != null) {
                accessDialog.dismiss();
            }
            action.run();
        });
        content.addView(button, new LinearLayout.LayoutParams(WRAP, WRAP));
        return button;
    }

    private void updateAccessDialog() {
        if (accessDialog == null) {
            return;
        }
        setText(photosExplanation, photosAccessDescription);
        setText(meterExplanation, meterAccessDescription);
        photosAction.setText(offerPhotos ? R.string.dash_connect_photos : R.string.dash_manage_photos);
        meterAction.setText(meterActive ? R.string.dash_stop_meter : R.string.dash_connect_meter);
        meterAction.setVisibility(meterActive || offerMeter ? VISIBLE : GONE);
    }

    @Override
    protected void onDetachedFromWindow() {
        if (accessDialog != null) {
            accessDialog.dismiss();
        }
        super.onDetachedFromWindow();
    }

    @Override
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        int available = MeasureSpec.getSize(widthMeasureSpec) - getPaddingLeft() - getPaddingRight();
        int width = Math.min(available, dp(920));
        float fontScale = getResources().getConfiguration().fontScale;
        if (width > 0 && (width != lastContentWidth || fontScale != lastFontScale)) {
            lastContentWidth = width;
            lastFontScale = fontScale;
            arrange(width, fontScale);
        }
        super.onMeasure(widthMeasureSpec, heightMeasureSpec);
    }

    private void arrange(int width, float fontScale) {
        FrameLayout.LayoutParams bodyParams = (FrameLayout.LayoutParams) body.getLayoutParams();
        bodyParams.width = width;
        body.setLayoutParams(bodyParams);
        boolean stackHeader = width < dp(260 * fontScale + 52);
        header.setOrientation(stackHeader ? LinearLayout.VERTICAL : LinearLayout.HORIZONTAL);
        header.setGravity(stackHeader ? Gravity.START : Gravity.CENTER_VERTICAL);
        findViewById(R.id.dash_brand).setLayoutParams(flexible(stackHeader));
        boolean sideBySide = width >= dp(640) && fontScale <= 1.35f;
        panels.setOrientation(sideBySide ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        findViewById(R.id.dash_meter_panel).setLayoutParams(sideBySide
                ? new LinearLayout.LayoutParams(0, WRAP, 1.1f) : flexible(true));
        LinearLayout.LayoutParams queueParams = flexible(!sideBySide);
        if (sideBySide) {
            queueParams.setMarginStart(dp(12));
        } else {
            queueParams.topMargin = dp(12);
        }
        findViewById(R.id.dash_queue_column).setLayoutParams(queueParams);
        int statsWidth = sideBySide ? Math.round((width - dp(44)) / 2.1f) - dp(34) : width - dp(66);
        boolean stackStats = statsWidth < dp(222 * fontScale);
        stats.setOrientation(stackStats ? LinearLayout.VERTICAL : LinearLayout.HORIZONTAL);
        findViewById(R.id.dash_remaining_group).setLayoutParams(flexible(stackStats));
        findViewById(R.id.dash_eta_group).setLayoutParams(flexible(stackStats));
        LinearLayout.LayoutParams divider = stackStats ? new LinearLayout.LayoutParams(MATCH, dp(1))
                : new LinearLayout.LayoutParams(dp(1), MATCH);
        if (stackStats) {
            divider.setMargins(0, dp(10), 0, dp(10));
        } else {
            divider.setMarginStart(dp(12));
            divider.setMarginEnd(dp(12));
        }
        findViewById(R.id.dash_stats_line).setLayoutParams(divider);
    }

    private static LinearLayout.LayoutParams flexible(boolean vertical) {
        return vertical ? new LinearLayout.LayoutParams(MATCH, WRAP)
                : new LinearLayout.LayoutParams(0, WRAP, 1f);
    }

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private String orDefault(String value, int fallback) {
        return TextUtils.isEmpty(value) ? getResources().getString(fallback) : value;
    }

    private void describeMissing(TextView view) {
        boolean missing = TextUtils.equals(view.getText(), getResources().getString(R.string.dash_missing));
        CharSequence description = missing ? getResources().getString(R.string.dash_unavailable) : null;
        if (!TextUtils.equals(description, view.getContentDescription())) {
            view.setContentDescription(description);
        }
    }

    private static void setText(TextView text, String value) {
        if (!TextUtils.equals(text.getText(), value)) {
            text.setText(value);
        }
    }

    /** A bounded foreground sparkline. Missing measurements never become zero-valued points. */
    private static final class RateChart extends View {
        private static final long WINDOW_MS = 60_000L;
        private static final long MAX_LINE_GAP_MS = 12_000L;
        private static final int MAX_POINTS = 256;
        private final ArrayDeque<Point> points = new ArrayDeque<>();
        private final Paint line = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint guide = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint dot = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path trace = new Path();
        private final Path area = new Path();
        private final float density;
        private final Runnable advanceWindow = this::invalidate;

        RateChart(Context context) {
            super(context);
            density = getResources().getDisplayMetrics().density;
            int mint = context.getColor(R.color.dash_mint);
            line.setColor(mint);
            line.setStyle(Paint.Style.STROKE);
            line.setStrokeWidth(2.2f * density);
            line.setStrokeCap(Paint.Cap.ROUND);
            line.setStrokeJoin(Paint.Join.ROUND);
            dot.setColor(mint);
            guide.setColor(0x44698D78);
            guide.setStrokeWidth(Math.max(1f, density * 0.7f));
            setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
            setScreenReaderFocusable(true);
        }

        void add(long time, double value) {
            if (time < 0) {
                return;
            }
            Point last = points.peekLast();
            if (last != null && time < last.time) {
                points.clear();
            } else if (last != null && time == last.time) {
                points.removeLast();
            }
            points.addLast(new Point(time, value));
            while (points.size() > MAX_POINTS) {
                points.removeFirst();
            }
            trim(time);
            invalidate();
        }

        void clear() {
            points.clear();
            removeCallbacks(advanceWindow);
            invalidate();
        }

        @Override
        protected void onDetachedFromWindow() {
            removeCallbacks(advanceWindow);
            super.onDetachedFromWindow();
        }

        private void trim(long end) {
            while (!points.isEmpty() && points.peekFirst().time < end - WINDOW_MS) {
                points.removeFirst();
            }
        }

        private double peak() {
            double max = 0;
            for (Point point : points) {
                if (point.valid()) {
                    max = Math.max(max, point.value);
                }
            }
            return max;
        }

        @Override
        protected void onSizeChanged(int w, int h, int oldWidth, int oldHeight) {
            super.onSizeChanged(w, h, oldWidth, oldHeight);
            if (h > 0) {
                fill.setShader(new LinearGradient(0, 0, 0, h, 0x62BAEBC9, 0x08BAEBC9, Shader.TileMode.CLAMP));
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            long end = SystemClock.elapsedRealtime();
            trim(end);
            float left = density * 3;
            float right = getWidth() - left;
            float top = density * 3;
            float bottom = getHeight() - top;
            if (right <= left || bottom <= top) {
                return;
            }
            canvas.drawLine(left, top, right, top, guide);
            canvas.drawLine(left, (top + bottom) / 2, right, (top + bottom) / 2, guide);
            canvas.drawLine(left, bottom, right, bottom, guide);
            double maximum = Math.max(1, peak());
            trace.rewind();
            area.rewind();
            boolean segment = false;
            long lastTime = -1;
            float lastX = 0;
            float lastY = 0;
            for (Point point : points) {
                if (!point.valid() || point.time - lastTime > MAX_LINE_GAP_MS) {
                    if (segment) {
                        area.lineTo(lastX, bottom);
                        area.close();
                    }
                    segment = false;
                }
                if (!point.valid()) {
                    continue;
                }
                float x = left + (right - left) * Math.min(1f, (float) (point.time - end + WINDOW_MS) / WINDOW_MS);
                float y = bottom - (bottom - top) * (float) (point.value / maximum);
                if (segment) {
                    trace.lineTo(x, y);
                    area.lineTo(x, y);
                } else {
                    trace.moveTo(x, y);
                    area.moveTo(x, bottom);
                    area.lineTo(x, y);
                    canvas.drawCircle(x, y, density * 1.6f, dot);
                    segment = true;
                }
                lastTime = point.time;
                lastX = x;
                lastY = y;
            }
            if (segment) {
                area.lineTo(lastX, bottom);
                area.close();
            }
            canvas.drawPath(area, fill);
            canvas.drawPath(trace, line);
            if (segment) {
                canvas.drawCircle(lastX, lastY, density * 2.4f, dot);
            }
            removeCallbacks(advanceWindow);
            if (!points.isEmpty() && isShown()) {
                postDelayed(advanceWindow, 1000);
            }
        }

        @Override
        public void onInitializeAccessibilityNodeInfo(AccessibilityNodeInfo info) {
            super.onInitializeAccessibilityNodeInfo(info);
            trim(SystemClock.elapsedRealtime());
            Point latest = null;
            for (Point point : points) {
                if (point.valid()) {
                    latest = point;
                }
            }
            String summary = latest == null ? getResources().getString(R.string.dash_chart_empty)
                    : getResources().getString(R.string.dash_chart_summary, accessibleRate(latest.value), accessibleRate(peak()));
            info.setContentDescription(getResources().getString(R.string.dash_chart_title) + ". " + summary);
        }

        private String accessibleRate(double value) {
            String bytes = Formatter.formatShortFileSize(getContext(), Math.round(value));
            return getResources().getString(R.string.dash_rate_bytes, bytes);
        }
    }

    private static final class Point {
        final long time;
        final double value;

        Point(long time, double value) {
            this.time = time;
            this.value = value;
        }

        boolean valid() {
            return Double.isFinite(value) && value >= 0;
        }
    }
}
