package `in`.mynt.zebu_call_tracker.background

import `in`.mynt.zebu_call_tracker.call.CallWireFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

class CallPayloadTest {

    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    private fun call(
        direction: String,
        status: String,
        durationSeconds: Int,
        endedAtMillis: Long?,
        ringDurationSeconds: Int?,
        answeredAtMillis: Long? = null,
    ) = CallRecord(
        localId = 1,
        idempotencyKey = "key-1",
        externalCallId = "android-$STARTED-9876543210",
        serverCallId = null,
        phoneNumber = "9876543210",
        contactName = null,
        direction = direction,
        status = status,
        startedAtMillis = STARTED,
        answeredAtMillis = answeredAtMillis,
        endedAtMillis = endedAtMillis,
        durationSeconds = durationSeconds,
        hasRecording = false,
        recordingPath = null,
        recordingMediaStoreId = null,
        recordingChecksum = null,
        recordingUploadStatus = RecordingStates.ABSENT,
        simSlot = 1,
        metadataJson = """{"timing":{"ended_at_source":"journal","ring_source":"journal"}}""",
        attemptCount = 0,
        clientCreatedAtMillis = STARTED,
        ringDurationSeconds = ringDurationSeconds,
    )

    @Test
    fun missedCall_carriesEndedAtAndRingDuration() {
        val json = CallPayload.build(
            call(
                direction = CallWireFormat.Direction.INCOMING,
                status = CallWireFormat.Status.MISSED,
                durationSeconds = 0,
                endedAtMillis = STARTED + 27_000,
                ringDurationSeconds = 27,
            ),
            deviceUuid = "device-1",
            isoFormat = iso,
        )

        assertEquals("missed", json.getString("status"))
        assertEquals("incoming", json.getString("direction"))
        assertEquals(iso.format(java.util.Date(STARTED)), json.getString("started_at"))
        assertEquals(iso.format(java.util.Date(STARTED + 27_000)), json.getString("ended_at"))
        assertEquals(27, json.getInt("ring_duration_seconds"))
        assertEquals(0, json.getInt("duration_seconds"))
        assertFalse(json.has("answered_at"))
        assertEquals(
            "journal",
            json.getJSONObject("metadata").getJSONObject("timing").getString("ring_source"),
        )
    }

    @Test
    fun cancelledOutgoing_carriesEndedAtAndRingDuration() {
        val json = CallPayload.build(
            call(
                direction = CallWireFormat.Direction.OUTGOING,
                status = CallWireFormat.Status.CANCELLED,
                durationSeconds = 0,
                endedAtMillis = STARTED + 9_000,
                ringDurationSeconds = 9,
            ),
            deviceUuid = "device-1",
            isoFormat = iso,
        )

        assertEquals("cancelled", json.getString("status"))
        assertTrue(json.has("ended_at"))
        assertEquals(9, json.getInt("ring_duration_seconds"))
    }

    @Test
    fun noRingMeasured_omitsRingAndEnd() {
        val json = CallPayload.build(
            call(
                direction = CallWireFormat.Direction.INCOMING,
                status = CallWireFormat.Status.MISSED,
                durationSeconds = 0,
                endedAtMillis = null,
                ringDurationSeconds = null,
            ),
            deviceUuid = "device-1",
            isoFormat = iso,
        )

        assertFalse(json.has("ring_duration_seconds"))
        assertFalse(json.has("ended_at"))
    }

    @Test
    fun missedCallWithStoredAnswerTime_omitsAnsweredAt() {
        // Call waiting: the ongoing call's OFFHOOK was stored as this call's
        // answer. The server refuses answered_at on a missed call (422).
        val json = CallPayload.build(
            call(
                direction = CallWireFormat.Direction.INCOMING,
                status = CallWireFormat.Status.MISSED,
                durationSeconds = 0,
                endedAtMillis = STARTED + 20_000,
                ringDurationSeconds = 20,
                answeredAtMillis = STARTED + 20_000,
            ),
            deviceUuid = "device-1",
            isoFormat = iso,
        )

        assertEquals("missed", json.getString("status"))
        assertFalse(json.has("answered_at"))
        assertTrue(json.has("ended_at"))
    }

    @Test
    fun endedCall_keepsAnsweredAt() {
        val json = CallPayload.build(
            call(
                direction = CallWireFormat.Direction.INCOMING,
                status = CallWireFormat.Status.ENDED,
                durationSeconds = 60,
                endedAtMillis = STARTED + 72_000,
                ringDurationSeconds = 12,
                answeredAtMillis = STARTED + 12_000,
            ),
            deviceUuid = "device-1",
            isoFormat = iso,
        )

        assertEquals("ended", json.getString("status"))
        assertEquals(iso.format(java.util.Date(STARTED + 12_000)), json.getString("answered_at"))
    }

    private companion object {
        const val STARTED = 1_760_000_000_000L
    }
}
