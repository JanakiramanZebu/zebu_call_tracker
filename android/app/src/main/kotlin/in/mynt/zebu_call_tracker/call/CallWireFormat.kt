package `in`.mynt.zebu_call_tracker.call

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

/**
 * The `direction` and `status` vocabulary the server accepts, and the only
 * sanctioned way to derive them from an Android call-log row.
 *
 * Taken from the Mobile API Guide, §4.4. These are **contractual**: the server
 * validates both the individual values and the combination, and rejects
 * anything else with `422 VALIDATION_ERROR`, flagged `retryable: false` — a
 * permanent drop, not a delay.
 *
 * This exists because the coordinator previously sent `status = "completed"`,
 * which is not a member of the enum at all. Every answered call — the bulk of
 * the queue — was rejected on arrival and discarded. The server's terminal
 * status is `ended`.
 *
 * **Mirror of `lib/core/network/call_wire_format.dart`.** Both sides write the
 * same outbox and either may be the one that captured a given call, so a call
 * must not be described differently depending on which got there first.
 */
object CallWireFormat {

    object Direction {
        const val INCOMING = "incoming"
        const val OUTGOING = "outgoing"
        const val UNKNOWN = "unknown"
    }

    /** `ended`, `missed`, `rejected`, `failed` and `cancelled` are terminal. */
    object Status {
        const val RINGING = "ringing"
        const val DIALING = "dialing"
        const val ANSWERED = "answered"
        const val MISSED = "missed"
        const val REJECTED = "rejected"
        const val FAILED = "failed"
        const val CANCELLED = "cancelled"

        /** The normal terminal state of a call that connected and finished. */
        const val ENDED = "ended"

        const val UNKNOWN = "unknown"

        val ALL = setOf(
            RINGING, DIALING, ANSWERED, MISSED, REJECTED,
            FAILED, CANCELLED, ENDED, UNKNOWN,
        )
    }

    /** Local values from older builds that were never valid on the wire. */
    private val LEGACY_STATUS = linkedMapOf("completed" to Status.ENDED)

    val normalizationStatements: List<String>
        get() = LEGACY_STATUS.entries.map {
            "UPDATE local_calls SET status = '${it.value}' WHERE status = '${it.key}';"
        }

    data class Outcome(val direction: String, val status: String)

    /**
     * Maps a call-log row onto a pair the server will accept.
     *
     * The combination rules matter as much as the values (§4.4):
     *
     *  - an **outgoing** call can never be `missed` or `rejected`. One that
     *    never connected is `cancelled` — the caller rang off. Sending
     *    `(outgoing, missed)`, as the previous mapping did for every
     *    zero-duration outgoing call, is a 422.
     *  - an **incoming** call can never be `dialing`.
     *
     * Anything unrecognised degrades to `unknown`, which §4.4 allows and which
     * can be narrowed later by re-posting the same idempotency key.
     */
    fun outcomeFor(
        rawDirection: String?,
        durationSeconds: Int,
        rawStatus: String? = null,
    ): Outcome {
        val direction = rawDirection?.trim()?.lowercase().orEmpty()
        val status = rawStatus?.trim()?.lowercase()
        val connected = durationSeconds > 0

        // An explicit terminal status from the call log wins over inference.
        if (status == Status.MISSED || direction == "missed") {
            return Outcome(Direction.INCOMING, Status.MISSED)
        }
        if (status == Status.REJECTED || direction == "rejected" || direction == "blocked") {
            return Outcome(Direction.INCOMING, Status.REJECTED)
        }

        if (direction == Direction.OUTGOING || direction.contains("out")) {
            // Dialled but never answered. NOT `missed` — illegal for outgoing.
            return Outcome(
                Direction.OUTGOING,
                if (connected) Status.ENDED else Status.CANCELLED,
            )
        }

        if (direction == Direction.INCOMING || direction.contains("in") || direction == "voicemail") {
            return Outcome(
                Direction.INCOMING,
                if (connected) Status.ENDED else Status.MISSED,
            )
        }

        return Outcome(
            Direction.UNKNOWN,
            if (connected) Status.ENDED else Status.UNKNOWN,
        )
    }

    /**
     * How a call's identity is derived. **Mirror of `CallWireIdentity` in
     * `lib/core/network/call_wire_format.dart`.**
     *
     * Two independent ingesters write the same outbox table: [
     * in.mynt.zebu_call_tracker.background.NativeCallIngestor] here and
     * `ingestNativeCallLogs` in Dart. They may disagree about when they run;
     * they must not disagree about what a call is *called*, because the
     * idempotency key is the only thing stopping the server storing the same
     * conversation twice.
     *
     * They did disagree. A withheld number arrives as null: this side
     * substituted "Unknown", Dart interpolated the null and produced the
     * literal text "null". Two external ids, two v5 UUIDs, two rows, and two
     * separate call records on the server for one phone call.
     */
    object Identity {

        /** Fixed forever: changing it renames every call ever queued. */
        private val DNS_NAMESPACE: UUID =
            UUID.fromString("6ba7b810-9dad-11d1-80b4-00c04fd430c8")

        /** Placeholder for a number the call log withheld. */
        const val WITHHELD_NUMBER = "Unknown"

        /**
         * The number as it goes into the external id, the key and the row.
         *
         * Only null is folded. An empty string is left alone deliberately:
         * both sides already produced the same id for it, and folding it would
         * rename rows that are not broken.
         */
        fun number(raw: String?): String = raw ?: WITHHELD_NUMBER

        /** Stable per-call id from the call log's own timestamp and number. */
        fun externalId(startedAtMillis: Long, rawNumber: String?): String =
            "android-$startedAtMillis-${number(rawNumber)}"

        /**
         * The name hashed into the v5 UUID. Must match Dart byte-for-byte.
         */
        fun keyName(externalCallId: String, startedAtMillis: Long): String =
            "zebu:call:$externalCallId:$startedAtMillis"

        /** The idempotency key for a call-log row. */
        fun key(startedAtMillis: Long, rawNumber: String?): String =
            keyFor(externalId(startedAtMillis, rawNumber), startedAtMillis)

        /**
         * RFC 4122 v5 over [DNS_NAMESPACE], matching Dart's
         * `Uuid().v5(namespace, name)`.
         *
         * Lived on `CallSyncWorker` until now, which is a strange home for the
         * function that decides a call's identity — it is a property of the
         * wire format, not of one of the four things that can trigger a sync.
         */
        fun keyFor(externalCallId: String, startedAtMillis: Long): String {
            val name = keyName(externalCallId, startedAtMillis)
            val bb = ByteBuffer.allocate(16)
            bb.putLong(DNS_NAMESPACE.mostSignificantBits)
            bb.putLong(DNS_NAMESPACE.leastSignificantBits)

            val md = MessageDigest.getInstance("SHA-1")
            md.update(bb.array())
            val hash = md.digest(name.toByteArray(Charsets.UTF_8))

            hash[6] = ((hash[6].toInt() and 0x0f) or 0x50).toByte()
            hash[8] = ((hash[8].toInt() and 0x3f) or 0x80).toByte()

            return UUID(
                ByteBuffer.wrap(hash, 0, 8).long,
                ByteBuffer.wrap(hash, 8, 8).long,
            ).toString()
        }
    }
}
