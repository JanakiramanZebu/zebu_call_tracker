package `in`.mynt.zebu_call_tracker.overlay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.AnimationUtils
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import `in`.mynt.zebu_call_tracker.R
import io.flutter.plugin.common.MethodChannel

/**
 * Draws a Truecaller-style post-call summary card over any app or screen.
 *
 * Lifecycle:
 *   startService() → onStartCommand() → addView() to WindowManager
 *   [8 sec timeout OR dismiss tap] → removeView() → stopSelf()
 *
 * "View Details" tap → fires MethodChannel event so Flutter can navigate
 *   to the matching CallDetailScreen.
 *
 * Requires SYSTEM_ALERT_WINDOW. If the permission is not held when
 * onStartCommand fires, the service stops itself immediately without crashing.
 */
class PostCallOverlayService : Service() {

    private val handler   = Handler(Looper.getMainLooper())
    private var windowMgr: WindowManager? = null
    private var root:      View?          = null
    private var data:      PostCallData?  = null

    private val autoDismiss = Runnable { dismiss() }

    // -------------------------------------------------------------------------
    // Service lifecycle
    // -------------------------------------------------------------------------

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val parsed = intent?.let { PostCallData.fromIntent(it) }
        if (parsed == null) { stopSelf(); return START_NOT_STICKY }
        data = parsed

        // Graceful degradation: if the user hasn't granted overlay permission,
        // do nothing. We never ask at runtime from here.
        if (!Settings.canDrawOverlays(this)) {
            stopSelf()
            return START_NOT_STICKY
        }

        // On API 34+ a foreground service is mandatory when starting from a
        // background context (BroadcastReceiver). We start minimal and cancel
        // it immediately after adding the view, so no persistent notification
        // appears in the shade.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIF_ID, buildSilentNotification())
        }

        showOverlay(parsed)
        handler.postDelayed(autoDismiss, AUTO_DISMISS_MS)

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(autoDismiss)
        removeOverlay()
        super.onDestroy()
    }

    // -------------------------------------------------------------------------
    // Overlay construction
    // -------------------------------------------------------------------------

    private fun showOverlay(d: PostCallData) {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        windowMgr = wm

        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getMetrics(metrics)
        val screenW = metrics.widthPixels
        val cardW   = (screenW * 0.88f).toInt()

        val card = buildCard(d, cardW)
        root = card

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE

        val params = WindowManager.LayoutParams(
            cardW,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            y = dp(24)
        }

        wm.addView(card, params)

        // Slide-up entrance animation
        card.startAnimation(android.view.animation.TranslateAnimation(
            0f, 0f, dp(200).toFloat(), 0f
        ).apply {
            duration = 300
            interpolator = android.view.animation.DecelerateInterpolator(2f)
        })
    }

    private fun buildCard(d: PostCallData, width: Int): LinearLayout {
        val ctx = this

        // ── Root container ────────────────────────────────────────────────────
        val root = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background  = roundedBackground(Color.parseColor("#E81A1A2E"), 20)
            elevation   = dp(8).toFloat()
        }

        // ── Header strip ──────────────────────────────────────────────────────
        val header = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            background  = roundedTopBackground(Color.parseColor("#FF26264A"), 20)
            setPadding(dp(14), dp(10), dp(14), dp(10))
            gravity     = Gravity.CENTER_VERTICAL
        }

        val appIcon = ImageView(ctx).apply {
            setImageResource(R.mipmap.ic_launcher)
            val sz = dp(20)
            layoutParams = LinearLayout.LayoutParams(sz, sz)
        }
        header.addView(appIcon)

        val headerLabel = TextView(ctx).apply {
            text       = "Zebu Call Tracker"
            setTextColor(Color.parseColor("#FFCCCCDD"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            typeface   = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            layoutParams = LinearLayout.LayoutParams(0, LP_WRAP, 1f).apply {
                leftMargin = dp(8)
            }
        }
        header.addView(headerLabel)

        // Dismiss ×
        val dismissBtn = TextView(ctx).apply {
            text      = "✕"
            setTextColor(Color.parseColor("#99AAAACC"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setPadding(dp(8), 0, 0, 0)
            setOnClickListener { dismiss() }
        }
        header.addView(dismissBtn)
        root.addView(header, LinearLayout.LayoutParams(LP_MATCH, LP_WRAP))

        // ── Body ──────────────────────────────────────────────────────────────
        val body = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(14), dp(18), dp(16))
        }

        // Direction icon + direction label row
        val dirRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity     = Gravity.CENTER_VERTICAL
        }

        val dirIcon = TextView(ctx).apply {
            text      = directionEmoji(d.direction)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        }
        dirRow.addView(dirIcon)

        val dirLabel = TextView(ctx).apply {
            text      = directionLabel(d.direction)
            setTextColor(Color.parseColor("#FFAAAACC"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            layoutParams = LinearLayout.LayoutParams(LP_WRAP, LP_WRAP).apply {
                leftMargin = dp(6)
            }
        }
        dirRow.addView(dirLabel)
        body.addView(dirRow)
        body.addView(spacer(ctx, dp(6)))

        // Display name
        val nameView = TextView(ctx).apply {
            text     = d.displayName
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        body.addView(nameView)

        // Phone number (only if different from displayName)
        if (d.phoneNumber.isNotBlank() && d.phoneNumber != d.displayName) {
            val numView = TextView(ctx).apply {
                text     = d.phoneNumber
                setTextColor(Color.parseColor("#CC99AABB"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                layoutParams = LinearLayout.LayoutParams(LP_WRAP, LP_WRAP).apply {
                    topMargin = dp(2)
                }
            }
            body.addView(numView)
        }

        body.addView(spacer(ctx, dp(12)))

        // Divider
        body.addView(View(ctx).apply {
            setBackgroundColor(Color.parseColor("#22AAAACC"))
            layoutParams = LinearLayout.LayoutParams(LP_MATCH, 1)
        })

        body.addView(spacer(ctx, dp(12)))

        // Duration row
        val durRow = metaRow(ctx,
            "⏱  " + formatDuration(d.durationSeconds),
            Color.parseColor("#FFDDDDEE"))
        body.addView(durRow)
        body.addView(spacer(ctx, dp(6)))

        // Recording row
        val recText = if (d.hasRecording) "🎙  Recording found" else "🔇  No recording"
        val recColor = if (d.hasRecording) Color.parseColor("#FF7EB8A2") else Color.parseColor("#88AAAACC")
        body.addView(metaRow(ctx, recText, recColor))

        body.addView(spacer(ctx, dp(16)))

        // ── Action buttons ────────────────────────────────────────────────────
        val btnRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity     = Gravity.CENTER_VERTICAL
        }

        val detailsBtn = buildButton(ctx,
            label = "View Details",
            bgColor = Color.parseColor("#FF3D5AFE"),
            fgColor = Color.WHITE,
            weight  = 1f
        ) { onViewDetails(d) }
        btnRow.addView(detailsBtn)

        val gap = View(ctx).apply {
            layoutParams = LinearLayout.LayoutParams(dp(10), 1)
        }
        btnRow.addView(gap)

        val closeBtn = buildButton(ctx,
            label = "Close",
            bgColor = Color.parseColor("#22AAAACC"),
            fgColor = Color.parseColor("#FFCCCCDD"),
            weight  = 0.6f
        ) { dismiss() }
        btnRow.addView(closeBtn)

        body.addView(btnRow)

        root.addView(body)
        return root
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    private fun onViewDetails(d: PostCallData) {
        // Persist so NativeBridge can forward to Flutter on resume.
        PostCallData.save(this, d)

        // Bring the app to the foreground — Flutter handles navigation.
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_OPEN_CALL, d.startedAtMillis)
        }
        launch?.let { startActivity(it) }

        dismiss()
    }

    private fun dismiss() {
        handler.removeCallbacks(autoDismiss)
        removeOverlay()
        stopSelf()
    }

    private fun removeOverlay() {
        try {
            root?.let { windowMgr?.removeView(it) }
        } catch (_: Exception) { /* already detached */ }
        root = null
    }

    // -------------------------------------------------------------------------
    // Foreground notification (API 34+ only; cancelled immediately)
    // -------------------------------------------------------------------------

    private fun buildSilentNotification(): Notification {
        val channelId = "post_call_overlay"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val chan = NotificationChannel(
                channelId, "Post-call overlay",
                NotificationManager.IMPORTANCE_MIN,
            ).apply { setShowBadge(false) }
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(chan)
        }
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("Zebu Call Tracker")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            .build()
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    private fun roundedBackground(color: Int, radiusDp: Int): GradientDrawable =
        GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(radiusDp).toFloat()
        }

    private fun roundedTopBackground(color: Int, radiusDp: Int): GradientDrawable =
        GradientDrawable().apply {
            setColor(color)
            val r = dp(radiusDp).toFloat()
            cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
        }

    private fun metaRow(ctx: Context, text: String, color: Int): TextView =
        TextView(ctx).apply {
            this.text = text
            setTextColor(color)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        }

    private fun buildButton(
        ctx:     Context,
        label:   String,
        bgColor: Int,
        fgColor: Int,
        weight:  Float,
        onClick: () -> Unit,
    ): TextView = TextView(ctx).apply {
        text = label
        setTextColor(fgColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity  = Gravity.CENTER
        background = GradientDrawable().apply {
            setColor(bgColor)
            cornerRadius = dp(10).toFloat()
        }
        setPadding(dp(8), dp(12), dp(8), dp(12))
        layoutParams = LinearLayout.LayoutParams(0, LP_WRAP, weight)
        setOnClickListener { onClick() }
    }

    private fun spacer(ctx: Context, heightPx: Int): View = View(ctx).apply {
        layoutParams = LinearLayout.LayoutParams(LP_MATCH, heightPx)
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density + 0.5f).toInt()

    private fun directionEmoji(dir: String): String = when (dir) {
        "incoming" -> "↙"
        "outgoing" -> "↗"
        "missed"   -> "↙"
        else       -> "↔"
    }

    private fun directionLabel(dir: String): String = when (dir) {
        "incoming" -> "Incoming call"
        "outgoing" -> "Outgoing call"
        "missed"   -> "Missed call"
        "rejected" -> "Rejected call"
        else       -> "Call"
    }

    private fun formatDuration(sec: Int): String {
        if (sec <= 0) return "Not answered"
        val m = sec / 60
        val s = sec % 60
        return if (m > 0) "${m} min ${s} sec" else "${s} sec"
    }

    companion object {
        private const val NOTIF_ID        = 7001
        private const val AUTO_DISMISS_MS = 8_000L
        const val EXTRA_OPEN_CALL         = "open_call_started_millis"

        private const val LP_WRAP  = ViewGroup.LayoutParams.WRAP_CONTENT
        private const val LP_MATCH = ViewGroup.LayoutParams.MATCH_PARENT
    }
}