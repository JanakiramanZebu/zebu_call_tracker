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
     * How long the dialer held the file open: DATE_ADDED is the moment
     * recording started, DATE_MODIFIED the moment it stopped. For an intact
     * file this reproduces the audio duration, which is why disagreement is
     * evidence the file is truncated or still being written.
     */
    val lifetimeSeconds: Long = dateModifiedEpochSeconds - dateAddedEpochSeconds
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
     * a statement about the same instant: an OEM dialer opens its file when
     * the call connects, so DATE_ADDED and this value describe one event and
     * should agree to within a second or two. Null falls back to the original
     * heuristic scoring.
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
    val ringGapSeconds: Long,
    val anchorDeltaSeconds: Long?,
    val lifetimeDeltaSeconds: Double,
    val identityMatched: Boolean,
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
    private const val MAX_RING_GAP_SECONDS = 180L
    private const val MIN_RING_GAP_SECONDS = -15L
    private const val MATCH_THRESHOLD = 0.70
    private const val AMBIGUITY_MARGIN = 0.15
    private const val PLAUSIBILITY_FLOOR = 0.40

    /**
     * How far DATE_ADDED may sit from a known answer time before the anchor
     * scores zero. Both are whole seconds from different providers, so one
     * second of slack is rounding and two is generous.
     */
    private const val ANCHOR_TOLERANCE_SECONDS = 2.0

    /**
     * Beyond this the candidate is rejected outright when an answer time is
     * known. A dialer does not open its file ten seconds away from the moment
     * the call connected; something that does belongs to a different call.
     */
    private const val MAX_ANCHOR_DELTA_SECONDS = 10L

    /**
     * How far the file's open-to-close lifetime may differ from the audio
     * duration it contains before the file is treated as truncated or still
     * being written.
     */
    private const val MAX_LIFETIME_DELTA_SECONDS = 15.0

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

        val minTime = call.startedAtEpochSeconds + MIN_RING_GAP_SECONDS
        val maxTime = call.startedAtEpochSeconds + MAX_RING_GAP_SECONDS

        val scored = mutableListOf<Triple<NativeRecordingCandidate, Double, NativeMatchSignals>>()

        for (candidate in candidates) {
            if (candidate.dateAddedEpochSeconds < minTime || candidate.dateAddedEpochSeconds > maxTime) {
                continue
            }

            val signals = scoreCandidate(call, candidate) ?: continue
            scored.add(Triple(candidate, weigh(signals), signals))
        }

        if (scored.isEmpty()) {
            // The anchor gate is strict by design, and it assumes the dialer
            // stamps DATE_ADDED when it OPENS the file. That holds on the
            // devices this was derived from, but the convention is the OEM's to
            // choose and some stamp it at close instead — on such a handset
            // every candidate would sit a whole call-length away from the
            // answer instant and be rejected, which is worse than the heuristic
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
                "Recording opened at the moment the call was answered."
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

    private fun scoreCandidate(
        call: NativeCallForMatching,
        candidate: NativeRecordingCandidate,
    ): NativeMatchSignals? {
        if (candidate.durationMillis <= 0) return null

        val durationDelta = abs(candidate.durationSeconds - call.durationSeconds)
        if (durationDelta > MAX_DURATION_DELTA_SECONDS) return null

        val ringGap = candidate.dateAddedEpochSeconds - call.startedAtEpochSeconds
        if (ringGap < MIN_RING_GAP_SECONDS || ringGap > MAX_RING_GAP_SECONDS) return null

        // A file whose open-to-close lifetime does not reproduce its own audio
        // duration is truncated, still being written, or was copied here by
        // something other than the dialer. Any of those makes it the wrong file
        // to attach, and it previously scored like a perfect match.
        val lifetimeDelta = abs(candidate.lifetimeSeconds - candidate.durationSeconds)
        if (candidate.lifetimeSeconds > 0 && lifetimeDelta > MAX_LIFETIME_DELTA_SECONDS) {
            return null
        }

        // Hard anchor gate. When the answer instant is known, a file that did
        // not open at that instant belongs to another call, however well its
        // duration happens to line up.
        val anchorDelta: Long?
        val anchorScore: Double?
        val answeredAtSeconds = call.answeredAtEpochSeconds
        if (answeredAtSeconds != null) {
            val delta = abs(candidate.dateAddedEpochSeconds - answeredAtSeconds)
            if (delta > MAX_ANCHOR_DELTA_SECONDS) return null
            anchorDelta = delta
            anchorScore = max(0.0, 1.0 - (delta / ANCHOR_TOLERANCE_SECONDS))
        } else {
            anchorDelta = null
            anchorScore = null
        }

        val durationScore = max(0.0, 1.0 - (durationDelta / DURATION_TOLERANCE_SECONDS))

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
