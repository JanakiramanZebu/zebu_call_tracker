package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys
import org.json.JSONArray
import org.json.JSONObject

/**
 * Durable hand-off between the background worker and Dart.
 *
 * The worker runs with no Flutter engine, so it cannot call into the Dart
 * matcher. It captures what is *perishable* and leaves interpretation to Dart:
 *
 *  - **Call log rows** are durable in the system provider, so capturing them is
 *    belt-and-braces. They are stored anyway because they are cheap and it lets
 *    Dart drain one batch instead of re-scanning.
 *  - **Recording listings are NOT durable.** The OEM dialers on this fleet
 *    rotate their own recordings, and a MediaStore row can disappear before the
 *    user next opens the app. Snapshotting the candidates that existed *at the
 *    time of the call* is the whole reason this runs in the background.
 *
 * Matching logic is deliberately NOT duplicated here. It lives once, in Dart's
 * RecordingMatcher, and runs over these snapshots when the app next starts.
 *
 * Bounded on purpose: a handset left unopened for a fortnight must not grow
 * this without limit. Overflow drops the OLDEST batches and raises a flag, so
 * Dart can tell the difference between "nothing happened" and "we lost some".
 */
object IngestStore {

    private const val PREFS = "call_ingest_store"
    private const val KEY_BATCHES = "batches"
    private const val KEY_CALL_CURSOR = "call_cursor_millis"
    private const val KEY_RECORDING_CURSOR = "recording_cursor_seconds"
    private const val KEY_OVERFLOWED = "overflowed"
    private const val KEY_LAST_RUN_AT = "last_run_at_millis"
    private const val KEY_LAST_RUN_STATUS = "last_run_status"
    private const val KEY_LAST_RUN_REASON = "last_run_reason"
    private const val KEY_RUN_COUNT = "run_count"
    private const val KEY_CAPTURED_CALLS = "captured_calls"

    /** Roughly a fortnight of heavy use; well under the SharedPreferences limit. */
    private const val MAX_BATCHES = 60

    /** Capture snapshots and run statistics — no secrets, plain storage. */
    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private const val SECURE_PREFS = "call_ingest_secure"
    private const val TAG = "IngestStore"

    @Volatile
    private var securePrefsInstance: SharedPreferences? = null

    /**
     * Separate, encrypted store for the background worker's auth session.
     *
     * The access and refresh tokens used to live in [prefs] as plain XML, which
     * put them within reach of any root/backup extraction while the Dart side's
     * copy of the very same tokens sat in flutter_secure_storage. This closes
     * that asymmetry.
     *
     * Falls back to the plain store if the keystore is unavailable — some
     * devices fail EncryptedSharedPreferences construction outright, and an app
     * that cannot sync at all is a worse outcome than one that stores its token
     * the way it always did. The fallback is logged.
     */
    private fun securePrefs(context: Context): SharedPreferences {
        securePrefsInstance?.let { return it }
        return synchronized(this) {
            securePrefsInstance ?: run {
                val store = try {
                    // security-crypto 1.0.0 API. The MasterKey.Builder form
                    // belongs to the 1.1.0 alphas, which this project does not
                    // take: see pubspec/build.gradle notes on holding stable
                    // versions against the pinned AGP.
                    val masterKeyAlias = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC)
                    EncryptedSharedPreferences.create(
                        SECURE_PREFS,
                        masterKeyAlias,
                        context.applicationContext,
                        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "EncryptedSharedPreferences unavailable (${e.message}); using plain store.")
                    prefs(context)
                }
                migrateLegacyPlaintextSession(context, store)
                securePrefsInstance = store
                store
            }
        }
    }

    /**
     * Moves a session written by an earlier build out of the plaintext store.
     *
     * Without this an already-signed-in handset would keep its tokens in the
     * clear until the user next signed in, and background sync would break
     * immediately on upgrade because the new store starts empty.
     */
    private fun migrateLegacyPlaintextSession(context: Context, target: SharedPreferences) {
        if (target === prefs(context)) return
        val legacy = prefs(context)
        val legacyToken = legacy.getString(KEY_AUTH_TOKEN, null) ?: return

        target.edit().apply {
            putString(KEY_AUTH_TOKEN, legacyToken)
            legacy.getString(KEY_REFRESH_TOKEN, null)?.let { putString(KEY_REFRESH_TOKEN, it) }
            legacy.getString(KEY_API_BASE_URL, null)?.let { putString(KEY_API_BASE_URL, it) }
            legacy.getString(KEY_DEVICE_UUID, null)?.let { putString(KEY_DEVICE_UUID, it) }
        }.apply()

        legacy.edit()
            .remove(KEY_AUTH_TOKEN)
            .remove(KEY_REFRESH_TOKEN)
            .remove(KEY_API_BASE_URL)
            .remove(KEY_DEVICE_UUID)
            .apply()

        Log.i(TAG, "Migrated background auth session out of plaintext preferences.")
    }

    // ------------------------------------------------------------- cursors

    fun callCursorMillis(context: Context): Long =
        prefs(context).getLong(KEY_CALL_CURSOR, 0L)

    fun recordingCursorSeconds(context: Context): Long =
        prefs(context).getLong(KEY_RECORDING_CURSOR, 0L)

    fun initializeCursors(context: Context, callMillis: Long, recordingSeconds: Long) {
        prefs(context).edit()
            .putLong(KEY_CALL_CURSOR, callMillis)
            .putLong(KEY_RECORDING_CURSOR, recordingSeconds)
            .apply()
    }

    // ------------------------------------------------------------- capture

    /**
     * Appends one batch and advances both cursors.
     *
     * Cursors move only to the newest item actually captured, never to "now":
     * a row written to the call log a moment after the query would otherwise be
     * skipped forever.
     */
    fun append(
        context: Context,
        calls: List<Map<String, Any?>>,
        recordings: List<Map<String, Any?>>,
        capturedAtMillis: Long,
    ) {
        if (calls.isEmpty() && recordings.isEmpty()) return

        val p = prefs(context)
        val batches = JSONArray(p.getString(KEY_BATCHES, "[]"))
        batches.put(
            JSONObject()
                .put("capturedAtMillis", capturedAtMillis)
                .put("calls", JSONArray(calls.map { JSONObject(it) }))
                .put("recordings", JSONArray(recordings.map { JSONObject(it) })),
        )

        var overflowed = p.getBoolean(KEY_OVERFLOWED, false)
        val trimmed = if (batches.length() > MAX_BATCHES) {
            overflowed = true
            JSONArray().also { out ->
                for (i in batches.length() - MAX_BATCHES until batches.length()) {
                    out.put(batches.get(i))
                }
            }
        } else {
            batches
        }

        val newestCall = calls
            .mapNotNull { (it["dateMillis"] as? Number)?.toLong() }
            .maxOrNull()
        val newestRecording = recordings
            .mapNotNull { (it["dateAddedEpochSeconds"] as? Number)?.toLong() }
            .maxOrNull()

        p.edit().apply {
            putString(KEY_BATCHES, trimmed.toString())
            putBoolean(KEY_OVERFLOWED, overflowed)
            putInt(KEY_CAPTURED_CALLS, p.getInt(KEY_CAPTURED_CALLS, 0) + calls.size)
            newestCall?.let { putLong(KEY_CALL_CURSOR, maxOf(it, callCursorMillis(context))) }
            newestRecording?.let {
                putLong(KEY_RECORDING_CURSOR, maxOf(it, recordingCursorSeconds(context)))
            }
        }.apply()
    }

    fun recordRun(context: Context, status: String, reason: String) {
        val p = prefs(context)
        p.edit()
            .putLong(KEY_LAST_RUN_AT, System.currentTimeMillis())
            .putString(KEY_LAST_RUN_STATUS, status)
            .putString(KEY_LAST_RUN_REASON, reason)
            .putInt(KEY_RUN_COUNT, p.getInt(KEY_RUN_COUNT, 0) + 1)
            .apply()
    }

    // --------------------------------------------------------------- drain

    private const val KEY_SYNCED_CALLS = "synced_calls"

    fun markCallSynced(context: Context, idempotencyKey: String, serverCallId: String) {
        val p = prefs(context)
        val arr = JSONArray(p.getString(KEY_SYNCED_CALLS, "[]"))
        arr.put(
            JSONObject()
                .put("idempotencyKey", idempotencyKey)
                .put("serverCallId", serverCallId)
                .put("syncedAtMillis", System.currentTimeMillis()),
        )
        p.edit().putString(KEY_SYNCED_CALLS, arr.toString()).apply()
    }

    fun getSyncedCalls(context: Context): List<Map<String, Any?>> {
        val p = prefs(context)
        val arr = JSONArray(p.getString(KEY_SYNCED_CALLS, "[]"))
        return arr.toMapList()
    }

    fun clearSyncedCalls(context: Context) {
        prefs(context).edit().remove(KEY_SYNCED_CALLS).apply()
    }

    fun read(context: Context): Map<String, Any?> {
        val p = prefs(context)
        val batches = JSONArray(p.getString(KEY_BATCHES, "[]"))
        val out = mutableListOf<Map<String, Any?>>()

        for (i in 0 until batches.length()) {
            val b = batches.getJSONObject(i)
            out += mapOf(
                "capturedAtMillis" to b.getLong("capturedAtMillis"),
                "calls" to b.getJSONArray("calls").toMapList(),
                "recordings" to b.getJSONArray("recordings").toMapList(),
            )
        }

        return mapOf(
            "batches" to out,
            "syncedCalls" to getSyncedCalls(context),
            "overflowed" to p.getBoolean(KEY_OVERFLOWED, false),
            "lastRunAtMillis" to p.getLong(KEY_LAST_RUN_AT, 0L),
            "lastRunStatus" to p.getString(KEY_LAST_RUN_STATUS, null),
            "lastRunReason" to p.getString(KEY_LAST_RUN_REASON, null),
            "runCount" to p.getInt(KEY_RUN_COUNT, 0),
            "capturedCalls" to p.getInt(KEY_CAPTURED_CALLS, 0),
            "callCursorMillis" to p.getLong(KEY_CALL_CURSOR, 0L),
        )
    }

    /**
     * Drops the batches Dart has folded in. Cursors and run stats survive:
     * clearing them would make the next run re-capture everything.
     */
    fun clearBatches(context: Context) {
        prefs(context).edit()
            .putString(KEY_BATCHES, "[]")
            .remove(KEY_SYNCED_CALLS)
            .putBoolean(KEY_OVERFLOWED, false)
            .apply()
    }

    // ------------------------------------------------------------- auth & sync session

    private const val KEY_AUTH_TOKEN = "auth_token"
    private const val KEY_REFRESH_TOKEN = "refresh_token"
    private const val KEY_API_BASE_URL = "api_base_url"
    private const val KEY_DEVICE_UUID = "device_uuid"
    private const val KEY_LAST_SYNC_AT = "last_sync_at_millis"
    private const val KEY_LAST_SYNC_STATUS = "last_sync_status"
    private const val KEY_LAST_SYNCED_COUNT = "last_synced_count"
    private const val KEY_LAST_SYNC_ERROR = "last_sync_error"

    fun saveAuthSession(
        context: Context,
        token: String,
        refreshToken: String?,
        apiBaseUrl: String,
        deviceUuid: String,
    ) {
        securePrefs(context).edit().apply {
            putString(KEY_AUTH_TOKEN, token)
            if (!refreshToken.isNullOrBlank()) {
                putString(KEY_REFRESH_TOKEN, refreshToken)
            }
            putString(KEY_API_BASE_URL, apiBaseUrl)
            putString(KEY_DEVICE_UUID, deviceUuid)
        }.apply()
    }

    fun updateAuthTokens(
        context: Context,
        accessToken: String,
        refreshToken: String?,
    ) {
        securePrefs(context).edit().apply {
            putString(KEY_AUTH_TOKEN, accessToken)
            if (!refreshToken.isNullOrBlank()) {
                putString(KEY_REFRESH_TOKEN, refreshToken)
            }
        }.apply()
    }

    fun clearAuthSession(context: Context) {
        securePrefs(context).edit()
            .remove(KEY_AUTH_TOKEN)
            .remove(KEY_REFRESH_TOKEN)
            .remove(KEY_API_BASE_URL)
            .remove(KEY_DEVICE_UUID)
            .apply()
    }

    fun getAuthToken(context: Context): String? =
        securePrefs(context).getString(KEY_AUTH_TOKEN, null)

    fun getRefreshToken(context: Context): String? =
        securePrefs(context).getString(KEY_REFRESH_TOKEN, null)

    fun getApiBaseUrl(context: Context): String? =
        securePrefs(context).getString(KEY_API_BASE_URL, null)

    fun getDeviceUuid(context: Context): String? =
        securePrefs(context).getString(KEY_DEVICE_UUID, null)

    fun recordSyncOutcome(
        context: Context,
        status: String,
        syncedCount: Int,
        error: String? = null,
    ) {
        prefs(context).edit()
            .putLong(KEY_LAST_SYNC_AT, System.currentTimeMillis())
            .putString(KEY_LAST_SYNC_STATUS, status)
            .putInt(KEY_LAST_SYNCED_COUNT, syncedCount)
            .putString(KEY_LAST_SYNC_ERROR, error)
            .apply()
    }

    fun getLastSyncInfo(context: Context): Map<String, Any?> {
        val p = prefs(context)
        return mapOf(
            "lastSyncAtMillis" to p.getLong(KEY_LAST_SYNC_AT, 0L),
            "lastSyncStatus" to p.getString(KEY_LAST_SYNC_STATUS, null),
            "lastSyncedCount" to p.getInt(KEY_LAST_SYNCED_COUNT, 0),
            "lastSyncError" to p.getString(KEY_LAST_SYNC_ERROR, null),
        )
    }

    private fun JSONArray.toMapList(): List<Map<String, Any?>> =
        (0 until length()).map { i ->
            val o = getJSONObject(i)
            o.keys().asSequence().associateWith { k ->
                if (o.isNull(k)) null else o.get(k)
            }
        }
}
