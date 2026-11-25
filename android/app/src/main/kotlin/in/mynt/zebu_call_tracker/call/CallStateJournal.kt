package `in`.mynt.zebu_call_tracker.call

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
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
 * log row yet, and answered-vs-missed edge cases), and to measure the ring,
 * which the log does not store at all. It is safe to lose.
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

    /**
     * One recorded transition.
     *
     * [elapsedMillis] is `SystemClock.elapsedRealtime()` and [bootCount] is
     * `Settings.Global.BOOT_COUNT`, both taken with [atMillis]. They are what
     * ring time is measured from (see [RingTimeline]); both are null on
     * entries written by a build that did not record them.
     */
    data class JournalEntry(
        val state: String,
        val atMillis: Long,
        val elapsedMillis: Long?,
        val bootCount: Int?,
    ) {
        fun toEdge() = RingTimeline.Edge(atMillis, elapsedMillis, bootCount)
    }

    fun record(context: Context, state: String, atMillis: Long) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val entries = JSONArray(prefs.getString(KEY_ENTRIES, "[]"))

        entries.put(
            JSONObject()
                .put("state", state)
                .put("atMillis", atMillis)
                .put("elapsed", SystemClock.elapsedRealtime())
                .put("boot", bootCount(context)),
        )

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
            // ingested. Nothing clears it any more — the native ingester's
            // cursor is what tracks catching up — so it only reports that the
            // receiver has run at all.
            .putBoolean(KEY_RECONCILE_PENDING, true)
            .apply()
    }

    /**
     * The device's boot count, or -1 when the platform will not say. -1 never
     * matches anything in [RingTimeline], so an unreadable count costs the
     * ring rather than risking one measured across a reboot.
     */
    fun bootCount(context: Context): Int = try {
        Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)
    } catch (_: Exception) {
        -1
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

    /** Largest gap between the log's DATE and the matching transition. */
    const val SEARCH_SKEW_MILLIS = 5_000L

    /** Longest plausible ring, matching RecordingMatcher's own bound. */
    private const val MAX_RING_MILLIS = 180_000L

    /** How far the journal's measured talk time may differ from DURATION. */
    private const val CORROBORATION_TOLERANCE_MILLIS = 5_000L

    /**
     * Locates the `ringing`/`offhook`/`idle` transitions for one call-log row.
     *
     * Three shapes are recognised:
     *  - ringing → offhook → idle: incoming, answered. offhook is the pickup.
     *  - ringing → idle: incoming, missed or rejected. Only for a row whose
     *    DURATION is 0 — a connected call cannot have skipped offhook.
     *  - offhook → idle, no ringing: outgoing. offhook is when dialling
     *    *started*; the remote party answering produces no broadcast at all
     *    (that needs precise call state, a privileged API), so the answer
     *    instant is not here. [RingTimeline] reconstructs it from DURATION.
     *
     * `idle` IS the end of the call in every shape.
     *
     * Returns null when nothing in the journal corroborates this call. The
     * result is deliberately all-or-nothing: half a window paired with a
     * guessed other half is how a wrong `answered_at` reaches the server, and
     * the server recomputes `duration_seconds` from the pair it is given.
     *
     * Takes the journal already parsed by [snapshot] rather than reading it
     * itself: an ingest pass asks this once per call, and re-parsing the whole
     * JSON blob from SharedPreferences for every row of a 500-call backfill
     * page was pure waste.
     */
    fun edgesFor(
        entries: List<JournalEntry>,
        startedAtMillis: Long,
        durationSeconds: Int,
    ): RingTimeline.Edges? {
        if (entries.isEmpty()) return null

        val durationMillis = durationSeconds * 1000L
        val from = startedAtMillis - SEARCH_SKEW_MILLIS
        val until = startedAtMillis + MAX_RING_MILLIS + durationMillis + SEARCH_SKEW_MILLIS

        // The window opens at the first transition of THIS call. Anything
        // earlier belongs to a previous one; the journal is a flat list and
        // carries no call identity of its own.
        val inWindow = entries.filter { it.atMillis in from..until }
        if (inWindow.isEmpty()) return null

        val ringing = inWindow.firstOrNull { it.state == "ringing" }
        val offHook = inWindow.firstOrNull { it.state == "offhook" }

        if (offHook == null) {
            // Rang and stopped without anyone picking up. Only a call the log
            // also says never connected; anything else means these
            // transitions belong to a different call.
            if (ringing == null || durationSeconds > 0) return null
            val idle = inWindow.firstOrNull {
                it.state == "idle" && it.atMillis > ringing.atMillis
            } ?: return null
            return RingTimeline.Edges(start = ringing.toEdge(), answered = null, idle = idle.toEdge())
        }

        // The idle that CLOSES the call, so it must come after the pickup.
        val idle = inWindow.firstOrNull {
            it.state == "idle" && it.atMillis > offHook.atMillis
        } ?: return null

        // Corroboration. A call that connected must show a talk period at
        // least as long as DURATION; for an incoming call the two should very
        // nearly agree, while an outgoing call's offhook..idle span also
        // contains the ring, so it may legitimately be much longer.
        val measured = idle.atMillis - offHook.atMillis
        if (measured < durationMillis - CORROBORATION_TOLERANCE_MILLIS) {
            // Measured less talk time than the call log reports: these
            // transitions belong to a different call.
            return null
        }
        val isIncoming = ringing != null && ringing.atMillis < offHook.atMillis
        if (isIncoming &&
            measured > durationMillis + CORROBORATION_TOLERANCE_MILLIS
        ) {
            return null
        }
        if (!isIncoming && measured > durationMillis + MAX_RING_MILLIS) {
            return null
        }

        return if (isIncoming) {
            RingTimeline.Edges(start = ringing!!.toEdge(), answered = offHook.toEdge(), idle = idle.toEdge())
        } else {
            RingTimeline.Edges(start = offHook.toEdge(), answered = null, idle = idle.toEdge())
        }
    }

    /**
     * Transitions in the order recorded. Parse once per pass and hand the
     * result to [edgesFor].
     */
    fun snapshot(context: Context): List<JournalEntry> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val array = JSONArray(prefs.getString(KEY_ENTRIES, "[]"))
        val out = ArrayList<JournalEntry>(array.length())
        for (i in 0 until array.length()) {
            val o = array.optJSONObject(i) ?: continue
            val state = o.optString("state").takeIf { it.isNotEmpty() } ?: continue
            out += JournalEntry(
                state = state,
                atMillis = o.optLong("atMillis"),
                elapsedMillis = if (o.has("elapsed")) o.optLong("elapsed") else null,
                bootCount = if (o.has("boot")) o.optInt("boot") else null,
            )
        }
        return out
    }

    /**
     * The wall-clock time of the oldest entry that can still be measured
     * against (it carries elapsed time and a boot count), or null when there
     * is none. Rows older than this cannot gain a ring time from the journal.
     */
    fun oldestMeasurableMillis(entries: List<JournalEntry>): Long? =
        entries.filter { it.elapsedMillis != null && it.bootCount != null }
            .minOfOrNull { it.atMillis }
}
