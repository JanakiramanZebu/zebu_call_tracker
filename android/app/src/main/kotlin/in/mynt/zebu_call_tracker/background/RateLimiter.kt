package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.util.Log

/**
 * Keeps uploads under the server's per-user, per-minute limits.
 *
 * The server counts requests per user in a one-minute window that starts at
 * the first request, and answers the one over the limit with
 * `429 RATE_LIMIT_EXCEEDED` and a `Retry-After`. Two of its limits matter
 * here: `POST /sync/calls` at 120 a minute and `POST /calls/{id}/recording` at
 * 60. Every metadata upload this app makes, batch or single-row, goes through
 * `/sync/calls`; `POST /calls` is never used.
 *
 * Metadata cannot realistically reach its limit (one request carries up to
 * 200 calls). Recordings can: a backlog of short ones — after first install, a
 * media permission granted late, a long stretch offline — uploads one after
 * another in well under a second each, and the 61st in a minute was refused.
 *
 * Each bucket allows about 80% of the server's number. The counters are per
 * user, so a second handset of the same employee shares them, and the margin
 * absorbs a 401 replay that counts as a second request.
 *
 * Two pieces of state per bucket:
 *  - a sliding window of when this process sent, in memory;
 *  - a cooldown from a real 429, persisted so a process restart, or another
 *    trigger arriving early, still respects the server's `Retry-After`.
 */
object RateLimiter {

    private const val TAG = "RateLimiter"
    private const val PREFS = "zebu_rate_limits"
    private const val WINDOW_MILLIS = 60_000L

    /** Used when a 429 arrives without a readable `Retry-After`. */
    private const val DEFAULT_COOLDOWN_SECONDS = 60L

    enum class Bucket(val perMinute: Int, val prefKey: String) {
        /** `POST /sync/calls`: server limit 120 a minute. */
        SYNC_CALLS(96, "sync_calls_until"),

        /** `POST /calls/{id}/recording`: server limit 60 a minute. */
        RECORDING(48, "recording_until"),
    }

    private val sent = Bucket.entries.associateWith { ArrayDeque<Long>() }

    /**
     * Milliseconds until [bucket] may send again; 0 when it may send now.
     * The longer of the server's cooldown and this process's own window.
     */
    @Synchronized
    fun waitMillis(context: Context, bucket: Bucket): Long {
        val now = System.currentTimeMillis()
        val cooldown = (cooldownUntil(context, bucket) - now).coerceAtLeast(0L)

        val window = sent.getValue(bucket)
        while (window.isNotEmpty() && window.first() <= now - WINDOW_MILLIS) {
            window.removeFirst()
        }
        val windowWait = if (window.size < bucket.perMinute) {
            0L
        } else {
            window.first() + WINDOW_MILLIS - now
        }
        return maxOf(cooldown, windowWait)
    }

    /** Counts one request about to go out in [bucket]. */
    @Synchronized
    fun record(bucket: Bucket) {
        sent.getValue(bucket).addLast(System.currentTimeMillis())
    }

    /** A 429 for [bucket]: nothing more in it until the server's window reopens. */
    fun onRateLimited(context: Context, bucket: Bucket, retryAfterSeconds: Long?) {
        val seconds = retryAfterSeconds ?: DEFAULT_COOLDOWN_SECONDS
        val until = System.currentTimeMillis() + seconds * 1000L
        prefs(context).edit().putLong(bucket.prefKey, until).apply()
        Log.i(TAG, "[RATE_LIMITED] ${bucket.name}: server asked for ${seconds}s.")
    }

    /** Epoch millis until which [bucket] is held by a 429; 0 when it is not. */
    fun cooldownUntil(context: Context, bucket: Bucket): Long =
        prefs(context).getLong(bucket.prefKey, 0L)
            .takeIf { it > System.currentTimeMillis() } ?: 0L

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
