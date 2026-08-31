package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.util.Log
import `in`.mynt.zebu_call_tracker.call.CallLogReader
import `in`.mynt.zebu_call_tracker.permissions.PermissionInspector
import `in`.mynt.zebu_call_tracker.recording.NativeCallForMatching
import `in`.mynt.zebu_call_tracker.recording.NativeRecordingMatcher
import `in`.mynt.zebu_call_tracker.recording.RecordingScanner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max

object NativeCallIngestor {
    private const val TAG = "NativeCallIngestor"
    private const val CALL_LIMIT = 200
    private const val RECORDING_LIMIT = 300

    const val STATUS_OK = "ok"
    const val STATUS_BLOCKED = "blocked"
    const val STATUS_FAILED = "failed"

    suspend fun ingest(context: Context, reason: String): Boolean = withContext(Dispatchers.IO) {
        if (!PermissionInspector.isGranted(context, PermissionInspector.CALL_LOG)) {
            IngestStore.recordRun(context, STATUS_BLOCKED, reason)
            return@withContext false
        }

        try {
            val initialSinceMillis = IngestStore.callCursorMillis(context)
            val isFirstRun = initialSinceMillis == 0L
            
            var beforeMillis = if (isFirstRun) System.currentTimeMillis() else 0L
            var pageCount = 0
            val maxPages = if (isFirstRun) 30 else 1
            var totalCallsIngested = 0

            while (pageCount < maxPages) {
                pageCount++

                val calls = CallLogReader.read(
                    context,
                    sinceMillis = initialSinceMillis,
                    limit = if (isFirstRun) 500 else CALL_LIMIT,
                    beforeMillis = beforeMillis,
                )

                if (calls.isEmpty()) break

                var minMillis = Long.MAX_VALUE
                var maxMillis = Long.MIN_VALUE
                for (call in calls) {
                    val m = (call["dateMillis"] as? Number)?.toLong() ?: continue
                    if (m < minMillis) minMillis = m
                    if (m > maxMillis) maxMillis = m
                }

                val recordings = if (RecordingScanner.hasPermission(context) && minMillis <= maxMillis) {
                    RecordingScanner.scan(
                        context,
                        sinceEpochSeconds = max(0L, (minMillis / 1000L) - 300L),
                        limit = if (isFirstRun) 1000 else RECORDING_LIMIT,
                        beforeEpochSeconds = (maxMillis / 1000L) + 300L,
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
                        Log.i(TAG, "[RECORDING_DISCOVERY] Matched recording ${c.mediaStoreId} for call at $dateMillis")
                    }
                }

                // 2. Insert newly captured calls directly into persistent SQLite outbox
                NativeCallOutboxDao.insertCapturedCalls(context, calls, matchesMap)
                totalCallsIngested += calls.size

                if (!isFirstRun) {
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
                    break
                }

                // Prepare for next page in historical run
                val oldestInBatch = minMillis
                if (oldestInBatch >= beforeMillis) break
                beforeMillis = oldestInBatch
            }

            if (isFirstRun) {
                // Initialize the cursor to the current time so subsequent runs act as forward-only
                IngestStore.initializeCursors(
                    context = context,
                    callMillis = System.currentTimeMillis(),
                    recordingSeconds = System.currentTimeMillis() / 1000L
                )
                Log.i(TAG, "[CALL_INGEST] Historical initial backfill complete: ingested $totalCallsIngested calls across $pageCount pages.")
            } else if (totalCallsIngested > 0) {
                Log.i(TAG, "[CALL_INGEST] ingest[$reason]: $totalCallsIngested calls captured to SQLite outbox.")
            }

            IngestStore.recordRun(context, STATUS_OK, reason)
            return@withContext true
        } catch (e: SecurityException) {
            IngestStore.recordRun(context, STATUS_BLOCKED, reason)
            return@withContext false
        } catch (e: Exception) {
            IngestStore.recordRun(context, STATUS_FAILED, reason)
            Log.w(TAG, "ingest[$reason] failed: ${e::class.java.simpleName}: ${e.message}")
            return@withContext false
        }
    }
}
