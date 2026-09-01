package `in`.mynt.zebu_call_tracker.call

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
}
