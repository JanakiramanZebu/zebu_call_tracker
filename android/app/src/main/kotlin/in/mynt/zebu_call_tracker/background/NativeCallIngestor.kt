package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.os.Build
import android.util.Log
import `in`.mynt.zebu_call_tracker.call.CallEnrichment
import `in`.mynt.zebu_call_tracker.call.CallLogReader
import `in`.mynt.zebu_call_tracker.call.CallStateJournal
import `in`.mynt.zebu_call_tracker.call.CallWireFormat
import `in`.mynt.zebu_call_tracker.call.ContactResolver
import `in`.mynt.zebu_call_tracker.permissions.PermissionInspector
import `in`.mynt.zebu_call_tracker.recording.NativeCallForMatching
import `in`.mynt.zebu_call_tracker.recording.NativeMatchSignals
import `in`.mynt.zebu_call_tracker.recording.NativeRecordingCandidate
import `in`.mynt.zebu_call_tracker.recording.NativeRecordingMatcher
import `in`.mynt.zebu_call_tracker.recording.RecordingScanner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max

object NativeCallIngestor {
    private const val TAG = "NativeCallIngestor"
    private const val CALL_LIMIT = 200
    private const val RECORDING_LIMIT = 300

    /**
     * How far back the first run reaches.
     *
     * The server takes one call per request and rejects anything older than its
     * `max_call_age_days` policy (90 at the time of writing). An unbounded
     * backfill therefore queued up to 15,000 rows — most of them too old for
     * the server to accept — ahead of every live call, and the outbox never
     * drained. 30 days is comfortably inside the server's window and is the
     * span anyone actually reviews.
     *
     * Calls older than this are not ingested at all. The call-history screen
     * reads the system call log directly, so they remain visible in the app —
     * they are simply never queued for an upload the server would refuse.
     */
    /**
     * How long after a call ends the app keeps looking for its recording.
     *
     * One constant for both halves of the search. They were 600s for "keep
     * looking" and 300s for "give up", so for five minutes a call was declared
     * `absent` while still being offered to the matcher — and a recording an
     * OEM dialer wrote late could be attached to a call that had already been
     * written off.
     *
     * Ten minutes is generous for a dialer that normally writes its file within
     * seconds of the call-log row, and bounded enough that a call without audio
     * stops being reconsidered on every pass.
     */
    private const val RECORDING_DISCOVERY_WINDOW_SECONDS = 600L

    private const val BACKFILL_DAYS = 30L
    private const val BACKFILL_PAGES = 12

    /**
     * The app's own build number, for the metadata bag.
     *
     * Read from the package manager rather than BuildConfig: `buildConfig` is
     * an opt-in Gradle feature and this module does not enable it, so the
     * generated class is not guaranteed to exist.
     */
    private fun appVersionCode(context: Context): Int? = try {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode.toInt()
        } else {
            @Suppress("DEPRECATION")
            info.versionCode
        }
    } catch (e: Exception) {
        null
    }

    const val STATUS_OK = "ok"
    const val STATUS_BLOCKED = "blocked"
    const val STATUS_FAILED = "failed"

    suspend fun ingest(context: Context, reason: String): Boolean = withContext(Dispatchers.IO) {
        if (!PermissionInspector.isGranted(context, PermissionInspector.CALL_LOG)) {
            IngestStore.recordRun(context, STATUS_BLOCKED, reason)
            return@withContext false
        }

        try {
            val cursorMillis = IngestStore.callCursorMillis(context)

            // A non-zero cursor over an empty outbox is a contradiction, and the
            // cursor is the side that is wrong. The rows live in SQLite and the
            // cursor lives in SharedPreferences, so a database wiped and rebuilt
            // by the corruption repair in `AppDatabase` — or cleared by hand —
            // leaves the cursor still claiming everything is captured. Nothing
            // then re-reads the call log, and the dashboard stays empty
            // permanently, which is exactly the state this recovers from.
            //
            // Treated as a first run, so the backfill horizon applies and the
            // last 30 days are rebuilt from the call log. Safe to repeat: the
            // idempotency key is derived from the call's own timestamp and
            // number, so re-ingesting produces the same rows and the server
            // upserts them rather than duplicating.
            val outboxEmpty = NativeCallOutboxDao.isEmpty(context)
            if (outboxEmpty && cursorMillis != 0L) {
                Log.w(
                    TAG,
                    "[CALL_INGEST] Outbox empty but cursor at $cursorMillis; " +
                        "rebuilding from the call log.",
                )
            }
            val isFirstRun = cursorMillis == 0L || outboxEmpty

            // On the first run, start from the backfill horizon rather than
            // from the beginning of the call log.
            val initialSinceMillis = if (isFirstRun) {
                System.currentTimeMillis() - (BACKFILL_DAYS * 24L * 60L * 60L * 1000L)
            } else {
                cursorMillis
            }

            var beforeMillis = if (isFirstRun) System.currentTimeMillis() else 0L
            var pageCount = 0
            val maxPages = if (isFirstRun) BACKFILL_PAGES else 1
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
                val appBuild = appVersionCode(context)

                // Names for callers the call log has none for. CACHED_NAME is
                // filled in by the dialer at the time of the call, so anyone
                // added to Contacts AFTERWARDS is nameless there forever, and
                // uploaded that way. One batched PhoneLookup per page fixes it;
                // denial of READ_CONTACTS makes it return nothing, which is a
                // valid outcome rather than an error.
                val unnamedNumbers = calls.mapNotNull { c ->
                    val cached = (c["cachedName"] as? String)?.takeIf { it.isNotBlank() }
                    if (cached != null) null else (c["number"] as? String)?.takeIf { it.isNotBlank() }
                }
                val resolvedNames = if (unnamedNumbers.isNotEmpty()) {
                    ContactResolver.resolveBatch(context, unnamedNumbers)
                } else {
                    emptyMap()
                }

                // 1. Recording matching and enrichment for new calls
                val matchesMap = mutableMapOf<Long, Map<String, Any?>>()
                for (call in calls) {
                    val dateMillis = (call["dateMillis"] as? Number)?.toLong() ?: continue
                    val duration = (call["durationSeconds"] as? Number)?.toInt() ?: 0
                    val rawNumber = call["number"] as? String
                    val contactName = (call["cachedName"] as? String)?.takeIf { it.isNotBlank() }
                        ?: rawNumber?.let { resolvedNames[it] }

                    // The direction the row will be stored with, so the answer
                    // time obeys the same rule the wire format does.
                    val direction = CallWireFormat.outcomeFor(
                        rawDirection = (call["type"] as? String) ?: "unknown",
                        durationSeconds = duration,
                    ).direction

                    // A call that never connected has no answer time and no
                    // recording, but its metadata is still worth carrying —
                    // block reason and presentation are most interesting
                    // exactly when a call did not happen.
                    val window = CallStateJournal.windowFor(context, dateMillis, duration)

                    var matched: NativeRecordingCandidate? = null
                    var signals: NativeMatchSignals? = null
                    var confidence: Double? = null
                    var checksum: String? = null
                    var uri: String? = null

                    if (duration > 0) {
                        val matchObj = NativeCallForMatching(
                            startedAtEpochMillis = dateMillis,
                            durationSeconds = duration,
                            phoneNumber = rawNumber,
                            contactName = contactName,
                            // Anchor on the journal's pickup where there is one.
                            // Resolved without a recording first, precisely
                            // because it is what decides WHICH recording.
                            answeredAtEpochMillis = CallEnrichment.resolveTimes(
                                direction = direction,
                                durationSeconds = duration,
                                window = window,
                                recording = null,
                            ).answeredAtMillis,
                        )

                        val result = NativeRecordingMatcher.match(matchObj, candidates)
                        if (result.isMatched && result.candidate != null) {
                            matched = result.candidate
                            signals = result.signals
                            confidence = result.confidence
                            checksum = RecordingScanner.sha256(context, matched.mediaStoreId)
                                ?.get("checksum") as? String
                            uri = RecordingScanner.contentUri(matched.mediaStoreId)
                            Log.i(
                                TAG,
                                "[RECORDING_DISCOVERY] Matched recording ${matched.mediaStoreId} " +
                                    "for call at $dateMillis (anchored=${signals?.isAnchored})",
                            )
                        } else if (result.isAmbiguous) {
                            Log.i(
                                TAG,
                                "[RECORDING_AMBIGUOUS] ${result.rankedCandidates.size} candidates " +
                                    "for call at $dateMillis: ${result.reason}",
                            )
                        }
                    }

                    // Re-resolved WITH the matched recording, which can supply
                    // the answer and end times the journal could not.
                    val times = CallEnrichment.resolveTimes(
                        direction = direction,
                        durationSeconds = duration,
                        window = window,
                        recording = matched,
                    )

                    matchesMap[dateMillis] = mapOf(
                        "mediaStoreId" to matched?.mediaStoreId,
                        "recordingPath" to uri,
                        "checksum" to checksum,
                        "contactName" to contactName,
                        "answeredAtMillis" to times.answeredAtMillis,
                        "endedAtMillis" to times.endedAtMillis,
                        "metadataJson" to CallEnrichment.buildMetadata(
                            row = call,
                            times = times,
                            recording = matched,
                            signals = signals,
                            confidence = confidence,
                            appBuild = appBuild,
                        ),
                    )
                }

                // 2. Insert newly captured calls directly into persistent SQLite outbox
                NativeCallOutboxDao.insertCapturedCalls(context, calls, matchesMap)
                totalCallsIngested += calls.size

                if (!isFirstRun) {
                    // 3. Retroactive matching for existing unlinked calls in SQLite
                    if (candidates.isNotEmpty()) {
                        val unlinkedCalls = NativeCallOutboxDao.getCallsNeedingRecordingMatch(
                            context,
                            maxAgeSeconds = RECORDING_DISCOVERY_WINDOW_SECONDS,
                        )
                        for (unlinked in unlinkedCalls) {
                            val dateMillis = (unlinked["startedAtMillis"] as? Number)?.toLong() ?: continue
                            val duration = (unlinked["durationSeconds"] as? Number)?.toInt() ?: 0
                            val key = unlinked["idempotencyKey"] as? String ?: continue

                            val direction = (unlinked["direction"] as? String) ?: "unknown"
                            // Either already known from the journal at insert
                            // time, or resolvable now that the receiver has had
                            // longer to see the transitions.
                            val knownAnswered =
                                (unlinked["answeredAtMillis"] as? Number)?.toLong()
                            val window =
                                CallStateJournal.windowFor(context, dateMillis, duration)
                            val anchor = knownAnswered ?: CallEnrichment.resolveTimes(
                                direction = direction,
                                durationSeconds = duration,
                                window = window,
                                recording = null,
                            ).answeredAtMillis

                            val matchObj = NativeCallForMatching(
                                startedAtEpochMillis = dateMillis,
                                durationSeconds = duration,
                                phoneNumber = unlinked["phoneNumber"] as? String,
                                contactName = unlinked["contactName"] as? String,
                                answeredAtEpochMillis = anchor,
                            )

                            val result = NativeRecordingMatcher.match(matchObj, candidates)
                            if (result.isMatched && result.candidate != null) {
                                val c = result.candidate
                                val checksumInfo = RecordingScanner.sha256(context, c.mediaStoreId)
                                val checksum = checksumInfo?.get("checksum") as? String
                                val uri = RecordingScanner.contentUri(c.mediaStoreId)

                                val times = CallEnrichment.resolveTimes(
                                    direction = direction,
                                    durationSeconds = duration,
                                    window = window,
                                    recording = c,
                                )

                                NativeCallOutboxDao.updateRecordingMatch(
                                    context = context,
                                    answeredAtMillis = times.answeredAtMillis,
                                    endedAtMillis = times.endedAtMillis,
                                    // The row's existing metadata was built
                                    // before this recording existed, so it
                                    // carries no `recording` object. Rebuilt
                                    // from the merged view rather than patched.
                                    metadataJson = CallEnrichment.remergeRecordingMetadata(
                                        existingJson = unlinked["metadataJson"] as? String,
                                        times = times,
                                        recording = c,
                                        signals = result.signals,
                                        confidence = result.confidence,
                                    ),
                                    idempotencyKey = key,
                                    recordingPath = uri,
                                    mediaStoreId = c.mediaStoreId,
                                    checksum = checksum,
                                )
                                Log.i(TAG, "[RECORDING_DISCOVERY] Retroactively matched recording ${c.mediaStoreId} to existing call $key")
                            }
                        }
                    }

                    // 4. Give up on calls whose discovery window has closed.
                    NativeCallOutboxDao.expireUnmatchedCalls(
                        context,
                        maxAgeSeconds = RECORDING_DISCOVERY_WINDOW_SECONDS,
                    )

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
                Log.i(
                    TAG,
                    "[CALL_INGEST] Backfill complete: $totalCallsIngested calls from the last " +
                        "$BACKFILL_DAYS days across $pageCount pages."
                )
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
