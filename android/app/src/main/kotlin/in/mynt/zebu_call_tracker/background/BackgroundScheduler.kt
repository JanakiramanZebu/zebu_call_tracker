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

    const val REASON_CALL_ENDED = "call-ended"
    const val REASON_BOOT = "boot"
    const val REASON_APP_START = "app-start"
    const val REASON_PERIODIC = "periodic"
    const val REASON_MANUAL = "manual"

    /**
     * Runs as soon as the system allows.
     *
     * Expedited, because the point of this path is to snapshot the recording
     * listing while the file the dialer just wrote is still there. If the app is
     * out of expedited quota the job silently downgrades to a normal one rather
     * than being dropped — [OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST].
     *
     * [ExistingWorkPolicy.REPLACE]: two calls in quick succession need one
     * capture, not a queue of them, and the newest run reads everything the
     * older one would have.
     */
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
     * The safety net. A PHONE_STATE broadcast can be missed — the process may be
     * force-stopped, the OEM may drop it, the device may be in Doze — but the
     * call log itself never is, so a periodic sweep recovers anything the
     * event-driven path lost.
     *
     * Six hours, not fifteen minutes: the call log is durable, so a slow sweep
     * costs nothing but battery saved. Only [Constraints.Builder.setRequiresBatteryNotLow]
     * is applied — no network constraint, because capture is purely local.
     */
    fun ensurePeriodic(context: Context) {
        val request = PeriodicWorkRequestBuilder<CallIngestWorker>(6, TimeUnit.HOURS)
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
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 5, TimeUnit.MINUTES)
            .addTag(TAG_INGEST)
            .build()

        // KEEP, not UPDATE: replacing the request on every app start would reset
        // its period each time and mean the periodic run never actually fires on
        // a handset that is opened daily.
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            WORK_PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            request,
        )
    }

    /** Called on sign-out: nothing should be captured for a signed-out handset. */
    fun cancelAll(context: Context) {
        WorkManager.getInstance(context).cancelAllWorkByTag(TAG_INGEST)
    }

    const val TAG_INGEST = "zebu.ingest"
}
