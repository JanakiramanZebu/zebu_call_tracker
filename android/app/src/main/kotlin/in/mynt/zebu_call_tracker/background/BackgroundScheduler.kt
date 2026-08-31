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

    fun ensurePeriodic(context: Context) {
        val request = PeriodicWorkRequestBuilder<CallIngestWorker>(15, TimeUnit.MINUTES)
            .setInputData(
                Data.Builder()
                    .putString(CallIngestWorker.KEY_REASON, REASON_PERIODIC)
                    .build(),
            )
            .setConstraints(
                Constraints.Builder()
                    .setRequiresBatteryNotLow(true)
                    .build(),
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
            .addTag(TAG_INGEST)
            .build()

        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WORK_PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )

        // Periodic background sync when network is available (every 15 minutes)
        val syncConstraints = Constraints.Builder()
            .setRequiredNetworkType(androidx.work.NetworkType.CONNECTED)
            .build()

        val syncRequest = PeriodicWorkRequestBuilder<CallSyncWorker>(15, TimeUnit.MINUTES)
            .setConstraints(syncConstraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
            .addTag(TAG_SYNC)
            .build()

        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WORK_SYNC_PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            syncRequest,
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
