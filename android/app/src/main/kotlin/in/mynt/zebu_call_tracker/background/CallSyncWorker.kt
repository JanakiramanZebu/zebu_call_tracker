package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Autonomous Native WorkManager Worker for Call Outbox Synchronization.
 *
 * Runs natively without requiring a Flutter engine or UI process. Delegates outbox
 * queue processing directly to [SyncCoordinator].
 *
 * The only caller of [SyncCoordinator.runSync]. Every other trigger — a call
 * captured, the network coming back, the app going to the background, "Sync
 * now" — goes through [BackgroundScheduler.enqueueSync] or its sibling held
 * back for a recording, so uploads wait for a connection (any connection:
 * recordings go over mobile data too) and never run twice side by side.
 */
class CallSyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun getForegroundInfo(): ForegroundInfo =
        ProgressNotification.foregroundInfo(
            applicationContext,
            NOTIF_ID,
            "Sending calls…",
            android.R.drawable.stat_sys_upload,
        )

    override suspend fun doWork(): Result {
        val startedAt = System.currentTimeMillis()

        // The held-back sync was armed for work that an immediate sync has
        // often taken by the time it fires — the recording linked, and its own
        // sync sent both halves. Checking first keeps that case to two EXISTS
        // queries instead of a full run and a stats write.
        if (inputData.getBoolean(KEY_ONLY_IF_WORK, false)) {
            val idle = withContext(Dispatchers.IO) {
                !SyncCoordinator.hasWorkToSend(applicationContext)
            }
            if (idle) {
                Log.d(TAG, "CallSyncWorker skipped: nothing left to send.")
                return Result.success()
            }
        }

        // The request that started this run is satisfied by it; only a request
        // made while it runs earns a follow-up.
        SyncCoordinator.consumeFollowUpRequest()

        var outcome = SyncCoordinator.runSync(
            applicationContext,
            "workmanager_job",
            onLongUpload = ::goForegroundForLongUpload,
        )

        // Two unique jobs run this worker — the immediate sync and the one held
        // back for a recording — so the two meeting is routine rather than a
        // corner case. The loser just
        // consumed a follow-up request that was meant for the run in progress:
        // hand it back so that run goes round again, and come back later in
        // case the run is already past the point of looking.
        if (outcome.status == SyncCoordinator.STATUS_ALREADY_RUNNING) {
            SyncCoordinator.requestFollowUp()
            Log.d(TAG, "CallSyncWorker deferred: another sync is running.")
            return Result.retry()
        }

        var passes = 1

        // enqueueSync uses KEEP so it cannot cancel an upload in flight — which
        // also means a trigger arriving mid-run is dropped by WorkManager. A
        // call captured just after the drain's last claim would then sit until
        // the safety net. Draining again here closes that gap, bounded so a
        // stream of triggers cannot keep the worker past its ten minutes.
        while (SyncCoordinator.consumeFollowUpRequest() &&
            !outcome.blocked &&
            outcome.rateLimitedUntilMillis == 0L &&
            !outcome.hasMoreWork &&
            passes < MAX_PASSES &&
            System.currentTimeMillis() - startedAt < FOLLOW_UP_WINDOW_MILLIS
        ) {
            outcome = SyncCoordinator.runSync(
                applicationContext,
                "workmanager_follow_up",
                onLongUpload = ::goForegroundForLongUpload,
            )
            passes++
        }

        Log.i(
            TAG,
            "CallSyncWorker finished: status=${outcome.status} " +
                "uploaded=${outcome.uploadedCount} failed=${outcome.failedCount} " +
                "moreWork=${outcome.hasMoreWork} blocked=${outcome.blocked} passes=$passes"
        )

        return when {
            // Revoked device, dead session, unregistered handset: nothing a
            // retry can fix, and retry() here used to back off and try again
            // for ever. Sign-in and the safety net bring the queue back.
            outcome.blocked -> Result.success()

            // The server's per-minute limit is full. The next run is booked
            // for when its window reopens, not left to WorkManager's backoff.
            outcome.rateLimitedUntilMillis > 0L -> {
                BackgroundScheduler.enqueueSyncAt(applicationContext, outcome.rateLimitedUntilMillis)
                Result.success()
            }

            // Budget exhausted or the run gave up with rows still queued.
            // Retry is the only way back in without cancelling ourselves —
            // the unique name this run holds is its own.
            outcome.hasMoreWork -> Result.retry()

            // Everything else: done, already running elsewhere, no credentials
            // yet, or individual calls failed — each carries its own
            // next_attempt_at, so the queue reschedules itself. Reporting
            // failure here would add a second, competing backoff on top.
            else -> Result.success()
        }
    }

    /**
     * Makes this a long-running worker before a big recording streams.
     *
     * WorkManager stops an ordinary worker at ten minutes, and a 30-60 minute
     * call's recording can take longer than that by itself on a slow mobile
     * link. Stopped mid-stream, the transfer is lost (the server keeps no
     * partial upload) and the next run starts from byte zero into the same
     * wall. A foreground worker has no such limit.
     *
     * Best effort. Android 12+ may refuse a foreground start from the
     * background (holding the overlay permission or a battery-optimisation
     * exemption usually allows it); the upload then goes ahead anyway, with
     * the always-on [CallTrackingService] keeping the process alive.
     */
    private suspend fun goForegroundForLongUpload() {
        try {
            setForeground(
                ProgressNotification.foregroundInfo(
                    applicationContext,
                    NOTIF_ID,
                    "Sending a call recording…",
                    android.R.drawable.stat_sys_upload,
                ),
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Could not run the upload in the foreground: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "CallSyncWorker"

        /**
         * Input flag: skip the run outright when the outbox owes nothing. Set
         * on the delayed request only — an explicit "Sync now"
         * always runs, so its status reflects a real attempt.
         */
        const val KEY_ONLY_IF_WORK = "only_if_work"
        private const val NOTIF_ID = 1002

        private const val MAX_PASSES = 3

        /** Leaves a full run budget inside WorkManager's ten-minute limit. */
        private const val FOLLOW_UP_WINDOW_MILLIS = 60_000L
    }
}
