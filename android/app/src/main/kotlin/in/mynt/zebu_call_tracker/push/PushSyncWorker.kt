package `in`.mynt.zebu_call_tracker.push

import android.content.Context
import android.util.Log
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
import `in`.mynt.zebu_call_tracker.background.BackgroundScheduler
import `in`.mynt.zebu_call_tracker.background.IngestStore
import `in`.mynt.zebu_call_tracker.background.NativeCallIngestor
import `in`.mynt.zebu_call_tracker.background.NativeCallOutboxDao
import `in`.mynt.zebu_call_tracker.background.NativeHeartbeat
import `in`.mynt.zebu_call_tracker.background.NativeStatusCheckIn
import `in`.mynt.zebu_call_tracker.background.ProgressNotification
import `in`.mynt.zebu_call_tracker.background.SyncCoordinator
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * The sync a server `SYNC_REQUEST` push asks for (Mobile API Guide §3.3), run
 * as the guide's sequence:
 *  1. heartbeat with the current `pending_calls` / `pending_recordings`;
 *  2. `GET /sync/status`, honouring `device_status` and `policy` (including
 *     `keepalive_service`);
 *  3. a capture pass — the push is for a phone whose own triggers were
 *     starved, so the call log may hold calls the outbox has not seen;
 *  4. `POST /sync/calls` and the pending recordings, one at a time, through
 *     the one [SyncCoordinator];
 *  5. a final heartbeat, so the admin console shows the cleared backlog.
 *
 * Enqueued as unique work with KEEP ([enqueue]): a second push while this one
 * runs does nothing, which is what the guide wants.
 */
class PushSyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    /** An expedited job needs this on Android 11 and below. */
    override suspend fun getForegroundInfo(): ForegroundInfo =
        ProgressNotification.foregroundInfo(
            applicationContext,
            NOTIF_ID,
            "Sending calls…",
            android.R.drawable.stat_sys_upload,
        )

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val ctx = applicationContext
        val reason = inputData.getString(KEY_REASON) ?: "unknown"
        if (!IngestStore.hasSession(ctx)) {
            Log.d(TAG, "Push sync ($reason) skipped: signed out.")
            return@withContext Result.success()
        }
        Log.i(TAG, "Push sync started (reason=$reason).")

        // 1.
        val opening = NativeHeartbeat.send(ctx)

        // 2.
        if (NativeStatusCheckIn.run(ctx) == NativeStatusCheckIn.Outcome.DEVICE_BLOCKED) {
            Log.w(TAG, "Push sync stopped: the server will not accept this device.")
            return@withContext Result.success()
        }

        // 3.
        NativeCallIngestor.ingest(ctx, REASON_INGEST)

        // 4.
        val outcome = SyncCoordinator.runSync(ctx, "fcm_push", onLongUpload = ::goForegroundForLongUpload)
        Log.i(
            TAG,
            "Push sync finished: status=${outcome.status} uploaded=${outcome.uploadedCount} " +
                "failed=${outcome.failedCount} moreWork=${outcome.hasMoreWork} blocked=${outcome.blocked}",
        )
        // The regular sync job owns the rest of a long backlog, with its own
        // follow-up and retry handling; this one only answers the push.
        if (outcome.rateLimitedUntilMillis > 0L) {
            BackgroundScheduler.enqueueSyncAt(ctx, outcome.rateLimitedUntilMillis)
        } else if (outcome.hasMoreWork || outcome.status == SyncCoordinator.STATUS_ALREADY_RUNNING) {
            BackgroundScheduler.enqueueSync(ctx)
        }

        // 5. Only when the numbers moved: if the server already has the
        // current counts, a second heartbeat would say nothing new. The wait
        // keeps the two inside the server's once-a-minute rule.
        val counts = NativeCallOutboxDao.heartbeatCounts(ctx)
        val changed = counts == null || opening == null ||
            counts.first != opening.pendingCalls || counts.second != opening.pendingRecordings
        if (changed) {
            delay(NativeHeartbeat.millisUntilAllowed(ctx))
            NativeHeartbeat.send(ctx)
        }

        Result.success()
    }

    /**
     * Lifts WorkManager's ten-minute limit before a long recording streams;
     * see `CallSyncWorker.goForegroundForLongUpload`. Best effort.
     */
    private suspend fun goForegroundForLongUpload() {
        try {
            setForeground(
                ProgressNotification.foregroundInfo(
                    applicationContext,
                    NOTIF_ID,
                    "Sending a call recording…",
                    android.R.drawable.stat_sys_upload,
                ),
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Could not run the upload in the foreground: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "PushSyncWorker"
        private const val WORK_NAME = "zebu.push.fcm-sync"
        private const val TAG_PUSH = "fcm-sync"
        private const val KEY_REASON = "reason"
        private const val REASON_INGEST = "fcm_push"
        // 1001-1004 belong to ingest, sync, the tracking service and the
        // coordinator's legacy notification.
        private const val NOTIF_ID = 1005

        /**
         * Hands the push off at once (`onMessageReceived` has about ten
         * seconds, and must never sync inline). Expedited where the quota
         * allows, on any network.
         */
        fun enqueue(context: Context, reason: String) {
            val request = OneTimeWorkRequestBuilder<PushSyncWorker>()
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
                )
                .setInputData(Data.Builder().putString(KEY_REASON, reason).build())
                .addTag(TAG_PUSH)
                .addTag(BackgroundScheduler.TAG_SYNC)
                .build()
            WorkManager.getInstance(context)
                .enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.KEEP, request)
        }
    }
}
