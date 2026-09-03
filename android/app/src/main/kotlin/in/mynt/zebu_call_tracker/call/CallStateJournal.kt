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

    /**
     * The raw transition timestamps belonging to one call-log row.
     *
     * All three are nullable because the receiver only sees what it was alive
     * for. A backfilled call, or one that arrived while the process was dead,
     * yields nulls rather than approximations.
     */
    data class CallWindow(
        val ringingAtMillis: Long?,
        val offHookAtMillis: Long?,
        val idleAtMillis: Long?,
    )

    /** Largest gap between the log's DATE and the matching transition. */
    private const val SEARCH_SKEW_MILLIS = 5_000L

    /** Longest plausible ring, matching RecordingMatcher's own bound. */
    private const val MAX_RING_MILLIS = 180_000L

    /** How far the journal's measured talk time may differ from DURATION. */
    private const val CORROBORATION_TOLERANCE_MILLIS = 5_000L

    /**
     * Locates the `ringing`/`offhook`/`idle` transitions for one call.
     *
     * **`offHookAtMillis` is not an answer time on its own.** For an INCOMING
     * call the sequence is ringing -> offhook -> idle, and offhook is the
     * moment somebody picked up. For an OUTGOING call there is no ringing
     * state at all: offhook fires when dialling *starts*, and the remote party
     * answering produces no broadcast whatsoever. `ACTION_PHONE_STATE_CHANGED`
     * simply cannot report an outgoing answer — that needs precise call state,
     * which is a privileged API. Callers must apply the direction rule
     * themselves; see [in.mynt.zebu_call_tracker.background.NativeCallIngestor].
     *
     * `idleAtMillis` IS the end of the call in both directions.
     *
     * Returns null when nothing in the journal corroborates this call. The
     * result is deliberately all-or-nothing: half a window paired with a
     * guessed other half is how a wrong `answered_at` reaches the server, and
     * the server recomputes `duration_seconds` from the pair it is given.
     */
    fun windowFor(
        context: Context,
        startedAtMillis: Long,
        durationSeconds: Int,
    ): CallWindow? {
        val entries = entries(context)
        if (entries.isEmpty()) return null

        val durationMillis = durationSeconds * 1000L
        val from = startedAtMillis - SEARCH_SKEW_MILLIS
        val until = startedAtMillis + MAX_RING_MILLIS + durationMillis + SEARCH_SKEW_MILLIS

        // The window opens at the first transition of THIS call. Anything
        // earlier belongs to a previous one; the journal is a flat list and
        // carries no call identity of its own.
        val inWindow = entries.filter { it.second in from..until }
        if (inWindow.isEmpty()) return null

        val ringing = inWindow.firstOrNull { it.first == "ringing" }?.second
        val offHook = inWindow.firstOrNull { it.first == "offhook" }?.second
        // The idle that CLOSES the call, so it must come after the pickup.
        val idle = inWindow.firstOrNull {
            it.first == "idle" && (offHook == null || it.second > offHook)
        }?.second

        if (offHook == null || idle == null) return null

        // Corroboration. A call that connected must show a talk period at
        // least as long as DURATION; for an incoming call the two should very
        // nearly agree, while an outgoing call's offhook..idle span also
        // contains the ring, so it may legitimately be much longer.
        val measured = idle - offHook
        if (measured < durationMillis - CORROBORATION_TOLERANCE_MILLIS) {
            // Measured less talk time than the call log reports: these
            // transitions belong to a different call.
            return null
        }
        val isIncoming = ringing != null
        if (isIncoming &&
            measured > durationMillis + CORROBORATION_TOLERANCE_MILLIS
        ) {
            return null
        }
        if (!isIncoming && measured > durationMillis + MAX_RING_MILLIS) {
            return null
        }

        return CallWindow(
            ringingAtMillis = ringing,
            offHookAtMillis = offHook,
            idleAtMillis = idle,
        )
    }

    /** Transitions as (state, atMillis), in the order recorded. */
    private fun entries(context: Context): List<Pair<String, Long>> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val array = JSONArray(prefs.getString(KEY_ENTRIES, "[]"))
        val out = ArrayList<Pair<String, Long>>(array.length())
        for (i in 0 until array.length()) {
            val o = array.optJSONObject(i) ?: continue
            val state = o.optString("state").takeIf { it.isNotEmpty() } ?: continue
            out += state to o.optLong("atMillis")
        }
        return out
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
