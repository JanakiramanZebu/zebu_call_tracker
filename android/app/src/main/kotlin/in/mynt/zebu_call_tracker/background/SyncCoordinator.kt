package `in`.mynt.zebu_call_tracker.background

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import `in`.mynt.zebu_call_tracker.call.CallWireFormat
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
import java.security.MessageDigest
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

    /**
     * Wall-clock budget for one drain.
     *
     * WorkManager stops a worker at 10 minutes. A run that ignores that gets
     * killed mid-upload with no chance to record where it got to, and the next
     * run starts over — so on a long backlog the queue appeared frozen. Stopping
     * at 8 minutes leaves room to finish the call in flight and hand back a
     * result, and [SyncOutcome.hasMoreWork] tells the caller to come straight
     * back for the rest.
     */
    private const val RUN_BUDGET_MILLIS = 8 * 60 * 1000L

    /**
     * Consecutive network failures before the run gives up.
     *
     * One call timing out is not evidence that the network is down — it may be
     * a single oversized recording or one bad server response. Aborting the
     * whole queue on the first one (as this used to) meant a single awkward row
     * stalled everything behind it.
     */
    private const val MAX_CONSECUTIVE_NETWORK_FAILURES = 3
    private const val CHANNEL_ID = "sync_progress"
    // Must not collide with CallTrackingService's 1003: this coordinator calls
    // notify()/cancel() on it around every run, and sharing the id meant each
    // finished sync tore down the persistent service's own foreground
    // notification — the one thing keeping that service alive.
    private const val NOTIFY_ID = 1004

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
        // Why the most recent row failed, in the server's own words. A PARTIAL
        // run recorded no error at all, so the Sync screen could say "Partial"
        // and nothing more — the handset knew the cause and threw it away.
        var lastErrorDetail: String? = null

        try {
            Log.i(TAG, "[SYNC_START] Trigger: $reason. Recovering stale records...")

            // 1. Recover stale records stuck in UPLOADING state from previous process death
            NativeCallOutboxDao.recoverStuckUploadingCalls(appContext)

            // 2. Recover rows buried by a fault that was never theirs. The
            //    permanent set is passed in rather than duplicated in the DAO
            //    so there is one list of "the server will refuse this for ever"
            //    and both halves of the state machine read it.
            NativeCallOutboxDao.reviveRetryableFailures(appContext, PERMANENT_RECORD_CODES)

            val rawBaseUrl = IngestStore.getApiBaseUrl(appContext)
            var currentToken = IngestStore.getAuthToken(appContext)
            val deviceUuid = IngestStore.getDeviceUuid(appContext)

            if (rawBaseUrl.isNullOrBlank() || currentToken.isNullOrBlank()) {
                Log.d(TAG, "No API base URL or auth token configured; skipping background sync.")
                IngestStore.recordSyncOutcome(appContext, "SKIPPED_NO_AUTH", 0)
                return@withContext SyncOutcome("SKIPPED_NO_AUTH", 0, 0)
            }

            if (deviceUuid.isNullOrBlank()) {
                // There is no useful default here. Sending a placeholder — this
                // used to fall back to the literal "android-device" — attributes
                // the batch to a device that was never registered, so the server
                // refuses every call in it. Stopping with a legible reason keeps
                // the outbox intact until the app has completed registration and
                // handed the real UUID down through setAuthSession().
                Log.w(TAG, "No device UUID stored; refusing to sync under a placeholder identity.")
                IngestStore.recordSyncOutcome(
                    appContext,
                    "SKIPPED_NO_DEVICE",
                    0,
                    "Device is not registered yet.",
                )
                return@withContext SyncOutcome("SKIPPED_NO_DEVICE", 0, 0)
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

            val policy = SyncPolicyStore.load(appContext)

            // 2. Metadata, in batches.
            //
            // `POST /sync/calls` takes an array and the guide recommends fifty
            // per request. This used to send one call per request, so a backlog
            // of five hundred meant five hundred round trips and five hundred
            // radio wake-ups to move a few kilobytes of JSON.
            //
            // Audio is NOT batched and never will be: §6.5 is explicit that
            // recordings go up one at a time, and they are handled by the
            // per-row loop below.
            val batchOutcome = drainMetadataBatches(
                context = appContext,
                baseUrl = normalizedBaseUrl,
                deviceUuid = deviceUuid,
                isoFormat = isoFormat,
                policy = policy,
                token = currentToken!!,
                runStartedAt = System.currentTimeMillis(),
                notificationManager = notificationManager,
            )
            uploadedCount += batchOutcome.uploaded
            failedCount += batchOutcome.failed
            if (batchOutcome.newToken != null) currentToken = batchOutcome.newToken
            if (batchOutcome.lastError != null) lastErrorDetail = batchOutcome.lastError
            if (batchOutcome.fatal) {
                IngestStore.recordSyncOutcome(
                    appContext,
                    "BLOCKED",
                    uploadedCount,
                    lastErrorDetail,
                )
                return@withContext SyncOutcome("BLOCKED", uploadedCount, failedCount, true)
            }

            // 3. Everything else — recordings, and any row the batch pass left
            //    behind — one at a time.
            Log.i(TAG, "[SYNC_LOOP] Starting 1-by-1 outbox processing loop...")

            // Every row this run has already handled.
            //
            // The loop's termination cannot rest on the claim predicate alone:
            // a row that comes back still matching it — a recording that fails
            // the same way every time, a state transition that does not stick —
            // would otherwise be re-claimed for as long as the process lives,
            // holding a wake lock and hammering the server. Claiming a key
            // twice in one run means no progress was made on it, so the run
            // stops rather than trying again immediately; the next trigger
            // picks it up with its backoff applied.
            val processedKeys = mutableSetOf<String>()
            val runStartedAt = System.currentTimeMillis()
            var consecutiveNetworkFailures = 0
            var stoppedEarly = false

            while (true) {
                if (System.currentTimeMillis() - runStartedAt > RUN_BUDGET_MILLIS) {
                    Log.i(TAG, "[SYNC_BUDGET] Run budget reached after $uploadedCount uploads; yielding.")
                    stoppedEarly = true
                    break
                }

                // Claim next WAITING or ready RETRY_PENDING record (sets state to UPLOADING atomically)
                val call = NativeCallOutboxDao.claimNextWaitingCall(appContext) ?: break

                if (!processedKeys.add(call.idempotencyKey)) {
                    Log.w(
                        TAG,
                        "[SYNC_LOOP] ${call.idempotencyKey} re-claimed without progressing; " +
                            "ending this run to avoid spinning."
                    )
                    NativeCallOutboxDao.markRetryPending(
                        appContext,
                        call.idempotencyKey,
                        "NO_PROGRESS",
                        call.attemptCount,
                        60L,
                    )
                    break
                }

                val maskedPhone = maskPhoneNumber(call.phoneNumber)
                Log.i(TAG, "[OUTBOX_CLAIM] Local ID: ${call.localId}, IdempotencyKey: ${call.idempotencyKey}, Phone: $maskedPhone, HasRec: ${call.hasRecording}, RecStatus: ${call.recordingUploadStatus}")

                // Post live progress notification
                showNotification(appContext, notificationManager, "Uploading $maskedPhone...")

                var confirmedServerCallId = call.serverCallId
                var confirmedRevision = 1
                var metadataSuccess = !confirmedServerCallId.isNullOrBlank()
                var isRetryable = true
                var errorCode = "UNKNOWN_ERROR"
                var retryAfterSeconds: Long? = null

                // -------------------------------------------------------------
                // STEP 1: Metadata Upload (if not already uploaded)
                // -------------------------------------------------------------
                if (!metadataSuccess) {
                    // Single source of truth for the wire vocabulary. Building
                    // it inline here is how `status = "completed"` — a value the
                    // server's enum does not contain — reached every request and
                    // had every answered call rejected with a non-retryable 422.
                    val outcome = CallWireFormat.outcomeFor(
                        rawDirection = call.direction,
                        durationSeconds = call.durationSeconds,
                        rawStatus = call.status,
                    )
                    val direction = outcome.direction
                    val statusStr = outcome.status

                    val startedAtStr = isoFormat.format(Date(call.startedAtMillis))
                    val nowStr = isoFormat.format(Date())

                    val callObj = JSONObject().apply {
                        put("idempotency_key", call.idempotencyKey)
                        // Through the shared rules, so a row missing its
                        // external id is named the same way the ingesters
                        // would have named it.
                        put(
                            "external_call_id",
                            call.externalCallId ?: CallWireFormat.Identity.externalId(
                                call.startedAtMillis,
                                call.phoneNumber,
                            ),
                        )
                        put("device_uuid", deviceUuid)
                        put("phone_number", call.phoneNumber)
                        if (!call.contactName.isNullOrBlank()) put("contact_name", call.contactName)
                        put("direction", direction)
                        put("status", statusStr)
                        put("started_at", startedAtStr)
                        applyTimings(this, call, isoFormat)
                        put("duration_seconds", call.durationSeconds)
                        put("has_recording", call.hasRecording)
                        put("sim_slot", call.simSlot)
                        put("client_created_at", nowStr)
                        applyMetadata(this, call)
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

                    val returnedId = metaResult.serverCallId?.takeIf { it.isNotBlank() }

                    if (metaResult.isSuccess && returnedId == null) {
                        // A 200 whose success/duplicate entry carries no
                        // `call_id`. This used to invent "server-<localId>",
                        // mark the row UPLOADED, and then POST the audio to
                        // /calls/server-42/recording — a 404 on every attempt,
                        // for ever. The call looked synced and its recording
                        // was silently lost.
                        //
                        // The record is safe to re-send: the idempotency key is
                        // unchanged, so a retry returns the existing row and
                        // its real id (§4.1).
                        metadataSuccess = false
                        errorCode = "MISSING_SERVER_CALL_ID"
                        isRetryable = true
                        lastErrorDetail = "server accepted the call but returned no call_id"
                        Log.w(
                            TAG,
                            "[METADATA_NO_CALL_ID] ${call.idempotencyKey} accepted with no " +
                                "call_id; re-queued rather than assigned a fabricated id.",
                        )
                    } else if (metaResult.isSuccess) {
                        metadataSuccess = true
                        confirmedServerCallId = returnedId
                        confirmedRevision = metaResult.revision
                        NativeCallOutboxDao.markServerCallId(appContext, call.idempotencyKey, returnedId!!, confirmedRevision)
                        Log.i(TAG, "[METADATA_UPLOAD_SUCCESS] IdempotencyKey: ${call.idempotencyKey}, ServerId: $returnedId")
                    } else {
                        metadataSuccess = false
                        errorCode = metaResult.errorCode
                        isRetryable = metaResult.isRetryable
                        retryAfterSeconds = metaResult.retryAfterSeconds
                        lastErrorDetail = metaResult.errorMessage
                            ?.let { "$errorCode: $it" }
                            ?: errorCode
                        Log.w(
                            TAG,
                            "[METADATA_UPLOAD_FAILED] IdempotencyKey: ${call.idempotencyKey}, " +
                                "Code: $errorCode, Retryable: $isRetryable, " +
                                "Detail: ${metaResult.errorMessage ?: "<none>"}",
                        )
                    }
                }

                // -------------------------------------------------------------
                // STEP 2: Recording Upload (if metadata succeeded and recording is pending)
                // -------------------------------------------------------------
                var recordingSuccess = true
                val serverId = confirmedServerCallId?.takeIf { it.isNotBlank() }
                if (metadataSuccess &&
                    serverId != null &&
                    call.hasRecording &&
                    call.recordingUploadStatus != "uploaded"
                ) {
                    val mediaStoreId = call.recordingMediaStoreId
                    val recordingUriStr = call.recordingPath ?: (if (mediaStoreId != null) RecordingScanner.contentUri(mediaStoreId) else null)

                    // 6.5: audio waits for an unmetered network unless the user
                    // has said otherwise. A recording is orders of magnitude
                    // larger than the metadata beside it, and spending somebody
                    // mobile data allowance on it uninvited is not this app
                    // decision to make. The row stays pending and the next run
                    // on Wi-Fi picks it up.
                    val meteredBlocked = !recordingUploadsAllowedNow(appContext)

                    if (meteredBlocked) {
                        Log.i(
                            TAG,
                            "[RECORDING_DEFERRED] ${call.idempotencyKey} held for an " +
                                "unmetered network.",
                        )
                        recordingSuccess = true
                        // The CALL is synced; only its audio is waiting. A
                        // plain retry-pending would move the row out of
                        // UPLOADED and report it to the user as unsent.
                        NativeCallOutboxDao.deferRecordingUpload(
                            appContext,
                            call.idempotencyKey,
                            900L,
                        )
                    } else if (recordingUriStr.isNullOrBlank()) {
                        // Terminal, not a failure: there is no file to retry.
                        // Marking it FAILED would leave the row matching the
                        // recording clause of the claim query forever.
                        Log.w(TAG, "[RECORDING_MISSING] No URI found for call ${call.idempotencyKey}; marking absent.")
                        NativeCallOutboxDao.markRecordingAbsent(appContext, call.idempotencyKey, "RECORDING_PATH_NULL")
                    } else if (
                        rejectRecordingLocally(appContext, policy, recordingUriStr, mediaStoreId)
                            .also { reason ->
                                if (reason != null) {
                                    // Sending a file the server is certain to
                                    // refuse costs the upload twice: once in
                                    // data, once in the retry. 6.4 says check
                                    // the size locally; the extension list is
                                    // the same argument.
                                    Log.w(
                                        TAG,
                                        "[RECORDING_REJECTED_LOCALLY] ${call.idempotencyKey}: $reason",
                                    )
                                    NativeCallOutboxDao.markRecordingAbsent(
                                        appContext, call.idempotencyKey, reason,
                                    )
                                }
                            } != null
                    ) {
                        // Handled above: terminal for this file, not for the call.
                        recordingSuccess = true
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
                            retryAfterSeconds = recResult.retryAfterSeconds
                            lastErrorDetail = "recording: $errorCode"
                            if (recResult.isRetryable) {
                                NativeCallOutboxDao.markRecordingFailed(appContext, call.idempotencyKey, errorCode)
                            } else {
                                // The server will keep rejecting this file.
                                // Stop offering it, but do not let that drag the
                                // call's own state backwards — see STEP 3.
                                NativeCallOutboxDao.markRecordingAbsent(appContext, call.idempotencyKey, errorCode)
                            }
                            Log.w(TAG, "[RECORDING_UPLOAD_FAILED] ServerId: $serverId, Code: $errorCode, Retryable: $isRetryable")
                        }
                    }
                }

                // -------------------------------------------------------------
                // STEP 3: Complete or Retry Transition
                // -------------------------------------------------------------
                if (metadataSuccess) consecutiveNetworkFailures = 0

                if (metadataSuccess && (recordingSuccess || !isRetryable)) {
                    // `sync_state` tracks the CALL, not its audio. Once the
                    // server has the metadata that fact is permanent, so a
                    // recording that can never be delivered still leaves the
                    // call UPLOADED — with recording_upload_status carrying the
                    // bad news. Downgrading the whole row to FAILED here used
                    // to hide successfully-synced calls from the UI and re-post
                    // metadata the server already had.
                    // Reachable only with a real id: the branch above turns a
                    // success without one into a retry.
                    NativeCallOutboxDao.markUploaded(appContext, call.idempotencyKey, serverId!!, confirmedRevision)
                    if (recordingSuccess) {
                        uploadedCount++
                    } else {
                        failedCount++
                        Log.w(TAG, "[CALL_COMPLETE] ${call.idempotencyKey} synced; recording undeliverable ($errorCode)")
                    }
                    Log.i(TAG, "[CALL_COMPLETE] IdempotencyKey: ${call.idempotencyKey}, FinalStatus: UPLOADED")
                } else {
                    failedCount++
                    if (isRetryable) {
                        // A server-supplied Retry-After wins over our own
                        // backoff — §9 requires it be honoured on a 429.
                        val delaySeconds = retryAfterSeconds
                            ?: (1L shl (call.attemptCount + 1).coerceIn(1, 16)).coerceIn(2L, 600L)
                        NativeCallOutboxDao.markRetryPending(appContext, call.idempotencyKey, errorCode, call.attemptCount, delaySeconds)
                        Log.i(TAG, "[SYNC_RETRY] Scheduled retry for ${call.idempotencyKey} in ${delaySeconds}s (Error: $errorCode)")

                        if (errorCode == "NETWORK_ERROR") {
                            consecutiveNetworkFailures++
                            if (consecutiveNetworkFailures >= MAX_CONSECUTIVE_NETWORK_FAILURES) {
                                Log.i(TAG, "Halting: $consecutiveNetworkFailures consecutive network failures.")
                                stoppedEarly = true
                                break
                            }
                            // Otherwise keep going — the next row may be fine.
                        } else if (errorCode in HALT_BUT_RETRYABLE_CODES) {
                            // The row stays queued with its backoff; only this
                            // run stops. Walking the rest of the backlog would
                            // produce the same failure once per call.
                            Log.i(TAG, "Halting run: $errorCode blocks every remaining row; queue preserved.")
                            IngestStore.recordSyncOutcome(
                                appContext,
                                blockedStatusFor(errorCode),
                                uploadedCount,
                                lastErrorDetail ?: errorCode,
                            )
                            stoppedEarly = true
                            break
                        }
                    } else {
                        NativeCallOutboxDao.markFailed(appContext, call.idempotencyKey, errorCode, call.attemptCount)
                        Log.i(TAG, "[SYNC_FAILURE] Permanent failure for ${call.idempotencyKey} (Code: $errorCode)")

                        if (isFatal(errorCode)) {
                            // The handset itself is blocked — revoked device,
                            // deactivated account. Nothing else in the queue
                            // will fare any better, and the guide is explicit
                            // that these must not be retried.
                            //
                            // The auth codes used to be tested here too. They
                            // are retryable now and never reach this branch:
                            // they halt the run from the retryable side, with
                            // the rows preserved rather than marked FAILED.
                            Log.w(TAG, "Halting outbox processing: $errorCode is fatal for this device.")
                            IngestStore.recordSyncOutcome(
                                appContext,
                                blockedStatusFor(errorCode),
                                uploadedCount,
                                lastErrorDetail ?: errorCode,
                            )
                            stoppedEarly = true
                            break
                        }
                    }
                }
            }

            lastStatus = if (failedCount == 0) "OK" else "PARTIAL"
            IngestStore.recordSyncOutcome(
                appContext,
                lastStatus,
                uploadedCount,
                if (failedCount == 0) null else lastErrorDetail,
            )
            Log.i(
                TAG,
                "[SYNC_STOP] Uploaded: $uploadedCount, Failed: $failedCount, " +
                    "stoppedEarly: $stoppedEarly"
            )

            // A run that stopped on its budget or on repeated network errors
            // has work left; that is reported through SyncOutcome.hasMoreWork.
            //
            // Deliberately NOT re-enqueued here: this method usually runs
            // inside CallSyncWorker, which IS the unique work named
            // WORK_SYNC_NOW, and BackgroundScheduler.enqueueSync uses
            // ExistingWorkPolicy.REPLACE — so enqueuing from here would cancel
            // the very run doing the enqueuing. The worker returns
            // Result.retry() instead, and WorkManager reschedules with backoff.

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

            return@withContext SyncOutcome(lastStatus, uploadedCount, failedCount, stoppedEarly)
        } finally {
            isRunning.set(false)
        }
    }

    private data class BatchDrainOutcome(
        val uploaded: Int = 0,
        val failed: Int = 0,
        val newToken: String? = null,
        val lastError: String? = null,
        /** The whole handset is blocked; stop the run. */
        val fatal: Boolean = false,
    )

    /**
     * Sends queued call metadata in batches until the queue or the budget runs
     * out.
     *
     * Partial success is the normal case (Mobile API Guide 5.3): one malformed
     * record never rejects the batch, so every result is applied on its own by
     * `idempotency_key`. Rows carrying audio are marked UPLOADED here and then
     * picked up by the per-row loop for their recording, which is why this
     * never touches `recording_upload_status`.
     */
    private fun drainMetadataBatches(
        context: Context,
        baseUrl: String,
        deviceUuid: String,
        isoFormat: SimpleDateFormat,
        policy: SyncPolicyStore.Policy,
        token: String,
        runStartedAt: Long,
        notificationManager: NotificationManager?,
    ): BatchDrainOutcome {
        var activeToken = token
        var refreshedToken: String? = null
        var uploaded = 0
        var failed = 0
        var lastError: String? = null

        while (true) {
            if (System.currentTimeMillis() - runStartedAt > RUN_BUDGET_MILLIS) {
                Log.i(TAG, "[BATCH_BUDGET] Metadata budget reached after $uploaded calls.")
                break
            }

            val batch = NativeCallOutboxDao.claimMetadataBatch(context, policy.batchSize)
            if (batch.isEmpty()) break

            Log.i(TAG, "[BATCH_START] Posting ${batch.size} call(s) in one request.")
            showNotification(
                context,
                notificationManager,
                "Sending ${batch.size} " + (if (batch.size == 1) "call" else "calls") + "...",
            )

            val nowStr = isoFormat.format(Date())
            val callsArray = JSONArray()
            for (call in batch) {
                val outcome = CallWireFormat.outcomeFor(
                    rawDirection = call.direction,
                    durationSeconds = call.durationSeconds,
                    rawStatus = call.status,
                )
                callsArray.put(
                    JSONObject().apply {
                        put("idempotency_key", call.idempotencyKey)
                        put(
                            "external_call_id",
                            call.externalCallId ?: CallWireFormat.Identity.externalId(
                                call.startedAtMillis,
                                call.phoneNumber,
                            ),
                        )
                        put("device_uuid", deviceUuid)
                        put("phone_number", call.phoneNumber)
                        if (!call.contactName.isNullOrBlank()) {
                            put("contact_name", call.contactName)
                        }
                        put("direction", outcome.direction)
                        put("status", outcome.status)
                        put("started_at", isoFormat.format(Date(call.startedAtMillis)))
                        applyTimings(this, call, isoFormat)
                        put("duration_seconds", call.durationSeconds)
                        put("has_recording", call.hasRecording)
                        put("sim_slot", call.simSlot)
                        put("client_created_at", nowStr)
                        applyMetadata(this, call)
                    },
                )
            }

            val payload = JSONObject().apply {
                put("device_uuid", deviceUuid)
                put("client_synced_at", nowStr)
                put("calls", callsArray)
            }

            val result = executeMetadataUpload(
                context = context,
                endpoint = "$baseUrl/sync/calls",
                payload = payload.toString(),
                token = activeToken,
                baseUrl = baseUrl,
            )
            if (result.newToken != null) {
                activeToken = result.newToken
                refreshedToken = result.newToken
            }

            if (result.transportFailed) {
                // The request never landed, so nothing in this batch was
                // decided. Every row goes back on its own backoff rather than
                // being judged by a response that does not exist.
                for (call in batch) {
                    NativeCallOutboxDao.markRetryPending(
                        context,
                        call.idempotencyKey,
                        result.errorCode,
                        call.attemptCount,
                        backoffSeconds(call.attemptCount),
                    )
                }
                failed += batch.size
                lastError = result.errorMessage ?: result.errorCode
                // "Stop the run", not "fail the rows" — every row in this batch
                // was re-queued above. Tested against the halt set rather than
                // AUTH_EXPIRED alone so a NO_SESSION or an exhausted refresh
                // stops here too instead of grinding through the whole backlog
                // one doomed request at a time.
                val fatal = isFatal(result.errorCode) ||
                    result.errorCode in HALT_BUT_RETRYABLE_CODES
                Log.w(TAG, "[BATCH_TRANSPORT_FAIL] ${result.errorCode}; ${batch.size} re-queued.")
                return BatchDrainOutcome(uploaded, failed, refreshedToken, lastError, fatal)
            }

            val byKey = batch.associateBy { it.idempotencyKey }
            val decided = mutableSetOf<String>()

            // `successful` and `duplicates` are both successes (5.3): a repeat
            // means the server already holds the record, which is precisely
            // what the idempotency key exists to guarantee.
            for (entry in result.accepted) {
                val call = byKey[entry.idempotencyKey] ?: continue
                decided += entry.idempotencyKey
                val serverId = entry.callId
                if (serverId.isNullOrBlank()) {
                    // No id means no recording URL and nothing to reference
                    // later. Re-queue rather than invent one.
                    NativeCallOutboxDao.markRetryPending(
                        context, call.idempotencyKey, "MISSING_SERVER_CALL_ID",
                        call.attemptCount, 60L,
                    )
                    failed++
                    continue
                }
                NativeCallOutboxDao.markServerCallId(
                    context, call.idempotencyKey, serverId, entry.revision,
                )
                NativeCallOutboxDao.markUploaded(
                    context, call.idempotencyKey, serverId, entry.revision,
                )
                uploaded++
            }

            for (entry in result.rejected) {
                val call = byKey[entry.idempotencyKey] ?: continue
                decided += entry.idempotencyKey
                failed++
                lastError = entry.message ?: entry.code
                if (entry.retryable) {
                    NativeCallOutboxDao.markRetryPending(
                        context, call.idempotencyKey, entry.code,
                        call.attemptCount, backoffSeconds(call.attemptCount),
                    )
                } else {
                    // 5.3: permanently rejected. Retrying forever will never
                    // succeed and burns the battery and the data allowance.
                    NativeCallOutboxDao.markFailed(
                        context, call.idempotencyKey, entry.code, call.attemptCount,
                    )
                }
            }

            // A row the server said nothing about. Not an error, but leaving it
            // UPLOADING strands it until the next crash-recovery pass.
            for (call in batch) {
                if (call.idempotencyKey in decided) continue
                Log.w(
                    TAG,
                    "[BATCH_UNANSWERED] ${call.idempotencyKey} absent from the response; re-queued.",
                )
                NativeCallOutboxDao.markRetryPending(
                    context, call.idempotencyKey, "NO_RESULT_FOR_KEY", call.attemptCount, 60L,
                )
            }

            Log.i(
                TAG,
                "[BATCH_DONE] sent=${batch.size} accepted=${result.accepted.size} " +
                    "rejected=${result.rejected.size}",
            )
        }

        return BatchDrainOutcome(uploaded, failed, refreshedToken, lastError, false)
    }

    /**
     * Whether audio may go out over the current connection.
     *
     * WorkManager only guarantees CONNECTED for the sync job, so the metered
     * check happens here rather than in the job constraint -- the same run also
     * carries metadata, which should not be held back for a Wi-Fi network.
     */
    private fun recordingUploadsAllowedNow(context: Context): Boolean {
        if (SyncPolicyStore.recordingsAllowedOnMeteredNetworks(context)) return true
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? android.net.ConnectivityManager ?: return true
        return try {
            val caps = cm.getNetworkCapabilities(cm.activeNetwork)
            // Unknown means do not block: a handset whose capabilities cannot be
            // read should still sync, and the server enforces its own limits.
            caps == null || caps.hasCapability(
                android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED,
            )
        } catch (e: Exception) {
            Log.w(TAG, "Could not read network metering: ${e.message}")
            true
        }
    }

    /**
     * Why the server would refuse this file, decided before a byte is sent.
     *
     * Null when it is worth uploading. Both checks mirror limits the server
     * publishes in `policy` and this app previously ignored: a 200 MB cap
     * (6.4) and an extension allow-list (6.3). Without them a long recording
     * was streamed in full to earn a 413, on the user data allowance, and an
     * exotic container earned a 415 the same way.
     */
    private fun rejectRecordingLocally(
        context: Context,
        policy: SyncPolicyStore.Policy,
        uriString: String,
        mediaStoreId: Long?,
    ): String? {
        return try {
            val uri = Uri.parse(uriString)
            var sizeBytes = -1L
            var displayName: String? = null

            context.contentResolver.query(
                uri,
                arrayOf(
                    android.provider.MediaStore.Audio.Media.SIZE,
                    android.provider.MediaStore.Audio.Media.DISPLAY_NAME,
                ),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    if (!c.isNull(0)) sizeBytes = c.getLong(0)
                    if (!c.isNull(1)) displayName = c.getString(1)
                }
            }

            if (sizeBytes > policy.maxRecordingSizeBytes) {
                return "PAYLOAD_TOO_LARGE"
            }

            val extension = displayName
                ?.substringAfterLast('.', "")
                ?.lowercase()
                ?.takeIf { it.isNotEmpty() }

            // Only reject on a KNOWN-bad extension. An unreadable name is not
            // evidence of a bad file, and the server checks magic bytes anyway.
            if (extension != null &&
                extension !in policy.allowedRecordingExtensions
            ) {
                return "UNSUPPORTED_MEDIA_TYPE"
            }

            null
        } catch (e: Exception) {
            Log.w(TAG, "Could not pre-check recording $mediaStoreId: ${e.message}")
            null
        }
    }

    /** Exponential with the cap the guide asks for (10.2). */
    /**
     * Writes `answered_at` and `ended_at` onto a call payload.
     *
     * Shared by both payload builders because they must describe a call
     * identically — the batch pass and the one-at-a-time pass handle the same
     * rows, and a row that took the slow path because it carries audio must not
     * be timestamped differently for it.
     *
     * `ended_at` used to be computed here as `started_at + duration_seconds`.
     * That is wrong by the entire ring: `started_at` is `CallLog.Calls.DATE`,
     * the moment the phone began ringing, while `DURATION` counts connected
     * seconds only. Every call the server holds ended earlier than it really
     * did, by between a second and three minutes.
     *
     * Both fields are omitted when the device could not establish them. The
     * server recomputes `duration_seconds` from the pair whenever both are
     * present and that value wins, so a fabricated pair does not merely add
     * noise — it overwrites the one number that was measured correctly.
     */
    private fun applyTimings(
        json: JSONObject,
        call: CallRecord,
        isoFormat: SimpleDateFormat,
    ) {
        call.answeredAtMillis?.let {
            json.put("answered_at", isoFormat.format(Date(it)))
        }
        call.endedAtMillis?.let {
            json.put("ended_at", isoFormat.format(Date(it)))
        }
    }

    /**
     * Attaches the stored `metadata` bag, if the row has one.
     *
     * Held as pre-encoded JSON rather than rebuilt here: it describes the
     * call-log row and the recording as they were at capture, and the provider
     * rows behind it are long out of scope by upload time. A string that no
     * longer parses is dropped, since sending the server a malformed object
     * costs the whole call a 422 for the sake of an optional field.
     */
    private fun applyMetadata(json: JSONObject, call: CallRecord) {
        val raw = call.metadataJson
        if (raw.isNullOrBlank()) return
        try {
            json.put("metadata", JSONObject(raw))
        } catch (e: Exception) {
            Log.w(TAG, "[METADATA_UNPARSEABLE] ${call.idempotencyKey}: ${e.message}")
        }
    }

    private fun backoffSeconds(attemptCount: Int): Long =
        (1L shl (attemptCount + 1).coerceIn(1, 16)).coerceIn(2L, 600L)

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
                    Log.i(TAG, "[TOKEN_REFRESH] Received 401 during metadata upload; refreshing...")
                    val refreshed = refreshAccessToken(context, baseUrl, activeToken)
                    if (refreshed.isSuccess) {
                        activeToken = refreshed.accessToken!!
                        refreshedNewToken = activeToken
                        continue // Retry metadata upload with the new token
                    }
                    // A refresh that failed on the network says nothing about
                    // whether the session is still good. Reporting AUTH_EXPIRED
                    // here marked the row permanently failed and halted the
                    // whole run, so one dropped connection buried the queue.
                    return MetadataUploadResult(
                        isSuccess = false,
                        transportFailed = true,
                        errorCode = refreshErrorCode(refreshed.failure),
                        // Retryable whatever the refresh failure was: the row
                        // is fine, the session is not. See refreshErrorCode.
                        isRetryable = true,
                        newToken = null,
                    )
                }

                if (statusCode in 200..299) {
                    // EVERY entry, not just the first.
                    //
                    // This used to read element zero of whichever array was
                    // non-empty and discard the rest, which was survivable only
                    // because each request carried exactly one call. A batch of
                    // fifty needs all fifty verdicts, matched back by
                    // `idempotency_key` -- the guide supplies `index` too, but
                    // the key is order-independent and therefore the safer join.
                    val accepted = mutableListOf<BatchEntry>()
                    val rejected = mutableListOf<BatchEntry>()

                    try {
                        val data = JSONObject(responseBody).optJSONObject("data")
                        accepted += data?.optJSONArray("successful").toAcceptedEntries()
                        accepted += data?.optJSONArray("duplicates").toAcceptedEntries()
                        rejected += data?.optJSONArray("failed").toRejectedEntries()
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to parse metadata response JSON: ${e.message}")
                    }

                    for (entry in rejected) {
                        // The REQUEST succeeded (200) and a call inside it was
                        // refused. This is where a 422 actually lands on the
                        // batch endpoint, so it is the one place the reason can
                        // be read at all.
                        Log.w(
                            TAG,
                            "[METADATA_REJECTED] ${entry.code} retryable=${entry.retryable} " +
                                (entry.message ?: "<no message>"),
                        )
                    }

                    val first = accepted.firstOrNull()
                    val firstRejection = rejected.firstOrNull()

                    return MetadataUploadResult(
                        // The single-row caller reads these; the batch caller
                        // reads the lists. Both describe the same response.
                        isSuccess = accepted.isNotEmpty() ||
                            (rejected.isEmpty() && accepted.isEmpty()),
                        serverCallId = first?.callId,
                        revision = first?.revision ?: 1,
                        errorCode = firstRejection?.code ?: "UNKNOWN",
                        errorMessage = firstRejection?.message,
                        isRetryable = firstRejection?.retryable ?: true,
                        newToken = refreshedNewToken,
                        accepted = accepted,
                        rejected = rejected,
                    )
                } else {
                    // Branch on error.code, never on the HTTP status alone
                    // (Mobile API Guide §1). The envelope carries the only
                    // thing that says whether this is worth retrying: a 403 is
                    // DEVICE_NOT_REGISTERED (recoverable — register and come
                    // back) or DEVICE_REVOKED (stop entirely), and treating
                    // both as a flat permanent failure silently killed every
                    // queued call on a handset that had simply not registered.
                    val serverCode = parseErrorCode(responseBody)
                    val serverDetail = describeError(responseBody)
                    Log.w(
                        TAG,
                        "[METADATA_HTTP_$statusCode] ${serverCode ?: "no error.code"} " +
                            (serverDetail ?: "<empty body>"),
                    )
                    return MetadataUploadResult(
                        isSuccess = false,
                        // The whole request was refused, so no per-call verdicts
                        // exist and the batch caller must re-queue all of them.
                        transportFailed = true,
                        errorCode = serverCode ?: "HTTP_$statusCode",
                        errorMessage = serverDetail,
                        isRetryable = isRetryableFailure(statusCode, serverCode),
                        retryAfterSeconds = parseRetryAfter(conn),
                        newToken = refreshedNewToken,
                    )
                }
            } catch (e: Exception) {
                Log.w(TAG, "Metadata upload network error: ${e.message}")
                return MetadataUploadResult(
                    isSuccess = false,
                    transportFailed = true,
                    errorCode = "NETWORK_ERROR",
                    isRetryable = true,
                    newToken = refreshedNewToken,
                )
            } finally {
                conn?.disconnect()
            }
        }

        // Both 401 attempts are spent. Retryable, and halting: the row is
        // untouched by whatever is wrong with the session, so it must not be
        // buried in FAILED where nothing will ever claim it again.
        return MetadataUploadResult(
            isSuccess = false,
            transportFailed = true,
            errorCode = "AUTH_REFRESH_FAILED",
            isRetryable = true,
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

        // 1. Resolve checksum.
        //
        // Falling back to a string of zeros, as this once did, sends the server
        // a digest that cannot match the bytes that follow. It rejects the
        // upload, non-retryably, on every attempt — so the recording is lost
        // rather than merely delayed. Reading the stream twice costs one extra
        // pass over the file and is the only answer that can succeed.
        val checksum = storedChecksum
            ?: (if (mediaStoreId != null) {
                RecordingScanner.sha256(context, mediaStoreId)?.get("checksum") as? String
            } else null)
            ?: digestUri(context, recordingUri)
            ?: return RecordingUploadResult(
                isSuccess = false,
                errorCode = "CHECKSUM_UNAVAILABLE",
                isRetryable = false,
                newToken = null,
            )

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

                    // 3. Write form fields: checksum, file_size, duration_seconds, mime_type
                    writeFormField(output, boundary, "checksum", checksum)
                    writeFormField(output, boundary, "file_size", totalUploaded.toString())
                    if (durationSeconds > 0) {
                        writeFormField(output, boundary, "duration_seconds", durationSeconds.toString())
                    }
                    // §6 lists this as an accepted field, and MediaStore knows
                    // the real type. Left unsent, the server falls back to the
                    // part's Content-Type, which is our own guess whenever the
                    // MediaStore lookup below returned nothing.
                    writeFormField(output, boundary, "mime_type", mimeType)

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
                    Log.i(TAG, "[TOKEN_REFRESH] Received 401 during recording upload; refreshing...")
                    val refreshed = refreshAccessToken(context, baseUrl, activeToken)
                    if (refreshed.isSuccess) {
                        activeToken = refreshed.accessToken!!
                        refreshedNewToken = activeToken
                        continue // Retry recording upload with the new token
                    }
                    return RecordingUploadResult(
                        isSuccess = false,
                        errorCode = refreshErrorCode(refreshed.failure),
                        // As above: a dead session says nothing about the audio.
                        isRetryable = true,
                        newToken = null,
                    )
                }

                if (statusCode in 200..299) {
                    return RecordingUploadResult(
                        isSuccess = true,
                        errorCode = "OK",
                        isRetryable = false,
                        newToken = refreshedNewToken,
                    )
                } else {
                    val serverCode = parseErrorCode(responseBody)
                    return RecordingUploadResult(
                        isSuccess = false,
                        errorCode = serverCode ?: "HTTP_$statusCode",
                        isRetryable = isRetryableFailure(statusCode, serverCode),
                        retryAfterSeconds = parseRetryAfter(conn),
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
            isRetryable = true,
            newToken = refreshedNewToken,
        )
    }

    /**
     * SHA-256 of whatever the ContentResolver serves for [uri], streamed in
     * 64 KB blocks so a long recording never lands in memory whole.
     *
     * Returns null when the URI cannot be opened, which the caller treats as
     * a permanent failure — an unreadable file will not become readable.
     */
    private fun digestUri(context: Context, uri: Uri): String? {
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            context.contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(64 * 1024)
                var read: Int
                while (input.read(buffer).also { read = it } != -1) {
                    digest.update(buffer, 0, read)
                }
            } ?: return null
            digest.digest().joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            Log.w(TAG, "Could not digest recording at $uri: ${e.message}")
            null
        }
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
     * Delegates to [TokenRefresher], which is the single-flight gate every
     * refresh in the app passes through.
     *
     * This method used to perform the exchange itself, straight into
     * [IngestStore], while three Dart-side `ApiClient` instances did the same
     * thing into `flutter_secure_storage`. Four holders of a token the server
     * rotates on every use, and no two of them told each other — so the second
     * one to refresh replayed a dead token and the server revoked the whole
     * session chain.
     *
     * [staleToken] is the token that just came back 401, so a caller that lost
     * a race gets the winner's token instead of starting a second exchange.
     */
    /**
     * Maps a refresh failure onto the vocabulary the outbox state machine reads.
     *
     * All three land in [HALT_BUT_RETRYABLE_CODES]: the run stops, because
     * every remaining row would fail identically against the same dead session,
     * but each row keeps its backoff and stays claimable.
     *
     * None of them may mark a row FAILED. A refusal to refresh is a fact about
     * the SESSION, never about the call — the record is as valid as it was a
     * second earlier, and it uploads fine once the handset is paired again.
     * Marking it FAILED was terminal: the claim query in `NativeCallOutboxDao`
     * matches only WAITING, RETRY_PENDING and UPLOADED-owing-audio, so a row
     * that hit one expired token was never offered to the server again — not by
     * the next run, not after a reboot, not after signing back in.
     */
    /**
     * Halt codes whose cure is re-registering the handset, not calling anyone.
     *
     * The Sync screen's BLOCKED alert says "contact your administrator", which
     * is right for a revoked device and useless for an expired session — the
     * employee fixes that themselves in under a minute. Reported under a
     * separate status so the alert can say so.
     */
    private val AUTH_HALT_CODES = setOf(
        "AUTH_EXPIRED",
        "AUTH_NO_SESSION",
        "AUTH_REFRESH_FAILED",
    )

    /** BLOCKED, but by a credential the user can replace. */
    private fun blockedStatusFor(errorCode: String?): String =
        if (errorCode in AUTH_HALT_CODES) "BLOCKED_AUTH" else "BLOCKED"

    private fun refreshErrorCode(failure: TokenRefresher.Failure?): String = when (failure) {
        TokenRefresher.Failure.TRANSIENT -> "AUTH_REFRESH_UNAVAILABLE"
        TokenRefresher.Failure.NO_SESSION -> "AUTH_NO_SESSION"
        else -> "AUTH_EXPIRED"
    }

    private fun refreshAccessToken(
        context: Context,
        baseUrl: String,
        staleToken: String?,
    ): TokenRefresher.Result = TokenRefresher.refresh(context, baseUrl, staleToken)

    /**
     * Retryable, but retrying the *rest of the queue* right now is pointless:
     * every remaining row would fail the same way against the same server
     * state. The run stops and each row keeps its backoff, so the outbox is
     * preserved and the next trigger picks up where this one left off.
     *
     * DEVICE_NOT_REGISTERED is the case that matters. The server now reports it
     * as retryable (it is: the app registers, and the same call is then
     * accepted), but without this the coordinator would walk the entire backlog
     * one failed request at a time before giving up.
     */
    private val HALT_BUT_RETRYABLE_CODES = setOf(
        // The token could not be refreshed for a reason that is not the
        // token's fault — no signal, a 5xx on /auth/refresh. Every remaining
        // row would 401 identically, so the run stops and each keeps its
        // backoff.
        "AUTH_REFRESH_UNAVAILABLE",

        // Every other way a refresh can fail. These once fell through to
        // markFailed, which is the wrong verb entirely: the outbox row is
        // valid, and it is the credential that has to be replaced. Halting
        // here preserves the queue and the Sync screen still reports BLOCKED,
        // so the user is told to sign in — the difference is that the backlog
        // is still there to upload when they do.
        "AUTH_EXPIRED",
        "AUTH_NO_SESSION",
        "AUTH_REFRESH_FAILED",
        "DEVICE_NOT_REGISTERED",
        "DEVICE_INACTIVE",
        "RATE_LIMIT_EXCEEDED",
        "INSUFFICIENT_STORAGE",
        "DATABASE_UNAVAILABLE",
        "SERVICE_UNAVAILABLE",
    )

    /**
     * Codes that mean this handset must stop syncing altogether until a person
     * intervenes (Mobile API Guide §9, §10.1). Retrying any of these only burns
     * battery and data.
     */
    private val FATAL_CODES = setOf(
        "DEVICE_REVOKED",
        "DEVICE_OWNED_BY_ANOTHER_USER",
        "ACCOUNT_INACTIVE",
        "ACCOUNT_LOCKED",
        "INVALID_TOKEN",
        "PERMISSION_DENIED",
    )

    /**
     * Codes that are permanent for THIS record but say nothing about the rest
     * of the queue. §5.3: drop it and stop retrying.
     */
    private val PERMANENT_RECORD_CODES = setOf(
        "SYNC_POLICY_VIOLATION",
        "VALIDATION_ERROR",
        "INVALID_CALL_STATE_TRANSITION",
        "PAYLOAD_TOO_LARGE",
        "UNSUPPORTED_MEDIA_TYPE",
        "CORRUPT_UPLOAD",
        "RECORDING_ALREADY_EXISTS",
        "RECORDING_NOT_FOUND",
    )

    /**
     * Recoverable despite a 4xx: the client can fix the precondition and the
     * same record will then be accepted.
     */
    private val RECOVERABLE_CODES = setOf(
        "DEVICE_NOT_REGISTERED",
        "DEVICE_INACTIVE",
        "CHECKSUM_MISMATCH",
        "FILE_SIZE_MISMATCH",
        "RECORDING_NOT_READY",
        "TOKEN_EXPIRED",
    )

    /** True when the code names a condition the whole run must stop for. */
    fun isFatal(errorCode: String?): Boolean = errorCode in FATAL_CODES

    /**
     * Pulls `error.code` out of the standard envelope (§1).
     *
     * Returns null when the body is not the envelope — a proxy error page, an
     * empty 502 — so the caller falls back to the HTTP status.
     */
    private fun parseErrorCode(body: String?): String? {
        if (body.isNullOrBlank()) return null
        return try {
            JSONObject(body).optJSONObject("error")
                ?.optString("code")
                ?.takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        }
    }

    /** How much of an unparseable error body is worth keeping. */
    private const val ERROR_BODY_LIMIT = 600

    /**
     * The human half of the envelope: `error.message` plus any per-field
     * `error.details`.
     *
     * A `422 VALIDATION_ERROR` names the field it objected to **only** in
     * `details`. This coordinator read `error.code` and discarded the rest of
     * the body, so a rejected call was recorded as the bare word
     * "VALIDATION_ERROR" — enough to know the upload failed, never enough to
     * know why, and not fixable without putting a proxy in front of the
     * handset. Falls back to the raw body when it is not an envelope at all (a
     * proxy error page), because that is still more than nothing.
     */
    private fun describeError(body: String?): String? {
        if (body.isNullOrBlank()) return null
        return try {
            val error = JSONObject(body).optJSONObject("error")
                ?: return body.take(ERROR_BODY_LIMIT)
            val message = error.optString("message").takeIf { it.isNotBlank() }
            val details = error.opt("details")
                ?.takeIf { it != JSONObject.NULL }
                ?.toString()
                ?.takeIf { it.isNotBlank() && it != "{}" && it != "[]" }
            listOfNotNull(message, details)
                .joinToString(" ")
                .takeIf { it.isNotBlank() }
                ?.take(ERROR_BODY_LIMIT)
        } catch (_: Exception) {
            body.take(ERROR_BODY_LIMIT)
        }
    }

    /** §10.1, expressed once. */
    private fun isRetryableFailure(statusCode: Int, errorCode: String?): Boolean {
        if (errorCode != null) {
            if (errorCode in FATAL_CODES) return false
            if (errorCode in PERMANENT_RECORD_CODES) return false
            if (errorCode in RECOVERABLE_CODES) return true
        }
        return statusCode in 500..599 || statusCode == 408 || statusCode == 429
    }

    /** Honours `Retry-After` on a 429, as §9 requires. Seconds form only. */
    private fun parseRetryAfter(conn: HttpURLConnection?): Long? =
        conn?.getHeaderField("Retry-After")?.trim()?.toLongOrNull()?.coerceIn(1L, 3600L)

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
        /** The queue was not drained: the run hit its budget or gave up early. */
        val hasMoreWork: Boolean = false,
    )

    /**
     * One call's verdict inside a batch response.
     *
     * `successful` and `duplicates` both land in [SyncCoordinator] as accepted:
     * a duplicate means the server already holds the record, which is what the
     * idempotency key is for (5.3).
     */
    private data class BatchEntry(
        val idempotencyKey: String,
        val callId: String? = null,
        val revision: Int = 1,
        val code: String = "UNKNOWN",
        val message: String? = null,
        val retryable: Boolean = true,
    )

    private fun JSONArray?.toAcceptedEntries(): List<BatchEntry> {
        val arr = this ?: return emptyList()
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val key = o.optString("idempotency_key").takeIf { it.isNotBlank() }
                ?: return@mapNotNull null
            BatchEntry(
                idempotencyKey = key,
                callId = o.optString("call_id").takeIf { it.isNotBlank() }
                    ?: o.optString("existing_call_id").takeIf { it.isNotBlank() }
                    ?: o.optString("id").takeIf { it.isNotBlank() },
                revision = o.optInt("revision", 1),
            )
        }
    }

    private fun JSONArray?.toRejectedEntries(): List<BatchEntry> {
        val arr = this ?: return emptyList()
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val key = o.optString("idempotency_key").takeIf { it.isNotBlank() }
                ?: return@mapNotNull null
            BatchEntry(
                idempotencyKey = key,
                code = o.optJSONObject("error")?.optString("code")
                    ?.takeIf { it.isNotBlank() } ?: "SERVER_ERROR",
                message = describeError(o.toString()),
                retryable = o.optBoolean("retryable", true),
            )
        }
    }

    private data class MetadataUploadResult(
        val isSuccess: Boolean,
        val serverCallId: String? = null,
        val revision: Int = 1,
        val errorCode: String = "UNKNOWN",
        /** `error.message` + `error.details`: WHICH field the server refused. */
        val errorMessage: String? = null,
        val isRetryable: Boolean = true,
        /** From a 429 `Retry-After`; the guide requires it be honoured. */
        val retryAfterSeconds: Long? = null,
        val newToken: String? = null,
        /** Every call the server accepted or already had. */
        val accepted: List<BatchEntry> = emptyList(),
        /** Every call the server refused, with its own reason. */
        val rejected: List<BatchEntry> = emptyList(),
        /**
         * The request produced no per-call verdicts at all -- it never landed,
         * or was refused whole. The batch caller must re-queue everything it
         * sent rather than assume silence means rejection.
         */
        val transportFailed: Boolean = false,
    )

    private data class RecordingUploadResult(
        val isSuccess: Boolean,
        val errorCode: String = "UNKNOWN",
        val isRetryable: Boolean = true,
        val retryAfterSeconds: Long? = null,
        val newToken: String? = null,
    )
}
