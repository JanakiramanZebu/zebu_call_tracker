package `in`.mynt.zebu_call_tracker.call

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * Durable, tiny journal of raw phone-state transitions seen by the background
 * receiver, drained by Dart on next start/resume.
 *
 * Why this can be so small: THE CALL LOG IS ITSELF DURABLE STORAGE. If the app
 * is killed and never runs for a day, no call data is lost — the cursor-based
 * CallLogReader catches up whenever Dart next runs. Background execution only
 * buys us *upload timeliness*, never data preservation. So this journal exists
 * purely to disambiguate cases the log alone is weak at (RINGING->IDLE with no
 * log row yet, and answered-vs-missed edge cases), and it is safe to lose.
 *
 * Bounded on purpose: an app left unopened for weeks must not grow this
 * unboundedly. Overflow drops the OLDEST entries and raises a flag, because the
 * newest transitions are the ones still awaiting a log row.
 */
object CallStateJournal {

    private const val PREFS = "call_state_journal"
    private const val KEY_ENTRIES = "entries"
    private const val KEY_OVERFLOWED = "overflowed"
    private const val KEY_RECONCILE_PENDING = "reconcile_pending"
    private const val MAX_ENTRIES = 200

    fun record(context: Context, state: String, atMillis: Long) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val entries = JSONArray(prefs.getString(KEY_ENTRIES, "[]"))

        entries.put(JSONObject().put("state", state).put("atMillis", atMillis))

        var overflowed = prefs.getBoolean(KEY_OVERFLOWED, false)
        val trimmed = if (entries.length() > MAX_ENTRIES) {
            overflowed = true
            JSONArray().also { out ->
                for (i in entries.length() - MAX_ENTRIES until entries.length()) {
                    out.put(entries.get(i))
                }
            }
        } else {
            entries
        }

        prefs.edit()
            .putString(KEY_ENTRIES, trimmed.toString())
            .putBoolean(KEY_OVERFLOWED, overflowed)
            // Any transition means the log may have gained a row we have not
            // ingested. Dart clears this once its cursor has caught up.
            .putBoolean(KEY_RECONCILE_PENDING, true)
            .apply()
    }

    fun read(context: Context): Map<String, Any?> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val entries = JSONArray(prefs.getString(KEY_ENTRIES, "[]"))
        val out = mutableListOf<Map<String, Any?>>()
        for (i in 0 until entries.length()) {
            val o = entries.getJSONObject(i)
            out += mapOf("state" to o.getString("state"), "atMillis" to o.getLong("atMillis"))
        }
        return mapOf(
            "entries" to out,
            "overflowed" to prefs.getBoolean(KEY_OVERFLOWED, false),
            "reconcilePending" to prefs.getBoolean(KEY_RECONCILE_PENDING, false),
        )
    }

    /** Called by Dart only after the transitions have been folded into the DB. */
    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_ENTRIES, "[]")
            .putBoolean(KEY_OVERFLOWED, false)
            .putBoolean(KEY_RECONCILE_PENDING, false)
            .apply()
    }
}
