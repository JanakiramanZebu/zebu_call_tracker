package `in`.mynt.zebu_call_tracker.call

import android.util.Log
import `in`.mynt.zebu_call_tracker.recording.NativeMatchSignals
import `in`.mynt.zebu_call_tracker.recording.NativeRecordingCandidate
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs

/**
 * Turns a call-log row plus whatever else the device knows into the two things
 * the outbox cannot derive for itself: real `answered_at` / `ended_at`
 * timestamps, and the JSON `metadata` bag the server accepts alongside them.
 *
 * Exists as its own object because both ingesters need identical answers. The
 * Dart mirror is `CallEnrichment` in
 * `lib/features/call_tracking/data/call_enrichment.dart`.
 *
 * The governing rule throughout: **a null is an answer.** Every field here is
 * optional on the wire, and the server recomputes `duration_seconds` from
 * `answered_at`/`ended_at` whenever both are present — so a confident wrong
 * pair corrupts a record that an absent pair would merely have left thin.
 */
object CallEnrichment {

    private const val TAG = "CallEnrichment"

    /** The server rejects a `metadata` object larger than this. */
    private const val MAX_METADATA_BYTES = 8 * 1024

    /**
     * How closely a recording's open-to-close lifetime must reproduce its audio
     * duration before DATE_ADDED is trusted as the answer instant.
     */
    private const val OPEN_STAMP_TOLERANCE_SECONDS = 5L

    /** Where a timestamp came from, so the server can weigh it. */
    object Source {
        /** Measured from the telephony broadcast. The best available. */
        const val JOURNAL = "journal"

        /** Taken from the matched recording's MediaStore timestamps. */
        const val RECORDING = "recording"

        /** Computed from a known answer time plus the log's duration. */
        const val DERIVED = "derived"
    }

    data class Times(
        val answeredAtMillis: Long?,
        val endedAtMillis: Long?,
        val answeredAtSource: String?,
        val endedAtSource: String?,
    )

    /**
     * Whether this file's timestamps follow the open-stamped convention.
     *
     * A dialer that stamps DATE_ADDED when it opens the file leaves
     * `DATE_MODIFIED - DATE_ADDED` equal to the audio duration. One that stamps
     * both at close leaves a lifetime of roughly zero. Only in the first case
     * does DATE_ADDED mean "the call was answered", so the device tells us
     * which reading is safe instead of us assuming one.
     */
    fun isOpenStamped(candidate: NativeRecordingCandidate): Boolean {
        if (candidate.lifetimeSeconds <= 0) return false
        val delta = abs(candidate.lifetimeSeconds - candidate.durationSeconds)
        return delta <= OPEN_STAMP_TOLERANCE_SECONDS
    }

    /**
     * Resolves when the call was answered and when it ended.
     *
     * The ladder, strongest first:
     *
     *  1. **Journal.** `OFFHOOK` is the pickup — but only for an INCOMING call.
     *     An outgoing call has no ringing state: OFFHOOK fires when dialling
     *     starts, and the remote party answering produces no broadcast at all.
     *     `ACTION_PHONE_STATE_CHANGED` cannot report an outgoing answer, so
     *     using OFFHOOK there would report dial time as talk time and inflate
     *     every outgoing call by its ring. `IDLE` is the hangup in both
     *     directions and is used for both.
     *  2. **Recording.** DATE_ADDED / DATE_MODIFIED, where [isOpenStamped]
     *     confirms the device means what we think by them.
     *  3. **Derived.** `answered + duration` for the end, once the answer is
     *     known from either source above.
     *  4. **Null.** Backfill, missed calls, and anything the receiver was not
     *     alive for.
     */
    fun resolveTimes(
        direction: String,
        durationSeconds: Int,
        window: CallStateJournal.CallWindow?,
        recording: NativeRecordingCandidate?,
    ): Times {
        val isIncoming = direction.trim().lowercase() == CallWireFormat.Direction.INCOMING
        val openStamped = recording != null && isOpenStamped(recording)

        var answeredAt: Long? = null
        var answeredSource: String? = null

        val offHook = window?.offHookAtMillis
        if (isIncoming && offHook != null) {
            answeredAt = offHook
            answeredSource = Source.JOURNAL
        } else if (openStamped) {
            answeredAt = recording!!.dateAddedEpochSeconds * 1000L
            answeredSource = Source.RECORDING
        }

        var endedAt: Long? = null
        var endedSource: String? = null

        val idle = window?.idleAtMillis
        if (idle != null) {
            endedAt = idle
            endedSource = Source.JOURNAL
        } else if (openStamped) {
            endedAt = recording!!.dateModifiedEpochSeconds * 1000L
            endedSource = Source.RECORDING
        } else if (answeredAt != null) {
            endedAt = answeredAt + (durationSeconds * 1000L)
            endedSource = Source.DERIVED
        }

        return Times(
            answeredAtMillis = answeredAt,
            endedAtMillis = endedAt,
            answeredAtSource = answeredSource,
            endedAtSource = endedSource,
        )
    }

    /**
     * Builds the `metadata` object for one call.
     *
     * Everything in here is a fact the call-log row or the MediaStore entry
     * already carried and that had no column of its own — it was read and
     * discarded. The server treats this bag as opaque and non-queryable, so
     * anything that later needs filtering has to graduate to a real column;
     * until then this is where it lives rather than nowhere.
     *
     * Absent values are omitted rather than sent as null, which keeps a plain
     * voice call's object down to a couple of hundred bytes.
     */
    fun buildMetadata(
        row: Map<String, Any?>,
        times: Times,
        recording: NativeRecordingCandidate?,
        signals: NativeMatchSignals?,
        confidence: Double?,
        appBuild: Int?,
    ): String? {
        val json = JSONObject()

        // The call log's own row id. NOT reused as `external_call_id`: that
        // field feeds the v5 idempotency key, so changing how it is derived
        // renames every call already queued and the server stores duplicates
        // for anything in flight. It belongs here, where it is merely useful.
        putIfPresent(json, "call_log_id", row["systemId"])
        putIfPresent(json, "presentation", row["presentation"])
        putIfPresent(json, "geocoded_location", truncate(row["geocodedLocation"] as? String, 128))
        putIfPresent(json, "country_iso", row["countryIso"])
        putIfPresent(json, "data_usage_bytes", row["dataUsageBytes"])
        putIfPresent(json, "via_number", row["viaNumber"])
        putIfPresent(json, "post_dial_digits", row["postDialDigits"])
        putIfPresent(json, "block_reason", row["blockReason"])
        putIfPresent(json, "number_label", row["numberLabel"])
        putIfPresent(json, "phone_account_id", truncate(row["phoneAccountId"] as? String, 128))
        putIfPresent(
            json,
            "phone_account_component",
            truncate(row["phoneAccountComponent"] as? String, 200),
        )
        putIfPresent(json, "app_build", appBuild)

        val features = row["features"] as? List<*>
        if (!features.isNullOrEmpty()) {
            json.put("features", JSONArray(features))
        }

        // How much of the timing above is measured and how much is inferred.
        // Without this the server cannot tell a journal-accurate answer time
        // from one reconstructed off a file timestamp.
        val timing = JSONObject()
        putIfPresent(timing, "answered_at_source", times.answeredAtSource)
        putIfPresent(timing, "ended_at_source", times.endedAtSource)
        if (timing.length() > 0) json.put("timing", timing)

        if (recording != null) {
            json.put("recording", recordingObject(recording, signals, confidence))
        }

        if (json.length() == 0) return null

        val encoded = json.toString()
        if (encoded.toByteArray(Charsets.UTF_8).size <= MAX_METADATA_BYTES) return encoded

        // Over the server's cap. Shed the recording detail — it is the largest
        // sub-object and the least load-bearing — rather than letting the whole
        // call be rejected for the sake of a filename.
        Log.w(TAG, "metadata over ${MAX_METADATA_BYTES}B; dropping recording detail")
        json.remove("recording")
        val trimmed = json.toString()
        return if (trimmed.toByteArray(Charsets.UTF_8).size <= MAX_METADATA_BYTES) trimmed else null
    }

    /**
     * Folds a newly discovered recording into metadata built before it existed.
     *
     * The retroactive matcher runs minutes after the call was ingested, by
     * which point the row already carries a metadata object describing
     * everything except the audio. Rebuilding it from the call-log row is not
     * an option — that row is long out of scope — so the existing JSON is
     * reparsed and the `recording` and `timing` sections replaced.
     *
     * A metadata string we cannot parse is discarded rather than propagated:
     * it can only have come from a build that wrote something different, and
     * merging into it blind risks sending the server a malformed bag.
     */
    fun remergeRecordingMetadata(
        existingJson: String?,
        times: Times,
        recording: NativeRecordingCandidate,
        signals: NativeMatchSignals?,
        confidence: Double?,
    ): String? {
        val json = if (existingJson.isNullOrBlank()) {
            JSONObject()
        } else {
            try {
                JSONObject(existingJson)
            } catch (e: Exception) {
                Log.w(TAG, "Discarding unparseable metadata: ${e.message}")
                JSONObject()
            }
        }

        val timing = JSONObject()
        putIfPresent(timing, "answered_at_source", times.answeredAtSource)
        putIfPresent(timing, "ended_at_source", times.endedAtSource)
        if (timing.length() > 0) json.put("timing", timing)

        json.put("recording", recordingObject(recording, signals, confidence))

        val encoded = json.toString()
        if (encoded.toByteArray(Charsets.UTF_8).size <= MAX_METADATA_BYTES) return encoded

        Log.w(TAG, "merged metadata over ${MAX_METADATA_BYTES}B; dropping recording detail")
        json.remove("recording")
        val trimmed = json.toString()
        return if (trimmed.toByteArray(Charsets.UTF_8).size <= MAX_METADATA_BYTES) trimmed else null
    }

    private fun recordingObject(
        recording: NativeRecordingCandidate,
        signals: NativeMatchSignals?,
        confidence: Double?,
    ): JSONObject = JSONObject().apply {
        put("media_store_id", recording.mediaStoreId)
        putIfPresent(this, "display_name", truncate(recording.displayName, 200))
        putIfPresent(this, "relative_path", truncate(recording.relativePath, 200))
        putIfPresent(this, "source", recording.source)
        putIfPresent(this, "mime_type", recording.mimeType)
        put("size_bytes", recording.sizeBytes)
        put("duration_seconds", round(recording.durationSeconds))
        put("date_added", recording.dateAddedEpochSeconds)
        put("date_modified", recording.dateModifiedEpochSeconds)
        if (confidence != null) put("match_confidence", round(confidence))
        if (signals != null) {
            put("match_anchored", signals.isAnchored)
            put("duration_delta_seconds", round(signals.durationDeltaSeconds))
            put("ring_gap_seconds", signals.ringGapSeconds)
            put("identity_matched", signals.identityMatched)
            putIfPresent(this, "anchor_delta_seconds", signals.anchorDeltaSeconds)
        }
    }

    /** Two decimal places; JSON has no use for a double's full tail. */
    private fun round(value: Double): Double = Math.round(value * 100.0) / 100.0

    private fun truncate(value: String?, max: Int): String? {
        if (value.isNullOrBlank()) return null
        return if (value.length <= max) value else value.substring(0, max)
    }

    private fun putIfPresent(json: JSONObject, key: String, value: Any?) {
        when (value) {
            null -> return
            is String -> if (value.isNotBlank()) json.put(key, value)
            else -> json.put(key, value)
        }
    }
}
