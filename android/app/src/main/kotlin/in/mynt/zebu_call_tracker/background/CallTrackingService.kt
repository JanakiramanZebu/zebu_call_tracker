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
import androidx.core.app.ServiceCompat
import `in`.mynt.zebu_call_tracker.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * The always-on call-tracking foreground service, ON for every signed-in
 * handset unless the server's sync policy sets `keepalive_service` to false
 * (see [SyncPolicyStore.Policy.keepaliveService]).
 *
 * Why it runs everywhere again: employees rarely open this app, and on Xiaomi,
 * Oppo, Vivo, OnePlus and Honor firmware a closed app stops receiving the
 * "call ended" broadcast and has its scheduled jobs deferred for hours, so
 * calls reached the CRM days late. Those builds leave a process with a
 * foreground service alone, which keeps the receiver, the content-URI
 * triggers and WorkManager all working.
 *
 * It complements the event-driven machinery rather than replacing it: the
 * call-state receiver, content-URI triggers on the call log and MediaStore,
 * and the hourly safety net ([BackgroundScheduler]) still do the capture. The
 * loop here is a 15-minute fallback pass plus the hourly heartbeat.
 *
 * Foreground type: `specialUse` on Android 14+ — `dataSync` is capped at six
 * hours a day from Android 15 and may not be started from BOOT_COMPLETED,
 * neither of which suits a service meant to run all day from boot — and
 * `dataSync` below 14, where it has neither limit.
 *
 * [reconcile] is the one way the app starts or stops it.
 */
class CallTrackingService : Service() {

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    /** When the loop below started its first pass; see [ACTION_TRIGGER_NOW]. */
    private var createdAtMillis = 0L

    override fun onCreate() {
        super.onCreate()
        createdAtMillis = System.currentTimeMillis()
        startForegroundTracking()

        // Capture only. Uploads are not run from here: the ingester enqueues a
        // network-constrained sync whenever a pass adds or links anything, and
        // the safety net covers retries. This loop used to run a full sync
        // every five minutes as well, duplicating that job — and, unlike it,
        // ran with no network at all, failing and re-queueing a batch each
        // time.
        serviceScope.launch {
            while (isActive) {
                // The session can vanish while this is running: the user signs
                // out, or TokenRefresher clears it after the server refuses the
                // refresh token. Carrying on would keep a foreground
                // notification up claiming calls are being tracked and sent,
                // which would no longer be true.
                if (IngestStore.getAuthToken(applicationContext).isNullOrBlank()) {
                    Log.i(TAG, "Session gone; standing down.")
                    standDown()
                    break
                }
                // The server can switch the service off while it runs.
                if (!isEnabled(applicationContext)) {
                    Log.i(TAG, "Tracking service disabled by sync policy; standing down.")
                    standDown()
                    break
                }

                NativeCallIngestor.ingest(applicationContext, "periodic_service")
                // A pass outside WorkManager does not re-arm the content
                // trigger on the way out, so do it here. KEEP: a no-op while
                // it is armed.
                BackgroundScheduler.armContentTrigger(applicationContext)
                // At most hourly however often this loop runs; silent on
                // failure. See NativeHeartbeat.
                NativeHeartbeat.sendIfDue(applicationContext)

                // At least fifteen minutes. The events catch calls and
                // recordings within seconds, so a short loop would only
                // re-read a call log nothing has touched; the server's
                // `recommended_sync_interval_seconds` can stretch it further.
                delay(maxOf(MIN_LOOP_INTERVAL_MILLIS, SyncPolicyStore.load(applicationContext).loopIntervalMillis))
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Before anything else, even when about to stop: a service started
        // with startForegroundService() that never calls startForeground()
        // is an ANR and a crash on Android 8+.
        startForegroundTracking()

        // A START_STICKY restart, or a start that raced a policy change or a
        // sign-out.
        if (!isEnabled(applicationContext) ||
            IngestStore.getAuthToken(applicationContext).isNullOrBlank()
        ) {
            Log.i(TAG, "Tracking service not wanted (policy off or no session); not running.")
            standDown()
            return START_NOT_STICKY
        }

        if (intent?.action == ACTION_TRIGGER_NOW) {
            val reason = intent.getStringExtra(EXTRA_REASON) ?: "manual_trigger"
            // A trigger that is what created the service arrives a moment
            // after onCreate, whose loop is already running its first pass.
            // A second pass straight behind it would find nothing new.
            if (System.currentTimeMillis() - createdAtMillis < FRESH_START_MILLIS) {
                Log.d(TAG, "Trigger [$reason] covered by the startup pass.")
            } else {
                Log.i(TAG, "Triggering immediate capture for reason: $reason")
                serviceScope.launch { NativeCallIngestor.ingest(applicationContext, reason) }
            }
        }

        // START_STICKY tells the OS to recreate the service after it has enough memory,
        // if it gets killed due to extreme memory pressure.
        return START_STICKY
    }

    private fun startForegroundTracking() {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && notificationManager != null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Zebu Echo status",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while Zebu Echo is saving your work calls."
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            // The app's own glyph (a handset), white on transparent as a
            // status-bar icon must be. It used to borrow the system download
            // arrow, which read as "something is downloading" all day.
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle("Echo is on")
            .setContentText("Call details and recordings are sent to Zebu CRM.")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setSilent(true)
            .setShowWhen(false)
            .setOngoing(true)
            .build()

        try {
            ServiceCompat.startForeground(this, NOTIF_ID, notification, foregroundType())
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground service: ${e.message}")
        }
    }

    /**
     * Android 15+ calls this when a time-limited foreground type exhausts its
     * budget. `specialUse` (Android 14+) has no such budget and `dataSync`
     * below 15 has none either, so it is not expected — but a service that
     * returns from it still in the foreground earns a
     * ForegroundServiceDidNotStopInTimeException crash, so it stands down
     * cleanly and leaves the WorkManager schedule to carry the load.
     *
     * stopSelf() with no id, not stopSelf(startId): the id passed here can be
     * an older start than the latest, and stopSelf(oldId) is then a no-op that
     * leaves the service running past its quota — exactly the crash above.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.i(TAG, "Foreground service timed out (type $fgsType); stopping. Scheduled work continues.")
        BackgroundScheduler.ensurePeriodic(applicationContext)
        standDown()
    }

    /** Drops the notification with the foreground state, then stops. */
    private fun standDown() {
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (e: Exception) {
            Log.w(TAG, "stopForeground failed: ${e.message}")
        }
        stopSelf()
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
        private const val CHANNEL_ID = "call_tracking_service"

        /** A trigger this soon after onCreate is the one that started the service. */
        private const val FRESH_START_MILLIS = 5_000L

        /**
         * The loop's floor. Capture is event-driven, so the loop is a
         * fallback and a quarter of an hour is plenty.
         */
        private const val MIN_LOOP_INTERVAL_MILLIS = 15L * 60L * 1000L

        const val ACTION_TRIGGER_NOW = "in.mynt.zebu.TRIGGER_NOW"
        const val EXTRA_REASON = "reason"

        /**
         * The type passed to startForeground; must be one the manifest
         * declares for this service (`dataSync|specialUse`).
         */
        private fun foregroundType(): Int = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            else -> 0
        }

        /**
         * Whether the server's sync policy allows the service. Default TRUE:
         * only an explicit `keepalive_service: false` turns it off.
         */
        fun isEnabled(context: Context): Boolean =
            SyncPolicyStore.load(context).keepaliveService

        /**
         * Brings the service in line with the policy: started when it is
         * enabled (the default) and a session exists, stopped otherwise.
         *
         * The one entry point for `MainActivity`, `BootReceiver`,
         * `startBackgroundTracking` and a policy change. Starting a service
         * that is already running only delivers another onStartCommand, and
         * stopping one that is not running is a no-op.
         */
        fun reconcile(context: Context) {
            if (isEnabled(context)) start(context) else stop(context)
        }

        /**
         * Starts the service, but only for a handset that has a session and a
         * policy that enables it. Private: callers go through [reconcile].
         *
         * A signed-out phone sitting on the sign-in screen used to run a
         * foreground service and show a permanent "tracking calls"
         * notification while tracking nothing -- there is no employee to
         * attribute a call to, and `SyncCoordinator` skips every run with
         * SKIPPED_NO_AUTH.
         *
         * The guards live here rather than at each call site so a future
         * caller cannot reintroduce the problem.
         */
        private fun start(context: Context) {
            if (IngestStore.getAuthToken(context).isNullOrBlank()) {
                Log.d(TAG, "No session; not starting the tracking service.")
                return
            }
            if (!isEnabled(context)) {
                Log.d(TAG, "Tracking service disabled by sync policy; not starting.")
                return
            }
            val intent = Intent(context, CallTrackingService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Android 12+ refuses a foreground start from the background
                // without an exemption. The scheduled work still runs; the
                // next launch, boot or app update starts the service.
                Log.w(TAG, "CallTrackingService could not be started: ${e.message}")
            }
        }

        /**
         * Stands the service down and clears its notification.
         *
         * Nothing called this before it existed, so signing out cancelled the
         * scheduled work and cleared the session but left the service running,
         * with a permanent notification asserting that calls were being tracked
         * and sent to the company. For a signed-out handset both halves of that
         * were false.
         */
        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, CallTrackingService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "CallTrackingService could not be stopped: ${e.message}")
            }
        }

        /**
         * Runs one capture now: through the service when it is enabled (which
         * also starts it), through WorkManager otherwise — stopping any
         * instance left over from before the policy said off.
         */
        fun triggerImmediate(context: Context, reason: String) {
            if (IngestStore.getAuthToken(context).isNullOrBlank()) return
            if (!isEnabled(context)) {
                stop(context)
                BackgroundScheduler.enqueueNow(context, reason)
                return
            }
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
                // Not allowed to start from here (background, no exemption):
                // the capture still happens, through WorkManager.
                Log.w(TAG, "CallTrackingService trigger could not be sent: ${e.message}")
                BackgroundScheduler.enqueueNow(context, reason)
            }
        }
    }
}
