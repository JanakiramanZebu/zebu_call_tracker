package `in`.mynt.zebu_call_tracker.call

import android.content.Context
import android.database.Cursor
import android.provider.CallLog
import `in`.mynt.zebu_call_tracker.permissions.PermissionInspector

/**
 * Reads the system call log incrementally.
 *
 * This is the AUTHORITATIVE source for a finished call. The PHONE_STATE
 * broadcast is only an early trigger: it is delayed, duplicated and reordered
 * in practice and carries no duration. Everything durable (number, direction,
 * duration, final status) is taken from here.
 *
 * Incremental by contract: callers pass the highest DATE already ingested and
 * we return strictly newer rows, newest first, bounded by [limit]. The whole
 * history is never re-read.
 */
object CallLogReader {

    /** Columns we actually consume. Kept minimal on purpose (privacy + speed). */
    private val PROJECTION = arrayOf(
        CallLog.Calls._ID,
        CallLog.Calls.NUMBER,
        CallLog.Calls.CACHED_NAME,
        CallLog.Calls.TYPE,
        CallLog.Calls.DATE,
        CallLog.Calls.DURATION,
        CallLog.Calls.PHONE_ACCOUNT_ID,
        CallLog.Calls.NUMBER_PRESENTATION,
    )

    class MissingPermission : SecurityException("READ_CALL_LOG not granted")

    /**
     * @param sinceMillis exclusive lower bound on CallLog.Calls.DATE (epoch ms,
     *        device local clock). Pass 0 for a first-run backfill.
     */
    fun read(context: Context, sinceMillis: Long, limit: Int): List<Map<String, Any?>> {
        if (!PermissionInspector.isGranted(context, PermissionInspector.CALL_LOG)) {
            throw MissingPermission()
        }

        val rows = mutableListOf<Map<String, Any?>>()

        // The row cap goes in the URI, NOT in the sort order.
        // "DATE DESC LIMIT n" is rejected by the call-log provider on modern
        // Android with "Invalid token LIMIT" — the provider validates the sort
        // clause against SQL injection and refuses the trailing LIMIT.
        // CallLog.Calls.LIMIT_PARAM_KEY is the supported mechanism, and it
        // still caps at the SQL layer, so a device with tens of thousands of
        // rows never materialises them all.
        val uri = CallLog.Calls.CONTENT_URI.buildUpon()
            .appendQueryParameter(CallLog.Calls.LIMIT_PARAM_KEY, limit.toString())
            .build()

        context.contentResolver.query(
            uri,
            PROJECTION,
            "${CallLog.Calls.DATE} > ?",
            arrayOf(sinceMillis.toString()),
            "${CallLog.Calls.DATE} DESC",
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                rows += mapRow(cursor)
            }
        }
        return rows
    }

    /** Total row count, for the capability probe / first-run backfill estimate. */
    fun count(context: Context): Int {
        if (!PermissionInspector.isGranted(context, PermissionInspector.CALL_LOG)) {
            throw MissingPermission()
        }
        context.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls._ID),
            null,
            null,
            null,
        )?.use { return it.count }
        return 0
    }

    private fun mapRow(c: Cursor): Map<String, Any?> {
        val presentation = c.getIntOrNull(CallLog.Calls.NUMBER_PRESENTATION)
        val rawNumber = c.getStringOrNull(CallLog.Calls.NUMBER)

        return mapOf(
            "systemId" to c.getLongOrNull(CallLog.Calls._ID),
            // Withheld / payphone / unknown numbers legitimately have no digits.
            // We surface presentation so the Dart layer can store `unknown`
            // rather than dropping the call record entirely.
            "number" to if (presentation == CallLog.Calls.PRESENTATION_ALLOWED) rawNumber else null,
            "presentation" to presentationName(presentation),
            "cachedName" to c.getStringOrNull(CallLog.Calls.CACHED_NAME),
            "type" to typeName(c.getIntOrNull(CallLog.Calls.TYPE)),
            "dateMillis" to c.getLongOrNull(CallLog.Calls.DATE),
            "durationSeconds" to c.getLongOrNull(CallLog.Calls.DURATION),
            // Maps to a SubscriptionInfo.subscriptionId on multi-SIM devices.
            // Frequently null or an opaque ICCID string depending on OEM.
            "phoneAccountId" to c.getStringOrNull(CallLog.Calls.PHONE_ACCOUNT_ID),
        )
    }

    private fun presentationName(value: Int?): String = when (value) {
        CallLog.Calls.PRESENTATION_ALLOWED -> "allowed"
        CallLog.Calls.PRESENTATION_RESTRICTED -> "restricted"
        CallLog.Calls.PRESENTATION_PAYPHONE -> "payphone"
        CallLog.Calls.PRESENTATION_UNKNOWN -> "unknown"
        else -> "unknown"
    }

    private fun typeName(value: Int?): String = when (value) {
        CallLog.Calls.INCOMING_TYPE -> "incoming"
        CallLog.Calls.OUTGOING_TYPE -> "outgoing"
        CallLog.Calls.MISSED_TYPE -> "missed"
        CallLog.Calls.VOICEMAIL_TYPE -> "voicemail"
        CallLog.Calls.REJECTED_TYPE -> "rejected"
        CallLog.Calls.BLOCKED_TYPE -> "blocked"
        else -> "unknown"
    }

    private fun Cursor.getStringOrNull(column: String): String? =
        getColumnIndex(column).takeIf { it >= 0 }?.let { if (isNull(it)) null else getString(it) }

    private fun Cursor.getLongOrNull(column: String): Long? =
        getColumnIndex(column).takeIf { it >= 0 }?.let { if (isNull(it)) null else getLong(it) }

    private fun Cursor.getIntOrNull(column: String): Int? =
        getColumnIndex(column).takeIf { it >= 0 }?.let { if (isNull(it)) null else getInt(it) }
}
