package `in`.mynt.zebu_call_tracker.call

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.telephony.TelephonyManager
import android.util.Log
import `in`.mynt.zebu_call_tracker.background.BackgroundScheduler
import `in`.mynt.zebu_call_tracker.background.IngestStore
import `in`.mynt.zebu_call_tracker.overlay.PostCallData
import `in`.mynt.zebu_call_tracker.overlay.PostCallOverlayController
import `in`.mynt.zebu_call_tracker.recording.RecordingScanner

/**
 * Background call-state entry point.
 *
 * ACTION_PHONE_STATE_CHANGED is on the implicit-broadcast exemption list, so a
 * manifest receiver still wakes a stopped process on Android 8+. This is why
 * detection survives the app being backgrounded or killed.
 *
 * Intentionally does almost nothing:
 *  - onReceive runs on the main thread with a ~10s budget, so no I/O beyond a
 *    small SharedPreferences write.
 *  - Android 12+ forbids starting a foreground service from a background
 *    broadcast, so nothing is started here. Enqueuing WorkManager work IS
 *    allowed, and that is how the actual capture happens.
 *  - Reconciliation is cursor-based against the call log, which is itself
 *    durable, so deferring it loses no data.
 *
 * The phone number carried in this broadcast is deliberately ignored: from API
 * 28 it requires READ_CALL_LOG anyway, and the log row is both authoritative
 * and complete.
 */
class CallStateReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return

        val normalised = state.lowercase()
        val now = System.currentTimeMillis()

        // From API 29 an app holding READ_CALL_LOG receives every transition
        // twice — once with the number extra and once without. Without this
        // each call ended with two immediate ingests, two sets of delayed
        // passes and two journal entries. A genuine repeat of the same state
        // cannot happen this quickly: another transition always comes between.
        if (normalised == lastState && now - lastStateAtMillis < DUPLICATE_WINDOW_MILLIS) {
            return
        }
        lastState = normalised
        lastStateAtMillis = now

        // Never log the number — privacy requirement, and it is unused here.
        Log.i(TAG, "phone state -> $state")
        CallStateJournal.record(context, normalised, now)

        // IDLE is the transition that matters: the call has finished, so the
        // log row and — critically — the dialer's recording file now exist.
        // Capturing on RINGING/OFFHOOK would run before either is written.
        //
        // Only for a signed-in handset. A call taken while signed out belongs
        // to no employee; the call log is durable, so the cursor picks it up
        // after sign-in if it should be captured at all. (BackgroundScheduler
        // enforces the same rule; checked here too so a signed-out phone does
        // not even wake WorkManager.)
        if (normalised == "idle" && IngestStore.hasSession(context)) {
            // WorkManager, not a direct service start. The class comment above
            // is the reason: from Android 12 a background broadcast may not
            // start a foreground service, and this receiver runs with the app
            // backgrounded by definition. A revision that called
            // CallTrackingService.triggerImmediate() from here threw
            // ForegroundServiceStartNotAllowedException into a catch block on
            // every single call, so the immediate pass never actually ran and
            // capture silently fell back to the delayed passes below.
            BackgroundScheduler.enqueueNow(context, BackgroundScheduler.REASON_CALL_ENDED)

            // One delayed pass, as a fallback for a dialer that indexes its
            // recording after the call-log row. There used to be two (10 s and
            // 30 s) on every call; the MediaStore content trigger now links
            // the file within seconds of it appearing, so this only covers a
            // trigger the system dropped or deferred. 30 s lands it inside the
            // 45 s hold on the call's sync, so the audio still rides with the
            // metadata.
            //
            // Not queued when it cannot find anything: a call that never went
            // off-hook (missed, rejected) has no recording, and without the
            // media permission nothing can be read. The worker also skips it
            // if, by the time it runs, no captured call is still waiting.
            if (connectedThisCall(context) && RecordingScanner.hasPermission(context)) {
                BackgroundScheduler.enqueueDelayedIngest(
                    context,
                    RECORDING_FALLBACK_DELAY_SECONDS,
                    "${BackgroundScheduler.REASON_RECORDING_PASS_PREFIX}${RECORDING_FALLBACK_DELAY_SECONDS}s",
                )
            }
        }

        if (normalised == "idle") {
            showPostCallOverlay(context)
        } else {
            // A new call is ringing or being dialled. The post-call card stays
            // up until the user closes it, so without this it would sit over
            // the dialer's in-call screen — TYPE_APPLICATION_OVERLAY draws above
            // ordinary activities, the incoming-call screen included.
            PostCallOverlayController.dismiss()
        }
    }

    /**
     * Whether the call that just ended ever went off-hook, per the journal.
     *
     * Off-hook is the only transition that can precede a recording: it is the
     * pickup for an incoming call and the dial for an outgoing one. A call
     * that only rang was missed or rejected. Reads the small journal blob
     * that [CallStateJournal.record] has just written — no other I/O.
     */
    private fun connectedThisCall(context: Context): Boolean =
        entriesForLatestCall(journalEntries(context)).any { it.first == "offhook" }

    /**
     * Hands the just-ended call to [PostCallOverlayController].
     *
     * Only a seed is assembled here. `onReceive` runs on the main thread with a
     * ten-second budget, so this does no I/O: the controller reads the call log
     * on its own thread and patches the real number, name, direction and
     * duration into the card once it is already on screen.
     *
     * There is no service to start. The card is a plain WindowManager view now,
     * because the foreground service this used to launch could not start on any
     * supported API level — see the class comment on
     * [PostCallOverlayController] for the two separate reasons why.
     */
    private fun showPostCallOverlay(context: Context) {
        if (!Settings.canDrawOverlays(context)) return

        val entries = journalEntries(context)

        // Only transitions belonging to THIS call. The journal is a flat,
        // bounded list with no call identity of its own, and the previous
        // revision read `takeLast(5)` — which spans whatever came before, so a
        // "ringing" left over from the last call made an outgoing one look
        // incoming. Cutting at the last idle before the current one bounds it
        // to a single call.
        val thisCall = entriesForLatestCall(entries)

        val states = thisCall.map { it.first }
        val direction = when {
            states.contains("ringing") && states.contains("offhook") -> "incoming"
            states.contains("ringing") -> "missed"
            states.contains("offhook") -> "outgoing"
            else -> "unknown"
        }

        val offHookAt = thisCall.lastOrNull { it.first == "offhook" }?.second
        val idleAt = thisCall.lastOrNull { it.first == "idle" }?.second
            ?: System.currentTimeMillis()
        val approxDurationSec = if (offHookAt != null) {
            ((idleAt - offHookAt) / 1000L).toInt().coerceAtLeast(0)
        } else {
            0
        }

        PostCallOverlayController.show(
            context,
            PostCallData(
                // Placeholders, replaced within a second by the call log. They
                // are never left on screen unless the log is unreadable.
                displayName = "Call ended",
                phoneNumber = "",
                direction = direction,
                durationSeconds = approxDurationSec,
                hasRecording = false,
                startedAtMillis = offHookAt ?: idleAt,
            ),
        )
    }

    /** The journal as (state, atMillis) pairs, oldest first. */
    private fun journalEntries(context: Context): List<Pair<String, Long>> =
        CallStateJournal.snapshot(context)

    /**
     * The tail of [entries] belonging to the call that has just finished.
     *
     * The last entry is this call's `idle`; the call started after the previous
     * one, so everything from the second-to-last `idle` onwards is ours.
     */
    private fun entriesForLatestCall(
        entries: List<Pair<String, Long>>,
    ): List<Pair<String, Long>> {
        if (entries.isEmpty()) return entries
        val previousIdle = entries
            .dropLast(1)
            .indexOfLast { it.first == "idle" }
        return if (previousIdle >= 0) entries.drop(previousIdle + 1) else entries
    }

    companion object {
        private const val TAG = "CallStateReceiver"

        /** Long enough to swallow the API 29+ double delivery, far shorter than any call. */
        private const val DUPLICATE_WINDOW_MILLIS = 2_000L

        /**
         * The fallback recording pass. Kept under the sync's
         * [BackgroundScheduler.SYNC_AFTER_RECORDING_DELAY_SECONDS] hold.
         */
        private const val RECORDING_FALLBACK_DELAY_SECONDS = 30L

        // Process-wide: the system creates a new receiver instance per
        // broadcast. onReceive always runs on the main thread, so no locking.
        private var lastState: String? = null
        private var lastStateAtMillis = 0L
    }
}