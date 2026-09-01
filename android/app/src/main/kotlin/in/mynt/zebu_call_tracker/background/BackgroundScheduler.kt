package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/**
 * The one place that decides when background ingest runs.
 *
 * WorkManager rather than an AlarmManager or a bare service, for three reasons
 * this app cannot work around:
 *  - Android 12+ throws when a background broadcast starts a foreground
 *    service, which rules out doing the work inline in the call-state receiver.
 *  - Work survives process death, app update and reboot, which a registered
 *    receiver or a live service does not.
 *  - The OEM battery managers on this fleet (Samsung in particular) kill
 *    ad-hoc services aggressively but honour scheduled jobs.
 */
object BackgroundScheduler {

    private const val WORK_IMMEDIATE = "zebu.call-ingest.now"
    private const val WORK_PERIODIC = "zebu.call-ingest.periodic"
    private const val WORK_SYNC_NOW = "zebu.call-sync.now"
    private const val WORK_SYNC_PERIODIC = "zebu.call-sync.periodic"

    const val REASON_CALL_ENDED = "call-ended"
    const val REASON_BOOT = "boot"
    const val REASON_APP_START = "app-start"
    const val REASON_PERIODIC = "periodic"
    const val REASON_MANUAL = "manual"

    /** WorkManager's floor for periodic work; asking for less is silently raised. */
    private const val PERIODIC_INTERVAL_MINUTES = 15L

    fun enqueueNow(context: Context, reason: String) {
        val request = OneTimeWorkRequestBuilder<CallIngestWorker>()
            .setInputData(Data.Builder().putString(CallIngestWorker.KEY_REASON, reason).build())
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(TAG_INGEST)
            .build()

        WorkManager.getInstance(context)
            .enqueueUniqueWork(WORK_IMMEDIATE, ExistingWorkPolicy.REPLACE, request)
    }

    /**
     * Enqueues delayed call ingest pass to handle OEM dialer MediaStore indexing delays.
     */
    fun enqueueDelayedIngest(context: Context, delaySeconds: Long, reason: String) {
        val workName = "zebu.call-ingest.delayed.${delaySeconds}s"
        val request = OneTimeWorkRequestBuilder<CallIngestWorker>()
            .setInputData(Data.Builder().putString(CallIngestWorker.KEY_REASON, reason).build())
            .setInitialDelay(delaySeconds, TimeUnit.SECONDS)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(TAG_INGEST)
            .build()

        WorkManager.getInstance(context)
            .enqueueUniqueWork(workName, ExistingWorkPolicy.REPLACE, request)
    }

    /**
     * Enqueues immediate native call sync with connected network constraint.
     */
    fun enqueueSync(context: Context) {
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(androidx.work.NetworkType.CONNECTED)
            .build()

        val request = OneTimeWorkRequestBuilder<CallSyncWorker>()
            .setConstraints(constraints)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(TAG_SYNC)
            .build()

        WorkManager.getInstance(context)
            .enqueueUniqueWork(WORK_SYNC_NOW, ExistingWorkPolicy.REPLACE, request)
    }

    /**
     * The durable floor under everything else.
     *
     * [CallTrackingService] runs a faster loop while it is alive, but it cannot
     * be relied on to stay alive: a `dataSync` foreground service is capped at
     * six hours per day from Android 15, and the OEM battery managers on this
     * fleet stop such services well before that. An earlier revision cancelled
     * these two jobs and left the service as the only periodic trigger, which
     * meant that once it was killed nothing retried an upload until the user
     * either opened the app or took another call.
     *
     * WorkManager survives process death, app update and reboot, and its jobs
     * are not subject to the foreground-service quota, so this is what makes
     * "keeps uploading with the app swiped away" true rather than aspirational.
     *
     * KEEP, not REPLACE: re-arming on every launch must not reset the interval
     * and push the next run 15 minutes into the future each time the user opens
     * the app.
     */
    fun ensurePeriodic(context: Context) {
        val workManager = WorkManager.getInstance(context)

        // Capture: no network needed — this only reads the call log and
        // MediaStore, and it must run even offline so a recording is snapshotted
        // before the dialer rotates it.
        workManager.enqueueUniquePeriodicWork(
            WORK_PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<CallIngestWorker>(PERIODIC_INTERVAL_MINUTES, TimeUnit.MINUTES)
                .setInputData(Data.Builder().putString(CallIngestWorker.KEY_REASON, REASON_PERIODIC).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 60, TimeUnit.SECONDS)
                .addTag(TAG_INGEST)
                .build(),
        )

        // Drain: pointless without a connection, so let WorkManager hold it
        // until there is one rather than burning a run to discover there isn't.
        workManager.enqueueUniquePeriodicWork(
            WORK_SYNC_PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<CallSyncWorker>(PERIODIC_INTERVAL_MINUTES, TimeUnit.MINUTES)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(androidx.work.NetworkType.CONNECTED)
                        .build(),
                )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 60, TimeUnit.SECONDS)
                .addTag(TAG_SYNC)
                .build(),
        )
    }

    /** Called on sign-out: nothing should be captured for a signed-out handset. */
    fun cancelAll(context: Context) {
        WorkManager.getInstance(context).cancelAllWorkByTag(TAG_INGEST)
        WorkManager.getInstance(context).cancelAllWorkByTag(TAG_SYNC)
    }

    const val TAG_INGEST = "zebu.ingest"
    const val TAG_SYNC = "zebu.sync"
}
