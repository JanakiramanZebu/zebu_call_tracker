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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

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
         * Generates a standard RFC 4122 UUID v5 matching Dart's Uuid().v5(Uuid.NAMESPACE_DNS, ...)
         */
        fun generateDeterministicIdempotencyKey(extId: String, dateMillis: Long): String {
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
    }
}
