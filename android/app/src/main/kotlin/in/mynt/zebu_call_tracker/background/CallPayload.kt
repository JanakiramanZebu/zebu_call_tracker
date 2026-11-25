package `in`.mynt.zebu_call_tracker.background

import android.util.Log
import `in`.mynt.zebu_call_tracker.call.CallWireFormat
import `in`.mynt.zebu_call_tracker.call.RingTimeline
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date

/**
 * One call as `POST /sync/calls` receives it.
 *
 * Shared by both of [SyncCoordinator]'s payload builders because they must
 * describe a call identically — the batch pass and the one-at-a-time pass
 * handle the same rows, and a row that took the slow path because it carries
 * audio must not be described differently for it.
 */
object CallPayload {

    private const val TAG = "CallPayload"

    fun build(call: CallRecord, deviceUuid: String, isoFormat: SimpleDateFormat): JSONObject {
        // Single source of truth for the wire vocabulary. Building it inline
        // is how `status = "completed"` — a value the server's enum does not
        // contain — reached every request and had every answered call
        // rejected with a non-retryable 422.
        val outcome = CallWireFormat.outcomeFor(
            rawDirection = call.direction,
            durationSeconds = call.durationSeconds,
            rawStatus = call.status,
        )
        return JSONObject().apply {
            put("idempotency_key", call.idempotencyKey)
            // Through the shared rules, so a row missing its external id is
            // named the same way the ingesters would have named it.
            put(
                "external_call_id",
                call.externalCallId ?: CallWireFormat.Identity.externalId(
                    call.startedAtMillis,
                    call.phoneNumber,
                ),
            )
            put("device_uuid", deviceUuid)
            put("phone_number", call.phoneNumber)
            if (!call.contactName.isNullOrBlank()) put("contact_name", call.contactName)
            put("direction", outcome.direction)
            put("status", outcome.status)
            put("started_at", isoFormat.format(Date(call.startedAtMillis)))
            applyTimings(this, call, isoFormat)
            put("duration_seconds", call.durationSeconds)
            put("has_recording", call.hasRecording)
            call.simSlot?.let { put("sim_slot", it) }
            // When the call was captured, not when it was sent.
            put(
                "client_created_at",
                isoFormat.format(Date(call.clientCreatedAtMillis ?: System.currentTimeMillis())),
            )
            applyMetadata(this, call)
        }
    }

    /**
     * Writes `answered_at`, `ended_at` and `ring_duration_seconds`.
     *
     * `ended_at` used to be computed here as `started_at + duration_seconds`.
     * That is wrong by the entire ring: `started_at` is `CallLog.Calls.DATE`,
     * the moment the phone began ringing, while `DURATION` counts connected
     * seconds only. Every call the server holds ended earlier than it really
     * did, by between a second and three minutes.
     *
     * Each field is omitted when the device could not establish it. The
     * server recomputes `duration_seconds` from the answered/ended pair
     * whenever both are present and that value wins, so a fabricated pair
     * does not merely add noise — it overwrites the one number that was
     * measured correctly. `ended_at` is sent for missed, rejected and
     * cancelled calls too: it is how the server derives their ring time, and
     * a server that predates `ring_duration_seconds` ignores that field.
     */
    private fun applyTimings(
        json: JSONObject,
        call: CallRecord,
        isoFormat: SimpleDateFormat,
    ) {
        // Never earlier than started_at: the server refuses that as a
        // validation error, and inside `POST /sync/calls` one such call fails
        // the WHOLE batch. The recording matcher accepts a file stamped up to
        // 15 s before the call-log start, and an open-stamped recording's
        // DATE_ADDED then lands before it. A time that cannot be right is
        // dropped; the server falls back to the measured duration.
        call.answeredAtMillis?.takeIf { it >= call.startedAtMillis }?.let {
            json.put("answered_at", isoFormat.format(Date(it)))
        }
        call.endedAtMillis?.takeIf { it >= call.startedAtMillis }?.let {
            json.put("ended_at", isoFormat.format(Date(it)))
        }
        call.ringDurationSeconds?.takeIf { it in 0..RingTimeline.MAX_RING_SECONDS }?.let {
            json.put("ring_duration_seconds", it)
        }
    }

    /**
     * Attaches the stored `metadata` bag, if the row has one.
     *
     * Held as pre-encoded JSON rather than rebuilt here: it describes the
     * call-log row and the recording as they were at capture, and the provider
     * rows behind it are long out of scope by upload time. A string that no
     * longer parses is dropped, since sending the server a malformed object
     * costs the whole call a 422 for the sake of an optional field.
     */
    private fun applyMetadata(json: JSONObject, call: CallRecord) {
        val raw = call.metadataJson
        if (raw.isNullOrBlank()) return
        try {
            json.put("metadata", JSONObject(raw))
        } catch (e: Exception) {
            Log.w(TAG, "[METADATA_UNPARSEABLE] ${call.idempotencyKey}: ${e.message}")
        }
    }
}
