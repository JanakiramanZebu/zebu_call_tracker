package `in`.mynt.zebu_call_tracker.background

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Persistent foreground service to prevent the OS from killing the app process
 * when it is swiped away from the Recent Apps list. This ensures WorkManager
 * and BroadcastReceivers continue to fire reliably.
 */
class CallTrackingService : Service() {

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun onCreate() {
        super.onCreate()
        startForegroundTracking()

        // Periodic background processing independent of WorkManager
        serviceScope.launch {
            while (isActive) {
                try {
                    val ingested = NativeCallIngestor.ingest(applicationContext, "periodic_service")
                    if (ingested) {
                        SyncCoordinator.runSync(applicationContext, "periodic_service")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error in periodic tracking loop: ${e.message}")
                }
                // Sleep for 15 minutes before the next run
                delay(15 * 60 * 1000L)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundTracking()
        
        if (intent?.action == ACTION_TRIGGER_NOW) {
            val reason = intent.getStringExtra(EXTRA_REASON) ?: "manual_trigger"
            Log.i(TAG, "Triggering immediate unthrottled background processing for reason: $reason")
            serviceScope.launch {
                try {
                    val ingested = NativeCallIngestor.ingest(applicationContext, reason)
                    if (ingested) {
                        SyncCoordinator.runSync(applicationContext, reason)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error in immediate tracking loop: ${e.message}")
                }
            }
        }

        // START_STICKY tells the OS to recreate the service after it has enough memory,
        // if it gets killed due to extreme memory pressure.
        return START_STICKY
    }

    private fun startForegroundTracking() {
        val channelId = "call_tracking_service"
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && notificationManager != null) {
            val channel = NotificationChannel(
                channelId,
                "Background Call Tracking",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps the app running in the background to ensure reliable call tracking and syncing."
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

        val notification = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.stat_sys_download) // Reusing existing system icon
            .setContentTitle("Zebu Call Tracker")
            .setContentText("Tracking calls in the background...")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIF_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground service: ${e.message}")
        }
    }

    override fun onBind(intent: Intent?): IBinder? {
        // Not a bound service
        return null
    }

    companion object {
        private const val TAG = "CallTrackingService"
        private const val NOTIF_ID = 1003
        
        const val ACTION_TRIGGER_NOW = "in.mynt.zebu.TRIGGER_NOW"
        const val EXTRA_REASON = "reason"

        fun start(context: Context) {
            val intent = Intent(context, CallTrackingService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "CallTrackingService could not be started: ${e.message}")
            }
        }
        
        fun triggerImmediate(context: Context, reason: String) {
            val intent = Intent(context, CallTrackingService::class.java).apply {
                action = ACTION_TRIGGER_NOW
                putExtra(EXTRA_REASON, reason)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.w(TAG, "CallTrackingService trigger could not be sent: ${e.message}")
            }
        }
    }
}
