package `in`.mynt.zebu_call_tracker.overlay

import android.content.Intent

/**
 * Snapshot of one completed call, as shown on the post-call card.
 *
 * Every field defaults to a safe value: the overlay must never crash because
 * a call-log column was null (withheld number, missing duration, etc).
 *
 * It used to be persisted to SharedPreferences on "View Details" as well, but
 * nothing ever read that copy back: the tap reaches Flutter through
 * [EXTRA_OPEN_CALL] on the launch intent, and NativeBridge holds it until Dart
 * subscribes.
 */
data class PostCallData(
    val displayName: String,          // contact name, cached name, or the number
    val phoneNumber: String,          // raw number; "" if withheld
    val direction: String,            // "incoming" | "outgoing" | "missed" | "unknown"
    val durationSeconds: Int,         // 0 for missed / rejected calls
    val hasRecording: Boolean,        // whether a recording was detected
    val startedAtMillis: Long,        // epoch ms; 0 if unknown
    val isContact: Boolean = false,   // displayName came from contacts / the log's cached name
) {
    /** Carries this card to [PostCallActivity] on the notification's intent. */
    fun writeTo(intent: Intent): Intent = intent
        .putExtra(EXTRA_NAME, displayName)
        .putExtra(EXTRA_NUMBER, phoneNumber)
        .putExtra(EXTRA_DIRECTION, direction)
        .putExtra(EXTRA_DURATION, durationSeconds)
        .putExtra(EXTRA_STARTED_AT, startedAtMillis)
        .putExtra(EXTRA_IS_CONTACT, isContact)

    companion object {
        private const val EXTRA_NAME = "post_call_name"
        private const val EXTRA_NUMBER = "post_call_number"
        private const val EXTRA_DIRECTION = "post_call_direction"
        private const val EXTRA_DURATION = "post_call_duration"
        private const val EXTRA_STARTED_AT = "post_call_started_at"
        private const val EXTRA_IS_CONTACT = "post_call_is_contact"

        /** The card [writeTo] packed, or null for an intent that carries none. */
        fun readFrom(intent: Intent?): PostCallData? {
            val name = intent?.getStringExtra(EXTRA_NAME) ?: return null
            return PostCallData(
                displayName = name,
                phoneNumber = intent.getStringExtra(EXTRA_NUMBER).orEmpty(),
                direction = intent.getStringExtra(EXTRA_DIRECTION) ?: "unknown",
                durationSeconds = intent.getIntExtra(EXTRA_DURATION, 0),
                hasRecording = false,
                startedAtMillis = intent.getLongExtra(EXTRA_STARTED_AT, 0L),
                isContact = intent.getBooleanExtra(EXTRA_IS_CONTACT, false),
            )
        }

        /**
         * Set on the launcher intent when the user taps "View Details".
         *
         * Read by `MainActivity`, which hands it to `NativeBridge` so Flutter
         * can open the matching call. Lives here rather than on the overlay
         * itself because the overlay is no longer a component with a lifetime
         * of its own — see [PostCallOverlayController].
         */
        const val EXTRA_OPEN_CALL = "open_call_started_millis"
    }
}
