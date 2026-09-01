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

/**
 * Captures new calls and the recordings that existed alongside them, without
 * the app being open and without a Flutter engine.
 *
 * Runs via [BackgroundScheduler]:
 *  - a call just ended (immediate and delayed runs),
 *  - periodic safety net,
 *  - device rebooted or package replaced.
 *
 * Captures call logs into the native SQLite outbox queue, performs heuristic recording
 * matching, and invokes [SyncCoordinator].
 */
class CallIngestWorker(
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
                description = "Shows background call processing status."
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Processing calls")
            .setContentText("Capturing recent call records...")
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
        val context = applicationContext
        val reason = inputData.getString(KEY_REASON) ?: REASON_UNKNOWN

        try {
            val success = NativeCallIngestor.ingest(context, reason)
            if (success) {
                SyncCoordinator.runSync(context, "ingest_$reason")
            }
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "ingest[$reason] failed: ${e::class.java.simpleName}: ${e.message}")
            if (runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.failure()
        }
    }

    companion object {
        private const val TAG = "CallIngestWorker"

        const val KEY_REASON = "reason"
        const val REASON_UNKNOWN = "unknown"

        private const val NOTIF_ID = 1001
        private const val MAX_ATTEMPTS = 3
    }
}
