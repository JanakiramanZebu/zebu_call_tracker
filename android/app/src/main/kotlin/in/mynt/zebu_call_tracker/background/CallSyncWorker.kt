package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Autonomous Native Background Call Sync Worker.
 *
 * Runs without a Flutter engine or UI process. Reads captured calls directly
 * from [IngestStore] and uploads them to the backend API according to the
 * offline-first outbox specification.
 */
class CallSyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val context = applicationContext
        val baseUrl = IngestStore.getApiBaseUrl(context)
        val token = IngestStore.getAuthToken(context)
        val deviceUuid = IngestStore.getDeviceUuid(context) ?: "android-device"

        if (baseUrl.isNullOrBlank() || token.isNullOrBlank()) {
            Log.d(TAG, "No server URL or auth token configured; skipping background sync")
            IngestStore.recordSyncOutcome(context, "SKIPPED_NO_AUTH", 0)
            return@withContext Result.success()
        }

        val snapshot = IngestStore.read(context)
        @Suppress("UNCHECKED_CAST")
        val batches = snapshot["batches"] as? List<Map<String, Any?>> ?: emptyList()

        if (batches.isEmpty()) {
            Log.d(TAG, "No pending call batches in outbox to sync")
            return@withContext Result.success()
        }

        // Collect all calls from all pending batches
        val callsToSync = mutableListOf<Map<String, Any?>>()
        for (batch in batches) {
            @Suppress("UNCHECKED_CAST")
            val calls = batch["calls"] as? List<Map<String, Any?>> ?: emptyList()
            callsToSync.addAll(calls)
        }

        if (callsToSync.isEmpty()) {
            IngestStore.clearBatches(context)
            return@withContext Result.success()
        }

        val isoFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }

        val callsArray = JSONArray()
        for (c in callsToSync) {
            val dateMillis = (c["dateMillis"] as? Number)?.toLong() ?: System.currentTimeMillis()
            val number = (c["number"] as? String) ?: "Unknown"
            val direction = (c["type"] as? String) ?: "unknown"
            val duration = (c["durationSeconds"] as? Number)?.toInt() ?: 0
            val contactName = c["cachedName"] as? String
            val extId = "android-$dateMillis-$number"
            val idempotencyKey = "zebu:call:$extId:$dateMillis"

            val statusStr = if (direction == "missed" || direction == "rejected") direction else "completed"

            val callObj = JSONObject().apply {
                put("idempotency_key", idempotencyKey)
                put("external_call_id", extId)
                put("device_uuid", deviceUuid)
                put("phone_number", number)
                if (contactName != null) put("contact_name", contactName)
                put("direction", direction)
                put("status", statusStr)
                put("started_at", isoFormat.format(Date(dateMillis)))
                put("ended_at", isoFormat.format(Date(dateMillis + (duration * 1000L))))
                put("duration_seconds", duration)
                put("has_recording", false)
                put("sim_slot", 1)
                put("client_created_at", isoFormat.format(Date()))
            }
            callsArray.put(callObj)
        }

        val payload = JSONObject().apply {
            put("device_uuid", deviceUuid)
            put("client_synced_at", isoFormat.format(Date()))
            put("calls", callsArray)
        }

        val endpoint = baseUrl.trimEnd('/') + "/sync/calls"
        var conn: HttpURLConnection? = null

        try {
            val url = URL(endpoint)
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 15000
                readTimeout = 25000
                doOutput = true
                doInput = true
                setRequestProperty("Content-Type", "application/json; charset=UTF-8")
                setRequestProperty("Accept", "application/json")
                setRequestProperty("Authorization", "Bearer $token")
            }

            OutputStreamWriter(conn.outputStream, "UTF-8").use { writer ->
                writer.write(payload.toString())
                writer.flush()
            }

            val statusCode = conn.responseCode
            Log.i(TAG, "POST /sync/calls response: $statusCode")

            if (statusCode in 200..299) {
                val responseText = BufferedReader(InputStreamReader(conn.inputStream)).use { it.readText() }
                Log.i(TAG, "Sync success: ${callsToSync.size} calls uploaded. Response: $responseText")
                IngestStore.clearBatches(context)
                IngestStore.recordSyncOutcome(context, "OK", callsToSync.size)
                Result.success()
            } else if (statusCode == 401 || statusCode == 403) {
                Log.w(TAG, "Sync unauthorized ($statusCode). Token may be expired.")
                IngestStore.recordSyncOutcome(context, "UNAUTHORIZED", 0, "HTTP $statusCode")
                Result.failure()
            } else {
                val errText = try {
                    BufferedReader(InputStreamReader(conn.errorStream)).use { it.readText() }
                } catch (_: Exception) { "" }
                Log.w(TAG, "Sync failed ($statusCode): $errText")
                IngestStore.recordSyncOutcome(context, "FAILED_SERVER", 0, "HTTP $statusCode")
                if (runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.failure()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Sync network/connection error: ${e.message}")
            IngestStore.recordSyncOutcome(context, "NETWORK_ERROR", 0, e.message)
            if (runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.failure()
        } finally {
            conn?.disconnect()
        }
    }

    companion object {
        private const val TAG = "CallSyncWorker"
        private const val MAX_ATTEMPTS = 5
    }
}
