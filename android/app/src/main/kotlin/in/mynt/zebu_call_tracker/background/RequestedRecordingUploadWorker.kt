package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.time.Instant
import java.time.OffsetDateTime
import java.util.concurrent.TimeUnit

/**
 * Answers an administrator's "Request from phone" for one call's recording.
 *
 * The request arrives two ways, and both land here under one unique work name
 * per call ([enqueue]), so a repeated push or a request still listed in
 * `GET /sync/status` never runs twice side by side:
 *  - an FCM `UPLOAD_RECORDING` push (`CallTrackMessagingService`);
 *  - a `pending_recording_uploads` item with `requested: true`
 *    ([NativeStatusCheckIn]), which repeats until the request is resolved,
 *    so a phone that missed the push still gets it.
 *
 * The worker finds the call and its recording and decides; the upload itself
 * is [SyncCoordinator.uploadRequestedRecording], under the coordinator's run
 * lock, because the coordinator is the only uploader (docs/sync-architecture.md).
 * When there is nothing to send, or the file is refused for good, the worker
 * says so through `POST /calls/{id}/recording-request/response` so the
 * administrator sees why.
 *
 * Logs carry the call id, request id and outcome only: no phone numbers, no
 * file names.
 */
class RequestedRecordingUploadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    /** An expedited job needs this on Android 11 and below. */
    override suspend fun getForegroundInfo(): ForegroundInfo =
        ProgressNotification.foregroundInfo(
            applicationContext,
            NOTIF_ID,
            "Sending a requested call recording…",
            android.R.drawable.stat_sys_upload,
        )

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val ctx = applicationContext
        val request = Request.from(inputData) ?: return@withContext Result.success()
        val tag = "call=${request.callId} request=${request.requestId ?: "-"} source=${request.source}"

        // Signed out or never paired: nothing can be sent, and retrying will
        // not change that. The request stays listed on the server.
        if (!IngestStore.hasSession(ctx) || IngestStore.getDeviceUuid(ctx).isNullOrBlank()) {
            Log.i(TAG, "[$tag] no session; stopping.")
            return@withContext Result.failure()
        }
        if (DoneRequests.isDone(ctx, request)) {
            Log.i(TAG, "[$tag] already answered; nothing to do.")
            return@withContext Result.success()
        }

        val call = NativeCallOutboxDao.findCallForRecordingRequest(
            ctx,
            serverCallId = request.callId,
            externalCallId = request.externalCallId,
            startedAtMillis = request.startedAtMillis,
            phoneNumber = request.phoneNumber,
        )
        val find = when {
            call == null -> Find.NO_CALL
            call.externalCallId?.startsWith(NativeCallOutboxDao.EXTERNAL_WHATSAPP_PREFIX) == true ->
                Find.WHATSAPP
            else -> when (NativeCallIngestor.linkRecordingFor(ctx, call)) {
                NativeCallIngestor.RecordingLink.LINKED -> Find.LINKED
                NativeCallIngestor.RecordingLink.DELETED -> Find.DELETED
                NativeCallIngestor.RecordingLink.NO_MATCH -> Find.NO_MATCH
                NativeCallIngestor.RecordingLink.NO_PERMISSION -> Find.NO_PERMISSION
            }
        }

        val upload = if (find == Find.LINKED && call != null) {
            SyncCoordinator.uploadRequestedRecording(
                ctx,
                idempotencyKey = call.idempotencyKey,
                serverCallId = request.callId,
                onLongUpload = ::goForegroundForLongUpload,
            )
        } else {
            null
        }

        val action = RequestedRecordingDecision.decide(find, upload, runAttemptCount)
        Log.i(
            TAG,
            "[$tag] find=$find upload=${upload?.outcome ?: "-"}/${upload?.errorCode ?: "-"} " +
                "attempt=$runAttemptCount -> ${action.javaClass.simpleName}",
        )

        when (action) {
            is Action.Done -> {
                DoneRequests.markDone(ctx, request)
                Result.success()
            }
            is Action.Retry -> Result.retry()
            is Action.Stop -> Result.failure()
            is Action.Respond -> respond(ctx, request, action, tag)
        }
    }

    /**
     * `POST /calls/{id}/recording-request/response`. A 404 means the request
     * is already closed, which is as good as an answer.
     */
    private fun respond(context: Context, request: Request, action: Action.Respond, tag: String): Result {
        val body = JSONObject()
            .put("status", action.status)
            .put("message", action.message.take(MAX_MESSAGE_LENGTH))
        val response = NativeApi.request(
            context, "POST", "/calls/${request.callId}/recording-request/response", body,
        )
        return when {
            response.isSuccess || response.status == 404 -> {
                Log.i(TAG, "[$tag] answered ${action.status} (${response.status}).")
                DoneRequests.markDone(context, request)
                Result.success()
            }
            SyncCoordinator.isFatal(response.errorCode) ||
                response.refreshFailure == TokenRefresher.Failure.INVALID ||
                response.refreshFailure == TokenRefresher.Failure.NO_SESSION -> {
                Log.w(TAG, "[$tag] answer refused (${response.errorCode ?: response.status}); stopping.")
                Result.failure()
            }
            else -> {
                Log.w(TAG, "[$tag] answer not delivered (${response.errorCode ?: response.status}); retrying.")
                Result.retry()
            }
        }
    }

    /**
     * Lifts WorkManager's ten-minute limit before a long recording streams;
     * see `PushSyncWorker.goForegroundForLongUpload`. Best effort.
     */
    private suspend fun goForegroundForLongUpload() {
        try {
            setForeground(getForegroundInfo())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Could not run the upload in the foreground: ${e.message}")
        }
    }

    /** One administrator request, as either source delivers it. */
    data class Request(
        val callId: String,
        val requestId: String?,
        val externalCallId: String?,
        val startedAtMillis: Long?,
        /** Only `/sync/status` sends one; the push carries no personal data. */
        val phoneNumber: String?,
        val source: String,
    ) {
        internal fun toData(): Data = Data.Builder()
            .putString(KEY_CALL_ID, callId)
            .putString(KEY_REQUEST_ID, requestId)
            .putString(KEY_EXTERNAL_CALL_ID, externalCallId)
            .putLong(KEY_STARTED_AT_MILLIS, startedAtMillis ?: -1L)
            .putString(KEY_PHONE_NUMBER, phoneNumber)
            .putString(KEY_SOURCE, source)
            .build()

        companion object {
            internal fun from(data: Data): Request? {
                val callId = data.getString(KEY_CALL_ID)?.takeIf { isValidCallId(it) } ?: return null
                return Request(
                    callId = callId,
                    requestId = data.getString(KEY_REQUEST_ID)?.takeIf { it.isNotBlank() },
                    externalCallId = data.getString(KEY_EXTERNAL_CALL_ID)?.takeIf { it.isNotBlank() },
                    startedAtMillis = data.getLong(KEY_STARTED_AT_MILLIS, -1L).takeIf { it > 0L },
                    phoneNumber = data.getString(KEY_PHONE_NUMBER)?.takeIf { it.isNotBlank() },
                    source = data.getString(KEY_SOURCE) ?: "unknown",
                )
            }

            /**
             * From the server's fields, as strings. `started_at` is ISO-8601;
             * an unreadable one only costs the time-window fallback.
             */
            fun of(
                callId: String?,
                requestId: String?,
                externalCallId: String?,
                startedAt: String?,
                phoneNumber: String?,
                source: String,
            ): Request? {
                val id = callId?.trim()?.takeIf { isValidCallId(it) } ?: return null
                return Request(
                    callId = id,
                    requestId = requestId?.trim()?.takeIf { it.isNotBlank() && it != "null" },
                    externalCallId = externalCallId?.trim()?.takeIf { it.isNotBlank() && it != "null" },
                    startedAtMillis = parseIsoMillis(startedAt),
                    phoneNumber = phoneNumber?.trim()?.takeIf { it.isNotBlank() && it != "null" },
                    source = source,
                )
            }

            /** `call_…`, and nothing that could change the request path. */
            private fun isValidCallId(id: String): Boolean = CALL_ID_PATTERN.matches(id)

            private fun parseIsoMillis(value: String?): Long? {
                val s = value?.trim()?.takeIf { it.isNotBlank() && it != "null" } ?: return null
                return try {
                    OffsetDateTime.parse(s).toInstant().toEpochMilli()
                } catch (_: Exception) {
                    try {
                        Instant.parse(s).toEpochMilli()
                    } catch (_: Exception) {
                        null
                    }
                }
            }
        }
    }

    /** Where the call and its recording stand on this phone. */
    enum class Find { NO_CALL, WHATSAPP, LINKED, DELETED, NO_MATCH, NO_PERMISSION }

    /** What the worker does next. */
    sealed class Action {
        /** Finished: uploaded, or nothing the server wants any more. */
        object Done : Action()

        /** Transient: WorkManager tries again with backoff. */
        object Retry : Action()

        /** No session or a refused device: stop without retrying. */
        object Stop : Action()

        /** Tell the administrator why there is no recording. */
        data class Respond(val status: String, val message: String) : Action()
    }

    /**
     * The decision table, kept free of Android so it can be tested on its own.
     * Messages are shown to the administrator: short, plain, and never with a
     * number or a name in them.
     */
    object RequestedRecordingDecision {
        const val NOT_FOUND = "not_found"
        const val FAILED = "failed"

        /** Upload attempts before a transient failure is reported as failed. */
        const val MAX_UPLOAD_ATTEMPTS = 5

        fun decide(find: Find, upload: SyncCoordinator.RequestedUpload?, attempt: Int): Action = when (find) {
            Find.NO_CALL -> Action.Respond(NOT_FOUND, "This call is not on the phone")
            // The server never asks for these; if it ever did, there is no
            // WhatsApp audio to send and nothing to say.
            Find.WHATSAPP -> Action.Done
            Find.DELETED -> Action.Respond(NOT_FOUND, "Recording file was deleted")
            Find.NO_MATCH -> Action.Respond(NOT_FOUND, "No recording file for this call")
            Find.NO_PERMISSION ->
                Action.Respond(NOT_FOUND, "App is not allowed to read call recordings on this phone")
            Find.LINKED -> decideUpload(upload, attempt)
        }

        private fun decideUpload(upload: SyncCoordinator.RequestedUpload?, attempt: Int): Action {
            if (upload == null) return Action.Retry
            val code = upload.errorCode
            return when (upload.outcome) {
                SyncCoordinator.RequestedUploadOutcome.UPLOADED -> Action.Done
                SyncCoordinator.RequestedUploadOutcome.CALL_GONE -> Action.Done
                SyncCoordinator.RequestedUploadOutcome.STOPPED -> Action.Stop
                SyncCoordinator.RequestedUploadOutcome.REJECTED -> when (code) {
                    "FILE_NOT_FOUND" -> Action.Respond(NOT_FOUND, "Recording file was deleted")
                    "PAYLOAD_TOO_LARGE" -> Action.Respond(FAILED, "Upload failed: file too large")
                    "UNSUPPORTED_MEDIA_TYPE" -> Action.Respond(FAILED, "Upload failed: unsupported file type")
                    else -> Action.Respond(FAILED, "Upload failed: server rejected the file")
                }
                SyncCoordinator.RequestedUploadOutcome.RETRY -> when {
                    // Waiting on someone else's turn or the server's window is
                    // not the upload failing.
                    code == SyncCoordinator.CODE_SYNC_BUSY || code == "RATE_LIMIT_EXCEEDED" -> Action.Retry
                    attempt + 1 >= MAX_UPLOAD_ATTEMPTS ->
                        Action.Respond(FAILED, "Upload failed after several attempts")
                    else -> Action.Retry
                }
            }
        }
    }

    /**
     * Request ids already answered, so a push that arrives after the upload
     * (FCM may deliver late, or twice) does not send the file again. A new
     * request for the same call has a new id and goes through.
     */
    private object DoneRequests {
        private const val PREFS = "zebu_recording_requests"
        private const val MAX_ENTRIES = 200

        fun isDone(context: Context, request: Request): Boolean {
            val requestId = request.requestId ?: return false
            val stored = prefs(context).getString(request.callId, null) ?: return false
            return stored.substringBefore('|') == requestId
        }

        fun markDone(context: Context, request: Request) {
            val requestId = request.requestId ?: return
            val prefs = prefs(context)
            val editor = prefs.edit().putString(request.callId, "$requestId|${System.currentTimeMillis()}")
            val all = prefs.all
            if (all.size >= MAX_ENTRIES) {
                all.entries
                    .sortedBy { (it.value as? String)?.substringAfter('|')?.toLongOrNull() ?: 0L }
                    .take(all.size - MAX_ENTRIES + 1)
                    .forEach { editor.remove(it.key) }
            }
            editor.apply()
        }

        private fun prefs(context: Context) =
            context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    companion object {
        private const val TAG = "RequestedRecording"
        private const val WORK_NAME_PREFIX = "zebu.recording-request."
        private const val TAG_REQUEST = "recording-request"
        private const val KEY_CALL_ID = "call_id"
        private const val KEY_REQUEST_ID = "request_id"
        private const val KEY_EXTERNAL_CALL_ID = "external_call_id"
        private const val KEY_STARTED_AT_MILLIS = "started_at_millis"
        private const val KEY_PHONE_NUMBER = "phone_number"
        private const val KEY_SOURCE = "source"
        private const val MAX_MESSAGE_LENGTH = 255

        // 1001-1005 belong to ingest, sync, the tracking service, the
        // coordinator's legacy notification and the push sync.
        private const val NOTIF_ID = 1006

        private val CALL_ID_PATTERN = Regex("^call_[A-Za-z0-9]+$")

        /**
         * Queues the request for [Request.callId]. KEEP: while one is queued or
         * running for that call, a repeat (another push, the next check-in) is
         * a no-op. Expedited where the quota allows, on any network.
         */
        fun enqueue(context: Context, request: Request) {
            val work = OneTimeWorkRequestBuilder<RequestedRecordingUploadWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
                )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30L, TimeUnit.SECONDS)
                .setInputData(request.toData())
                .addTag(TAG_REQUEST)
                .addTag(BackgroundScheduler.TAG_SYNC)
                .build()
            WorkManager.getInstance(context)
                .enqueueUniqueWork(WORK_NAME_PREFIX + request.callId, ExistingWorkPolicy.KEEP, work)
            Log.i(TAG, "Queued call=${request.callId} request=${request.requestId ?: "-"} source=${request.source}.")
        }

        /**
         * Queues a `pending_recording_uploads` item when it is an
         * administrator's request (`requested: true`). False for the ordinary
         * "you promised a recording" items, which the caller handles as before.
         */
        fun enqueueIfRequested(context: Context, item: JSONObject, source: String): Boolean {
            if (!item.optBoolean("requested", false)) return false
            Request.of(
                callId = item.optString("call_id"),
                requestId = item.opt("request_id")?.takeIf { it != JSONObject.NULL }?.toString(),
                externalCallId = item.optString("external_call_id"),
                startedAt = item.optString("started_at"),
                phoneNumber = item.optString("phone_number"),
                source = source,
            )?.let { enqueue(context, it) }
            return true
        }
    }
}
