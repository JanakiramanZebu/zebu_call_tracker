package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.net.URLEncoder

/**
 * `POST /devices/heartbeat`, from every sender the app has (Mobile API Guide
 * §3.2, "Heartbeat"):
 *  - the background, at most once per [HOURLY_INTERVAL_MILLIS] ([sendIfDue]),
 *    from the hourly safety net and the tracking service's loop, whichever
 *    comes first — this is the one that tells administrators the phone is
 *    still alive, since employees rarely open the app;
 *  - the foreground, on launch and on each sync cycle while the app is open
 *    (Dart, through the `sendHeartbeat` channel method);
 *  - the push sync, before and after its run (`PushSyncWorker`).
 *
 * All three go through here so that one stamp enforces the server's "never
 * more than once a minute" ([MIN_SPACING_MILLIS]) across all of them. The
 * Dart foreground heartbeat used to keep its own clock, which could not see
 * this one.
 *
 * The body always carries `pending_calls` and `pending_recordings`, counted
 * by [NativeCallOutboxDao.heartbeatCounts]: the server shows them on the
 * Devices page and pushes the phone (§3.3) while they stay above zero.
 *
 * Telemetry only: every failure is swallowed and logged, nothing here
 * touches the outbox, and it is never a reason for a sync to stop.
 */
object NativeHeartbeat {

    private const val TAG = "NativeHeartbeat"
    private const val PREFS = "native_heartbeat"
    private const val KEY_LAST_SENT = "last_sent_at_millis"

    /**
     * Just under an hour, so the hourly safety net (whose runs drift by a few
     * minutes) does not skip every other slot.
     */
    private const val HOURLY_INTERVAL_MILLIS = 55L * 60L * 1000L

    /** The server's floor between two heartbeats from one device. */
    const val MIN_SPACING_MILLIS = 60L * 1000L

    /** Serialises check-and-send, so two senders cannot both pass the gate. */
    private val lock = Any()

    /** What a sent heartbeat reported. */
    data class Report(val pendingCalls: Int, val pendingRecordings: Int)

    /** The hourly background heartbeat. Blocking; never throws. */
    fun sendIfDue(context: Context) {
        send(context, HOURLY_INTERVAL_MILLIS)
    }

    /**
     * Sends one heartbeat unless another went out less than [minIntervalMillis]
     * ago (never less than [MIN_SPACING_MILLIS]).
     *
     * Blocking network I/O: call off the main thread. Never throws.
     *
     * @return what was reported, or null when nothing was sent or the server
     *   never answered.
     */
    fun send(context: Context, minIntervalMillis: Long = MIN_SPACING_MILLIS): Report? = synchronized(lock) {
        try {
            val appContext = context.applicationContext
            if (!IngestStore.hasSession(appContext)) return null
            val deviceUuid = IngestStore.getDeviceUuid(appContext)
            if (deviceUuid.isNullOrBlank()) return null

            val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val elapsed = now - prefs.getLong(KEY_LAST_SENT, 0L)
            // Negative when the clock was moved back; sending is the safe answer.
            if (elapsed in 0L until minIntervalMillis.coerceAtLeast(MIN_SPACING_MILLIS)) return null

            val (pendingCalls, pendingRecordings) =
                NativeCallOutboxDao.heartbeatCounts(appContext) ?: (0 to 0)
            val body = JSONObject().apply {
                appVersion(appContext)?.let { put("app_version", it) }
                put("os_version", Build.VERSION.RELEASE)
                put("pending_calls", pendingCalls)
                put("pending_recordings", pendingRecordings)
            }
            val response = NativeApi.request(
                appContext,
                "POST",
                "/devices/heartbeat?device_uuid=" + URLEncoder.encode(deviceUuid, "UTF-8"),
                body,
            )

            // Any answer from the server counts as this slot's attempt, so a
            // device the server refuses is not asked again every fifteen
            // minutes. Only a request that never landed is retried sooner.
            val status = response.status ?: return null
            prefs.edit().putLong(KEY_LAST_SENT, now).apply()
            Log.d(TAG, "Heartbeat answered $status (calls=$pendingCalls, recordings=$pendingRecordings).")
            if (response.isSuccess) Report(pendingCalls, pendingRecordings) else null
        } catch (e: Exception) {
            Log.w(TAG, "Heartbeat failed: ${e.message}")
            null
        }
    }

    /**
     * How long until [send] would go out again under the one-minute floor:
     * zero when it may go now.
     */
    fun millisUntilAllowed(context: Context): Long {
        val last = context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong(KEY_LAST_SENT, 0L)
        val elapsed = System.currentTimeMillis() - last
        if (elapsed < 0L) return 0L
        return (MIN_SPACING_MILLIS - elapsed).coerceAtLeast(0L)
    }

    /** `versionName`, the same `1.0.0` Dart reports as `app_version`. */
    internal fun appVersion(context: Context): String? = try {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName
    } catch (e: Exception) {
        null
    }
}
