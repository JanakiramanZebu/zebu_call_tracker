package `in`.mynt.zebu_call_tracker.call

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RingTimelineTest {

    private val incoming = CallWireFormat.Direction.INCOMING
    private val outgoing = CallWireFormat.Direction.OUTGOING

    /** Wall clock 1 000 000 000 ms and elapsed 50 000 ms are the same instant. */
    private fun edge(offsetMillis: Long, boot: Int? = 7) = RingTimeline.Edge(
        wallMillis = WALL_T0 + offsetMillis,
        elapsedMillis = ELAPSED_T0 + offsetMillis,
        bootCount = boot,
    )

    private fun assertUnavailable(result: RingTimeline.Result) {
        assertFalse(result.isAvailable)
        assertEquals(RingTimeline.Source.UNAVAILABLE, result.ringSource)
        assertNull(result.ringDurationSeconds)
        assertNull(result.endedAtMillis)
        assertNull(result.answeredAtMillis)
    }

    @Test
    fun incomingAnswered_ringsUntilPickup() {
        val edges = RingTimeline.Edges(start = edge(0), answered = edge(12_400), idle = edge(72_400))
        val r = RingTimeline.compute(edges, incoming, durationSeconds = 60)

        assertEquals(WALL_T0 + 12_400, r.answeredAtMillis)
        assertEquals(WALL_T0 + 72_400, r.endedAtMillis)
        assertEquals(12, r.ringDurationSeconds)
        assertEquals(RingTimeline.Source.JOURNAL, r.ringSource)
        assertEquals(CallEnrichment.Source.JOURNAL, r.answeredAtSource)
        assertEquals(CallEnrichment.Source.JOURNAL, r.endedAtSource)
    }

    @Test
    fun incomingMissed_ringsUntilIdle() {
        val edges = RingTimeline.Edges(start = edge(0), answered = null, idle = edge(31_600))
        val r = RingTimeline.compute(edges, incoming, durationSeconds = 0)

        assertNull(r.answeredAtMillis)
        assertEquals(WALL_T0 + 31_600, r.endedAtMillis)
        assertEquals(32, r.ringDurationSeconds)
        assertEquals(RingTimeline.Source.JOURNAL, r.ringSource)
    }

    @Test
    fun incomingRejected_ringsUntilIdle() {
        // A rejected call is ringing -> idle, like a missed one, only shorter.
        val edges = RingTimeline.Edges(start = edge(0), answered = null, idle = edge(4_200))
        val r = RingTimeline.compute(edges, incoming, durationSeconds = 0)

        assertNull(r.answeredAtMillis)
        assertEquals(WALL_T0 + 4_200, r.endedAtMillis)
        assertEquals(4, r.ringDurationSeconds)
    }

    @Test
    fun outgoingConnected_answerIsHangupMinusDuration() {
        // Dialled at T0, hung up 100 s later after 75 s of talk: 25 s ringing.
        val edges = RingTimeline.Edges(start = edge(0), answered = null, idle = edge(100_000))
        val r = RingTimeline.compute(edges, outgoing, durationSeconds = 75)

        assertEquals(WALL_T0 + 25_000, r.answeredAtMillis)
        assertEquals(WALL_T0 + 100_000, r.endedAtMillis)
        assertEquals(25, r.ringDurationSeconds)
        assertEquals(CallEnrichment.Source.DERIVED, r.answeredAtSource)
        assertEquals(CallEnrichment.Source.JOURNAL, r.endedAtSource)
    }

    @Test
    fun outgoingNotConnected_ringsUntilIdle() {
        val edges = RingTimeline.Edges(start = edge(0), answered = null, idle = edge(18_000))
        val r = RingTimeline.compute(edges, outgoing, durationSeconds = 0)

        assertNull(r.answeredAtMillis)
        assertEquals(WALL_T0 + 18_000, r.endedAtMillis)
        assertEquals(18, r.ringDurationSeconds)
    }

    @Test
    fun bootCountMismatch_isUnavailable() {
        // Rebooted mid-call: the idle edge belongs to a later boot.
        val edges = RingTimeline.Edges(start = edge(0, boot = 7), answered = null, idle = edge(20_000, boot = 8))
        assertUnavailable(RingTimeline.compute(edges, incoming, durationSeconds = 0))
    }

    @Test
    fun missingIdle_isUnavailable() {
        val edges = RingTimeline.Edges(start = edge(0), answered = edge(5_000), idle = null)
        assertUnavailable(RingTimeline.compute(edges, incoming, durationSeconds = 30))
    }

    @Test
    fun outgoingNegativeRemainder_isFlooredToZero() {
        // DURATION (40 s) exceeds the measured span (38 s): the ring floors at 0.
        val edges = RingTimeline.Edges(start = edge(0), answered = null, idle = edge(38_000))
        val r = RingTimeline.compute(edges, outgoing, durationSeconds = 40)

        assertEquals(0, r.ringDurationSeconds)
        assertEquals(WALL_T0 + 38_000, r.endedAtMillis)
        assertEquals(WALL_T0 - 2_000, r.answeredAtMillis)
    }

    @Test
    fun ringOverAnHour_isClampedTo3600() {
        val edges = RingTimeline.Edges(start = edge(0), answered = null, idle = edge(4_000_000))
        val r = RingTimeline.compute(edges, incoming, durationSeconds = 0)

        assertEquals(3600, r.ringDurationSeconds)
        assertEquals(WALL_T0 + 4_000_000, r.endedAtMillis)
    }

    @Test
    fun noJournalMatch_isUnavailable() {
        // The fallback: app killed, phone rebooted or permission missing, so
        // nothing in the journal matched the call-log row.
        assertUnavailable(RingTimeline.compute(null, incoming, durationSeconds = 0))
        assertUnavailable(RingTimeline.compute(null, outgoing, durationSeconds = 45))
    }

    @Test
    fun legacyEntriesWithoutMonotonicTime_areUnavailable() {
        val legacy = RingTimeline.Edge(wallMillis = WALL_T0, elapsedMillis = null, bootCount = null)
        val edges = RingTimeline.Edges(start = legacy, answered = null, idle = edge(10_000))
        assertUnavailable(RingTimeline.compute(edges, incoming, durationSeconds = 0))
    }

    @Test
    fun unknownDirection_isUnavailable() {
        val edges = RingTimeline.Edges(start = edge(0), answered = null, idle = edge(10_000))
        assertUnavailable(RingTimeline.compute(edges, CallWireFormat.Direction.UNKNOWN, durationSeconds = 0))
    }

    @Test
    fun wallClockJump_doesNotChangeTheRing() {
        // The wall clock moved back 10 minutes mid-ring (network time sync);
        // elapsedRealtime did not, and the ring is measured from it.
        val start = edge(0)
        val idle = RingTimeline.Edge(
            wallMillis = WALL_T0 - 600_000 + 20_000,
            elapsedMillis = ELAPSED_T0 + 20_000,
            bootCount = 7,
        )
        val r = RingTimeline.compute(RingTimeline.Edges(start, null, idle), incoming, durationSeconds = 0)

        assertTrue(r.isAvailable)
        assertEquals(20, r.ringDurationSeconds)
    }

    private companion object {
        const val WALL_T0 = 1_000_000_000_000L
        const val ELAPSED_T0 = 50_000L
    }
}
