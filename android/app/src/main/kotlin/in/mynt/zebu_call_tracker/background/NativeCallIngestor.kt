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
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

object NativeCallIngestor {
    private const val TAG = "NativeCallIngestor"
    private const val CALL_LIMIT = 200
    private const val RECORDING_LIMIT = 300

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
     *
     * Measured from the END of the call (start + ring + duration) by both
     * halves. It used to be measured from the start, which closed the window
     * on any call longer than ten minutes before a dialer that dates its file
     * at hang-up had written it — so exactly the long calls lost their audio.
     */
    private const val RECORDING_DISCOVERY_WINDOW_SECONDS = 600L

    /**
     * The longest ring before pickup, which `duration_seconds` (talk time)
     * leaves out. Same value as the matcher's `MAX_RING_GAP_SECONDS` and the
     * outbox's discovery window.
     */
    private const val RING_ALLOWANCE_SECONDS = 180L

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
    private const val BACKFILL_DAYS = 30L
    private const val BACKFILL_PAGES = 12
    private const val BACKFILL_PAGE_SIZE = 500

    /**
     * Pages an incremental pass may read. The call log is queried newest
     * first, so a single capped page after a long gap (a handset off for a
     * week) captured only the newest [CALL_LIMIT] calls — and the cursor then
     * moved past the rest for good.
     */
    private const val INCREMENTAL_PAGES = 10

    /**
     * How far below the cursor an incremental pass re-reads. The call log
     * dates a row by the call's start but writes it at the call's end, so a
     * row can appear below a cursor a shorter, overlapping call has already
     * moved. Six hours covers any realistic call; already-captured rows are
     * dropped by key before any work is done on them.
     */
    private const val LATE_ROW_OVERLAP_MILLIS = 6L * 60L * 60L * 1000L

    /**
     * Slack either side of a call when looking for its recording: clock skew
     * between the call log and MediaStore, and a media scanner that indexes
     * the file a little after the dialer closes it.
     */
    private const val RECORDING_SKEW_SECONDS = 300L

    /**
     * The app's own build number, for the metadata bag.
     *
     * Read from the package manager rather than BuildConfig: `buildConfig` is
     * an opt-in Gradle feature and this module does not enable it, so the
     * generated class is not guaranteed to exist.
     *
     * Resolved once per process: it cannot change while the process lives (an
     * update kills it), and it used to be a package-manager binder call on
     * every pass, including the many that capture nothing.
     */
    private fun appVersionCode(context: Context): Int? {
        if (appBuildResolved) return appBuild
        val resolved = try {
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
        appBuild = resolved
        appBuildResolved = true
        return resolved
    }

    @Volatile
    private var appBuild: Int? = null

    @Volatile
    private var appBuildResolved = false

    /**
     * Whether a pass could link anything: a captured call is still inside its
     * discovery window without a recording, and the media permission that a
     * link needs is held. One EXISTS on the outbox; no call-log or MediaStore
     * IPC. See [CallIngestWorker] for the runs that ask.
     */
    fun hasCallsAwaitingRecording(context: Context): Boolean =
        RecordingScanner.hasPermission(context) &&
            NativeCallOutboxDao.hasCallsNeedingRecordingMatch(
                context,
                maxAgeSeconds = RECORDING_DISCOVERY_WINDOW_SECONDS,
            )

    const val STATUS_OK = "ok"
    const val STATUS_BLOCKED = "blocked"
    const val STATUS_FAILED = "failed"

    /**
     * Single-flight. Ingest is triggered from many places that routinely
     * overlap — the immediate and delayed call-end passes, the content
     * trigger (which a call ending also fires), the safety net, boot, and the
     * keepalive service where enabled — and two passes side by side
     * read the same rows, scan the same recordings and race to link them.
     */
    private val running = AtomicBoolean(false)

    /** A trigger arrived mid-pass; the running pass owes exactly one more. */
    private val rerunRequested = AtomicBoolean(false)

    /**
     * Captures new calls and links late recordings. Never throws.
     *
     * A call made while a pass is already running does not start a second
     * one: it asks the running pass for one follow-up and returns true, since
     * that follow-up will cover whatever prompted it. Any number of triggers
     * during one pass collapse into that single follow-up.
     *
     * When a pass adds or links anything, it asks for a sync itself; callers
     * do not upload.
     */
    suspend fun ingest(context: Context, reason: String): Boolean =
        withContext(Dispatchers.IO) { ingestSingleFlight(context, reason) }

    private fun ingestSingleFlight(context: Context, reason: String): Boolean {
        var ok = true
        while (true) {
            if (!running.compareAndSet(false, true)) {
                rerunRequested.set(true)
                // The holder may have released between the failed claim and
                // the flag being set, and so never seen it. Claiming again
                // settles it: failure means a holder that has not yet checked
                // the flag (or a new pass that has not started), and either
                // will serve this trigger.
                if (!running.compareAndSet(false, true)) {
                    Log.d(TAG, "ingest[$reason] coalesced into the pass already running.")
                    return true
                }
            }
            try {
                do {
                    rerunRequested.set(false)
                    ok = ingestOnce(context, reason)
                } while (rerunRequested.get())
            } finally {
                running.set(false)
            }
            // A trigger can land between the last check above and the release;
            // it is served by going round again.
            if (!rerunRequested.get()) return ok
        }
    }

    private fun ingestOnce(context: Context, reason: String): Boolean {
        // A signed-out handset captures nothing: there is no employee to
        // attribute a call to. Work left over from before a session ended
        // (the server revoking it, say) lands here and stops.
        if (!IngestStore.hasSession(context)) {
            Log.d(TAG, "ingest[$reason] skipped: no session.")
            return false
        }
        if (!PermissionInspector.isGranted(context, PermissionInspector.CALL_LOG)) {
            IngestStore.recordRun(context, STATUS_BLOCKED, reason)
            return false
        }

        return try {
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

            // Parsed once for the whole pass, not once per call.
            val journal = CallStateJournal.snapshot(context)
            val appBuild = appVersionCode(context)

            val changed = if (cursorMillis == 0L || outboxEmpty) {
                // An empty outbox means any saved resume point describes rows
                // that are gone, so the backfill starts over.
                backfill(context, journal, appBuild, restart = outboxEmpty)
            } else {
                incremental(context, journal, appBuild, cursorMillis, reason)
            }

            requestSyncFor(context, changed)
            IngestStore.recordRun(context, STATUS_OK, reason, capturedCalls = changed.captured)
            true
        } catch (e: SecurityException) {
            IngestStore.recordRun(context, STATUS_BLOCKED, reason)
            false
        } catch (e: Exception) {
            IngestStore.recordRun(context, STATUS_FAILED, reason)
            Log.w(TAG, "ingest[$reason] failed: ${e::class.java.simpleName}: ${e.message}")
            false
        }
    }

    /**
     * [awaitingRecording] counts the captured calls that connected, are recent
     * enough for a recording still to appear, and have none yet. Always a
     * subset of [captured].
     */
    private data class PassResult(val captured: Int, val linked: Int, val awaitingRecording: Int = 0)

    /**
     * Hands a pass's changes to the uploader — now, or after the recording.
     *
     * An answered call's audio typically lands in MediaStore seconds after its
     * call-log row. Sending the metadata at once and the recording on the next
     * sync was two radio wake-ups per call, a minute apart. So when EVERYTHING
     * this pass added is an answered call still waiting for its file, the sync
     * is held [BackgroundScheduler.SYNC_AFTER_RECORDING_DELAY_SECONDS] for the
     * content trigger or the fallback pass to link it, and both go up in one
     * burst.
     *
     * Anything else goes now: a missed, rejected or zero-length call has no
     * recording to wait for, a call matched at insert already has it, and a
     * late link is the recording arriving. Without the media permission no
     * link can happen, so waiting would only delay the metadata. An immediate
     * sync also carries any waiting call's metadata with it — the hold is an
     * optimisation, never a guarantee.
     */
    private fun requestSyncFor(context: Context, changed: PassResult) {
        if (changed.captured == 0 && changed.linked == 0) return
        val onlyAwaitingRecordings = changed.linked == 0 &&
            changed.awaitingRecording == changed.captured &&
            RecordingScanner.hasPermission(context)
        if (onlyAwaitingRecordings) {
            BackgroundScheduler.enqueueSyncAfterRecording(context)
        } else {
            BackgroundScheduler.enqueueSync(context)
        }
    }

    /**
     * The first run: the last [BACKFILL_DAYS] days, newest page first.
     *
     * Resumable. Progress is saved after every page, so a backfill cut short
     * by process death picks up below the last page it finished instead of
     * starting again from today. The cursor is set only when it completes, to
     * the moment it began — calls made while it ran are newer than its first
     * page and are the incremental pass's to read. (It used to be set to the
     * moment it ENDED, which skipped exactly those calls.)
     */
    private fun backfill(
        context: Context,
        journal: List<Pair<String, Long>>,
        appBuild: Int?,
        restart: Boolean,
    ): PassResult {
        if (restart) IngestStore.clearBackfillProgress(context)

        val resumedFrom = IngestStore.backfillStartedAtMillis(context)
        val startedAt = if (resumedFrom > 0L) resumedFrom else System.currentTimeMillis()
        // Never further back than the server will accept: an administrator
        // can set max_call_age_days below this, and every older row queued
        // would only be refused for good.
        val backfillDays = minOf(BACKFILL_DAYS, SyncPolicyStore.load(context).maxCallAgeDays.toLong())
        val sinceMillis = startedAt - (backfillDays * 24L * 60L * 60L * 1000L)
        var beforeMillis = if (resumedFrom > 0L) {
            IngestStore.backfillBeforeMillis(context).takeIf { it > 0L } ?: startedAt
        } else {
            startedAt
        }
        if (resumedFrom > 0L) {
            Log.i(TAG, "[CALL_INGEST] Resuming backfill below $beforeMillis.")
        } else {
            IngestStore.saveBackfillProgress(context, startedAt, beforeMillis)
        }

        var pageCount = 0
        var captured = 0
        while (pageCount < BACKFILL_PAGES) {
            pageCount++
            val calls = CallLogReader.read(
                context,
                sinceMillis = sinceMillis,
                limit = BACKFILL_PAGE_SIZE,
                beforeMillis = beforeMillis,
            )
            if (calls.isEmpty()) break

            captured += capturePage(context, calls, journal, appBuild, recordingLimit = 1000).captured

            val oldestInBatch = oldestMillis(calls) ?: break
            if (oldestInBatch >= beforeMillis) break
            beforeMillis = oldestInBatch
            IngestStore.saveBackfillProgress(context, startedAt, beforeMillis)
        }

        // Exclusive lower bound for the next read, so a call at exactly
        // `startedAt` — excluded by the first page's exclusive upper bound —
        // is still read once.
        IngestStore.finishBackfill(context, cursorMillis = startedAt - 1)
        Log.i(
            TAG,
            "[CALL_INGEST] Backfill complete: $captured new calls from the last " +
                "$BACKFILL_DAYS days across $pageCount pages."
        )
        return PassResult(captured = captured, linked = 0)
    }

    /**
     * Every run after the first: new call-log rows since the cursor, then the
     * recently captured calls still waiting for a recording.
     *
     * The second half runs on every pass, including the ones that find no
     * new rows. That is precisely the case the delayed call-end passes exist
     * for — the row was captured by the immediate pass, and the dialer writes
     * the file seconds later — and it used to be skipped whenever the call log
     * had nothing new, so a late recording was never linked by them.
     */
    private fun incremental(
        context: Context,
        journal: List<Pair<String, Long>>,
        appBuild: Int?,
        cursorMillis: Long,
        reason: String,
    ): PassResult {
        // Read BEFORE this pass inserts anything: a call captured just now has
        // already been offered every recording on disk by capturePage, and
        // offering it the same ones again would only repeat the work.
        val unlinked = NativeCallOutboxDao.getCallsNeedingRecordingMatch(
            context,
            maxAgeSeconds = RECORDING_DISCOVERY_WINDOW_SECONDS,
        )

        var captured = 0
        var awaitingRecording = 0
        var newestCaptured: Long? = null
        var beforeMillis = 0L
        for (page in 1..INCREMENTAL_PAGES) {
            // Reads LATE_ROW_OVERLAP_MILLIS below the cursor. The cursor is a
            // call's DATE — its start — but Android writes the row when the
            // call ENDS. A call that comes in while another is in progress
            // (call waiting) and finishes first moves the cursor past the
            // longer call's start, and the longer call's row, written later,
            // was then never read: the CRM lost precisely the long calls.
            val calls = CallLogReader.read(
                context,
                sinceMillis = (cursorMillis - LATE_ROW_OVERLAP_MILLIS).coerceAtLeast(0L),
                limit = CALL_LIMIT,
                beforeMillis = beforeMillis,
            )
            if (calls.isEmpty()) break

            // The overlap re-reads rows already captured; dropping them here
            // keeps the recording scan and contact lookup to new rows only.
            val fresh = uncaptured(context, calls)
            if (fresh.isNotEmpty()) {
                val pageResult = capturePage(context, fresh, journal, appBuild, recordingLimit = RECORDING_LIMIT)
                captured += pageResult.captured
                awaitingRecording += pageResult.awaitingRecording
            }
            if (page == 1) newestCaptured = newestMillis(calls)

            if (calls.size < CALL_LIMIT) break
            val oldest = oldestMillis(calls) ?: break
            if (beforeMillis != 0L && oldest >= beforeMillis) break
            beforeMillis = oldest
        }
        // Only once every page is in: moving it after the first (newest) page
        // and then dying would leave the older pages behind the cursor.
        newestCaptured?.let { IngestStore.advanceCallCursor(context, it) }

        val linked = if (unlinked.isEmpty()) 0 else linkLateRecordings(context, journal, unlinked)

        // Give up on calls whose discovery window has closed.
        NativeCallOutboxDao.expireUnmatchedCalls(
            context,
            maxAgeSeconds = RECORDING_DISCOVERY_WINDOW_SECONDS,
        )

        if (captured > 0) {
            Log.i(TAG, "[CALL_INGEST] ingest[$reason]: $captured calls captured to SQLite outbox.")
        }
        return PassResult(captured = captured, linked = linked, awaitingRecording = awaitingRecording)
    }

    /**
     * Matches, enriches and inserts one page of call-log rows. Returns how many
     * were new to the outbox, as a [PassResult] with nothing linked.
     */
    private fun capturePage(
        context: Context,
        calls: List<Map<String, Any?>>,
        journal: List<Pair<String, Long>>,
        appBuild: Int?,
        recordingLimit: Int,
    ): PassResult {
        val oldest = oldestMillis(calls)
        // The latest END in the page (start + ring + talk time), not the
        // latest start: a dialer that dates its file at hang-up writes it a
        // whole call-length after the start, so a bound of start + skew missed
        // the recording of any call longer than the skew at insert time. Same
        // span linkLateRecordings scans. The scan only stops a candidate from
        // being hidden; the matcher decides which convention a file follows.
        val latestEndSeconds = latestEndSeconds(calls)
        val recordings = if (oldest != null && latestEndSeconds != null) {
            scanRecordings(
                context,
                sinceEpochSeconds = max(0L, (oldest / 1000L) - RECORDING_SKEW_SECONDS),
                beforeEpochSeconds = latestEndSeconds + RECORDING_SKEW_SECONDS,
                limit = recordingLimit,
            )
        } else {
            emptyList()
        }
        val candidates = recordings.mapNotNull { NativeRecordingMatcher.mapToCandidate(it) }

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
            val window = CallStateJournal.windowFor(journal, dateMillis, duration)

            var matched: NativeRecordingCandidate? = null
            var signals: NativeMatchSignals? = null
            var confidence: Double? = null
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
                    // No checksum here. The coordinator hashes the file at
                    // upload, which it must do anyway for any row without
                    // one — and a digest taken now can be stale by then.
                    // Hashing every matched recording at capture read each
                    // file end to end twice.
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

        val inserted = NativeCallOutboxDao.insertCapturedCalls(context, calls, matchesMap)

        // New rows that connected, have no recording yet, and ended recently
        // enough for one still to appear. A backfilled call from last week
        // has no recording coming, and holding its sync would gain nothing.
        val windowOpenSinceSeconds = System.currentTimeMillis() / 1000L - RECORDING_DISCOVERY_WINDOW_SECONDS
        val awaitingRecording = calls.count { call ->
            val dateMillis = (call["dateMillis"] as? Number)?.toLong() ?: return@count false
            val duration = (call["durationSeconds"] as? Number)?.toLong() ?: 0L
            dateMillis in inserted.insertedDateMillis &&
                duration > 0L &&
                matchesMap[dateMillis]?.get("mediaStoreId") == null &&
                dateMillis / 1000L + duration + RING_ALLOWANCE_SECONDS >= windowOpenSinceSeconds
        }
        return PassResult(captured = inserted.count, linked = 0, awaitingRecording = awaitingRecording)
    }

    /**
     * Offers recordings on disk to captured calls that are still waiting for
     * one. Returns how many it linked.
     */
    private fun linkLateRecordings(
        context: Context,
        journal: List<Pair<String, Long>>,
        unlinked: List<Map<String, Any?>>,
    ): Int {
        // One scan covering every waiting call, from the earliest start to the
        // latest end (start + ring + talk time). Spanning the call's duration
        // as well as its start costs nothing on a short call and keeps a long
        // one in range on a dialer that dates its file at hang-up.
        var fromSeconds = Long.MAX_VALUE
        var untilSeconds = Long.MIN_VALUE
        for (row in unlinked) {
            val start = (row["startedAtMillis"] as? Number)?.toLong() ?: continue
            val duration = (row["durationSeconds"] as? Number)?.toLong() ?: 0L
            fromSeconds = minOf(fromSeconds, start / 1000L)
            untilSeconds = maxOf(untilSeconds, start / 1000L + duration + RING_ALLOWANCE_SECONDS)
        }
        if (fromSeconds > untilSeconds) return 0

        val candidates = scanRecordings(
            context,
            sinceEpochSeconds = max(0L, fromSeconds - RECORDING_SKEW_SECONDS),
            beforeEpochSeconds = untilSeconds + RECORDING_SKEW_SECONDS,
            limit = RECORDING_LIMIT,
        ).mapNotNull { NativeRecordingMatcher.mapToCandidate(it) }
        if (candidates.isEmpty()) return 0

        var linked = 0
        for (row in unlinked) {
            val dateMillis = (row["startedAtMillis"] as? Number)?.toLong() ?: continue
            val duration = (row["durationSeconds"] as? Number)?.toInt() ?: 0
            val key = row["idempotencyKey"] as? String ?: continue

            val direction = (row["direction"] as? String) ?: "unknown"
            // Either already known from the journal at insert
            // time, or resolvable now that the receiver has had
            // longer to see the transitions.
            val knownAnswered = (row["answeredAtMillis"] as? Number)?.toLong()
            val window = CallStateJournal.windowFor(journal, dateMillis, duration)
            val anchor = knownAnswered ?: CallEnrichment.resolveTimes(
                direction = direction,
                durationSeconds = duration,
                window = window,
                recording = null,
            ).answeredAtMillis

            val matchObj = NativeCallForMatching(
                startedAtEpochMillis = dateMillis,
                durationSeconds = duration,
                phoneNumber = row["phoneNumber"] as? String,
                contactName = row["contactName"] as? String,
                answeredAtEpochMillis = anchor,
            )

            val result = NativeRecordingMatcher.match(matchObj, candidates)
            if (result.isMatched && result.candidate != null) {
                val c = result.candidate
                val times = CallEnrichment.resolveTimes(
                    direction = direction,
                    durationSeconds = duration,
                    window = window,
                    recording = c,
                )

                val updated = NativeCallOutboxDao.updateRecordingMatch(
                    context = context,
                    answeredAtMillis = times.answeredAtMillis,
                    endedAtMillis = times.endedAtMillis,
                    // The row's existing metadata was built
                    // before this recording existed, so it
                    // carries no `recording` object. Rebuilt
                    // from the merged view rather than patched.
                    metadataJson = CallEnrichment.remergeRecordingMetadata(
                        existingJson = row["metadataJson"] as? String,
                        times = times,
                        recording = c,
                        signals = result.signals,
                        confidence = result.confidence,
                    ),
                    idempotencyKey = key,
                    recordingPath = RecordingScanner.contentUri(c.mediaStoreId),
                    mediaStoreId = c.mediaStoreId,
                    // Hashed at upload; see capturePage.
                    checksum = null,
                )
                if (updated) linked++
                Log.i(TAG, "[RECORDING_DISCOVERY] Retroactively matched recording ${c.mediaStoreId} to existing call $key")
            }
        }
        return linked
    }

    /**
     * MediaStore listing for a time window, or nothing.
     *
     * A scan that fails — permission withdrawn, a vendor MediaStore rejecting
     * the query — costs this pass its recordings, not its calls. It used to
     * throw out of the whole pass, so the call-log rows already read were
     * never inserted either.
     */
    private fun scanRecordings(
        context: Context,
        sinceEpochSeconds: Long,
        beforeEpochSeconds: Long,
        limit: Int,
    ): List<Map<String, Any?>> {
        if (!RecordingScanner.hasPermission(context)) return emptyList()
        return try {
            RecordingScanner.scan(
                context,
                sinceEpochSeconds = sinceEpochSeconds,
                limit = limit,
                beforeEpochSeconds = beforeEpochSeconds,
            )
        } catch (e: Exception) {
            Log.w(TAG, "[RECORDING_SCAN] failed: ${e::class.java.simpleName}: ${e.message}")
            emptyList()
        }
    }

    /** The rows of [calls] whose idempotency key is not in the outbox yet. */
    private fun uncaptured(context: Context, calls: List<Map<String, Any?>>): List<Map<String, Any?>> {
        val keyed = calls.mapNotNull { c ->
            val dateMillis = (c["dateMillis"] as? Number)?.toLong() ?: return@mapNotNull null
            CallWireFormat.Identity.key(dateMillis, c["number"] as? String) to c
        }
        val existing = NativeCallOutboxDao.existingKeys(context, keyed.map { it.first })
        return keyed.filter { it.first !in existing }.map { it.second }
    }

    private fun oldestMillis(calls: List<Map<String, Any?>>): Long? =
        calls.mapNotNull { (it["dateMillis"] as? Number)?.toLong() }.minOrNull()

    private fun newestMillis(calls: List<Map<String, Any?>>): Long? =
        calls.mapNotNull { (it["dateMillis"] as? Number)?.toLong() }.maxOrNull()

    /** The latest `start + ring + duration` in [calls], in epoch seconds. */
    private fun latestEndSeconds(calls: List<Map<String, Any?>>): Long? =
        calls.mapNotNull { c ->
            val start = (c["dateMillis"] as? Number)?.toLong() ?: return@mapNotNull null
            start / 1000L + RING_ALLOWANCE_SECONDS +
                ((c["durationSeconds"] as? Number)?.toLong() ?: 0L).coerceAtLeast(0L)
        }.maxOrNull()
}
