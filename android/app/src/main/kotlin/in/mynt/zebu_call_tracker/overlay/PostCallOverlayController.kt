package `in`.mynt.zebu_call_tracker.overlay

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.content.res.ColorStateList
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.text.format.DateFormat
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.animation.DecelerateInterpolator
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import `in`.mynt.zebu_call_tracker.R
import `in`.mynt.zebu_call_tracker.call.CallLogReader
import `in`.mynt.zebu_call_tracker.call.ContactResolver
import java.util.Date
import java.util.concurrent.Executors
import kotlin.math.min

/**
 * Draws the post-call summary card over whatever is on screen.
 *
 * The card sits in the middle of the screen over a dimmed scrim and stays until
 * the user closes it — Close, View details or Call back. It never times out.
 * It is taken down by the next call instead: [dismiss] runs from
 * [in.mynt.zebu_call_tracker.call.CallStateReceiver] on RINGING and OFFHOOK, so
 * a card left up never covers the dialer's in-call screen.
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
 *    `ForegroundServiceDidNotStartInTimeException` at the process.
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
 * "View details" and "Call back" taps from the background-activity-start
 * restriction.
 *
 * So there is no service, no foreground notification, no type permission and no
 * five-second deadline. A window added to [WindowManager] raises the process's
 * `hasOverlayUi` flag, which holds it at perceptible priority while the card is
 * up.
 *
 * ## Window
 *
 * One full-screen window: the scrim is the window's own background and the card
 * is centred in it. A full-screen window is the only way to stop a tap beside
 * the card from reaching the app underneath — `FLAG_NOT_FOCUSABLE` (which keeps
 * the keyboard and the back button with that app) implies
 * `FLAG_NOT_TOUCH_MODAL`, so a card-sized window would let outside touches
 * through. `TYPE_APPLICATION_OVERLAY` sits below the status and navigation
 * bars, so Home, Back and the notification shade still work.
 *
 * ## Look
 *
 * The app's v3 design: a Zebu-blue strip, the caller, a ruled three-fact row and
 * solid buttons, in IBM Plex Sans loaded from the Flutter bundle. Light or dark
 * follows the app's Appearance setting, read from the plugin's
 * SharedPreferences file (`flutter.appearance`), and the phone's own dark mode
 * when that is System.
 *
 * ## Lifecycle
 *
 * `show()` → `addView` → a tap or the next call → `removeView`.
 * Main-thread only; [show] and [dismiss] post themselves there if called from
 * anywhere else.
 */
object PostCallOverlayController {

    private const val TAG = "PostCallOverlay"

    /**
     * How far back a call-log row may sit and still be "the call that just
     * ended". Generous because the OEM dialers on this fleet write the row a
     * beat after IDLE, and the clock is the device's own either way.
     */
    private const val LOG_MATCH_WINDOW_MILLIS = 120_000L

    /** One retry, for dialers that have not written the row by IDLE. */
    private const val ENRICH_RETRY_DELAY_MILLIS = 1_200L

    /** The card never grows wider than this, on tablets and landscape. */
    private const val CARD_MAX_WIDTH_DP = 360

    /** Font files bundled by Flutter (pubspec.yaml); see [font]. */
    private const val FONT_DIR = "flutter_assets/assets/fonts/"

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
    private var root: FrameLayout? = null
    private var current: PostCallData? = null

    private val fonts = HashMap<Int, Typeface>()

    // -------------------------------------------------------------------------
    // Entry points
    // -------------------------------------------------------------------------

    /**
     * Shows the card for a call that has just ended.
     *
     * [seed] is whatever the receiver could work out synchronously, which is
     * little: a direction guessed from the state journal and an approximate
     * duration. The card goes up with that immediately and the real number,
     * contact name, direction and duration are read off the call log on a
     * background thread, after which the card's content is rebuilt in place.
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

        enrich(app, seed, isRetry = false)
    }

    /** Takes the card down, if it is up. Safe to call at any time. */
    fun dismiss() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { dismiss() }
            return
        }
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
                // card keeps the seed's values.
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
                isContact = name != null,
            )

            handler.post { applyEnrichment(context, enriched) }
        }
    }

    /**
     * Rebuilds the card from [data]. Only while it is still on screen.
     *
     * A rebuild rather than patching views: the log can change the direction
     * the seed guessed, and a missed call has a different set of buttons from
     * an answered one.
     */
    private fun applyEnrichment(context: Context, data: PostCallData) {
        val host = root ?: return
        current = data
        host.removeAllViews()
        host.addView(buildCard(context, data, paletteFor(context)), cardLayoutParams(context))
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

        val p = paletteFor(context)
        val host = FrameLayout(context).apply {
            setBackgroundColor(p.scrim)
            // The scrim swallows taps so nothing behind the card is pressed by
            // accident. It does not close the card: only the buttons do.
            isClickable = true
            isFocusable = false
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            addView(buildCard(context, data, p), cardLayoutParams(context))
        }
        root = host

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            type,
            // NOT_FOCUSABLE keeps the keyboard and the back button with
            // whatever is underneath; the window is full-screen, so touches
            // still land on the scrim and the card rather than passing through.
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.CENTER
        }

        wm.addView(host, params)

        // One entrance: the scrim fades in and the card settles from a touch
        // below and slightly smaller. ViewPropertyAnimator honours the system
        // animation scale, so "Remove animations" makes this instant.
        host.alpha = 0f
        host.animate().alpha(1f).setDuration(200).start()
        host.getChildAt(0)?.apply {
            alpha = 0f
            translationY = dp(context, 12).toFloat()
            scaleX = 0.97f
            scaleY = 0.97f
            animate()
                .alpha(1f)
                .translationY(0f)
                .scaleX(1f)
                .scaleY(1f)
                .setDuration(260)
                .setInterpolator(DecelerateInterpolator(2f))
                .withEndAction {
                    sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED)
                }
                .start()
        }
    }

    private fun cardLayoutParams(context: Context): FrameLayout.LayoutParams {
        val screen = context.resources.displayMetrics.widthPixels
        val width = min(screen - dp(context, 48), dp(context, CARD_MAX_WIDTH_DP))
        return FrameLayout.LayoutParams(width, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER)
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
        current = null
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    private fun onViewDetails(context: Context) {
        val data = current ?: return

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

    /**
     * Opens the dialer with the number filled in. ACTION_DIAL, not ACTION_CALL:
     * it needs no CALL_PHONE permission and the user still presses call, so a
     * mis-tap never rings anyone.
     */
    private fun onCallBack(context: Context) {
        val number = current?.phoneNumber?.takeIf { it.isNotBlank() } ?: return
        try {
            context.startActivity(
                Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", number, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (e: Exception) {
            Log.w(TAG, "No dialer for call back: ${e.message}")
        }
        dismiss()
    }

    // -------------------------------------------------------------------------
    // Palette
    // -------------------------------------------------------------------------

    /** The app's ZColors values the card uses, for one brightness. */
    private class Palette(
        val scrim: Int,
        val raised: Int,
        val line: Int,
        val ink: Int,
        val ink2: Int,
        val ink3: Int,
        val primary: Int,
        val secondary: Int,
        val onSecondary: Int,
        val incoming: Int,
        val outgoing: Int,
        val missed: Int,
        val rejected: Int,
        val noAnswer: Int,
        val ok: Int,
    )

    private val DARK = Palette(
        scrim = 0xAD04070C.toInt(),
        raised = 0xFF121925.toInt(),
        line = 0xFF1D2635.toInt(),
        ink = 0xFFE8EDF5.toInt(),
        ink2 = 0xFFAEB8CA.toInt(),
        ink3 = 0xFF808CA2.toInt(),
        primary = 0xFF2F5FE0.toInt(),
        secondary = 0xFF1A2333.toInt(),
        onSecondary = 0xFFE8EDF5.toInt(),
        incoming = 0xFF4CC795.toInt(),
        outgoing = 0xFF7FA6FF.toInt(),
        missed = 0xFFEE6C78.toInt(),
        rejected = 0xFFE0995F.toInt(),
        noAnswer = 0xFFD4AE5A.toInt(),
        ok = 0xFF4CC795.toInt(),
    )

    private val LIGHT = Palette(
        scrim = 0x750F1726,
        raised = 0xFFFFFFFF.toInt(),
        line = 0xFFE2E5EA.toInt(),
        ink = 0xFF0F1726.toInt(),
        ink2 = 0xFF3D4859.toInt(),
        ink3 = 0xFF5C6779.toInt(),
        primary = 0xFF0037B7.toInt(),
        secondary = 0xFFE9ECF1.toInt(),
        onSecondary = 0xFF0F1726.toInt(),
        incoming = 0xFF0E7A51.toInt(),
        outgoing = 0xFF0037B7.toInt(),
        missed = 0xFFBF3440.toInt(),
        rejected = 0xFFA3561A.toInt(),
        noAnswer = 0xFF866300.toInt(),
        ok = 0xFF0E7A51.toInt(),
    )

    private val ZEBU_BLUE = 0xFF0037B7.toInt()
    private val ON_BRAND_MUTED = 0xD1FFFFFF.toInt()

    /**
     * Light or dark, matching the app. The Flutter side stores the Appearance
     * choice as `appearance` through shared_preferences, which on Android is
     * the `FlutterSharedPreferences` file with a `flutter.` prefix.
     */
    private fun paletteFor(context: Context): Palette {
        val choice = try {
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getString("flutter.appearance", null)
        } catch (_: Exception) {
            null
        }
        val dark = when (choice) {
            "dark" -> true
            "light" -> false
            else -> (context.resources.configuration.uiMode and
                Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        }
        return if (dark) DARK else LIGHT
    }

    // -------------------------------------------------------------------------
    // View construction
    // -------------------------------------------------------------------------

    private enum class Kind { INCOMING, OUTGOING, NO_ANSWER, MISSED, REJECTED, OTHER }

    private fun kindOf(d: PostCallData): Kind = when (d.direction) {
        "incoming" -> Kind.INCOMING
        "outgoing" -> if (d.durationSeconds > 0) Kind.OUTGOING else Kind.NO_ANSWER
        "missed" -> Kind.MISSED
        "rejected", "blocked" -> Kind.REJECTED
        else -> Kind.OTHER
    }

    private fun buildCard(ctx: Context, d: PostCallData, p: Palette): LinearLayout {
        val radius = dp(ctx, 20).toFloat()
        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(p.raised)
                cornerRadius = radius
            }
            clipToOutline = true
            elevation = dp(ctx, 12).toFloat()
            // The card itself is not a button; taps on its body do nothing.
            isClickable = true
        }
        card.addView(buildStrip(ctx, d), LinearLayout.LayoutParams(LP_MATCH, LP_WRAP))
        card.addView(buildBody(ctx, d, p), LinearLayout.LayoutParams(LP_MATCH, LP_WRAP))
        return card
    }

    /** The Zebu-blue strip: app mark, name, and when the call ended. */
    private fun buildStrip(ctx: Context, d: PostCallData): LinearLayout {
        val strip = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(ZEBU_BLUE)
            setPadding(dp(ctx, 16), dp(ctx, 12), dp(ctx, 16), dp(ctx, 12))
        }

        val markSize = dp(ctx, 26)
        strip.addView(
            FrameLayout(ctx).apply {
                background = GradientDrawable().apply {
                    setColor(Color.WHITE)
                    cornerRadius = dp(ctx, 8).toFloat()
                }
                addView(
                    ImageView(ctx).apply {
                        setImageResource(R.drawable.ic_launcher_monochrome)
                        setColorFilter(ZEBU_BLUE)
                        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                    },
                    FrameLayout.LayoutParams(markSize, markSize),
                )
            },
            LinearLayout.LayoutParams(markSize, markSize),
        )

        strip.addView(
            text(ctx, "Zebu Call Tracker", 13f, 600, Color.WHITE),
            LinearLayout.LayoutParams(0, LP_WRAP, 1f).apply { leftMargin = dp(ctx, 10) },
        )

        val at = if (d.startedAtMillis > 0) {
            DateFormat.getTimeFormat(ctx).format(Date(d.startedAtMillis + d.durationSeconds * 1000L))
        } else {
            null
        }
        val kind = kindOf(d)
        val whenLabel = when {
            at == null -> null
            kind == Kind.MISSED -> "Missed at $at"
            kind == Kind.REJECTED -> "Declined at $at"
            else -> "Ended at $at"
        }
        if (whenLabel != null) {
            strip.addView(text(ctx, whenLabel, 12f, 400, ON_BRAND_MUTED))
        }
        return strip
    }

    private fun buildBody(ctx: Context, d: PostCallData, p: Palette): LinearLayout {
        val kind = kindOf(d)
        val body = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(ctx, 20), dp(ctx, 20), dp(ctx, 20), dp(ctx, 18))
        }

        // Direction: glyph + label in the outcome colour.
        val (dirColor, dirLabel, glyph) = when (kind) {
            Kind.INCOMING -> Triple(p.incoming, "Incoming call", Glyph.INCOMING)
            Kind.OUTGOING -> Triple(p.outgoing, "Outgoing call", Glyph.OUTGOING)
            Kind.NO_ANSWER -> Triple(p.noAnswer, "Outgoing call, not answered", Glyph.OUTGOING)
            Kind.MISSED -> Triple(p.missed, "Missed call", Glyph.MISSED)
            Kind.REJECTED -> Triple(p.rejected, "Declined call", Glyph.REJECTED)
            Kind.OTHER -> Triple(p.ink3, "Call ended", Glyph.UNKNOWN)
        }
        body.addView(
            LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(
                    GlyphView(ctx, glyph, dirColor),
                    LinearLayout.LayoutParams(dp(ctx, 13), dp(ctx, 13)),
                )
                addView(
                    text(ctx, dirLabel, 13f, 600, dirColor),
                    LinearLayout.LayoutParams(LP_WRAP, LP_WRAP).apply { leftMargin = dp(ctx, 6) },
                )
            },
        )

        body.addView(
            text(ctx, d.displayName, 23f, 600, p.ink).apply {
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
                letterSpacing = -0.02f
            },
            LinearLayout.LayoutParams(LP_MATCH, LP_WRAP).apply { topMargin = dp(ctx, 6) },
        )

        val second = when {
            d.isContact && d.phoneNumber.isNotBlank() -> d.phoneNumber
            !d.isContact && d.phoneNumber.isNotBlank() -> "Not in your contacts"
            else -> null
        }
        if (second != null) {
            body.addView(
                text(ctx, second, 15f, 400, p.ink2).apply { tabular() },
                LinearLayout.LayoutParams(LP_MATCH, LP_WRAP).apply { topMargin = dp(ctx, 2) },
            )
        }

        body.addView(
            buildFacts(ctx, d, kind, p),
            LinearLayout.LayoutParams(LP_MATCH, LP_WRAP).apply { topMargin = dp(ctx, 16) },
        )

        // Deliberately says nothing about a recording.
        //
        // The card used to claim "Recording found" or "No recording" moments
        // after the call. It cannot know: the OEM dialers on this fleet write
        // the audio file after the call-log row and MediaStore indexes it later
        // still, which is exactly why the ingest scheduler runs a delayed pass.
        // "No recording" was wrong on most recorded calls. This line is true
        // whatever happens next.
        body.addView(
            LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(
                    GlyphView(ctx, Glyph.CHECK, p.ok),
                    LinearLayout.LayoutParams(dp(ctx, 15), dp(ctx, 15)),
                )
                addView(
                    text(ctx, "Saved on this phone. Sending to Zebu CRM.", 13f, 400, p.ink2),
                    LinearLayout.LayoutParams(LP_WRAP, LP_WRAP).apply { leftMargin = dp(ctx, 8) },
                )
            },
            LinearLayout.LayoutParams(LP_MATCH, LP_WRAP).apply { topMargin = dp(ctx, 16) },
        )

        body.addView(
            buildButtons(ctx, d, kind, p),
            LinearLayout.LayoutParams(LP_MATCH, LP_WRAP).apply { topMargin = dp(ctx, 16) },
        )
        return body
    }

    /** Three facts in a ruled row, like a confirmation slip. */
    private fun buildFacts(ctx: Context, d: PostCallData, kind: Kind, p: Palette): LinearLayout {
        val time = if (d.startedAtMillis > 0) {
            DateFormat.getTimeFormat(ctx).format(Date(d.startedAtMillis))
        } else {
            "—"
        }
        val facts: List<Pair<String, Pair<String, Int>>> = when (kind) {
            Kind.MISSED, Kind.REJECTED, Kind.NO_ANSWER -> listOf(
                "Rang at" to (time to p.ink),
                "Result" to (
                    when (kind) {
                        Kind.MISSED -> "Missed" to p.missed
                        Kind.REJECTED -> "Declined" to p.rejected
                        else -> "No answer" to p.noAnswer
                    }
                ),
                "Status" to ("Saved" to p.ink),
            )
            else -> listOf(
                "Talk time" to (stopwatch(d.durationSeconds) to p.ink),
                "Started" to (time to p.ink),
                "Status" to ("Saved" to p.ink),
            )
        }

        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            background = ruledTopBottom(ctx, p)
            setPadding(0, dp(ctx, 1), 0, dp(ctx, 1))
        }
        facts.forEachIndexed { i, (label, value) ->
            val cell = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(if (i == 0) 0 else dp(ctx, 14), dp(ctx, 12), dp(ctx, 4), dp(ctx, 12))
                if (i > 0) background = ruledLeft(ctx, p)
                addView(text(ctx, label, 12f, 400, p.ink3))
                addView(
                    text(ctx, value.first, 15f, 600, value.second).apply {
                        tabular()
                        maxLines = 1
                        ellipsize = TextUtils.TruncateAt.END
                    },
                    LinearLayout.LayoutParams(LP_WRAP, LP_WRAP).apply { topMargin = dp(ctx, 3) },
                )
            }
            row.addView(cell, LinearLayout.LayoutParams(0, LP_WRAP, 1f))
        }
        return row
    }

    private fun buildButtons(ctx: Context, d: PostCallData, kind: Kind, p: Palette): LinearLayout {
        val box = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }
        val canCallBack = (kind == Kind.MISSED || kind == Kind.REJECTED) &&
            d.phoneNumber.isNotBlank()

        if (canCallBack) {
            box.addView(
                button(ctx, "Call back", p.primary, Color.WHITE) { onCallBack(ctx) },
                LinearLayout.LayoutParams(LP_MATCH, dp(ctx, 50)),
            )
            box.addView(
                pair(
                    ctx,
                    button(ctx, "Close", p.secondary, p.onSecondary) { dismiss() },
                    button(ctx, "Details", p.secondary, p.onSecondary) { onViewDetails(ctx) },
                ),
                LinearLayout.LayoutParams(LP_MATCH, dp(ctx, 48)).apply { topMargin = dp(ctx, 10) },
            )
        } else {
            box.addView(
                pair(
                    ctx,
                    button(ctx, "Close", p.secondary, p.onSecondary) { dismiss() },
                    button(ctx, "View details", p.primary, Color.WHITE) { onViewDetails(ctx) },
                ),
                LinearLayout.LayoutParams(LP_MATCH, dp(ctx, 50)),
            )
        }
        return box
    }

    private fun pair(ctx: Context, a: View, b: View): LinearLayout =
        LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(a, LinearLayout.LayoutParams(0, LP_MATCH, 1f))
            addView(
                b,
                LinearLayout.LayoutParams(0, LP_MATCH, 1f).apply { leftMargin = dp(ctx, 10) },
            )
        }

    /** A solid, ripple-only button — a real [Button] so TalkBack announces it. */
    private fun button(
        ctx: Context,
        label: String,
        bg: Int,
        fg: Int,
        onClick: () -> Unit,
    ): Button = Button(ctx).apply {
        text = label
        isAllCaps = false
        setTextColor(fg)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        typeface = font(ctx, 600)
        gravity = Gravity.CENTER
        minHeight = 0
        minimumHeight = 0
        minWidth = 0
        minimumWidth = 0
        stateListAnimator = null
        elevation = 0f
        setPadding(dp(ctx, 12), 0, dp(ctx, 12), 0)
        val shape = GradientDrawable().apply {
            setColor(bg)
            cornerRadius = dp(ctx, 12).toFloat()
        }
        val mask = GradientDrawable().apply {
            setColor(Color.WHITE)
            cornerRadius = dp(ctx, 12).toFloat()
        }
        background = RippleDrawable(
            ColorStateList.valueOf((fg and 0x00FFFFFF) or 0x29000000),
            shape,
            mask,
        )
        setOnClickListener { onClick() }
    }

    private fun ruledTopBottom(ctx: Context, p: Palette) = object : ColorDrawable(Color.TRANSPARENT) {
        private val paint = Paint().apply { color = p.line }
        private val h = dp(ctx, 1).toFloat()
        override fun draw(canvas: Canvas) {
            val b = bounds
            canvas.drawRect(b.left.toFloat(), b.top.toFloat(), b.right.toFloat(), b.top + h, paint)
            canvas.drawRect(b.left.toFloat(), b.bottom - h, b.right.toFloat(), b.bottom.toFloat(), paint)
        }
    }

    private fun ruledLeft(ctx: Context, p: Palette) = object : ColorDrawable(Color.TRANSPARENT) {
        private val paint = Paint().apply { color = p.line }
        private val w = dp(ctx, 1).toFloat()
        override fun draw(canvas: Canvas) {
            val b = bounds
            canvas.drawRect(b.left.toFloat(), b.top.toFloat(), b.left + w, b.bottom.toFloat(), paint)
        }
    }

    // -------------------------------------------------------------------------
    // Glyphs — the same 16-unit call glyphs the Flutter app draws (CallGlyph)
    // -------------------------------------------------------------------------

    private enum class Glyph { INCOMING, OUTGOING, MISSED, REJECTED, UNKNOWN, CHECK }

    private class GlyphView(ctx: Context, private val glyph: Glyph, color: Int) : View(ctx) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }

        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        }

        override fun onDraw(canvas: Canvas) {
            val k = width / 16f
            paint.strokeWidth = 1.8f * k
            fun line(x1: Float, y1: Float, x2: Float, y2: Float) =
                canvas.drawLine(x1 * k, y1 * k, x2 * k, y2 * k, paint)
            when (glyph) {
                Glyph.INCOMING -> {
                    line(12f, 4f, 4f, 12f); line(4f, 6.5f, 4f, 12f); line(4f, 12f, 9.5f, 12f)
                }
                Glyph.OUTGOING -> {
                    line(4f, 12f, 12f, 4f); line(6.5f, 4f, 12f, 4f); line(12f, 4f, 12f, 9.5f)
                }
                Glyph.MISSED -> {
                    line(4.5f, 4.5f, 11.5f, 11.5f); line(11.5f, 4.5f, 4.5f, 11.5f)
                }
                Glyph.REJECTED -> {
                    canvas.drawCircle(8f * k, 8f * k, 5.25f * k, paint)
                    line(4.3f, 4.3f, 11.7f, 11.7f)
                }
                Glyph.UNKNOWN -> canvas.drawCircle(8f * k, 8f * k, 2.5f * k, paint)
                Glyph.CHECK -> {
                    line(3.5f, 8.5f, 6.5f, 11.5f); line(6.5f, 11.5f, 12.5f, 4.5f)
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Small helpers
    // -------------------------------------------------------------------------

    private fun text(ctx: Context, value: String, sizeSp: Float, weight: Int, color: Int) =
        TextView(ctx).apply {
            text = value
            setTextColor(color)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp)
            typeface = font(ctx, weight)
            includeFontPadding = false
            setLineSpacing(0f, 1.15f)
        }

    private fun TextView.tabular() {
        fontFeatureSettings = "tnum"
    }

    /**
     * IBM Plex Sans at [weight], from the Flutter asset bundle so the card
     * matches the app. Falls back to the system sans if the file is missing —
     * a wrong font is better than no card.
     */
    private fun font(ctx: Context, weight: Int): Typeface {
        val w = when {
            weight >= 700 -> 700
            weight >= 600 -> 600
            weight >= 500 -> 500
            else -> 400
        }
        fonts[w]?.let { return it }
        val file = when (w) {
            700 -> "IBMPlexSans-Bold.ttf"
            600 -> "IBMPlexSans-SemiBold.ttf"
            500 -> "IBMPlexSans-Medium.ttf"
            else -> "IBMPlexSans-Regular.ttf"
        }
        val face = try {
            Typeface.createFromAsset(ctx.assets, FONT_DIR + file)
        } catch (e: Exception) {
            Log.i(TAG, "Bundled font unavailable, using system sans: ${e.message}")
            if (w >= 600) Typeface.create("sans-serif-medium", Typeface.NORMAL) else Typeface.SANS_SERIF
        }
        fonts[w] = face
        return face
    }

    /** `4:12`, `1:02:05`. Matches Fmt.stopwatch on the Flutter side. */
    private fun stopwatch(sec: Int): String {
        if (sec <= 0) return "0:00"
        val h = sec / 3600
        val m = (sec % 3600) / 60
        val s = sec % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }

    private fun dp(ctx: Context, value: Int): Int =
        (value * ctx.resources.displayMetrics.density + 0.5f).toInt()

    private const val LP_WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
    private const val LP_MATCH = ViewGroup.LayoutParams.MATCH_PARENT
}
