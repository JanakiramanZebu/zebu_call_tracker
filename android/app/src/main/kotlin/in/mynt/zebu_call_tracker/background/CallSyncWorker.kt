package `in`.mynt.zebu_call_tracker.background

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import `in`.mynt.zebu_call_tracker.call.CallWireFormat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Autonomous Native WorkManager Worker for Call Outbox Synchronization.
 *
 * Runs natively without requiring a Flutter engine or UI process. Delegates outbox
 * queue processing directly to [SyncCoordinator] for single-threaded 1-by-1 upload.
 */
class CallSyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun getForegroundInfo(): ForegroundInfo {
        return createForegroundInfo(applicationContext)
    }

    private fun createForegroundInfo(context: Context): ForegroundInfo {
        val channelId = "sync_progress"
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && notificationManager != null) {
            val channel = NotificationChannel(
                channelId,
                "Sync Progress",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows live call uploading status."
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Syncing calls")
            .setContentText("Uploading pending call logs and recordings...")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIF_ID, notification)
        }
    }

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        Log.i(TAG, "CallSyncWorker starting background sync run...")
        val outcome = SyncCoordinator.runSync(applicationContext, "workmanager_job")

        Log.i(
            TAG,
            "CallSyncWorker finished: status=${outcome.status} " +
                "uploaded=${outcome.uploadedCount} failed=${outcome.failedCount} " +
                "moreWork=${outcome.hasMoreWork}"
        )

        return@withContext when {
            // Budget exhausted or the run gave up with rows still queued.
            // Retry is the only way back in without cancelling ourselves —
            // WORK_SYNC_NOW is this worker's own unique name.
            outcome.hasMoreWork -> Result.retry()

            // Another run already holds the lock; it will finish the queue.
            outcome.status == "ALREADY_RUNNING" -> Result.success()

            // No credentials yet. Retrying on a backoff would spin until the
            // user signs in; the periodic job and the post-sign-in trigger
            // both cover that case.
            outcome.status == "SKIPPED_NO_AUTH" -> Result.success()

            // Individual calls failed but each carries its own next_attempt_at,
            // so the queue reschedules itself. Reporting failure here would add
            // a second, competing backoff on top of that.
            else -> Result.success()
        }
    }

    companion object {
        private const val TAG = "CallSyncWorker"
        private const val NOTIF_ID = 1002

        /**
         * Retained as the name older call sites use. The implementation moved
         * to [CallWireFormat.Identity], which is the mirror of Dart's
         * `CallWireIdentity` — a call's identity belongs to the wire format,
         * not to one of the several things that can trigger a sync.
         */
        fun generateDeterministicIdempotencyKey(extId: String, dateMillis: Long): String =
            CallWireFormat.Identity.keyFor(extId, dateMillis)
    }
}
