package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.os.Build
import android.util.Log
import org.json.JSONObject

/**
 * `GET /sync/status` without a Flutter engine (Mobile API Guide §5.1).
 *
 * The app is set-and-forget: most phones are never opened after pairing. So
 * everything the check-in is for has to happen here, in the background, and
 * not only in Dart's foreground pass:
 *  - whether the device may sync at all (`device_status`);
 *  - re-registering a device the server no longer knows (§3.2);
 *  - the server's limits (`policy`, including `keepalive_service`);
 *  - `pending_recording_uploads`: audio the server is still owed, re-offered
 *    when the file is on the phone, or reported gone with
 *    `PATCH {has_recording: false}` (§6.5) so the server stops asking.
 *
 * Dart's pass does the same when the app is open; both are idempotent.
 */
object NativeStatusCheckIn {

    private const val TAG = "NativeStatusCheckIn"
    private const val PREFS = "zebu_status_check_in"
    private const val KEY_LAST_RUN = "last_run_millis"

    /**
     * How often an ordinary sync run checks in. The answers barely change, and
     * every trigger (each call ending, each network change) runs a sync.
     */
    private const val CHECK_INTERVAL_MILLIS = 30L * 60L * 1000L

    enum class Outcome {
        /** The device may sync. */
        OK,

        /** `device_status` is not ACTIVE: stop, the coordinator would only be refused. */
        DEVICE_BLOCKED,

        /** No answer, or one this could not read. Sync anyway; the coordinator copes. */
        UNKNOWN,
    }

    /**
     * Runs the check-in if [CHECK_INTERVAL_MILLIS] has passed since the last
     * one, or if one is owed ([markDue]). Null when it was not due.
     */
    fun runIfDue(context: Context): Outcome? {
        val last = prefs(context).getLong(KEY_LAST_RUN, 0L)
        val elapsed = System.currentTimeMillis() - last
        if (elapsed in 0 until CHECK_INTERVAL_MILLIS) return null
        return run(context)
    }

    /** The next sync checks in whatever the interval says: a new pairing. */
    fun markDue(context: Context) {
        prefs(context).edit().remove(KEY_LAST_RUN).apply()
    }

    /**
     * Whether the last word on this handset was "blocked" — by a check-in, or
     * by an upload refused with a fatal code. Only a check-in that hears
     * ACTIVE lifts it ([clearBlocked]).
     */
    fun isBlocked(context: Context): Boolean =
        IngestStore.getLastSyncInfo(context)["lastSyncStatus"] == "BLOCKED"

    /** Blocking: call off the main thread. Never throws. */
    fun run(context: Context): Outcome {
        val appContext = context.applicationContext
        return try {
            var response = NativeApi.request(appContext, "GET", "/sync/status")
            if (!response.isSuccess) {
                val code = response.errorCode
                if (code in REREGISTER_CODES && register(appContext)) {
                    response = NativeApi.request(appContext, "GET", "/sync/status")
                }
            }
            if (!response.isSuccess) {
                val code = response.errorCode
                if (code in BLOCKING_CODES) {
                    stamp(appContext)
                    recordBlocked(appContext, code!!)
                    return Outcome.DEVICE_BLOCKED
                }
                return Outcome.UNKNOWN
            }
            var data = response.data ?: return Outcome.UNKNOWN

            // §5.1 question 1, and §3.2: a device the server does not know, or
            // has set INACTIVE, re-registers. Every write would be refused
            // until it does, and on a phone nobody opens Dart never would.
            val deviceStatus = data.optString("device_status", "ACTIVE")
            val registered = data.optBoolean("device_registered", true)
            if ((!registered || deviceStatus == "INACTIVE") && register(appContext)) {
                NativeApi.request(appContext, "GET", "/sync/status").data?.let { data = it }
            }
            stamp(appContext)

            // §5.1 question 4: "read these at runtime". Stored for the
            // coordinator exactly as Dart's check-in stores it, and the
            // always-on service is brought in line with `keepalive_service`
            // on every check-in, as §5.1 asks.
            data.optJSONObject("policy")?.let { policy ->
                val keepaliveBefore = CallTrackingService.isEnabled(appContext)
                SyncPolicyStore.save(appContext, policy.toString())
                if (CallTrackingService.isEnabled(appContext) != keepaliveBefore) {
                    CallTrackingService.reconcile(appContext)
                }
            }

            // REVOKED is the documented case; anything else that is not ACTIVE
            // is refused by the server just the same.
            val finalStatus = data.optString("device_status", "ACTIVE")
            if (finalStatus.isNotBlank() && finalStatus != "ACTIVE") {
                Log.w(TAG, "Device status is $finalStatus; not syncing.")
                recordBlocked(appContext, "DEVICE_$finalStatus")
                return Outcome.DEVICE_BLOCKED
            }
            clearBlocked(appContext)

            repairPendingRecordings(appContext, data)
            Outcome.OK
        } catch (e: Exception) {
            Log.w(TAG, "Status check-in failed: ${e.message}")
            Outcome.UNKNOWN
        }
    }

    /**
     * `pending_recording_uploads`: calls the server holds that promised audio
     * it never received. The only way to catch an upload whose response was
     * lost: locally it looks finished, so nothing would offer the file again.
     */
    private fun repairPendingRecordings(context: Context, data: JSONObject) {
        val pending = data.optJSONArray("pending_recording_uploads") ?: return
        var reopened = 0
        var reported = 0
        var requested = 0
        for (i in 0 until pending.length()) {
            // An administrator's "Request from phone": answered by its own
            // worker, which uploads or tells the administrator why not. Never
            // PATCHed here: has_recording:false would close the request with
            // no reason given. Enqueued with KEEP, so a request already queued
            // (by its push, or the last check-in) is left alone.
            val item = pending.optJSONObject(i)
            if (item != null && RequestedRecordingUploadWorker.enqueueIfRequested(context, item, "sync")) {
                requested++
                continue
            }
            val callId = item?.optString("call_id")
                ?.takeIf { it.isNotBlank() }
                ?: pending.optString(i).takeIf { it.isNotBlank() && !it.startsWith("{") }
                ?: continue
            when (NativeCallOutboxDao.reopenRecordingByServerId(context, callId)) {
                NativeCallOutboxDao.Reopen.REOPENED -> reopened++
                NativeCallOutboxDao.Reopen.NO_FILE -> {
                    // §6.5: the file is gone for good. Say so, or the server
                    // keeps this call in its pending list for ever.
                    val r = NativeApi.request(
                        context, "PATCH", "/calls/$callId",
                        JSONObject().put("has_recording", false),
                    )
                    if (r.isSuccess) reported++
                }
                NativeCallOutboxDao.Reopen.UNKNOWN_CALL -> Unit
            }
        }
        if (reopened > 0 || reported > 0 || requested > 0) {
            Log.i(TAG, "[PENDING_RECORDINGS] re-offered=$reopened reported_absent=$reported requested=$requested")
        }
        if (reopened > 0) BackgroundScheduler.enqueueSync(context)
    }

    /**
     * `POST /devices/register` (§3.2). Idempotent on the server: the same
     * uuid only refreshes the row. True when the server accepted it.
     */
    private fun register(context: Context): Boolean {
        val uuid = IngestStore.getDeviceUuid(context)?.takeIf { it.isNotBlank() } ?: return false
        val body = JSONObject().apply {
            put("device_uuid", uuid)
            put("device_name", Build.MODEL ?: "Android Device")
            put("manufacturer", Build.MANUFACTURER ?: "Generic")
            put("model", Build.MODEL ?: "Unknown")
            put("platform", "android")
            put("os_version", Build.VERSION.RELEASE ?: "Unknown")
            NativeHeartbeat.appVersion(context)?.let { put("app_version", it) }
        }
        val response = NativeApi.request(context, "POST", "/devices/register", body)
        Log.i(TAG, "Device re-registration: ${response.status} ${response.errorCode ?: ""}")
        if (!response.isSuccess) return false
        // §3.3: a re-created device row has no push token.
        try {
            `in`.mynt.zebu_call_tracker.push.PushTokenWorker.enqueue(context, force = true)
        } catch (_: Exception) {}
        return true
    }

    private fun stamp(context: Context) {
        prefs(context).edit().putLong(KEY_LAST_RUN, System.currentTimeMillis()).apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * Shown by the app as "Access removed". Without this a revoked phone with
     * an empty queue looked healthy: only an upload that hit DEVICE_REVOKED
     * ever recorded the block, and there was nothing to upload.
     */
    private fun recordBlocked(context: Context, code: String) {
        IngestStore.recordSyncOutcome(context, "BLOCKED", 0, code)
    }

    /**
     * Lifts a block once the server says ACTIVE again, whoever recorded it:
     * the server's word on the device is the authority, and the coordinator
     * refuses to send while one stands.
     */
    private fun clearBlocked(context: Context) {
        if (isBlocked(context)) {
            IngestStore.recordSyncOutcome(context, "OK", 0, null)
        }
    }

    private val BLOCKING_CODES = setOf("DEVICE_REVOKED", "DEVICE_INACTIVE", "ACCOUNT_INACTIVE")

    /** §9: these are cured by registering the device again. */
    private val REREGISTER_CODES = setOf("DEVICE_NOT_REGISTERED", "DEVICE_INACTIVE")
}
