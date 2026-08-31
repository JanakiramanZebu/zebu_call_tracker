package `in`.mynt.zebu_call_tracker.background

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import `in`.mynt.zebu_call_tracker.recording.RecordingScanner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.InputStream
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Single Native SyncCoordinator.
 *
 * Coordinates execution across all triggers (app startup, app resume, new call inserted,
 * delayed recording discovery, network restoration, scheduled background recovery, retry schedule, manual Sync Now).
 *
 * Guarantees:
 *  - Mutex lock: Exactly ONE sync coordinator execution loop running at a time.
 *  - Concurrency = 1: Uploads exactly ONE call per HTTP request.
 *  - Persistent State Machine: WAITING -> UPLOADING -> UPLOADED / RETRY_PENDING / FAILED.
 *  - Native streaming multipart audio upload (zero OOM on large audio files).
 *  - Native single-flight token refresh on HTTP 401 without Flutter.
 *  - Process recovery: Recovers stale UPLOADING records after process death.
 *  - Clean shutdown: Stops immediately when queue is empty or network disappears.
 */
object SyncCoordinator {

    private const val TAG = "SyncCoordinator"
    private const val CHANNEL_ID = "sync_progress"
    private const val NOTIFY_ID = 1003

    private val isRunning = AtomicBoolean(false)

    /**
     * Executes single-threaded, sequential 1-by-1 outbox synchronization.
     */
    suspend fun runSync(context: Context, reason: String = "auto"): SyncOutcome = withContext(Dispatchers.IO) {
        if (!isRunning.compareAndSet(false, true)) {
            Log.d(TAG, "SyncCoordinator execution already in progress [$reason]; skipping concurrent run.")
            return@withContext SyncOutcome("ALREADY_RUNNING", 0, 0)
        }

        val appContext = context.applicationContext
        var uploadedCount = 0
        var failedCount = 0
        var lastStatus = "OK"

        try {
            Log.i(TAG, "[SYNC_START] Trigger: $reason. Recovering stale records...")

            // 1. Recover stale records stuck in UPLOADING state from previous process death
            NativeCallOutboxDao.recoverStuckUploadingCalls(appContext)

            val rawBaseUrl = IngestStore.getApiBaseUrl(appContext)
            var currentToken = IngestStore.getAuthToken(appContext)
            val deviceUuid = IngestStore.getDeviceUuid(appContext) ?: "android-device"

            if (rawBaseUrl.isNullOrBlank() || currentToken.isNullOrBlank()) {
                Log.d(TAG, "No API base URL or auth token configured; skipping background sync.")
                IngestStore.recordSyncOutcome(appContext, "SKIPPED_NO_AUTH", 0)
                return@withContext SyncOutcome("SKIPPED_NO_AUTH", 0, 0)
            }

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

            val isoFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }

            val notificationManager = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ensureNotificationChannel(appContext, notificationManager)

            // 2. Sequential One-By-One Upload Loop (concurrency = 1)
            Log.i(TAG, "[SYNC_LOOP] Starting 1-by-1 outbox processing loop...")

            while (true) {
                // Claim next WAITING or ready RETRY_PENDING record (sets state to UPLOADING atomically)
                val call = NativeCallOutboxDao.claimNextWaitingCall(appContext) ?: break

                val maskedPhone = maskPhoneNumber(call.phoneNumber)
                Log.i(TAG, "[OUTBOX_CLAIM] Local ID: ${call.localId}, IdempotencyKey: ${call.idempotencyKey}, Phone: $maskedPhone, HasRec: ${call.hasRecording}, RecStatus: ${call.recordingUploadStatus}")

                // Post live progress notification
                showNotification(appContext, notificationManager, "Uploading $maskedPhone...")

                var confirmedServerCallId = call.serverCallId
                var confirmedRevision = 1
                var metadataSuccess = !confirmedServerCallId.isNullOrBlank()
                var isRetryable = true
                var errorCode = "UNKNOWN_ERROR"

                // -------------------------------------------------------------
                // STEP 1: Metadata Upload (if not already uploaded)
                // -------------------------------------------------------------
                if (!metadataSuccess) {
                    val rawType = call.direction.lowercase()
                    val (direction, statusStr) = when (rawType) {
                        "incoming" -> Pair("incoming", if (call.durationSeconds > 0) "completed" else "missed")
                        "outgoing" -> Pair("outgoing", "completed")
                        "missed"   -> Pair("incoming", "missed")
                        "rejected" -> Pair("incoming", "rejected")
                        else       -> Pair(if (rawType.contains("out")) "outgoing" else "incoming", if (call.durationSeconds > 0) "completed" else "missed")
                    }

                    val startedAtStr = isoFormat.format(Date(call.startedAtMillis))
                    val endedAtStr = isoFormat.format(Date(call.startedAtMillis + (call.durationSeconds * 1000L)))
                    val nowStr = isoFormat.format(Date())

                    val callObj = JSONObject().apply {
                        put("idempotency_key", call.idempotencyKey)
                        put("external_call_id", call.externalCallId ?: "android-${call.startedAtMillis}-${call.phoneNumber}")
                        put("device_uuid", deviceUuid)
                        put("phone_number", call.phoneNumber)
                        if (!call.contactName.isNullOrBlank()) put("contact_name", call.contactName)
                        put("direction", direction)
                        put("status", statusStr)
                        put("started_at", startedAtStr)
                        put("ended_at", endedAtStr)
                        put("duration_seconds", call.durationSeconds)
                        put("has_recording", call.hasRecording)
                        put("sim_slot", call.simSlot)
                        put("client_created_at", nowStr)
                    }

                    val singleCallArray = JSONArray().apply { put(callObj) }
                    val metadataPayload = JSONObject().apply {
                        put("device_uuid", deviceUuid)
                        put("client_synced_at", nowStr)
                        put("calls", singleCallArray)
                    }

                    Log.i(TAG, "[METADATA_UPLOAD_START] IdempotencyKey: ${call.idempotencyKey}")

                    val metaResult = executeMetadataUpload(
                        context = appContext,
                        endpoint = "$normalizedBaseUrl/sync/calls",
                        payload = metadataPayload.toString(),
                        token = currentToken!!,
                        baseUrl = normalizedBaseUrl,
                    )

                    if (metaResult.newToken != null) {
                        currentToken = metaResult.newToken
                    }

                    if (metaResult.isSuccess) {
                        metadataSuccess = true
                        confirmedServerCallId = metaResult.serverCallId?.takeIf { it.isNotBlank() } ?: "server-${call.localId}"
                        confirmedRevision = metaResult.revision
                        NativeCallOutboxDao.markServerCallId(appContext, call.idempotencyKey, confirmedServerCallId!!, confirmedRevision)
                        Log.i(TAG, "[METADATA_UPLOAD_SUCCESS] IdempotencyKey: ${call.idempotencyKey}, ServerId: $confirmedServerCallId")
                    } else {
                        metadataSuccess = false
                        errorCode = metaResult.errorCode
                        isRetryable = metaResult.isRetryable
                        Log.w(TAG, "[METADATA_UPLOAD_FAILED] IdempotencyKey: ${call.idempotencyKey}, Code: $errorCode, Retryable: $isRetryable")
                    }
                }

                // -------------------------------------------------------------
                // STEP 2: Recording Upload (if metadata succeeded and recording is pending)
                // -------------------------------------------------------------
                var recordingSuccess = true
                if (metadataSuccess && call.hasRecording && call.recordingUploadStatus != "uploaded") {
                    val serverId = confirmedServerCallId?.takeIf { it.isNotBlank() } ?: "server-${call.localId}"
                    val mediaStoreId = call.recordingMediaStoreId
                    val recordingUriStr = call.recordingPath ?: (if (mediaStoreId != null) RecordingScanner.contentUri(mediaStoreId) else null)

                    if (recordingUriStr.isNullOrBlank()) {
                        Log.w(TAG, "[RECORDING_MISSING] No URI found for call ${call.idempotencyKey}; marking absent.")
                        NativeCallOutboxDao.markRecordingFailed(appContext, call.idempotencyKey, "RECORDING_PATH_NULL")
                    } else {
                        Log.i(TAG, "[RECORDING_UPLOAD_START] ServerId: $serverId, MediaStoreId: $mediaStoreId")
                        val recResult = executeStreamingRecordingUpload(
                            context = appContext,
                            endpoint = "$normalizedBaseUrl/calls/$serverId/recording",
                            recordingUri = Uri.parse(recordingUriStr),
                            mediaStoreId = mediaStoreId,
                            storedChecksum = call.recordingChecksum,
                            durationSeconds = call.durationSeconds,
                            token = currentToken!!,
                            baseUrl = normalizedBaseUrl,
                        )

                        if (recResult.newToken != null) {
                            currentToken = recResult.newToken
                        }

                        if (recResult.isSuccess) {
                            recordingSuccess = true
                            NativeCallOutboxDao.markRecordingUploaded(appContext, call.idempotencyKey)
                            Log.i(TAG, "[RECORDING_UPLOAD_SUCCESS] ServerId: $serverId")
                        } else {
                            recordingSuccess = false
                            errorCode = recResult.errorCode
                            isRetryable = recResult.isRetryable
                            NativeCallOutboxDao.markRecordingFailed(appContext, call.idempotencyKey, errorCode)
                            Log.w(TAG, "[RECORDING_UPLOAD_FAILED] ServerId: $serverId, Code: $errorCode, Retryable: $isRetryable")
                        }
                    }
                }

                // -------------------------------------------------------------
                // STEP 3: Complete or Retry Transition
                // -------------------------------------------------------------
                if (metadataSuccess && recordingSuccess) {
                    val finalServerId = confirmedServerCallId?.takeIf { it.isNotBlank() } ?: "server-${call.localId}"
                    NativeCallOutboxDao.markUploaded(appContext, call.idempotencyKey, finalServerId, confirmedRevision)
                    uploadedCount++
                    Log.i(TAG, "[CALL_COMPLETE] IdempotencyKey: ${call.idempotencyKey}, FinalStatus: UPLOADED")
                } else {
                    failedCount++
                    if (isRetryable) {
                        val delaySeconds = (1L shl (call.attemptCount + 1)).coerceIn(2L, 600L)
                        NativeCallOutboxDao.markRetryPending(appContext, call.idempotencyKey, errorCode, call.attemptCount, delaySeconds)
                        Log.i(TAG, "[SYNC_RETRY] Scheduled retry for ${call.idempotencyKey} in ${delaySeconds}s (Error: $errorCode)")

                        if (errorCode == "NETWORK_ERROR" || errorCode == "AUTH_EXPIRED") {
                            Log.i(TAG, "Halting outbox processing loop due to $errorCode.")
                            break
                        }
                    } else {
                        NativeCallOutboxDao.markFailed(appContext, call.idempotencyKey, errorCode, call.attemptCount)
                        Log.i(TAG, "[SYNC_FAILURE] Permanent failure for ${call.idempotencyKey} (Code: $errorCode)")
                    }
                }
            }

            lastStatus = if (failedCount == 0) "OK" else "PARTIAL"
            IngestStore.recordSyncOutcome(appContext, lastStatus, uploadedCount)
            Log.i(TAG, "[SYNC_STOP] Uploaded: $uploadedCount, Failed: $failedCount")

            // Finalize progress notification
            notificationManager?.let { nm ->
                try {
                    if (uploadedCount > 0) {
                        val doneNotif = NotificationCompat.Builder(appContext, CHANNEL_ID)
                            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                            .setContentTitle("Sync complete")
                            .setContentText("$uploadedCount calls synced successfully")
                            .setOngoing(false)
                            .setAutoCancel(true)
                            .setPriority(NotificationCompat.PRIORITY_LOW)
                            .build()
                        nm.notify(NOTIFY_ID, doneNotif)
                    } else {
                        nm.cancel(NOTIFY_ID)
                    }
                } catch (_: Exception) {}
            }

            return@withContext SyncOutcome(lastStatus, uploadedCount, failedCount)
        } finally {
            isRunning.set(false)
        }
    }

    /**
     * Executes metadata upload with automatic token refresh on 401.
     */
    private fun executeMetadataUpload(
        context: Context,
        endpoint: String,
        payload: String,
        token: String,
        baseUrl: String,
    ): MetadataUploadResult {
        var activeToken = token
        var refreshedNewToken: String? = null

        for (attempt in 0..1) {
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
                    setRequestProperty("Authorization", "Bearer $activeToken")
                }

                OutputStreamWriter(conn.outputStream, "UTF-8").use { writer ->
                    writer.write(payload)
                    writer.flush()
                }

                val statusCode = conn.responseCode
                val responseBody = if (statusCode in 200..299) {
                    conn.inputStream.bufferedReader().use { it.readText() }
                } else {
                    conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                }

                if (statusCode == 401 && attempt == 0) {
                    Log.i(TAG, "[TOKEN_REFRESH] Received 401 during metadata upload; attempting native refresh...")
                    val newToken = performNativeTokenRefresh(context, baseUrl)
                    if (newToken != null) {
                        activeToken = newToken
                        refreshedNewToken = newToken
                        continue // Retry metadata upload with new token
                    } else {
                        return MetadataUploadResult(
                            isSuccess = false,
                            errorCode = "AUTH_EXPIRED",
                            isRetryable = false,
                            newToken = null,
                        )
                    }
                }

                if (statusCode in 200..299) {
                    var serverCallId: String? = null
                    var revision = 1
                    var isSuccess = true
                    var errorCode = "UNKNOWN"
                    var isRetryable = true

                    try {
                        val json = JSONObject(responseBody)
                        val data = json.optJSONObject("data")
                        val successfulArr = data?.optJSONArray("successful")
                        val duplicatesArr = data?.optJSONArray("duplicates")
                        val failedArr = data?.optJSONArray("failed")

                        if (successfulArr != null && successfulArr.length() > 0) {
                            val item = successfulArr.getJSONObject(0)
                            serverCallId = item.optString("call_id").takeIf { it.isNotBlank() } ?: item.optString("id").takeIf { it.isNotBlank() }
                            revision = item.optInt("revision", 1)
                        } else if (duplicatesArr != null && duplicatesArr.length() > 0) {
                            val item = duplicatesArr.getJSONObject(0)
                            serverCallId = item.optString("call_id").takeIf { it.isNotBlank() } ?: item.optString("existing_call_id").takeIf { it.isNotBlank() } ?: item.optString("id").takeIf { it.isNotBlank() }
                            revision = item.optInt("revision", 1)
                        } else if (failedArr != null && failedArr.length() > 0) {
                            isSuccess = false
                            val errObj = failedArr.getJSONObject(0).optJSONObject("error")
                            errorCode = errObj?.optString("code") ?: "SERVER_ERROR"
                            isRetryable = failedArr.getJSONObject(0).optBoolean("retryable", true)
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to parse metadata response JSON: ${e.message}")
                    }

                    return MetadataUploadResult(
                        isSuccess = isSuccess,
                        serverCallId = serverCallId,
                        revision = revision,
                        errorCode = errorCode,
                        isRetryable = isRetryable,
                        newToken = refreshedNewToken,
                    )
                } else {
                    val retryable = statusCode in 500..599 || statusCode == 408 || statusCode == 429
                    return MetadataUploadResult(
                        isSuccess = false,
                        errorCode = "HTTP_$statusCode",
                        isRetryable = retryable,
                        newToken = refreshedNewToken,
                    )
                }
            } catch (e: Exception) {
                Log.w(TAG, "Metadata upload network error: ${e.message}")
                return MetadataUploadResult(
                    isSuccess = false,
                    errorCode = "NETWORK_ERROR",
                    isRetryable = true,
                    newToken = refreshedNewToken,
                )
            } finally {
                conn?.disconnect()
            }
        }

        return MetadataUploadResult(
            isSuccess = false,
            errorCode = "AUTH_REFRESH_FAILED",
            isRetryable = false,
            newToken = refreshedNewToken,
        )
    }

    /**
     * Executes streaming multipart recording upload directly from Android ContentResolver.
     * Uses chunked streaming mode to prevent memory pressure or OOM on large audio files.
     */
    private fun executeStreamingRecordingUpload(
        context: Context,
        endpoint: String,
        recordingUri: Uri,
        mediaStoreId: Long?,
        storedChecksum: String?,
        durationSeconds: Int,
        token: String,
        baseUrl: String,
    ): RecordingUploadResult {
        var activeToken = token
        var refreshedNewToken: String? = null

        // 1. Resolve checksum
        val checksum = storedChecksum ?: (if (mediaStoreId != null) {
            RecordingScanner.sha256(context, mediaStoreId)?.get("checksum") as? String
        } else null) ?: "0000000000000000000000000000000000000000000000000000000000000000"

        for (attempt in 0..1) {
            var conn: HttpURLConnection? = null
            var inputStream: InputStream? = null

            try {
                // Verify recording can be opened
                inputStream = context.contentResolver.openInputStream(recordingUri)
                if (inputStream == null) {
                    Log.w(TAG, "Cannot open recording input stream for URI: $recordingUri")
                    return RecordingUploadResult(
                        isSuccess = false,
                        errorCode = "FILE_NOT_FOUND",
                        isRetryable = false,
                        newToken = refreshedNewToken,
                    )
                }

                val boundary = "==Boundary==" + UUID.randomUUID().toString()
                val lineEnd = "\r\n"
                val twoHyphens = "--"

                val url = URL(endpoint)
                conn = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = 30000
                    readTimeout = 60000
                    doOutput = true
                    doInput = true
                    useCaches = false
                    setChunkedStreamingMode(64 * 1024) // 64KB streaming buffer
                    setRequestProperty("Connection", "Keep-Alive")
                    setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
                    setRequestProperty("Authorization", "Bearer $activeToken")
                    setRequestProperty("X-Checksum-SHA256", checksum)
                }

                // Resolve dynamic display name and mime type from MediaStore if available
                var filename = "recording_${mediaStoreId ?: System.currentTimeMillis()}.m4a"
                var mimeType = "audio/mp4"

                if (mediaStoreId != null) {
                    try {
                        val proj = arrayOf(
                            android.provider.MediaStore.Audio.Media.DISPLAY_NAME,
                            android.provider.MediaStore.Audio.Media.MIME_TYPE
                        )
                        context.contentResolver.query(recordingUri, proj, null, null, null)?.use { cur ->
                            if (cur.moveToFirst()) {
                                val dName = cur.getString(0)
                                val mType = cur.getString(1)
                                if (!dName.isNullOrBlank()) filename = dName
                                if (!mType.isNullOrBlank()) mimeType = mType
                            }
                        }
                    } catch (_: Exception) {}
                }

                conn.outputStream.use { output ->
                    // 1. Write file part header
                    val fileHeader = buildString {
                        append(twoHyphens).append(boundary).append(lineEnd)
                        append("Content-Disposition: form-data; name=\"file\"; filename=\"$filename\"").append(lineEnd)
                        append("Content-Type: $mimeType").append(lineEnd)
                        append(lineEnd)
                    }
                    output.write(fileHeader.toByteArray(Charsets.UTF_8))

                    // 2. Stream audio bytes directly in 64KB buffers
                    val buffer = ByteArray(64 * 1024)
                    var bytesRead: Int
                    var totalUploaded = 0L
                    BufferedInputStream(inputStream).use { bis ->
                        while (bis.read(buffer).also { bytesRead = it } != -1) {
                            output.write(buffer, 0, bytesRead)
                            totalUploaded += bytesRead
                        }
                    }
                    output.write(lineEnd.toByteArray(Charsets.UTF_8))

                    // 3. Write form fields: checksum, file_size, duration_seconds
                    writeFormField(output, boundary, "checksum", checksum)
                    writeFormField(output, boundary, "file_size", totalUploaded.toString())
                    if (durationSeconds > 0) {
                        writeFormField(output, boundary, "duration_seconds", durationSeconds.toString())
                    }

                    // 4. Closing boundary
                    val closing = "$twoHyphens$boundary$twoHyphens$lineEnd"
                    output.write(closing.toByteArray(Charsets.UTF_8))
                    output.flush()
                }

                val statusCode = conn.responseCode
                val responseBody = if (statusCode in 200..299) {
                    conn.inputStream.bufferedReader().use { it.readText() }
                } else {
                    conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                }

                if (statusCode == 401 && attempt == 0) {
                    Log.i(TAG, "[TOKEN_REFRESH] Received 401 during recording upload; attempting native refresh...")
                    val newToken = performNativeTokenRefresh(context, baseUrl)
                    if (newToken != null) {
                        activeToken = newToken
                        refreshedNewToken = newToken
                        continue // Retry recording upload with new token
                    } else {
                        return RecordingUploadResult(
                            isSuccess = false,
                            errorCode = "AUTH_EXPIRED",
                            isRetryable = false,
                            newToken = null,
                        )
                    }
                }

                if (statusCode in 200..299) {
                    return RecordingUploadResult(
                        isSuccess = true,
                        errorCode = "OK",
                        isRetryable = false,
                        newToken = refreshedNewToken,
                    )
                } else {
                    val retryable = statusCode in 500..599 || statusCode == 408 || statusCode == 429
                    return RecordingUploadResult(
                        isSuccess = false,
                        errorCode = "HTTP_$statusCode",
                        isRetryable = retryable,
                        newToken = refreshedNewToken,
                    )
                }
            } catch (e: Exception) {
                Log.w(TAG, "Recording upload stream error: ${e.message}")
                return RecordingUploadResult(
                    isSuccess = false,
                    errorCode = "NETWORK_ERROR",
                    isRetryable = true,
                    newToken = refreshedNewToken,
                )
            } finally {
                try { inputStream?.close() } catch (_: Exception) {}
                conn?.disconnect()
            }
        }

        return RecordingUploadResult(
            isSuccess = false,
            errorCode = "AUTH_REFRESH_FAILED",
            isRetryable = false,
            newToken = refreshedNewToken,
        )
    }

    private fun writeFormField(output: OutputStream, boundary: String, name: String, value: String) {
        val lineEnd = "\r\n"
        val twoHyphens = "--"
        val part = buildString {
            append(twoHyphens).append(boundary).append(lineEnd)
            append("Content-Disposition: form-data; name=\"$name\"").append(lineEnd)
            append(lineEnd)
            append(value).append(lineEnd)
        }
        output.write(part.toByteArray(Charsets.UTF_8))
    }

    /**
     * Autonomous Native Token Refresh.
     *
     * Executes `POST /auth/refresh` directly with stored refresh token.
     * Persists new access and refresh tokens durably without Flutter.
     */
    private fun performNativeTokenRefresh(context: Context, baseUrl: String): String? {
        val refreshToken = IngestStore.getRefreshToken(context)
        if (refreshToken.isNullOrBlank()) {
            Log.w(TAG, "[TOKEN_REFRESH] No native refresh token available in storage.")
            return null
        }

        var conn: HttpURLConnection? = null
        try {
            val endpoint = "$baseUrl/auth/refresh"
            val url = URL(endpoint)
            conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10000
                readTimeout = 15000
                doOutput = true
                doInput = true
                setRequestProperty("Content-Type", "application/json; charset=UTF-8")
                setRequestProperty("Accept", "application/json")
            }

            val payload = JSONObject().apply {
                put("refresh_token", refreshToken)
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
                val json = JSONObject(responseBody)
                val isSuccess = json.optBoolean("success", false)
                val data = json.optJSONObject("data")
                val tokens = data?.optJSONObject("tokens")

                val newAccessToken = tokens?.optString("access_token")
                val newRefreshToken = tokens?.optString("refresh_token")

                if (!newAccessToken.isNullOrBlank()) {
                    IngestStore.updateAuthTokens(context, newAccessToken, newRefreshToken)
                    Log.i(TAG, "[TOKEN_REFRESH] Successfully refreshed access token natively.")
                    return newAccessToken
                }
            } else {
                Log.w(TAG, "[TOKEN_REFRESH] Refresh token request failed with HTTP $statusCode: $responseBody")
            }
        } catch (e: Exception) {
            Log.w(TAG, "[TOKEN_REFRESH] Exception during native token refresh: ${e.message}")
        } finally {
            conn?.disconnect()
        }

        return null
    }

    private fun maskPhoneNumber(phone: String): String {
        if (phone.length <= 4) return "****"
        return phone.substring(0, 2) + "*****" + phone.substring(phone.length - 2)
    }

    private fun ensureNotificationChannel(context: Context, notificationManager: NotificationManager?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && notificationManager != null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Sync Progress",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows live call uploading status."
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun showNotification(context: Context, notificationManager: NotificationManager?, statusText: String) {
        notificationManager?.let { nm ->
            try {
                val notif = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.stat_sys_upload)
                    .setContentTitle("Syncing call")
                    .setContentText(statusText)
                    .setProgress(0, 0, true)
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)
                    .setPriority(NotificationCompat.PRIORITY_LOW)
                    .build()
                nm.notify(NOTIFY_ID, notif)
            } catch (_: Exception) {}
        }
    }

    data class SyncOutcome(
        val status: String,
        val uploadedCount: Int,
        val failedCount: Int,
    )

    private data class MetadataUploadResult(
        val isSuccess: Boolean,
        val serverCallId: String? = null,
        val revision: Int = 1,
        val errorCode: String = "UNKNOWN",
        val isRetryable: Boolean = true,
        val newToken: String? = null,
    )

    private data class RecordingUploadResult(
        val isSuccess: Boolean,
        val errorCode: String = "UNKNOWN",
        val isRetryable: Boolean = true,
        val newToken: String? = null,
    )
}
