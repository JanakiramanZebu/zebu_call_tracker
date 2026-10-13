package `in`.mynt.zebu_call_tracker.overlay

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
    companion object {
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
