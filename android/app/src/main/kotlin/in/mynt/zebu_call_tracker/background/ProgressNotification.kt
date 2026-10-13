package `in`.mynt.zebu_call_tracker.background

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.ForegroundInfo

/**
 * The `sync_progress` channel and the foreground notification both workers
 * show while WorkManager runs them as expedited work.
 *
 * The channel used to be created in three places — each worker and the Dart
 * notification service — with three different names and descriptions, so
 * whichever ran last decided what the employee saw in Settings. The name and
 * description here must match `notification_service.dart`.
 */
object ProgressNotification {

    const val CHANNEL_ID = "sync_progress"
    private const val CHANNEL_NAME = "Sending progress"
    private const val CHANNEL_DESCRIPTION = "Shows while calls are being sent."

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        // Re-creating an existing channel only updates its name and
        // description, which is what moves an installed handset off the old
        // wording.
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW).apply {
                description = CHANNEL_DESCRIPTION
                setShowBadge(false)
            },
        )
    }

    /** A low-priority, title-only notification for a worker running in the foreground. */
    fun foregroundInfo(context: Context, notificationId: Int, title: String, icon: Int): ForegroundInfo {
        ensureChannel(context)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(icon)
            .setContentTitle(title)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(notificationId, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(notificationId, notification)
        }
    }
}
