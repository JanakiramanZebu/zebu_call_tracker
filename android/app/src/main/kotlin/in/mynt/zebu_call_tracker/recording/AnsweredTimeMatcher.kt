package `in`.mynt.zebu_call_tracker.recording

import java.text.ParseException
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.max

/**
 * The second search an administrator's recording request gets before the
 * phone answers "not found".
 *
 * [NativeRecordingMatcher] scores a file by how well its length agrees with
 * the call log's; without a known answer time, a few seconds' disagreement
 * keeps it below its threshold. Seen on the Samsung reference device: a call
 * logged at 75 s produced a 69.9 s recording, named for the moment it was
 * answered, that the scorer left unmatched — and the request for it was
 * answered "not found".
 *
 * This asks a narrower question instead — did a recording start while this
 * call was being answered? Samsung's One UI dialer writes
 * `Call_<name>_<yyMMdd>_<HHmmss>.m4a`, where the time is the moment the call
 * was ANSWERED (typically 10–30 s after the call log's start); other dialers
 * are dated from the file's own MediaStore stamps. A recording counts when it
 * started between the call's start and start + ring time + [ANSWER_SLACK_SECONDS],
 * and its length is close to the call's. The name is never required to match:
 * contacts get renamed.
 *
 * Only for a call the server is asking about. Pure: no Android, testable alone.
 */
object AnsweredTimeMatcher {

    /** Grace after the expected answer, for a dialer slow to open its file. */
    const val ANSWER_SLACK_SECONDS = 60L

    /** Ring time assumed when the answer time is unknown: the matcher's own limit. */
    const val DEFAULT_RING_SECONDS = 180L

    /** A file stamped this far before the call log's start still counts (clock skew). */
    private const val EARLY_SLACK_SECONDS = 5L

    /** Length allowance: max(15 s, 10 %) — a request names one call, so this can be generous. */
    private const val MIN_DURATION_SLACK_SECONDS = 15.0
    private const val DURATION_SLACK_RATIO = 0.10

    /** Where an answer usually lands when the log cannot say: ~20 s of ring. */
    private const val TYPICAL_RING_SECONDS = 20L

    private const val MAX_END_STAMP_LIFETIME_SECONDS = 5L

    /** `_yyMMdd_HHmmss` at the end of the name, before the extension. */
    private val NAME_TIME = Regex("_(\\d{6})_(\\d{6})(?:\\([0-9]+\\))?\\.[A-Za-z0-9]+$")

    /** The window searched, as epoch seconds, for the log line. */
    data class Window(val fromSeconds: Long, val untilSeconds: Long)

    fun window(callStartSeconds: Long, answeredAtSeconds: Long?): Window {
        val ring = answeredAtSeconds?.let { (it - callStartSeconds).coerceAtLeast(0L) }
            ?: DEFAULT_RING_SECONDS
        return Window(callStartSeconds - EARLY_SLACK_SECONDS, callStartSeconds + ring + ANSWER_SLACK_SECONDS)
    }

    /**
     * The recording of the call that started at [callStartSeconds] and talked
     * for [callDurationSeconds], or null. When several qualify, the one that
     * started nearest the answer time (or a typical ring when unknown) wins.
     */
    fun pick(
        callStartSeconds: Long,
        callDurationSeconds: Int,
        answeredAtSeconds: Long?,
        candidates: List<NativeRecordingCandidate>,
        zone: TimeZone = TimeZone.getDefault(),
    ): NativeRecordingCandidate? {
        if (callDurationSeconds <= 0) return null
        val w = window(callStartSeconds, answeredAtSeconds)
        val slack = max(MIN_DURATION_SLACK_SECONDS, callDurationSeconds * DURATION_SLACK_RATIO)
        val expected = answeredAtSeconds ?: (callStartSeconds + TYPICAL_RING_SECONDS)
        return candidates
            .asSequence()
            .filter { it.durationMillis > 0L }
            .filter { abs(it.durationSeconds - callDurationSeconds) <= slack }
            .map { it to startedAtSeconds(it, zone) }
            .filter { (_, start) -> start in w.fromSeconds..w.untilSeconds }
            .minByOrNull { (_, start) -> abs(start - expected) }
            ?.first
    }

    /**
     * When the recording started: the time in its name where the dialer put
     * one, else DATE_ADDED for a file stamped when it was opened, else the
     * close time minus the audio for one stamped at hang-up.
     */
    fun startedAtSeconds(c: NativeRecordingCandidate, zone: TimeZone = TimeZone.getDefault()): Long =
        nameTimeSeconds(c.displayName, zone)
            ?: if (c.lifetimeSeconds > MAX_END_STAMP_LIFETIME_SECONDS) {
                c.dateAddedEpochSeconds
            } else {
                c.endStampedStartEpochSeconds
            }

    /** Epoch seconds of a `_yyMMdd_HHmmss` name, read in the phone's own time zone. */
    fun nameTimeSeconds(displayName: String?, zone: TimeZone = TimeZone.getDefault()): Long? {
        val m = NAME_TIME.find(displayName ?: return null) ?: return null
        val format = SimpleDateFormat("yyMMddHHmmss", Locale.US).apply {
            isLenient = false
            timeZone = zone
        }
        return try {
            format.parse(m.groupValues[1] + m.groupValues[2])?.time?.div(1000L)
        } catch (_: ParseException) {
            null
        }
    }
}
