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
}

/**
 * Call details for native matching.
 */
data class NativeCallForMatching(
    val startedAtEpochMillis: Long,
    val durationSeconds: Int,
    val phoneNumber: String?,
    val contactName: String?,
) {
    val startedAtEpochSeconds: Long = startedAtEpochMillis / 1000L
    val numberTail: String = extractTail(phoneNumber)
    val lowerContactName: String = contactName?.trim()?.lowercase() ?: ""

    private fun extractTail(number: String?): String {
        if (number == null || number.length < 7) return ""
        val digits = number.replace(Regex("[^0-9]"), "")
        return if (digits.length >= 10) digits.substring(digits.length - 10) else digits
    }
}

/**
 * Result of matching a call with recording candidates.
 */
data class NativeRecordingMatchResult(
    val isMatched: Boolean,
    val confidence: Double,
    val candidate: NativeRecordingCandidate?,
    val reason: String,
)

/**
 * Native Kotlin Heuristic Recording Matcher.
 *
 * Implements identical scoring rules as Dart RecordingMatcher so recording association
 * succeeds with 100% parity when Flutter is completely closed.
 */
object NativeRecordingMatcher {

    private const val DURATION_TOLERANCE_SECONDS = 5.0
    private const val MAX_DURATION_DELTA_SECONDS = 15.0
    private const val MAX_RING_GAP_SECONDS = 180L
    private const val MIN_RING_GAP_SECONDS = -15L
    private const val MATCH_THRESHOLD = 0.70
    private const val AMBIGUITY_MARGIN = 0.15
    private const val PLAUSIBILITY_FLOOR = 0.40

    private const val W_DURATION = 0.45
    private const val W_TIMING = 0.35
    private const val W_IDENTITY = 0.20

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

        val scored = mutableListOf<Pair<NativeRecordingCandidate, Double>>()

        for (candidate in candidates) {
            if (candidate.dateAddedEpochSeconds < minTime || candidate.dateAddedEpochSeconds > maxTime) {
                continue
            }

            val score = scoreCandidate(call, candidate) ?: continue
            scored.add(Pair(candidate, score))
        }

        if (scored.isEmpty()) {
            return NativeRecordingMatchResult(false, 0.0, null, "No candidate within duration/timing bounds.")
        }

        scored.sortByDescending { it.second }
        val best = scored.first()
        val runnerUpScore = if (scored.size > 1) scored[1].second else 0.0

        if (best.second < PLAUSIBILITY_FLOOR) {
            return NativeRecordingMatchResult(false, best.second, null, "Best score below plausibility floor.")
        }

        if (best.second < MATCH_THRESHOLD || (best.second - runnerUpScore) < AMBIGUITY_MARGIN) {
            return NativeRecordingMatchResult(
                false,
                best.second,
                best.first,
                if (best.second < MATCH_THRESHOLD) "Best score below match threshold." else "Ambiguous second candidate."
            )
        }

        return NativeRecordingMatchResult(true, best.second, best.first, "Matched successfully.")
    }

    private fun scoreCandidate(
        call: NativeCallForMatching,
        candidate: NativeRecordingCandidate,
    ): Double? {
        if (candidate.durationMillis <= 0) return null

        val durationDelta = abs(candidate.durationSeconds - call.durationSeconds)
        if (durationDelta > MAX_DURATION_DELTA_SECONDS) return null

        val ringGap = candidate.dateAddedEpochSeconds - call.startedAtEpochSeconds
        if (ringGap < MIN_RING_GAP_SECONDS || ringGap > MAX_RING_GAP_SECONDS) return null

        val durationScore = max(0.0, 1.0 - (durationDelta / DURATION_TOLERANCE_SECONDS))

        val timingScore = when {
            ringGap < 0 -> 0.85
            ringGap <= 20 -> 1.0
            else -> max(0.0, 1.0 - ((ringGap - 20.0) / (MAX_RING_GAP_SECONDS - 20.0)))
        }

        val identityMatched = checkIdentityMatch(call, candidate)
        val identityScore = if (identityMatched) 1.0 else 0.5

        return (W_DURATION * durationScore) + (W_TIMING * timingScore) + (W_IDENTITY * identityScore)
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
