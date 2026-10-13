package `in`.mynt.zebu_call_tracker.recording

import kotlin.math.abs
import kotlin.math.max

/**
 * Native recording candidate representation.
 */
data class NativeRecordingCandidate(
    val mediaStoreId: Long,
    val displayName: String?,
    val relativePath: String?,
    val durationMillis: Long,
    val sizeBytes: Long,
    val dateAddedEpochSeconds: Long,
    val dateModifiedEpochSeconds: Long,
    val mimeType: String?,
    val source: String,
) {
    val durationSeconds: Double = durationMillis / 1000.0
    val normalizedDigits: String = displayName?.replace(Regex("[^0-9]"), "") ?: ""
    val lowerDisplayName: String = displayName?.lowercase() ?: ""

    /**
     * DATE_MODIFIED - DATE_ADDED. What it means depends on the dialer:
     *
     *  - OPEN-stamped (the Samsung reference device): DATE_ADDED is when
     *    recording started and DATE_MODIFIED when it stopped, so an intact
     *    file's lifetime reproduces its audio duration.
     *  - END-stamped (several other OEMs): the row is created when the file is
     *    CLOSED, at hang-up, so both stamps sit at the end of the call and the
     *    lifetime is about zero, or slightly negative when the media scanner
     *    indexed it a moment after the last write.
     */
    val lifetimeSeconds: Long = dateModifiedEpochSeconds - dateAddedEpochSeconds

    /**
     * When recording started, read as an END-stamped file: the close time
     * minus the audio. DATE_MODIFIED is the close (the file's last write)
     * even when the row was indexed later; DATE_ADDED stands in when it is
     * missing.
     */
    val endStampedStartEpochSeconds: Long =
        (if (dateModifiedEpochSeconds > 0L) dateModifiedEpochSeconds else dateAddedEpochSeconds) -
            Math.round(durationSeconds)
}

/**
 * Call details for native matching.
 */
data class NativeCallForMatching(
    val startedAtEpochMillis: Long,
    val durationSeconds: Int,
    val phoneNumber: String?,
    val contactName: String?,
    /**
     * When the call was actually picked up, if the device could say.
     *
     * This is the anchor that turns matching from a duration coincidence into
     * a statement about the same instant: an OEM dialer starts recording when
     * the call connects, so the recording's estimated start and this value
     * describe one event and should agree to within a second or two. Null
     * falls back to the original heuristic scoring.
     */
    val answeredAtEpochMillis: Long? = null,
) {
    val startedAtEpochSeconds: Long = startedAtEpochMillis / 1000L
    val answeredAtEpochSeconds: Long? = answeredAtEpochMillis?.let { it / 1000L }
    val numberTail: String = extractTail(phoneNumber)
    val lowerContactName: String = contactName?.trim()?.lowercase() ?: ""

    private fun extractTail(number: String?): String {
        if (number == null || number.length < 7) return ""
        val digits = number.replace(Regex("[^0-9]"), "")
        return if (digits.length >= 10) digits.substring(digits.length - 10) else digits
    }
}

/**
 * How one candidate scored, kept so a decision can be explained rather than
 * asserted — by the UI when it asks for a review, and by the server's metadata
 * bag when someone disputes an association months later.
 *
 * Mirror of `MatchSignals` in `lib/features/recording/domain/recording_matcher.dart`.
 */
data class NativeMatchSignals(
    val durationScore: Double,
    val timingScore: Double,
    val identityScore: Double,
    val anchorScore: Double?,
    val durationDeltaSeconds: Double,
    /** Estimated recording start − call start. */
    val ringGapSeconds: Long,
    val anchorDeltaSeconds: Long?,
    val lifetimeDeltaSeconds: Double,
    val identityMatched: Boolean,
    /**
     * Which reading of the file's stamps won: true when its start was taken
     * as DATE_MODIFIED minus the audio (stamped at close), false when it was
     * DATE_ADDED (stamped at open).
     */
    val endStamped: Boolean = false,
) {
    /** True when an answer time was known and the file lines up with it. */
    val isAnchored: Boolean get() = anchorScore != null && anchorScore > 0.0
}

/**
 * Result of matching a call with recording candidates.
 */
data class NativeRecordingMatchResult(
    val isMatched: Boolean,
    val confidence: Double,
    val candidate: NativeRecordingCandidate?,
    val reason: String,
    val signals: NativeMatchSignals? = null,
    val runnerUpConfidence: Double = 0.0,
    /**
     * Every candidate that survived the hard gates, best first. The review UI
     * needs more than the winner to offer a choice, and this used to be
     * computed and thrown away.
     */
    val rankedCandidates: List<Pair<NativeRecordingCandidate, Double>> = emptyList(),
) {
    /** Plausible candidates existed but none won clearly. */
    val isAmbiguous: Boolean get() = !isMatched && rankedCandidates.isNotEmpty()
}

/**
 * Native Kotlin Heuristic Recording Matcher.
 *
 * Implements identical scoring rules as Dart RecordingMatcher so recording association
 * succeeds with 100% parity when Flutter is completely closed.
 *
 * **Every constant and weight below is mirrored in
 * `lib/features/recording/domain/recording_matcher.dart`.** Nothing enforces
 * that at build time — the two are different languages reading the same
 * MediaStore — so a change here is only half a change until the Dart file
 * matches it value for value.
 */
object NativeRecordingMatcher {

    private const val DURATION_TOLERANCE_SECONDS = 5.0
    private const val MAX_DURATION_DELTA_SECONDS = 15.0

    /**
     * How far a long call's audio may drift from its call-log duration, as a
     * fraction of that duration. The duration tolerance, its hard gate and
     * the lifetime gate all widen in proportion beyond 750 s (where 2% passes
     * 15 s): max(15 s, 2%) is 72 s on an hour-long call. A fixed 15 s rejected
     * long recordings whose dialer paused or resampled for a few seconds per
     * ten minutes. Cross-matching stays out of reach because the ring-gap gate
     * does not widen, and two long calls cannot both start within it.
     */
    private const val DURATION_DRIFT_RATIO = 0.02

    private const val MAX_RING_GAP_SECONDS = 180L
    private const val MIN_RING_GAP_SECONDS = -15L
    private const val MATCH_THRESHOLD = 0.70
    private const val AMBIGUITY_MARGIN = 0.15
    private const val PLAUSIBILITY_FLOOR = 0.40

    /**
     * How far the recording's estimated start may sit from a known answer
     * time before the anchor scores zero. Both are whole seconds from
     * different providers, so one second of slack is rounding and two is
     * generous.
     */
    private const val ANCHOR_TOLERANCE_SECONDS = 2.0

    /**
     * Beyond this the candidate is rejected outright when an answer time is
     * known. A dialer does not start recording ten seconds away from the
     * moment the call connected; a file that did belongs to a different call.
     */
    private const val MAX_ANCHOR_DELTA_SECONDS = 10L

    /**
     * How far the file's open-to-close lifetime may differ from the audio
     * duration it contains, read as an OPEN-stamped file, before it is treated
     * as truncated or still being written. Widened for long calls like the
     * duration gate (see [DURATION_DRIFT_RATIO]).
     */
    private const val MAX_LIFETIME_DELTA_SECONDS = 15.0

    /**
     * A lifetime at or below this reads as END-stamped: the dialer created the
     * row when it closed the file, so both stamps sit at hang-up.
     */
    private const val MAX_END_STAMP_LIFETIME_SECONDS = 5L

    // Heuristic weights: no answer time available. Duration dominates because
    // it is the signal that held to within ~1s across every observed pair;
    // identity is weakest because a contact rename or a withheld number wipes
    // it out entirely.
    private const val W_DURATION = 0.45
    private const val W_TIMING = 0.35
    private const val W_IDENTITY = 0.20

    // Anchored weights: an answer time IS available. The anchor takes half the
    // weight because it is the only signal that identifies a specific call
    // rather than a plausible one — it is what separates two back-to-back
    // calls of similar length to the same person, which is precisely the case
    // the heuristic path has to declare ambiguous.
    private const val WA_ANCHOR = 0.50
    private const val WA_DURATION = 0.25
    private const val WA_TIMING = 0.10
    private const val WA_IDENTITY = 0.15

    fun match(
        call: NativeCallForMatching,
        candidates: List<NativeRecordingCandidate>,
    ): NativeRecordingMatchResult {
        if (candidates.isEmpty()) {
            return NativeRecordingMatchResult(false, 0.0, null, "No recording candidates found.")
        }

        if (call.durationSeconds <= 0) {
            return NativeRecordingMatchResult(false, 0.0, null, "Call never connected (duration <= 0).")
        }

        val scored = mutableListOf<Triple<NativeRecordingCandidate, Double, NativeMatchSignals>>()

        for (candidate in candidates) {
            val signals = scoreCandidate(call, candidate) ?: continue
            scored.add(Triple(candidate, weigh(signals), signals))
        }

        if (scored.isEmpty()) {
            // The anchor gate is strict by design. Both stamping conventions
            // are read from the file's own lifetime now, but the answer time
            // can still be off on a handset whose journal is wrong, or whose
            // audio drifts from the wall clock over a long call — and then
            // every candidate is rejected, which is worse than the heuristic
            // this replaced.
            //
            // So when the anchor eliminates EVERYTHING, it is treated as
            // evidence about the device rather than about the recordings, and
            // the call is rescored without it. The heuristic path is the floor;
            // anchoring can only improve on it, never lose to it.
            if (call.answeredAtEpochMillis != null) {
                return match(call.copy(answeredAtEpochMillis = null), candidates)
            }
            return NativeRecordingMatchResult(false, 0.0, null, "No candidate within duration/timing bounds.")
        }

        scored.sortByDescending { it.second }
        val best = scored.first()
        val runnerUpScore = if (scored.size > 1) scored[1].second else 0.0
        val ranked = scored.map { it.first to it.second }

        if (best.second < PLAUSIBILITY_FLOOR) {
            return NativeRecordingMatchResult(
                isMatched = false,
                confidence = best.second,
                candidate = null,
                reason = "Best score below plausibility floor.",
                signals = best.third,
                runnerUpConfidence = runnerUpScore,
                rankedCandidates = ranked,
            )
        }

        if (best.second < MATCH_THRESHOLD || (best.second - runnerUpScore) < AMBIGUITY_MARGIN) {
            return NativeRecordingMatchResult(
                isMatched = false,
                confidence = best.second,
                candidate = best.first,
                reason = if (best.second < MATCH_THRESHOLD) {
                    "Best score below match threshold."
                } else {
                    "Ambiguous second candidate."
                },
                signals = best.third,
                runnerUpConfidence = runnerUpScore,
                rankedCandidates = ranked,
            )
        }

        return NativeRecordingMatchResult(
            isMatched = true,
            confidence = best.second,
            candidate = best.first,
            reason = if (best.third.isAnchored) {
                "Recording started at the moment the call was answered."
            } else {
                "Matched successfully."
            },
            signals = best.third,
            runnerUpConfidence = runnerUpScore,
            rankedCandidates = ranked,
        )
    }

    /** Applies whichever weight set the available signals justify. */
    private fun weigh(s: NativeMatchSignals): Double =
        if (s.anchorScore != null) {
            (WA_ANCHOR * s.anchorScore) +
                (WA_DURATION * s.durationScore) +
                (WA_TIMING * s.timingScore) +
                (WA_IDENTITY * s.identityScore)
        } else {
            (W_DURATION * s.durationScore) +
                (W_TIMING * s.timingScore) +
                (W_IDENTITY * s.identityScore)
        }

    /**
     * How much the duration and lifetime allowances widen for this call: 1
     * up to 750 s, then in proportion to its length. See
     * [DURATION_DRIFT_RATIO].
     */
    private fun driftScale(call: NativeCallForMatching): Double =
        max(1.0, call.durationSeconds * DURATION_DRIFT_RATIO / MAX_DURATION_DELTA_SECONDS)

    /**
     * Scores the candidate under each stamping convention its own lifetime
     * allows, and keeps the better reading. Null when neither survives.
     *
     *  - OPEN: the recording started at DATE_ADDED. Only when the lifetime
     *    reproduces the audio duration — the lifetime check, which belongs to
     *    this reading alone — or when there is no DATE_MODIFIED to check.
     *  - END: the recording started at DATE_MODIFIED minus the audio. When
     *    the lifetime is about zero (the row was made at hang-up) or clearly
     *    shorter than the audio (the row was indexed mid-call).
     *
     * A file plausible both ways — a short one, or one with no DATE_MODIFIED
     * — is scored both ways. Its best reading is still ONE candidate, so it
     * cannot make itself ambiguous. A file held open longer than its audio by
     * more than the tolerance fits neither: something touched it after the
     * dialer closed it.
     *
     * A zero lifetime on a long file is NOT also read as open-stamped (the
     * old rule let any lifetime of zero or less through). Its DATE_ADDED is
     * the hang-up, which is exactly where the next call to the same person
     * starts, so that reading turned every quick call-back into a tie.
     *
     * Before this, every rule measured from DATE_ADDED, so on a dialer that
     * stamps at close a call longer than the 180 s ring gate (or, through the
     * lifetime check, longer than about 15 s) could never be matched, anchor
     * or not.
     */
    private fun scoreCandidate(
        call: NativeCallForMatching,
        candidate: NativeRecordingCandidate,
    ): NativeMatchSignals? {
        if (candidate.durationMillis <= 0) return null

        val scale = driftScale(call)
        val durationDelta = abs(candidate.durationSeconds - call.durationSeconds)
        if (durationDelta > MAX_DURATION_DELTA_SECONDS * scale) return null

        val lifetime = candidate.lifetimeSeconds
        val lifetimeTolerance = MAX_LIFETIME_DELTA_SECONDS * scale
        val lifetimeDelta = abs(lifetime - candidate.durationSeconds)

        // A file whose open-to-close lifetime does not reproduce its own audio
        // duration is, read as open-stamped, truncated, still being written,
        // or copied here by something other than the dialer.
        val open = if (candidate.dateModifiedEpochSeconds <= 0L || lifetimeDelta <= lifetimeTolerance) {
            scoreAt(call, candidate, candidate.dateAddedEpochSeconds, false, durationDelta, lifetimeDelta, scale)
        } else {
            null
        }
        val end = if (lifetime <= MAX_END_STAMP_LIFETIME_SECONDS ||
            lifetime < candidate.durationSeconds - lifetimeTolerance
        ) {
            scoreAt(call, candidate, candidate.endStampedStartEpochSeconds, true, durationDelta, lifetimeDelta, scale)
        } else {
            null
        }

        if (open == null || end == null) return open ?: end
        // Ties go to the open reading, the convention the model was built on.
        return if (weigh(end) > weigh(open)) end else open
    }

    /** Scores the candidate as a recording that started at [startedAtSeconds]. */
    private fun scoreAt(
        call: NativeCallForMatching,
        candidate: NativeRecordingCandidate,
        startedAtSeconds: Long,
        endStamped: Boolean,
        durationDelta: Double,
        lifetimeDelta: Double,
        scale: Double,
    ): NativeMatchSignals? {
        val ringGap = startedAtSeconds - call.startedAtEpochSeconds
        if (ringGap < MIN_RING_GAP_SECONDS || ringGap > MAX_RING_GAP_SECONDS) return null

        // Hard anchor gate. When the answer instant is known, a file that did
        // not start recording at that instant belongs to another call, however
        // well its duration happens to line up.
        val anchorDelta: Long?
        val anchorScore: Double?
        val answeredAtSeconds = call.answeredAtEpochSeconds
        if (answeredAtSeconds != null) {
            val delta = abs(startedAtSeconds - answeredAtSeconds)
            if (delta > MAX_ANCHOR_DELTA_SECONDS) return null
            anchorDelta = delta
            anchorScore = max(0.0, 1.0 - (delta / ANCHOR_TOLERANCE_SECONDS))
        } else {
            anchorDelta = null
            anchorScore = null
        }

        val durationScore = max(0.0, 1.0 - (durationDelta / (DURATION_TOLERANCE_SECONDS * scale)))

        val timingScore = when {
            ringGap < 0 -> 0.85
            ringGap <= 20 -> 1.0
            else -> max(0.0, 1.0 - ((ringGap - 20.0) / (MAX_RING_GAP_SECONDS - 20.0)))
        }

        val identityMatched = checkIdentityMatch(call, candidate)

        return NativeMatchSignals(
            durationScore = durationScore,
            timingScore = timingScore,
            // Absence of a filename match is not evidence AGAINST: withheld
            // numbers and unsaved contacts legitimately produce no overlap.
            identityScore = if (identityMatched) 1.0 else 0.5,
            anchorScore = anchorScore,
            durationDeltaSeconds = durationDelta,
            ringGapSeconds = ringGap,
            anchorDeltaSeconds = anchorDelta,
            lifetimeDeltaSeconds = lifetimeDelta,
            identityMatched = identityMatched,
            endStamped = endStamped,
        )
    }

    private fun checkIdentityMatch(
        call: NativeCallForMatching,
        candidate: NativeRecordingCandidate,
    ): Boolean {
        if (candidate.lowerDisplayName.isEmpty()) return false

        if (call.numberTail.isNotEmpty()) {
            if (candidate.normalizedDigits.contains(call.numberTail)) return true
        }

        if (call.lowerContactName.length >= 3) {
            if (candidate.lowerDisplayName.contains(call.lowerContactName)) return true
        }

        return false
    }

    /**
     * Converts a raw map from [RecordingScanner.scan] to a [NativeRecordingCandidate].
     */
    fun mapToCandidate(map: Map<String, Any?>): NativeRecordingCandidate? {
        val id = (map["mediaStoreId"] as? Number)?.toLong() ?: return null
        val durationMillis = (map["durationMillis"] as? Number)?.toLong() ?: 0L
        val sizeBytes = (map["sizeBytes"] as? Number)?.toLong() ?: 0L
        val dateAdded = (map["dateAddedEpochSeconds"] as? Number)?.toLong() ?: 0L
        val dateModified = (map["dateModifiedEpochSeconds"] as? Number)?.toLong() ?: 0L

        return NativeRecordingCandidate(
            mediaStoreId = id,
            displayName = map["displayName"] as? String,
            relativePath = map["relativePath"] as? String,
            durationMillis = durationMillis,
            sizeBytes = sizeBytes,
            dateAddedEpochSeconds = dateAdded,
            dateModifiedEpochSeconds = dateModified,
            mimeType = map["mimeType"] as? String,
            source = (map["source"] as? String) ?: "UNKNOWN",
        )
    }
}
