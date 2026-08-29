package `in`.mynt.zebu_call_tracker.overlay

import android.content.Context
import android.content.Intent

/**
 * Snapshot of one completed call, carried into the overlay service via intent
 * extras. Uses only primitive types so it survives process boundaries cleanly.
 *
 * Every field defaults to a safe value: the overlay must never crash because
 * a call-log column was null (withheld number, missing duration, etc).
 */
data class PostCallData(
    val displayName: String,          // contact name, cached name, or the number
    val phoneNumber: String,          // raw number; "" if withheld
    val direction: String,            // "incoming" | "outgoing" | "missed" | "unknown"
    val durationSeconds: Int,         // 0 for missed / rejected calls
    val hasRecording: Boolean,        // whether a recording was detected
    val startedAtMillis: Long,        // epoch ms; 0 if unknown
) {
    companion object {
        private const val KEY_DISPLAY   = "pc_display"
        private const val KEY_NUMBER    = "pc_number"
        private const val KEY_DIRECTION = "pc_direction"
        private const val KEY_DURATION  = "pc_duration"
        private const val KEY_RECORDING = "pc_recording"
        private const val KEY_STARTED   = "pc_started"

        fun fromContext(context: Context): PostCallData? {
            val prefs = context.getSharedPreferences("post_call_data", Context.MODE_PRIVATE)
            val started = prefs.getLong(KEY_STARTED, -1L)
            if (started == -1L) return null   // nothing has been stored yet
            return PostCallData(
                displayName    = prefs.getString(KEY_DISPLAY, "Unknown") ?: "Unknown",
                phoneNumber    = prefs.getString(KEY_NUMBER, "") ?: "",
                direction      = prefs.getString(KEY_DIRECTION, "unknown") ?: "unknown",
                durationSeconds= prefs.getInt(KEY_DURATION, 0),
                hasRecording   = prefs.getBoolean(KEY_RECORDING, false),
                startedAtMillis= started,
            )
        }

        fun save(context: Context, data: PostCallData) {
            context.getSharedPreferences("post_call_data", Context.MODE_PRIVATE).edit()
                .putString(KEY_DISPLAY,   data.displayName)
                .putString(KEY_NUMBER,    data.phoneNumber)
                .putString(KEY_DIRECTION, data.direction)
                .putInt(KEY_DURATION,     data.durationSeconds)
                .putBoolean(KEY_RECORDING,data.hasRecording)
                .putLong(KEY_STARTED,     data.startedAtMillis)
                .apply()
        }

        fun clear(context: Context) {
            context.getSharedPreferences("post_call_data", Context.MODE_PRIVATE)
                .edit().clear().apply()
        }

        /** Packs [data] into a launch intent for [PostCallOverlayService]. */
        fun intoIntent(context: Context, data: PostCallData): Intent =
            Intent(context, PostCallOverlayService::class.java).apply {
                putExtra(KEY_DISPLAY,    data.displayName)
                putExtra(KEY_NUMBER,     data.phoneNumber)
                putExtra(KEY_DIRECTION,  data.direction)
                putExtra(KEY_DURATION,   data.durationSeconds)
                putExtra(KEY_RECORDING,  data.hasRecording)
                putExtra(KEY_STARTED,    data.startedAtMillis)
            }

        /** Unpacks from an intent. Returns null if essential extras are missing. */
        fun fromIntent(intent: Intent): PostCallData? {
            val started = intent.getLongExtra(KEY_STARTED, -1L)
            if (started == -1L) return null
            return PostCallData(
                displayName     = intent.getStringExtra(KEY_DISPLAY) ?: "Unknown",
                phoneNumber     = intent.getStringExtra(KEY_NUMBER) ?: "",
                direction       = intent.getStringExtra(KEY_DIRECTION) ?: "unknown",
                durationSeconds = intent.getIntExtra(KEY_DURATION, 0),
                hasRecording    = intent.getBooleanExtra(KEY_RECORDING, false),
                startedAtMillis = started,
            )
        }
    }
}