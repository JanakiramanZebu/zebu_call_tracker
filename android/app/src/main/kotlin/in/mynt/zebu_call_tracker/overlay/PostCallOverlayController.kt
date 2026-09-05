package `in`.mynt.zebu_call_tracker.overlay

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.DisplayMetrics
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.view.animation.TranslateAnimation
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import `in`.mynt.zebu_call_tracker.R
import `in`.mynt.zebu_call_tracker.call.CallLogReader
import `in`.mynt.zebu_call_tracker.call.ContactResolver
import java.util.concurrent.Executors

/**
 * Draws a Truecaller-style post-call summary card over whatever is on screen.
 *
 * ## Why this is not a Service
 *
 * It was one, and that is precisely why the card never appeared. The service
 * was declared `foregroundServiceType="phoneCall"` and started with
 * `startForegroundService()` from [in.mynt.zebu_call_tracker.call.CallStateReceiver],
 * which is broken at both ends of the supported range:
 *
 *  - **API 26–33.** `startForegroundService()` obliges the service to call
 *    `startForeground()` within five seconds. It only did so on API 34+, so
 *    every single call ended with the system throwing
 *    `ForegroundServiceDidNotStartInTimeException` at the process — before the
 *    eight-second auto-dismiss had run.
 *  - **API 34+** (this app targets 36). The `phoneCall` type requires the app
 *    to hold `MANAGE_OWN_CALLS` or the `ROLE_DIALER` role. It has neither, so
 *    `startForeground()` threw `SecurityException` out of `onStartCommand`
 *    before the view was ever added.
 *
 * The service also bought nothing. The comment on the old receiver claimed
 * `phoneCall` exempted it from Android 12's ban on starting a foreground
 * service from a background broadcast; it does not — types are not exemptions.
 * The exemption actually in play is `SYSTEM_ALERT_WINDOW`, which this code
 * checks for anyway because it cannot draw without it. That same permission is
 * what lets a window be added from any context and what exempts the
 * "View Details" tap from the background-activity-start restriction.
 *
 * So there is no service, no foreground notification, no type permission and no
 * five-second deadline. A window added to [WindowManager] raises the process's
 * `hasOverlayUi` flag, which holds it at perceptible priority for the few
 * seconds the card is up — which is the whole lifetime that needs protecting.
 *
 * ## Lifecycle
 *
 * `show()` → `addView` → [AUTO_DISMISS_MS] or a tap → `removeView`.
 * Main-thread only; [show] posts itself there if called from anywhere else.
 */
object PostCallOverlayController {

    private const val TAG = "PostCallOverlay"
    private const val AUTO_DISMISS_MS = 8_000L

    /**
     * How far back a call-log row may sit and still be "the call that just
     * ended". Generous because the OEM dialers on this fleet write the row a
     * beat after IDLE, and the clock is the device's own either way.
     */
    private const val LOG_MATCH_WINDOW_MILLIS = 120_000L

    /** One retry, for dialers that have not written the row by IDLE. */
    private const val ENRICH_RETRY_DELAY_MILLIS = 1_200L

    private val handler = Handler(Looper.getMainLooper())

    /**
     * Single thread, created once. The enrichment does two ContentProvider
     * queries and must never touch the main thread — `onReceive` has a ten
     * second budget and the card has to be on screen well inside it.
     */
    private val enrichExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "post-call-enrich").apply { isDaemon = true }
    }

    private var windowMgr: WindowManager? = null
    private var root: View? = null
    private var current: PostCallData? = null

    // Held so enrichment can fill them in after the card is already up.
    private var nameView: TextView? = null
    private var numberView: TextView? = null
    private var directionView: TextView? = null
    private var durationView: TextView? = null

    private val autoDismiss = Runnable { dismiss() }

    // -------------------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------------------

    /**
     * Shows the card for a call that has just ended.
     *
     * [seed] is whatever the receiver could work out synchronously, which is
     * little: a direction guessed from the state journal and an approximate
     * duration. The card goes up with that immediately and the real number,
     * contact name, direction and duration are read off the call log on a
     * background thread and patched in.
     *
     * A silent no-op without `SYSTEM_ALERT_WINDOW` — the card is opt-in, and
     * tracking does not depend on it.
     */
    fun show(context: Context, seed: PostCallData) {
        val app = context.applicationContext
        if (!Settings.canDrawOverlays(app)) {
            Log.i(TAG, "Overlay permission not granted; skipping post-call card.")
            return
        }
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { show(app, seed) }
            return
        }

        // A second call ending while the first card is up replaces it rather
        // than stacking a second window nobody asked for.
        removeOverlay()

        current = seed
        try {
            addOverlay(app, seed)
        } catch (e: Exception) {
            // A denied or revoked overlay permission surfaces here as a
            // BadTokenException. Nothing else in the app depends on the card,
            // so it must not take the process down with it.
            Log.w(TAG, "Could not add the post-call card: ${e.message}")
            clearViews()
            return
        }

        handler.removeCallbacks(autoDismiss)
        handler.postDelayed(autoDismiss, AUTO_DISMISS_MS)

        enrich(app, seed, isRetry = false)
    }

    fun dismiss() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { dismiss() }
            return
        }
        handler.removeCallbacks(autoDismiss)
        removeOverlay()
    }

    // -------------------------------------------------------------------------
    // Enrichment
    // -------------------------------------------------------------------------

    /**
     * Replaces the seed's guesses with the call log's facts.
     *
     * The log row is authoritative for number, direction and duration; the
     * journal-derived seed is not, and the card used to display the result of
     * that guess as "Recent call" against a blank number, which is worse than
     * showing nothing.
     *
     * Everything here is best-effort. A missing permission, an empty log or a
     * row that turns out to belong to an older call all leave the card exactly
     * as it is rather than replacing real text with placeholders.
     */
    private fun enrich(context: Context, seed: PostCallData, isRetry: Boolean) {
        enrichExecutor.execute {
            val row = try {
                CallLogReader.read(context, sinceMillis = 0L, limit = 1).firstOrNull()
            } catch (e: Exception) {
                // Most often READ_CALL_LOG is not held. Not worth a retry.
                Log.i(TAG, "Post-call enrichment unavailable: ${e.message}")
                null
            }

            val dateMillis = row?.get("dateMillis") as? Long
            val fresh = dateMillis != null &&
                System.currentTimeMillis() - dateMillis <= LOG_MATCH_WINDOW_MILLIS

            if (row == null || !fresh) {
                // The dialer has not written the row yet. One retry, then the
                // card lives out its eight seconds with the seed's values.
                if (!isRetry) {
                    handler.postDelayed(
                        { if (root != null) enrich(context, seed, isRetry = true) },
                        ENRICH_RETRY_DELAY_MILLIS,
                    )
                }
                return@execute
            }

            val number = (row["number"] as? String)?.takeIf { it.isNotBlank() }
            val name = (row["cachedName"] as? String)?.takeIf { it.isNotBlank() }
                ?: number?.let { ContactResolver.resolve(context, it) }
            val direction = (row["type"] as? String) ?: seed.direction
            val duration = (row["durationSeconds"] as? Long)?.toInt() ?: seed.durationSeconds

            val enriched = seed.copy(
                displayName = name ?: number ?: withheldLabel(row["presentation"] as? String),
                phoneNumber = number.orEmpty(),
                direction = direction,
                durationSeconds = duration,
                startedAtMillis = dateMillis,
            )

            handler.post { applyEnrichment(enriched) }
        }
    }

    /** The card is only still worth updating while it is on screen. */
    private fun applyEnrichment(data: PostCallData) {
        if (root == null) return
        current = data

        nameView?.text = data.displayName
        directionView?.text = directionLabel(data.direction)
        durationView?.text = "⏱  " + formatDuration(data.durationSeconds)

        numberView?.let { view ->
            val show = data.phoneNumber.isNotBlank() && data.phoneNumber != data.displayName
            view.visibility = if (show) View.VISIBLE else View.GONE
            if (show) view.text = data.phoneNumber
        }
    }

    /**
     * What to call someone whose number the network refused to send.
     *
     * A withheld number is a fact about the call, not a failure to read it, and
     * "Unknown" would suggest the app lost track of something.
     */
    private fun withheldLabel(presentation: String?): String = when (presentation) {
        "restricted" -> "Private number"
        "payphone" -> "Payphone"
        else -> "Unknown number"
    }

    // -------------------------------------------------------------------------
    // Window management
    // -------------------------------------------------------------------------

    private fun addOverlay(context: Context, data: PostCallData) {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        windowMgr = wm

        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getMetrics(metrics)
        val cardWidth = (metrics.widthPixels * 0.88f).toInt()

        val card = buildCard(context, data)
        root = card

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val params = WindowManager.LayoutParams(
            cardWidth,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            // NOT_FOCUSABLE keeps the keyboard and the back button with
            // whatever is underneath; touches inside our own bounds still
            // reach the buttons.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            y = dp(context, 24)
        }

        wm.addView(card, params)

        card.startAnimation(
            TranslateAnimation(0f, 0f, dp(context, 200).toFloat(), 0f).apply {
                duration = 300
                interpolator = DecelerateInterpolator(2f)
            },
        )
    }

    private fun removeOverlay() {
        try {
            root?.let { windowMgr?.removeView(it) }
        } catch (_: Exception) {
            // Already detached, or the window token died with the display.
        }
        clearViews()
    }

    private fun clearViews() {
        root = null
        nameView = null
        numberView = null
        directionView = null
        durationView = null
        current = null
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    private fun onViewDetails(context: Context) {
        val data = current ?: return

        // Persisted so NativeBridge can forward it to Flutter even if the
        // engine is not running yet and the intent extra arrives before Dart
        // has subscribed.
        PostCallData.save(context, data)

        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(PostCallData.EXTRA_OPEN_CALL, data.startedAtMillis)
            }

        // Starting an activity from here is a background activity start, which
        // Android 10+ restricts. Holding SYSTEM_ALERT_WINDOW is one of the
        // documented exemptions, and it is already a precondition for the card
        // being on screen at all.
        try {
            launch?.let { context.startActivity(it) }
        } catch (e: Exception) {
            Log.w(TAG, "Could not open the app from the post-call card: ${e.message}")
        }

        dismiss()
    }

    // -------------------------------------------------------------------------
    // View construction
    // -------------------------------------------------------------------------

    private fun buildCard(ctx: Context, d: PostCallData): LinearLayout {
        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = roundedBackground(ctx, Color.parseColor("#E81A1A2E"), 20)
            elevation = dp(ctx, 8).toFloat()
        }

        card.addView(buildHeader(ctx), LinearLayout.LayoutParams(LP_MATCH, LP_WRAP))
        card.addView(buildBody(ctx, d))
        return card
    }

    private fun buildHeader(ctx: Context): LinearLayout {
        val header = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            background = roundedTopBackground(ctx, Color.parseColor("#FF26264A"), 20)
            setPadding(dp(ctx, 14), dp(ctx, 10), dp(ctx, 14), dp(ctx, 10))
            gravity = Gravity.CENTER_VERTICAL
        }

        header.addView(
            ImageView(ctx).apply {
                setImageResource(R.mipmap.ic_launcher)
                val size = dp(ctx, 20)
                layoutParams = LinearLayout.LayoutParams(size, size)
            },
        )

        header.addView(
            TextView(ctx).apply {
                text = "Zebu Call Tracker"
                setTextColor(Color.parseColor("#FFCCCCDD"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
                layoutParams = LinearLayout.LayoutParams(0, LP_WRAP, 1f).apply {
                    leftMargin = dp(ctx, 8)
                }
            },
        )

        header.addView(
            TextView(ctx).apply {
                text = "✕"
                setTextColor(Color.parseColor("#99AAAACC"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                setPadding(dp(ctx, 8), 0, 0, 0)
                setOnClickListener { dismiss() }
            },
        )

        return header
    }

    private fun buildBody(ctx: Context, d: PostCallData): LinearLayout {
        val body = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 18), dp(ctx, 14), dp(ctx, 18), dp(ctx, 16))
        }

        val direction = TextView(ctx).apply {
            text = directionLabel(d.direction)
            setTextColor(Color.parseColor("#FFAAAACC"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        }
        directionView = direction
        body.addView(direction)
        body.addView(spacer(ctx, dp(ctx, 6)))

        val name = TextView(ctx).apply {
            text = d.displayName
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        nameView = name
        body.addView(name)

        // Always constructed, hidden until enrichment has a number worth
        // showing — the card is built before the log has been read, and adding
        // a view to a live window later is more fragile than toggling one.
        val number = TextView(ctx).apply {
            text = d.phoneNumber
            setTextColor(Color.parseColor("#CC99AABB"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            visibility =
                if (d.phoneNumber.isNotBlank() && d.phoneNumber != d.displayName) {
                    View.VISIBLE
                } else {
                    View.GONE
                }
            layoutParams = LinearLayout.LayoutParams(LP_WRAP, LP_WRAP).apply {
                topMargin = dp(ctx, 2)
            }
        }
        numberView = number
        body.addView(number)

        body.addView(spacer(ctx, dp(ctx, 12)))
        body.addView(
            View(ctx).apply {
                setBackgroundColor(Color.parseColor("#22AAAACC"))
                layoutParams = LinearLayout.LayoutParams(LP_MATCH, 1)
            },
        )
        body.addView(spacer(ctx, dp(ctx, 12)))

        val duration = TextView(ctx).apply {
            text = "⏱  " + formatDuration(d.durationSeconds)
            setTextColor(Color.parseColor("#FFDDDDEE"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        }
        durationView = duration
        body.addView(duration)
        body.addView(spacer(ctx, dp(ctx, 6)))

        // Deliberately says nothing about a recording.
        //
        // The card used to claim "Recording found" or "No recording" eight
        // seconds after the call. It cannot know: the OEM dialers on this fleet
        // write the audio file after the call-log row and MediaStore indexes it
        // later still, which is exactly why the ingest scheduler runs delayed
        // passes at ten and thirty seconds. "No recording" was wrong on most
        // recorded calls. This line is true whatever happens next.
        body.addView(
            TextView(ctx).apply {
                text = "☁  Saved — syncing in the background"
                setTextColor(Color.parseColor("#88AAAACC"))
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            },
        )

        body.addView(spacer(ctx, dp(ctx, 16)))
        body.addView(buildButtons(ctx))
        return body
    }

    private fun buildButtons(ctx: Context): LinearLayout {
        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        row.addView(
            button(ctx, "View Details", Color.parseColor("#FF3D5AFE"), Color.WHITE, 1f) {
                onViewDetails(ctx)
            },
        )
        row.addView(View(ctx).apply { layoutParams = LinearLayout.LayoutParams(dp(ctx, 10), 1) })
        row.addView(
            button(
                ctx,
                "Close",
                Color.parseColor("#22AAAACC"),
                Color.parseColor("#FFCCCCDD"),
                0.6f,
            ) { dismiss() },
        )

        return row
    }

    private fun button(
        ctx: Context,
        label: String,
        bgColor: Int,
        fgColor: Int,
        weight: Float,
        onClick: () -> Unit,
    ): TextView = TextView(ctx).apply {
        text = label
        setTextColor(fgColor)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
        background = GradientDrawable().apply {
            setColor(bgColor)
            cornerRadius = dp(ctx, 10).toFloat()
        }
        setPadding(dp(ctx, 8), dp(ctx, 12), dp(ctx, 8), dp(ctx, 12))
        layoutParams = LinearLayout.LayoutParams(0, LP_WRAP, weight)
        setOnClickListener { onClick() }
    }

    // -------------------------------------------------------------------------
    // Small helpers
    // -------------------------------------------------------------------------

    private fun roundedBackground(ctx: Context, color: Int, radiusDp: Int) =
        GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(ctx, radiusDp).toFloat()
        }

    private fun roundedTopBackground(ctx: Context, color: Int, radiusDp: Int) =
        GradientDrawable().apply {
            setColor(color)
            val r = dp(ctx, radiusDp).toFloat()
            cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
        }

    private fun spacer(ctx: Context, heightPx: Int): View = View(ctx).apply {
        layoutParams = LinearLayout.LayoutParams(LP_MATCH, heightPx)
    }

    private fun dp(ctx: Context, value: Int): Int =
        (value * ctx.resources.displayMetrics.density + 0.5f).toInt()

    private fun directionLabel(dir: String): String = when (dir) {
        "incoming" -> "↙  Incoming call"
        "outgoing" -> "↗  Outgoing call"
        "missed" -> "↙  Missed call"
        "rejected" -> "↙  Rejected call"
        "blocked" -> "↙  Blocked call"
        "voicemail" -> "↙  Voicemail"
        else -> "↔  Call ended"
    }

    private fun formatDuration(sec: Int): String {
        if (sec <= 0) return "Not answered"
        val m = sec / 60
        val s = sec % 60
        return if (m > 0) "$m min $s sec" else "$s sec"
    }

    private const val LP_WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
    private const val LP_MATCH = ViewGroup.LayoutParams.MATCH_PARENT
}
