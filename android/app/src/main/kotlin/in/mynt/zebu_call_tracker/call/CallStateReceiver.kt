package `in`.mynt.zebu_call_tracker.call

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager
import android.util.Log

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
 *    broadcast, so nothing is started here.
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
        CallStateJournal.record(context, state.lowercase(), System.currentTimeMillis())
    }

    companion object {
        private const val TAG = "CallStateReceiver"
    }
}
