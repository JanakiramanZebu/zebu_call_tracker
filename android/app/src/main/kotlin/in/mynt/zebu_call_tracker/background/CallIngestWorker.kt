package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.provider.CallLog
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import `in`.mynt.zebu_call_tracker.push.PushTokenWorker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Captures new calls and the recordings that existed alongside them, without
 * the app being open and without a Flutter engine.
 *
 * Runs via [BackgroundScheduler]:
 *  - a call just ended (the immediate pass, and one delayed recording pass),
 *  - the call log or the audio MediaStore changed (content-URI trigger),
 *  - the hourly safety net,
 *  - device rebooted or package replaced.
 *
 * Captures call logs into the native SQLite outbox and performs heuristic
 * recording matching. It does NOT upload: when a pass changes the outbox,
 * [NativeCallIngestor] hands off to [BackgroundScheduler.enqueueSync] (or its
 * delayed sibling), whose job waits for a network. Uploading inline here used
 * to run offline too — claiming a batch, failing it, and bumping every row's
 * attempt count for nothing.
 */
class CallIngestWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun getForegroundInfo(): ForegroundInfo =
        ProgressNotification.foregroundInfo(
            applicationContext,
            NOTIF_ID,
            "Checking for new calls",
            android.R.drawable.stat_sys_download,
        )

    /**
     * Always success. [NativeCallIngestor.ingest] records its own failures in
     * the run stats and never throws, and the next trigger (another call, the
     * content trigger, the safety net) is a better retry than WorkManager's
     * backoff — a pass that failed on a revoked permission would fail
     * identically on every retry.
     *
     * The content trigger is re-armed on the way out of EVERY run, skipped or
     * not and whatever started it: JobScheduler fires a content-triggered job
     * once, so a run that forgot would leave capture on the safety net alone.
     */
    override suspend fun doWork(): Result {
        val reason = inputData.getString(KEY_REASON) ?: REASON_UNKNOWN
        val isTriggerRun = reason == BackgroundScheduler.REASON_CONTENT_CHANGE
        try {
            withContext(Dispatchers.IO) { ingestFor(reason, isTriggerRun) }
        } finally {
            BackgroundScheduler.armContentTrigger(applicationContext, fromTriggerRun = isTriggerRun)
        }
        return Result.success()
    }

    private suspend fun ingestFor(reason: String, isTriggerRun: Boolean) {
        if (isRecordingOnlyRun(reason, isTriggerRun) &&
            !NativeCallIngestor.hasCallsAwaitingRecording(applicationContext)
        ) {
            // Nothing captured is waiting for a recording, so a pass could only
            // re-read the call log to find what the immediate pass and the
            // call-log trigger already took. Skipped before any IPC — and
            // before recordRun, so it costs no preferences write either.
            Log.d(TAG, "ingest[$reason] skipped: no call is waiting for a recording.")
            return
        }

        NativeCallIngestor.ingest(applicationContext, reason)

        // The safety net's second half. A pass that changed the outbox has
        // already asked for a sync; this catches what it would not — a row
        // whose backoff has run out, failures due their daily revival —
        // without waking the radio when the answer is "nothing".
        if (reason == BackgroundScheduler.REASON_PERIODIC) {
            if (SyncCoordinator.hasWorkToSend(applicationContext)) {
                BackgroundScheduler.enqueueSync(applicationContext)
            }
            // The admin console's "last seen", kept fresh while nobody opens
            // the app. On any network, at most hourly, silent on failure;
            // offline it simply waits for a later run.
            NativeHeartbeat.sendIfDue(applicationContext)
            // §3.3: "A token the server never receives means the phone can
            // never be woken." Catches an upload that ran out of retries.
            // A preferences read unless the server may be missing it.
            PushTokenWorker.enqueueIfNeeded(applicationContext)
        }
    }

    /**
     * True for a run whose only possible yield is a recording link: the
     * delayed post-call pass, and a content-triggered run that MediaStore
     * started on its own. A trigger that names the call log, or one the system
     * delivered without saying what changed, gets the full pass.
     */
    private fun isRecordingOnlyRun(reason: String, isTriggerRun: Boolean): Boolean {
        if (reason.startsWith(BackgroundScheduler.REASON_RECORDING_PASS_PREFIX)) return true
        if (!isTriggerRun) return false
        val authorities = triggeredContentAuthorities
        return authorities.isNotEmpty() && CallLog.AUTHORITY !in authorities
    }

    companion object {
        private const val TAG = "CallIngestWorker"
        const val KEY_REASON = "reason"
        const val REASON_UNKNOWN = "unknown"

        private const val NOTIF_ID = 1001
    }
}
