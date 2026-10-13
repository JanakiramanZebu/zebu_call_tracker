package `in`.mynt.zebu_call_tracker.platform

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log

/**
 * Notices, after the fact, that the app was force-stopped.
 *
 * Android delivers nothing to a force-stopped app: no call broadcasts, no
 * scheduled work, no FCM push, no boot event, until the user opens it again.
 * Nothing can wake it, and nothing should try to. What the app can do is
 * notice when it is next opened, so the user learns why tracking stopped and
 * does not do it again. The calls themselves are recovered from the call log
 * by the next ingest.
 *
 * Android 11+ only: older versions keep no exit history.
 */
object ForceStopDetector {

    private const val TAG = "ForceStopDetector"
    private const val PREFS = "zebu_force_stop"
    private const val KEY_ACKNOWLEDGED = "acknowledged_at"

    /** Only a recent stop is worth telling the user about. */
    private const val RELEVANT_FOR_MILLIS = 7L * 24L * 60L * 60L * 1000L

    /**
     * When the last process exit was a user-requested stop that the user has
     * not been told about; 0 when there is none.
     *
     * `REASON_USER_REQUESTED` is "Force stop" in Settings, and on the firmware
     * that treats it so, swiping the app out of Recents.
     */
    fun unacknowledgedStopAtMillis(context: Context): Long {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return 0L
        return try {
            val am = context.getSystemService(ActivityManager::class.java) ?: return 0L
            val last = am.getHistoricalProcessExitReasons(context.packageName, 0, 1)
                .firstOrNull() ?: return 0L
            if (last.reason != ApplicationExitInfo.REASON_USER_REQUESTED) return 0L
            val at = last.timestamp
            val acknowledged = prefs(context).getLong(KEY_ACKNOWLEDGED, 0L)
            val recent = System.currentTimeMillis() - at < RELEVANT_FOR_MILLIS
            if (at > acknowledged && recent) at else 0L
        } catch (e: Exception) {
            Log.w(TAG, "Could not read exit history: ${e.message}")
            0L
        }
    }

    /** The user has seen it. */
    fun acknowledge(context: Context) {
        prefs(context).edit().putLong(KEY_ACKNOWLEDGED, System.currentTimeMillis()).apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
