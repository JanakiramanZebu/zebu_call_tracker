package `in`.mynt.zebu_call_tracker.call

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.telephony.TelephonyManager
import android.util.Log
import `in`.mynt.zebu_call_tracker.background.BackgroundScheduler
import `in`.mynt.zebu_call_tracker.overlay.PostCallData
import `in`.mynt.zebu_call_tracker.overlay.PostCallOverlayService

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

        // Never log the number — privacy requirement, and it is unused here.
        Log.i(TAG, "phone state -> $state")
        val normalised = state.lowercase()
        CallStateJournal.record(context, normalised, System.currentTimeMillis())

        // IDLE is the transition that matters: the call has finished, so the
        // log row and — critically — the dialer's recording file now exist.
        // Capturing on RINGING/OFFHOOK would run before either is written.
        if (normalised == "idle") {
            // Trigger immediate unthrottled background processing in our active service
            `in`.mynt.zebu_call_tracker.background.CallTrackingService.triggerImmediate(context, "call_ended")
            
            // Queue delayed ingest passes to capture late MediaStore indexing by OEM dialers
            BackgroundScheduler.enqueueDelayedIngest(context, 10L, "call_ended_delay_10s")
            BackgroundScheduler.enqueueDelayedIngest(context, 30L, "call_ended_delay_30s")
            
            showPostCallOverlay(context)
        }
    }

    /**
     * Launches [PostCallOverlayService] if the overlay permission is held.
     *
     * We derive call data from the journal (which was just updated) and the
     * most recent call-log entry. If OVERLAY is not granted, this is a silent
     * no-op — the overlay is opt-in, not required for tracking.
     *
     * Starting a service from a broadcast receiver is only blocked for
     * *foreground* services on API 31+. PostCallOverlayService uses
     * foregroundServiceType=phoneCall, which is an explicit exemption even
     * in Android 12, so this is allowed.
     */
    private fun showPostCallOverlay(context: Context) {
        if (!Settings.canDrawOverlays(context)) return

        // Reconstruct the last call from the journal entries.
        val journal = CallStateJournal.read(context)
        @Suppress("UNCHECKED_CAST")
        val entries = (journal["entries"] as? List<Map<String, Any?>>).orEmpty()

        // Determine direction from the ringing → offhook → idle sequence.
        val states = entries.takeLast(5).map { it["state"] as? String }
        val direction = when {
            states.contains("offhook") && states.contains("ringing") -> "incoming"
            states.contains("offhook")                               -> "outgoing"
            else                                                      -> "missed"
        }

        // Build a minimal PostCallData from the journal; the call-log reconciler
        // will fill in duration and contact once WorkManager runs. For the
        // overlay we only need what is available right now.
        val last = entries.lastOrNull { it["state"] == "offhook" }
        val startedAt = (last?.get("atMillis") as? Long) ?: System.currentTimeMillis()
        val idleAt = (entries.lastOrNull { it["state"] == "idle" }?.get("atMillis") as? Long)
            ?: System.currentTimeMillis()
        val approxDurationSec = if (direction != "missed") {
            ((idleAt - startedAt) / 1000L).toInt().coerceAtLeast(0)
        } else 0

        val data = PostCallData(
            displayName     = "Recent call",   // Dart enriches this later
            phoneNumber     = "",              // withheld at this point
            direction       = direction,
            durationSeconds = approxDurationSec,
            hasRecording    = false,           // not yet scanned; Dart updates
            startedAtMillis = startedAt,
        )

        try {
            val serviceIntent = PostCallData.intoIntent(context, data)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // startForegroundService is needed on O+ when the service will call
                // startForeground(); the service itself does so only on API 34+, but
                // it is safe to use startForegroundService on O–13 as well since the
                // service always calls startForeground within 5 seconds.
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (e: Exception) {
            Log.w(TAG, "PostCallOverlay service could not be started from background: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "CallStateReceiver"
    }
}