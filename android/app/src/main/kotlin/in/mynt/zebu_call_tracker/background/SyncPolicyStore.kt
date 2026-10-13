package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * The server's operating limits, as last reported by `GET /sync/status`.
 *
 * Mobile API Guide §5.1 is explicit that these are read at runtime and not
 * hardcoded, because an administrator can change them. The app was fetching
 * them, parsing them into a Dart `SyncPolicy`, and then never consulting the
 * result — batch size, upload ceiling, extension list and sync interval were
 * all fixed constants scattered across two languages. The one that bit hardest
 * was the batch: the coordinator posted a single call per HTTP request against
 * a documented recommendation of fifty.
 *
 * Dart fetches and stores; the native coordinator reads. Defaults match the
 * guide, so a handset that has not yet reached `/sync/status` still behaves
 * sensibly.
 */
object SyncPolicyStore {

    private const val TAG = "SyncPolicyStore"
    private const val PREFS = "call_ingest_store"
    private const val KEY_POLICY = "sync_policy_json"

    data class Policy(
        val maxBatchSize: Int = 200,
        val recommendedBatchSize: Int = 50,
        val maxRecordingSizeBytes: Long = 209_715_200L,
        val allowedRecordingExtensions: Set<String> = DEFAULT_EXTENSIONS,
        val recommendedSyncIntervalSeconds: Int = 300,
        /**
         * Whether [CallTrackingService] may run at all (`keepalive_service`).
         *
         * Default TRUE, and absent means true: only an explicit `false` from
         * the server turns it off. Employees rarely open this app, and on
         * Xiaomi, Oppo, Vivo, OnePlus and Honor firmware a closed app stops
         * receiving the "call ended" broadcast and has its scheduled jobs
         * starved, so calls reached the CRM days late. A warm process with a
         * foreground service is what those builds respect. The event-driven
         * triggers and the hourly safety net still run beside it.
         */
        val keepaliveService: Boolean = true,
        /** §4.6: older calls are refused for good (`SYNC_POLICY_VIOLATION`). */
        val maxCallAgeDays: Int = 90,
    ) {
        /**
         * How often the warm-process loop sweeps, in milliseconds, when the
         * service is enabled at all (see [keepaliveService]).
         *
         * Taken from the server rather than invented. The floor is five
         * minutes: below that the loop was a radio and CPU wake-up per minute
         * to re-read a call log the event triggers already cover. The service
         * stretches this further to its own minimum; see [CallTrackingService].
         */
        val loopIntervalMillis: Long
            get() = recommendedSyncIntervalSeconds.toLong().coerceIn(300L, 3600L) * 1000L

        /**
         * How many calls go in one `POST /sync/calls`.
         *
         * The guide's recommendation, clamped by the server's own hard cap so a
         * misconfigured recommendation cannot produce a 422 that rejects the
         * whole batch.
         */
        val batchSize: Int
            get() = recommendedBatchSize.coerceIn(1, maxBatchSize.coerceAtLeast(1))
    }

    val DEFAULT_EXTENSIONS = setOf(
        "3gp", "aac", "amr", "m4a", "mp3", "mp4", "ogg", "opus", "wav",
    )

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Stores what `/sync/status` last reported. Called from Dart. */
    fun save(context: Context, json: String) {
        prefs(context).edit().putString(KEY_POLICY, json).apply()
    }

    /**
     * The current policy, or the guide's defaults when nothing has been stored
     * or the stored value cannot be parsed.
     *
     * Never throws: a policy this app cannot read is a reason to fall back, not
     * a reason to stop syncing.
     */
    fun load(context: Context): Policy {
        val raw = prefs(context).getString(KEY_POLICY, null) ?: return Policy()
        return try {
            val o = JSONObject(raw)
            Policy(
                maxBatchSize = o.optInt("max_batch_size", 200),
                recommendedBatchSize = o.optInt("recommended_batch_size", 50),
                maxRecordingSizeBytes =
                    o.optLong("max_recording_size_bytes", 209_715_200L),
                recommendedSyncIntervalSeconds =
                    o.optInt("recommended_sync_interval_seconds", 300),
                keepaliveService = o.optBoolean("keepalive_service", true),
                maxCallAgeDays = o.optInt("max_call_age_days", 90).coerceAtLeast(1),
                allowedRecordingExtensions =
                    o.optJSONArray("allowed_recording_extensions")
                        ?.toLowerCaseSet()
                        ?.takeIf { it.isNotEmpty() }
                        ?: DEFAULT_EXTENSIONS,
            )
        } catch (e: Exception) {
            Log.w(TAG, "Stored sync policy is unreadable; using defaults: ${e.message}")
            Policy()
        }
    }

    private fun JSONArray.toLowerCaseSet(): Set<String> =
        (0 until length())
            // ".m4a" and "m4a" alike: compared against a bare extension, a
            // leading dot rejected every file locally as unsupported.
            .mapNotNull {
                optString(it)?.trim()?.removePrefix(".")?.lowercase()?.takeIf { s -> s.isNotEmpty() }
            }
            .toSet()
}
