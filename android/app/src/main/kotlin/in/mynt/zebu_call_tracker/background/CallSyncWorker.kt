package `in`.mynt.zebu_call_tracker.background

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/**
 * Autonomous Native Background Call Sync Worker.
 *
 * Runs without a Flutter engine or UI process. Reads captured calls directly
 * from [IngestStore] and uploads them sequentially (concurrency = 1) to the
 * backend API according to the offline-first outbox specification.
 */
class CallSyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val context = applicationContext
        val rawBaseUrl = IngestStore.getApiBaseUrl(context)
        val token = IngestStore.getAuthToken(context)
        val deviceUuid = IngestStore.getDeviceUuid(context) ?: "android-device"

        if (rawBaseUrl.isNullOrBlank() || token.isNullOrBlank()) {
            Log.d(TAG, "No server URL or auth token configured; skipping background sync")
            IngestStore.recordSyncOutcome(context, "SKIPPED_NO_AUTH", 0)
            return@withContext Result.success()
        }

        // Normalize base URL to ensure proper /api/v1/sync/calls endpoint
        var normalizedBaseUrl = rawBaseUrl.trim()
        if (normalizedBaseUrl.endsWith("/")) {
            normalizedBaseUrl = normalizedBaseUrl.substring(0, normalizedBaseUrl.length - 1)
        }
        if (!normalizedBaseUrl.endsWith("/api/v1")) {
            normalizedBaseUrl = if (normalizedBaseUrl.endsWith("/api")) {
                "$normalizedBaseUrl/v1"
            } else {
                "$normalizedBaseUrl/api/v1"
            }
        }
        val endpoint = "$normalizedBaseUrl/sync/calls"

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

        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        val channelId = "sync_progress"
        val notifyId = 1003

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && notificationManager != null) {
            val channel = NotificationChannel(
                channelId,
                "Sync Progress",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows live call uploading status and remaining count."
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

        val isoFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }

        val totalCalls = callsToSync.size
        var uploadedCount = 0
        var failedCount = 0
        var currentIndex = 0

        Log.i(TAG, "[SYNC] Starting native background one-by-one upload loop ($totalCalls calls)...")

        for (c in callsToSync) {
            currentIndex++
            val dateMillis = (c["dateMillis"] as? Number)?.toLong() ?: System.currentTimeMillis()
            val number = (c["number"] as? String) ?: "Unknown"
            val rawType = (c["type"] as? String)?.lowercase() ?: "unknown"
            val duration = (c["durationSeconds"] as? Number)?.toInt() ?: 0
            val contactName = c["cachedName"] as? String
            val extId = "android-$dateMillis-$number"
            val idempotencyKey = generateDeterministicIdempotencyKey(extId, dateMillis)
            val remaining = (totalCalls - currentIndex).coerceAtLeast(0)

            // Post live progress notification
            notificationManager?.let { nm ->
                try {
                    val notif = NotificationCompat.Builder(context, channelId)
                        .setSmallIcon(android.R.drawable.stat_sys_upload)
                        .setContentTitle("Syncing call $currentIndex of $totalCalls")
                        .setContentText("$remaining remaining · Uploading $number")
                        .setProgress(totalCalls, currentIndex, false)
                        .setOngoing(true)
                        .setOnlyAlertOnce(true)
                        .setPriority(NotificationCompat.PRIORITY_LOW)
                        .build()
                    nm.notify(notifyId, notif)
                } catch (_: Exception) {}
            }

            // Strict backend direction & status mapping
            val (direction, statusStr) = when (rawType) {
                "incoming" -> Pair("incoming", if (duration > 0) "completed" else "missed")
                "outgoing" -> Pair("outgoing", "completed")
                "missed"   -> Pair("incoming", "missed")
                "rejected" -> Pair("incoming", "rejected")
                else       -> Pair(if (rawType.contains("out")) "outgoing" else "incoming", if (duration > 0) "completed" else "missed")
            }

            val startedAtStr = isoFormat.format(Date(dateMillis))
            val endedAtStr = isoFormat.format(Date(dateMillis + (duration * 1000L)))
            val nowStr = isoFormat.format(Date())

            val callObj = JSONObject().apply {
                put("idempotency_key", idempotencyKey)
                put("external_call_id", extId)
                put("device_uuid", deviceUuid)
                put("phone_number", number)
                if (!contactName.isNullOrBlank()) put("contact_name", contactName)
                put("direction", direction)
                put("status", statusStr)
                put("started_at", startedAtStr)
                put("ended_at", endedAtStr)
                put("duration_seconds", duration)
                put("has_recording", false)
                put("sim_slot", 1)
                put("client_created_at", nowStr)
            }

            val singleCallArray = JSONArray().apply { put(callObj) }
            val payload = JSONObject().apply {
                put("device_uuid", deviceUuid)
                put("client_synced_at", nowStr)
                put("calls", singleCallArray)
            }

            Log.i(TAG, "[SYNC] UPLOAD START - IdempotencyKey: $idempotencyKey, Phone: $number, Dir: $direction, Status: $statusStr")
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
                val responseBody = if (statusCode in 200..299) {
                    conn.inputStream.bufferedReader().use { it.readText() }
                } else {
                    conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                }

                if (statusCode in 200..299) {
                    var serverCallId: String? = null
                    var isSuccess = true
                    try {
                        val json = JSONObject(responseBody)
                        val data = json.optJSONObject("data")
                        val successfulArr = data?.optJSONArray("successful")
                        val duplicatesArr = data?.optJSONArray("duplicates")
                        val failedArr = data?.optJSONArray("failed")

                        if (successfulArr != null && successfulArr.length() > 0) {
                            serverCallId = successfulArr.getJSONObject(0).optString("call_id")
                        } else if (duplicatesArr != null && duplicatesArr.length() > 0) {
                            serverCallId = duplicatesArr.getJSONObject(0).optString("existing_call_id")
                        } else if (failedArr != null && failedArr.length() > 0) {
                            isSuccess = false
                        }
                    } catch (_: Exception) {}

                    if (isSuccess) {
                        uploadedCount++
                        val confirmedId = if (!serverCallId.isNullOrBlank()) serverCallId else "synced-$dateMillis"
                        IngestStore.markCallSynced(context, idempotencyKey, confirmedId)
                        Log.i(TAG, "[SYNC] UPLOAD SUCCESS - IdempotencyKey: $idempotencyKey, ServerId: $confirmedId")
                    } else {
                        failedCount++
                        Log.w(TAG, "[SYNC] UPLOAD FAILED on server - IdempotencyKey: $idempotencyKey, Resp: $responseBody")
                    }
                } else {
                    failedCount++
                    Log.w(TAG, "[SYNC] UPLOAD HTTP ERROR ($statusCode) - IdempotencyKey: $idempotencyKey, Body: $responseBody")
                }
            } catch (e: Exception) {
                failedCount++
                Log.w(TAG, "[SYNC] Network error for $idempotencyKey: ${e.message}")
            } finally {
                conn?.disconnect()
            }
        }

        if (failedCount == 0) {
            IngestStore.clearBatches(context)
        }
        IngestStore.recordSyncOutcome(context, if (failedCount == 0) "OK" else "PARTIAL", uploadedCount)
        Log.i(TAG, "[SYNC] SYNC STOP - Uploaded: $uploadedCount, Failed: $failedCount")

        // Finalize notification
        notificationManager?.let { nm ->
            try {
                if (uploadedCount > 0) {
                    val doneNotif = NotificationCompat.Builder(context, channelId)
                        .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                        .setContentTitle("Sync complete")
                        .setContentText("$uploadedCount calls uploaded successfully")
                        .setOngoing(false)
                        .setAutoCancel(true)
                        .setPriority(NotificationCompat.PRIORITY_LOW)
                        .build()
                    nm.notify(notifyId, doneNotif)
                } else {
                    nm.cancel(notifyId)
                }
            } catch (_: Exception) {}
        }

        return@withContext if (failedCount == 0) Result.success() else Result.retry()
    }

    /**
     * Generates a standard RFC 4122 UUID v5 matching Dart's Uuid().v5(Uuid.NAMESPACE_DNS, ...)
     */
    private fun generateDeterministicIdempotencyKey(extId: String, dateMillis: Long): String {
        val name = "zebu:call:$extId:$dateMillis"
        val namespaceUuid = UUID.fromString("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        val bb = ByteBuffer.allocate(16)
        bb.putLong(namespaceUuid.mostSignificantBits)
        bb.putLong(namespaceUuid.leastSignificantBits)
        val nsBytes = bb.array()
        val nameBytes = name.toByteArray(Charsets.UTF_8)

        val md = MessageDigest.getInstance("SHA-1")
        md.update(nsBytes)
        val hash = md.digest(nameBytes)

        // Set version 5 and RFC 4122 variant
        hash[6] = ((hash[6].toInt() and 0x0f) or 0x50).toByte()
        hash[8] = ((hash[8].toInt() and 0x3f) or 0x80).toByte()

        val msb = ByteBuffer.wrap(hash, 0, 8).long
        val lsb = ByteBuffer.wrap(hash, 8, 8).long
        return UUID(msb, lsb).toString()
    }

    companion object {
        private const val TAG = "CallSyncWorker"
    }
}
