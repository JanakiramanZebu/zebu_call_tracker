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

    /** Whether the user opted in to sending recordings over mobile data. */
    private const val KEY_RECORDINGS_ON_METERED = "recordings_on_metered"

    data class Policy(
        val maxBatchSize: Int = 200,
        val recommendedBatchSize: Int = 50,
        val maxCallAgeDays: Int = 90,
        val maxRecordingSizeBytes: Long = 209_715_200L,
        val allowedRecordingExtensions: Set<String> = DEFAULT_EXTENSIONS,
        val recommendedSyncIntervalSeconds: Int = 300,
    ) {
        /**
         * How often the warm-process loop sweeps, in milliseconds.
         *
         * Taken from the server rather than invented. Clamped so a strange
         * value cannot turn the loop into a busy-wait or stretch it past the
         * scheduled work it is supposed to beat.
         */
        val loopIntervalMillis: Long
            get() = recommendedSyncIntervalSeconds.toLong().coerceIn(60L, 900L) * 1000L

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
                maxCallAgeDays = o.optInt("max_call_age_days", 90),
                maxRecordingSizeBytes =
                    o.optLong("max_recording_size_bytes", 209_715_200L),
                recommendedSyncIntervalSeconds =
                    o.optInt("recommended_sync_interval_seconds", 300),
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

    /**
     * §6.5: audio goes over unmetered networks unless the user says otherwise.
     *
     * Default false. A recording is far larger than the metadata beside it, and
     * spending somebody's mobile data on it without asking is not a decision
     * this app gets to make silently.
     */
    fun recordingsAllowedOnMeteredNetworks(context: Context): Boolean =
        prefs(context).getBoolean(KEY_RECORDINGS_ON_METERED, false)

    fun setRecordingsAllowedOnMeteredNetworks(context: Context, allowed: Boolean) {
        prefs(context).edit().putBoolean(KEY_RECORDINGS_ON_METERED, allowed).apply()
    }

    private fun JSONArray.toLowerCaseSet(): Set<String> =
        (0 until length())
            .mapNotNull { optString(it)?.trim()?.lowercase()?.takeIf { s -> s.isNotEmpty() } }
            .toSet()
}
