package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import `in`.mynt.zebu_call_tracker.call.CallLogReader
import `in`.mynt.zebu_call_tracker.permissions.PermissionInspector
import `in`.mynt.zebu_call_tracker.recording.RecordingScanner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Captures new calls and the recordings that existed alongside them, without
 * the app being open and without a Flutter engine.
 *
 * Runs in three situations, all of which funnel through [BackgroundScheduler]:
 *  - a call just ended (the state receiver enqueues an expedited run),
 *  - the periodic safety net fired (a broadcast can be missed; the call log
 *    cannot be),
 *  - the device rebooted or the app was updated.
 *
 * Deliberately does no matching and no upload. It reads two providers, writes
 * one durable snapshot, and stops — which keeps it well inside the execution
 * budget an expedited job gets, and keeps a single implementation of the
 * matching rules over in Dart.
 */
class CallIngestWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val context = applicationContext
        val reason = inputData.getString(KEY_REASON) ?: REASON_UNKNOWN

        // Without the call log there is nothing to capture, and re-running will
        // not change that. Reporting success (not retry) avoids WorkManager
        // backing off a job that would never succeed; the app re-enqueues when
        // the permission is granted.
        if (!PermissionInspector.isGranted(context, PermissionInspector.CALL_LOG)) {
            IngestStore.recordRun(context, STATUS_BLOCKED, reason)
            return@withContext Result.success()
        }

        try {
            val calls = CallLogReader.read(
                context,
                sinceMillis = IngestStore.callCursorMillis(context),
                limit = CALL_LIMIT,
            )

            // Recordings are only readable with the media permission, and its
            // absence is a normal degraded mode rather than a failure: calls are
            // still captured, they simply carry no audio.
            val recordings = if (RecordingScanner.hasPermission(context)) {
                RecordingScanner.scan(
                    context,
                    sinceEpochSeconds = IngestStore.recordingCursorSeconds(context),
                    limit = RECORDING_LIMIT,
                )
            } else {
                emptyList()
            }

            IngestStore.append(
                context = context,
                calls = calls,
                recordings = recordings,
                capturedAtMillis = System.currentTimeMillis(),
            )
            IngestStore.recordRun(context, STATUS_OK, reason)

            // Trigger native auto-sync to upload call outbox immediately
            BackgroundScheduler.enqueueSync(context)

            // Never log a number or a contact name — counts only.
            Log.i(TAG, "ingest[$reason]: ${calls.size} calls, ${recordings.size} recordings")
            Result.success()
        } catch (e: SecurityException) {

            // A permission revoked mid-run. Same reasoning as above: retrying
            // will not get it back.
            IngestStore.recordRun(context, STATUS_BLOCKED, reason)
            Result.success()
        } catch (e: Exception) {
            IngestStore.recordRun(context, STATUS_FAILED, reason)
            Log.w(TAG, "ingest[$reason] failed: ${e::class.java.simpleName}")
            // Provider hiccups (a busy content resolver, a transient database
            // lock) are worth one backed-off retry; a permanent fault stops
            // after WorkManager's own attempt limit.
            if (runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.failure()
        }
    }

    companion object {
        private const val TAG = "CallIngestWorker"

        const val KEY_REASON = "reason"
        const val REASON_UNKNOWN = "unknown"

        const val STATUS_OK = "ok"
        const val STATUS_BLOCKED = "blocked"
        const val STATUS_FAILED = "failed"

        /**
         * One run cannot be unbounded: an expedited job has a short budget, and
         * a phone that has been offline for a month should catch up over a few
         * runs rather than stall on one enormous query.
         */
        private const val CALL_LIMIT = 200
        private const val RECORDING_LIMIT = 300

        private const val MAX_ATTEMPTS = 3
    }
}
