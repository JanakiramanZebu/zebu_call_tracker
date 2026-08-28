package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * Durable hand-off between the background worker and Dart.
 *
 * The worker runs with no Flutter engine, so it cannot call into the Dart
 * matcher. It captures what is *perishable* and leaves interpretation to Dart:
 *
 *  - **Call log rows** are durable in the system provider, so capturing them is
 *    belt-and-braces. They are stored anyway because they are cheap and it lets
 *    Dart drain one batch instead of re-scanning.
 *  - **Recording listings are NOT durable.** The OEM dialers on this fleet
 *    rotate their own recordings, and a MediaStore row can disappear before the
 *    user next opens the app. Snapshotting the candidates that existed *at the
 *    time of the call* is the whole reason this runs in the background.
 *
 * Matching logic is deliberately NOT duplicated here. It lives once, in Dart's
 * RecordingMatcher, and runs over these snapshots when the app next starts.
 *
 * Bounded on purpose: a handset left unopened for a fortnight must not grow
 * this without limit. Overflow drops the OLDEST batches and raises a flag, so
 * Dart can tell the difference between "nothing happened" and "we lost some".
 */
object IngestStore {

    private const val PREFS = "call_ingest_store"
    private const val KEY_BATCHES = "batches"
    private const val KEY_CALL_CURSOR = "call_cursor_millis"
    private const val KEY_RECORDING_CURSOR = "recording_cursor_seconds"
    private const val KEY_OVERFLOWED = "overflowed"
    private const val KEY_LAST_RUN_AT = "last_run_at_millis"
    private const val KEY_LAST_RUN_STATUS = "last_run_status"
    private const val KEY_LAST_RUN_REASON = "last_run_reason"
    private const val KEY_RUN_COUNT = "run_count"
    private const val KEY_CAPTURED_CALLS = "captured_calls"

    /** Roughly a fortnight of heavy use; well under the SharedPreferences limit. */
    private const val MAX_BATCHES = 60

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ------------------------------------------------------------- cursors

    fun callCursorMillis(context: Context): Long =
        prefs(context).getLong(KEY_CALL_CURSOR, 0L)

    fun recordingCursorSeconds(context: Context): Long =
        prefs(context).getLong(KEY_RECORDING_CURSOR, 0L)

    // ------------------------------------------------------------- capture

    /**
     * Appends one batch and advances both cursors.
     *
     * Cursors move only to the newest item actually captured, never to "now":
     * a row written to the call log a moment after the query would otherwise be
     * skipped forever.
     */
    fun append(
        context: Context,
        calls: List<Map<String, Any?>>,
        recordings: List<Map<String, Any?>>,
        capturedAtMillis: Long,
    ) {
        if (calls.isEmpty() && recordings.isEmpty()) return

        val p = prefs(context)
        val batches = JSONArray(p.getString(KEY_BATCHES, "[]"))
        batches.put(
            JSONObject()
                .put("capturedAtMillis", capturedAtMillis)
                .put("calls", JSONArray(calls.map { JSONObject(it) }))
                .put("recordings", JSONArray(recordings.map { JSONObject(it) })),
        )

        var overflowed = p.getBoolean(KEY_OVERFLOWED, false)
        val trimmed = if (batches.length() > MAX_BATCHES) {
            overflowed = true
            JSONArray().also { out ->
                for (i in batches.length() - MAX_BATCHES until batches.length()) {
                    out.put(batches.get(i))
                }
            }
        } else {
            batches
        }

        val newestCall = calls
            .mapNotNull { (it["dateMillis"] as? Number)?.toLong() }
            .maxOrNull()
        val newestRecording = recordings
            .mapNotNull { (it["dateAddedEpochSeconds"] as? Number)?.toLong() }
            .maxOrNull()

        p.edit().apply {
            putString(KEY_BATCHES, trimmed.toString())
            putBoolean(KEY_OVERFLOWED, overflowed)
            putInt(KEY_CAPTURED_CALLS, p.getInt(KEY_CAPTURED_CALLS, 0) + calls.size)
            newestCall?.let { putLong(KEY_CALL_CURSOR, maxOf(it, callCursorMillis(context))) }
            newestRecording?.let {
                putLong(KEY_RECORDING_CURSOR, maxOf(it, recordingCursorSeconds(context)))
            }
        }.apply()
    }

    fun recordRun(context: Context, status: String, reason: String) {
        val p = prefs(context)
        p.edit()
            .putLong(KEY_LAST_RUN_AT, System.currentTimeMillis())
            .putString(KEY_LAST_RUN_STATUS, status)
            .putString(KEY_LAST_RUN_REASON, reason)
            .putInt(KEY_RUN_COUNT, p.getInt(KEY_RUN_COUNT, 0) + 1)
            .apply()
    }

    // --------------------------------------------------------------- drain

    fun read(context: Context): Map<String, Any?> {
        val p = prefs(context)
        val batches = JSONArray(p.getString(KEY_BATCHES, "[]"))
        val out = mutableListOf<Map<String, Any?>>()

        for (i in 0 until batches.length()) {
            val b = batches.getJSONObject(i)
            out += mapOf(
                "capturedAtMillis" to b.getLong("capturedAtMillis"),
                "calls" to b.getJSONArray("calls").toMapList(),
                "recordings" to b.getJSONArray("recordings").toMapList(),
            )
        }

        return mapOf(
            "batches" to out,
            "overflowed" to p.getBoolean(KEY_OVERFLOWED, false),
            "lastRunAtMillis" to p.getLong(KEY_LAST_RUN_AT, 0L),
            "lastRunStatus" to p.getString(KEY_LAST_RUN_STATUS, null),
            "lastRunReason" to p.getString(KEY_LAST_RUN_REASON, null),
            "runCount" to p.getInt(KEY_RUN_COUNT, 0),
            "capturedCalls" to p.getInt(KEY_CAPTURED_CALLS, 0),
            "callCursorMillis" to p.getLong(KEY_CALL_CURSOR, 0L),
        )
    }

    /**
     * Drops the batches Dart has folded in. Cursors and run stats survive:
     * clearing them would make the next run re-capture everything.
     */
    fun clearBatches(context: Context) {
        prefs(context).edit()
            .putString(KEY_BATCHES, "[]")
            .putBoolean(KEY_OVERFLOWED, false)
            .apply()
    }

    private fun JSONArray.toMapList(): List<Map<String, Any?>> =
        (0 until length()).map { i ->
            val o = getJSONObject(i)
            o.keys().asSequence().associateWith { k ->
                // JSONObject.NULL is not Kotlin null and would cross the
                // platform channel as an opaque object.
                if (o.isNull(k)) null else o.get(k)
            }
        }
}
