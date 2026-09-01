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
import kotlinx.coroutines.cancel
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Keeps the process warm so ingest and upload run at conversation speed rather
 * than at WorkManager's 15-minute floor.
 *
 * An accelerator, NOT the mechanism. A `dataSync` foreground service is capped
 * at six hours per 24 from Android 15, OEM battery managers stop it earlier
 * than that, and Android 12+ forbids starting it from the background — so
 * anything that must survive the app being killed belongs in
 * [BackgroundScheduler.ensurePeriodic], which is what actually guarantees
 * delivery. If this service never starts, the app still syncs; it just syncs
 * on the periodic schedule.
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
                // Faster than WorkManager's floor — the whole point of being
                // here. The periodic jobs remain armed underneath regardless.
                delay(LOOP_INTERVAL_MILLIS)
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

    /**
     * Android 15+ calls this when a `dataSync` service exhausts its six-hour
     * daily budget. Returning without stopping earns a
     * ForegroundServiceDidNotStopInTimeException crash, so stand down cleanly
     * and let the WorkManager schedule carry the load until the quota resets.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.i(TAG, "Foreground service quota exhausted; stopping. Periodic work continues.")
        BackgroundScheduler.ensurePeriodic(applicationContext)
        stopSelf(startId)
    }

    override fun onDestroy() {
        serviceScope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? {
        // Not a bound service
        return null
    }

    companion object {
        private const val TAG = "CallTrackingService"
        private const val NOTIF_ID = 1003
        private const val LOOP_INTERVAL_MILLIS = 15 * 60 * 1000L
        
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
