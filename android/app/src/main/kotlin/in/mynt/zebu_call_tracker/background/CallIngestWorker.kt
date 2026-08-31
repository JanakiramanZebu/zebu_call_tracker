package `in`.mynt.zebu_call_tracker.background

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import `in`.mynt.zebu_call_tracker.call.CallLogReader
import `in`.mynt.zebu_call_tracker.permissions.PermissionInspector
import `in`.mynt.zebu_call_tracker.recording.NativeCallForMatching
import `in`.mynt.zebu_call_tracker.recording.NativeRecordingMatcher
import `in`.mynt.zebu_call_tracker.recording.RecordingScanner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max

/**
 * Captures new calls and the recordings that existed alongside them, without
 * the app being open and without a Flutter engine.
 *
 * Runs via [BackgroundScheduler]:
 *  - a call just ended (immediate and delayed runs),
 *  - periodic safety net,
 *  - device rebooted or package replaced.
 *
 * Captures call logs into the native SQLite outbox queue, performs heuristic recording
 * matching, and invokes [SyncCoordinator].
 */
class CallIngestWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun getForegroundInfo(): ForegroundInfo {
        return createForegroundInfo(applicationContext)
    }

    private fun createForegroundInfo(context: Context): ForegroundInfo {
        val channelId = "sync_progress"
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && notificationManager != null) {
            val channel = NotificationChannel(
                channelId,
                "Sync Progress",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows background call processing status."
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Processing calls")
            .setContentText("Capturing recent call records...")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIF_ID, notification)
        }
    }

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val context = applicationContext
        val reason = inputData.getString(KEY_REASON) ?: REASON_UNKNOWN

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

            val recordings = if (RecordingScanner.hasPermission(context)) {
                RecordingScanner.scan(
                    context,
                    sinceEpochSeconds = max(0L, IngestStore.recordingCursorSeconds(context) - 300L),
                    limit = RECORDING_LIMIT,
                )
            } else {
                emptyList()
            }

            val candidates = recordings.mapNotNull { NativeRecordingMatcher.mapToCandidate(it) }

            // 1. Heuristic Recording Matching for new calls
            val matchesMap = mutableMapOf<Long, Map<String, Any?>>()
            for (call in calls) {
                val dateMillis = (call["dateMillis"] as? Number)?.toLong() ?: continue
                val duration = (call["durationSeconds"] as? Number)?.toInt() ?: 0
                if (duration <= 0) continue

                val matchObj = NativeCallForMatching(
                    startedAtEpochMillis = dateMillis,
                    durationSeconds = duration,
                    phoneNumber = call["number"] as? String,
                    contactName = call["cachedName"] as? String,
                )

                val result = NativeRecordingMatcher.match(matchObj, candidates)
                if (result.isMatched && result.candidate != null) {
                    val c = result.candidate
                    val checksumInfo = RecordingScanner.sha256(context, c.mediaStoreId)
                    val checksum = checksumInfo?.get("checksum") as? String
                    val uri = RecordingScanner.contentUri(c.mediaStoreId)

                    matchesMap[dateMillis] = mapOf(
                        "mediaStoreId" to c.mediaStoreId,
                        "recordingPath" to uri,
                        "checksum" to checksum,
                    )
                    Log.i(TAG, "[RECORDING_DISCOVERY] Matched recording ${c.mediaStoreId} for call at $dateMillis (confidence: ${result.confidence})")
                }
            }

            // 2. Insert newly captured calls directly into persistent SQLite outbox
            NativeCallOutboxDao.insertCapturedCalls(context, calls, matchesMap)

            // 3. Retroactive matching for existing unlinked calls in SQLite
            if (candidates.isNotEmpty()) {
                val unlinkedCalls = NativeCallOutboxDao.getCallsNeedingRecordingMatch(context, maxAgeSeconds = 600L)
                for (unlinked in unlinkedCalls) {
                    val dateMillis = (unlinked["startedAtMillis"] as? Number)?.toLong() ?: continue
                    val duration = (unlinked["durationSeconds"] as? Number)?.toInt() ?: 0
                    val key = unlinked["idempotencyKey"] as? String ?: continue

                    val matchObj = NativeCallForMatching(
                        startedAtEpochMillis = dateMillis,
                        durationSeconds = duration,
                        phoneNumber = unlinked["phoneNumber"] as? String,
                        contactName = unlinked["contactName"] as? String,
                    )

                    val result = NativeRecordingMatcher.match(matchObj, candidates)
                    if (result.isMatched && result.candidate != null) {
                        val c = result.candidate
                        val checksumInfo = RecordingScanner.sha256(context, c.mediaStoreId)
                        val checksum = checksumInfo?.get("checksum") as? String
                        val uri = RecordingScanner.contentUri(c.mediaStoreId)

                        NativeCallOutboxDao.updateRecordingMatch(
                            context = context,
                            idempotencyKey = key,
                            recordingPath = uri,
                            mediaStoreId = c.mediaStoreId,
                            checksum = checksum,
                        )
                        Log.i(TAG, "[RECORDING_DISCOVERY] Retroactively matched recording ${c.mediaStoreId} to existing call $key")
                    }
                }
            }

            // 4. Expire unlinked calls that passed the 5-minute discovery window
            NativeCallOutboxDao.expireUnmatchedCalls(context, maxAgeSeconds = 300L)

            // 5. Retain snapshot in IngestStore for Dart recording matcher compatibility
            IngestStore.append(
                context = context,
                calls = calls,
                recordings = recordings,
                capturedAtMillis = System.currentTimeMillis(),
            )
            IngestStore.recordRun(context, STATUS_OK, reason)

            // 6. Trigger native SyncCoordinator directly
            SyncCoordinator.runSync(context, "ingest_$reason")

            Log.i(TAG, "[CALL_INGEST] ingest[$reason]: ${calls.size} calls captured to SQLite outbox, ${recordings.size} recordings scanned, ${matchesMap.size} matched")
            Result.success()
        } catch (e: SecurityException) {
            IngestStore.recordRun(context, STATUS_BLOCKED, reason)
            Result.success()
        } catch (e: Exception) {
            IngestStore.recordRun(context, STATUS_FAILED, reason)
            Log.w(TAG, "ingest[$reason] failed: ${e::class.java.simpleName}: ${e.message}")
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

        private const val NOTIF_ID = 1001
        private const val CALL_LIMIT = 200
        private const val RECORDING_LIMIT = 300
        private const val MAX_ATTEMPTS = 3
    }
}
