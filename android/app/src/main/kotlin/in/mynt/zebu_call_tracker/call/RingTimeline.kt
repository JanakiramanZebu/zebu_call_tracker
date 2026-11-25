package `in`.mynt.zebu_call_tracker.call

import kotlin.math.roundToLong

/**
 * How long a call rang, and when it was answered and ended, from the phone-state
 * edges the device actually saw.
 *
 * The server derives ring time as `(answered_at ?? ended_at) − started_at`, so
 * a missed, rejected or cancelled call with no `ended_at` has no ring time at
 * all. Android's call log stores neither a ring nor an end, which leaves the
 * call-state journal (or, for WhatsApp, the notification listener) as the only
 * witness.
 *
 * The edges, per call:
 *  - incoming: RINGING at T0, then OFFHOOK at T1 (answered) or straight to
 *    IDLE at T2 (missed / rejected);
 *  - outgoing: OFFHOOK at T0 (dialling starts), IDLE at T2. The remote party
 *    answering produces no broadcast for an ordinary app, so the answer is
 *    reconstructed as T2 − DURATION, which is what the call log's DURATION
 *    measures back from the hang-up.
 *
 * **Durations come only from `elapsedRealtime` differences**, and only when
 * every edge involved was recorded during the same boot. Wall-clock time can
 * jump (NITZ, the user, a network time sync) and resets across a reboot;
 * elapsedRealtime does neither within one boot. Wall-clock is used for one
 * thing: turning an edge into the ISO timestamp the server stores.
 *
 * Pure Kotlin, no `android.*`, so the table is covered by JVM unit tests.
 */
object RingTimeline {

    /** Upper bound the server accepts for `ring_duration_seconds`. */
    const val MAX_RING_SECONDS = 3600

    /** `metadata.timing.ring_source` values. */
    object Source {
        const val JOURNAL = "journal"
        const val UNAVAILABLE = "unavailable"
    }

    /**
     * One phone-state edge. [elapsedMillis] and [bootCount] are null on
     * entries written before they were recorded; such an edge can still be
     * located, but never measured against.
     */
    data class Edge(
        val wallMillis: Long,
        val elapsedMillis: Long?,
        val bootCount: Int?,
    )

    /** T0 (ringing or dial start), T1 (incoming pickup), T2 (idle). */
    data class Edges(
        val start: Edge?,
        val answered: Edge?,
        val idle: Edge?,
    )

    data class Result(
        val answeredAtMillis: Long?,
        val endedAtMillis: Long?,
        val ringDurationSeconds: Int?,
        val answeredAtSource: String?,
        val endedAtSource: String?,
        val ringSource: String,
    ) {
        val isAvailable: Boolean get() = ringSource == Source.JOURNAL
    }

    /** Nothing measured: no ring, no end, no answer. Never a guess. */
    val UNAVAILABLE = Result(
        answeredAtMillis = null,
        endedAtMillis = null,
        ringDurationSeconds = null,
        answeredAtSource = null,
        endedAtSource = null,
        ringSource = Source.UNAVAILABLE,
    )

    /**
     * Applies the outcome table to [edges].
     *
     * [direction] is the wire direction (`CallWireFormat.outcomeFor`), so a
     * missed or rejected call arrives here as incoming. [durationSeconds] is
     * the call log's DURATION: connected seconds only.
     */
    fun compute(edges: Edges?, direction: String, durationSeconds: Int): Result {
        if (edges == null) return UNAVAILABLE
        val start = edges.start ?: return UNAVAILABLE
        val idle = edges.idle ?: return UNAVAILABLE
        val duration = durationSeconds.coerceAtLeast(0).toLong()

        return when (direction.trim().lowercase()) {
            CallWireFormat.Direction.INCOMING -> {
                val answered = edges.answered
                if (answered != null && duration == 0L) {
                    // OFFHOOK on a call the call log says never connected. On
                    // call waiting the missed call's ringing ends in OFFHOOK
                    // because the ongoing call is still up, and IDLE only comes
                    // when that call hangs up. So the ring ended at T1, and an
                    // answer time here would be refused by the server
                    // ("a 'missed' call cannot have answered_at set").
                    val ring = elapsedBetween(start, answered) ?: return UNAVAILABLE
                    endedOnly(answered, ring)
                } else if (answered != null) {
                    // Answered: rang from T0 until the pickup at T1.
                    val ring = elapsedBetween(start, answered) ?: return UNAVAILABLE
                    // T2 must still belong to the same boot and follow T1.
                    elapsedBetween(answered, idle) ?: return UNAVAILABLE
                    Result(
                        answeredAtMillis = answered.wallMillis,
                        endedAtMillis = idle.wallMillis,
                        ringDurationSeconds = clampSeconds(ring),
                        answeredAtSource = CallEnrichment.Source.JOURNAL,
                        endedAtSource = CallEnrichment.Source.JOURNAL,
                        ringSource = Source.JOURNAL,
                    )
                } else {
                    // Missed or rejected: rang from T0 until it stopped at T2.
                    val ring = elapsedBetween(start, idle) ?: return UNAVAILABLE
                    endedOnly(idle, ring)
                }
            }

            CallWireFormat.Direction.OUTGOING -> {
                val span = elapsedBetween(start, idle) ?: return UNAVAILABLE
                if (duration > 0) {
                    // Connected: the talk time is the last DURATION seconds
                    // before the hang-up; everything before it was ringing.
                    val ring = (span - duration * 1000L).coerceAtLeast(0L)
                    Result(
                        answeredAtMillis = idle.wallMillis - duration * 1000L,
                        endedAtMillis = idle.wallMillis,
                        ringDurationSeconds = clampSeconds(ring),
                        answeredAtSource = CallEnrichment.Source.DERIVED,
                        endedAtSource = CallEnrichment.Source.JOURNAL,
                        ringSource = Source.JOURNAL,
                    )
                } else {
                    // Not connected (cancelled): dialled and rang until T2.
                    endedOnly(idle, span)
                }
            }

            else -> UNAVAILABLE
        }
    }

    private fun endedOnly(idle: Edge, ringMillis: Long) = Result(
        answeredAtMillis = null,
        endedAtMillis = idle.wallMillis,
        ringDurationSeconds = clampSeconds(ringMillis),
        answeredAtSource = null,
        endedAtSource = CallEnrichment.Source.JOURNAL,
        ringSource = Source.JOURNAL,
    )

    /**
     * `to − from` in elapsed millis, or null when it cannot be trusted: either
     * edge lacks a monotonic reading, the two were recorded in different boots
     * (the phone restarted mid-call), or time ran backwards.
     */
    private fun elapsedBetween(from: Edge, to: Edge): Long? {
        val a = from.elapsedMillis ?: return null
        val b = to.elapsedMillis ?: return null
        val bootA = from.bootCount ?: return null
        val bootB = to.bootCount ?: return null
        if (a < 0 || b < 0 || bootA < 0 || bootB < 0) return null
        if (bootA != bootB) return null
        val delta = b - a
        return if (delta < 0) null else delta
    }

    /** Whole seconds, rounded, within 0..[MAX_RING_SECONDS]. */
    private fun clampSeconds(millis: Long): Int =
        (millis / 1000.0).roundToLong().coerceIn(0L, MAX_RING_SECONDS.toLong()).toInt()
}
