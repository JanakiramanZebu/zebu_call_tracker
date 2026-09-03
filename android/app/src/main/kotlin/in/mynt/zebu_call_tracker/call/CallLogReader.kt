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
 *
 * [beforeMillis] adds the other half — keyset pagination for the history list.
 * Paging by growing [limit] and discarding the prefix re-reads (and re-parses)
 * every earlier page, which is quadratic in the number of pages; asking for
 * "older than the oldest row I already have" reads each row exactly once and is
 * immune to rows being appended between pages.
 */
object CallLogReader {

    /**
     * Columns we actually consume.
     *
     * This used to be eight columns, "kept minimal on purpose (privacy +
     * speed)". That was the wrong trade once the server gained a `metadata`
     * bag: the narrow projection was not protecting anything, it was just
     * discarding facts about a call that the record is incomplete without —
     * whether it was a video call, which SIM really carried it, why a number
     * was blocked. Every column below is a property of a call this app is
     * already authorised to read in full.
     *
     * Cost is negligible: these are columns of rows the provider is already
     * materialising, not extra queries.
     *
     * Deliberately still NOT read:
     *  - `TRANSCRIPTION` — voicemail *content*, a different consent question
     *    from call metadata. Out of scope until someone asks for it explicitly.
     *  - `IS_READ` / `NEW` — dialer UI state, meaningless off the device.
     *
     * All of these exist at or below API 24, which is `minSdk`.
     */
    private val PROJECTION = arrayOf(
        CallLog.Calls._ID,
        CallLog.Calls.NUMBER,
        CallLog.Calls.CACHED_NAME,
        CallLog.Calls.TYPE,
        CallLog.Calls.DATE,
        CallLog.Calls.DURATION,
        CallLog.Calls.PHONE_ACCOUNT_ID,
        CallLog.Calls.NUMBER_PRESENTATION,
        // Disambiguates PHONE_ACCOUNT_ID, which is frequently an opaque ICCID
        // or null. Without it a dual-SIM call can be attributed to the wrong
        // line — see SimInfoReader.slotForAccountId.
        CallLog.Calls.PHONE_ACCOUNT_COMPONENT_NAME,
        CallLog.Calls.GEOCODED_LOCATION,
        CallLog.Calls.COUNTRY_ISO,
        // Bitmask: video / HD / WiFi / RTT. Decoded in featureFlags().
        CallLog.Calls.FEATURES,
        CallLog.Calls.DATA_USAGE,
        CallLog.Calls.VIA_NUMBER,
        CallLog.Calls.POST_DIAL_DIGITS,
        CallLog.Calls.BLOCK_REASON,
        // "mobile" / "work" / a user-defined label, for the matched contact.
        CallLog.Calls.CACHED_NUMBER_TYPE,
        CallLog.Calls.CACHED_NUMBER_LABEL,
    )

    // CallLog.Calls.FEATURES_* bits. Written out rather than referenced because
    // the constants arrived across several API levels (HD_CALL and WIFI at 26,
    // RTT at 28, VOLTE at 30) while the FEATURES *column* has been readable
    // since 21. The bit values are part of the provider's stored format and do
    // not change; naming them here keeps the decode working on every level we
    // support without a version ladder.
    private const val FEATURE_VIDEO = 0x1
    private const val FEATURE_PULLED_EXTERNALLY = 0x2
    private const val FEATURE_HD_CALL = 0x4
    private const val FEATURE_WIFI = 0x8
    private const val FEATURE_ASSISTED_DIALING = 0x10
    private const val FEATURE_RTT = 0x20
    private const val FEATURE_VOLTE = 0x40

    class MissingPermission : SecurityException("READ_CALL_LOG not granted")

    /**
     * @param sinceMillis exclusive lower bound on CallLog.Calls.DATE (epoch ms,
     *        device local clock). Pass 0 for a first-run backfill.
     * @param beforeMillis exclusive UPPER bound, for paging backwards through
     *        history. Pass 0 (or null from Dart) for "no upper bound".
     */
    fun read(
        context: Context,
        sinceMillis: Long,
        limit: Int,
        beforeMillis: Long = 0L,
    ): List<Map<String, Any?>> {
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

        // Both bounds go in the selection so the provider filters at the SQL
        // layer; filtering in Kotlin would defeat LIMIT_PARAM_KEY entirely.
        val selection = StringBuilder("${CallLog.Calls.DATE} > ?")
        val args = mutableListOf(sinceMillis.toString())
        if (beforeMillis > 0L) {
            selection.append(" AND ${CallLog.Calls.DATE} < ?")
            args += beforeMillis.toString()
        }

        context.contentResolver.query(
            uri,
            PROJECTION,
            selection.toString(),
            args.toTypedArray(),
            "${CallLog.Calls.DATE} DESC",
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                rows += mapRow(cursor)
            }
        }
        return rows
    }

    /**
     * Every call with [number], newest first — the history shown on a call's
     * detail screen.
     *
     * Matched on the LAST TEN DIGITS rather than the stored string. The same
     * person appears in the log as +919739787538, 09739787538 and 9739787538
     * depending on how each call was placed, and an equality test would split
     * one contact's history into three. Ten digits is the Indian subscriber
     * number; comparing more would reintroduce the prefix problem.
     *
     * The provider has no "strip non-digits" function, so the comparison is a
     * LIKE against the tail. That is a suffix match on an unindexed column, but
     * it is bounded by [limit] and runs once per detail screen, not per row.
     */
    fun readForNumber(context: Context, number: String, limit: Int): List<Map<String, Any?>> {
        if (!PermissionInspector.isGranted(context, PermissionInspector.CALL_LOG)) {
            throw MissingPermission()
        }

        val digits = number.filter { it.isDigit() }
        if (digits.length < MIN_MATCHABLE_DIGITS) return emptyList()
        val tail = digits.takeLast(SUBSCRIBER_DIGITS)

        val uri = CallLog.Calls.CONTENT_URI.buildUpon()
            .appendQueryParameter(CallLog.Calls.LIMIT_PARAM_KEY, limit.toString())
            .build()

        val rows = mutableListOf<Map<String, Any?>>()
        context.contentResolver.query(
            uri,
            PROJECTION,
            "${CallLog.Calls.NUMBER} LIKE ?",
            arrayOf("%$tail"),
            "${CallLog.Calls.DATE} DESC",
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                rows += mapRow(cursor)
            }
        }
        return rows
    }

    /** Below this a "number" is a service code or withheld — not a contact. */
    private const val MIN_MATCHABLE_DIGITS = 7
    private const val SUBSCRIBER_DIGITS = 10

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
            "phoneAccountComponent" to
                c.getStringOrNull(CallLog.Calls.PHONE_ACCOUNT_COMPONENT_NAME),
            "geocodedLocation" to c.getStringOrNull(CallLog.Calls.GEOCODED_LOCATION),
            "countryIso" to c.getStringOrNull(CallLog.Calls.COUNTRY_ISO),
            // A list rather than the raw bitmask: the number means nothing to a
            // reader of the server record, and the bit layout is Android's to
            // change. Empty list for a plain voice call.
            "features" to featureFlags(c.getIntOrNull(CallLog.Calls.FEATURES)),
            "dataUsageBytes" to c.getLongOrNull(CallLog.Calls.DATA_USAGE),
            // The number dialled THROUGH, on a multi-line/SIP account.
            "viaNumber" to c.getStringOrNull(CallLog.Calls.VIA_NUMBER),
            "postDialDigits" to c.getStringOrNull(CallLog.Calls.POST_DIAL_DIGITS),
            "blockReason" to blockReasonName(c.getIntOrNull(CallLog.Calls.BLOCK_REASON)),
            "numberLabel" to numberTypeLabel(
                c.getIntOrNull(CallLog.Calls.CACHED_NUMBER_TYPE),
                c.getStringOrNull(CallLog.Calls.CACHED_NUMBER_LABEL),
            ),
        )
    }

    /** Set bits of [CallLog.Calls.FEATURES], as names. Null/0 yields empty. */
    private fun featureFlags(value: Int?): List<String> {
        if (value == null || value == 0) return emptyList()
        val out = mutableListOf<String>()
        if (value and FEATURE_VIDEO != 0) out += "video"
        if (value and FEATURE_PULLED_EXTERNALLY != 0) out += "pulled_externally"
        if (value and FEATURE_HD_CALL != 0) out += "hd"
        if (value and FEATURE_WIFI != 0) out += "wifi"
        if (value and FEATURE_ASSISTED_DIALING != 0) out += "assisted_dialing"
        if (value and FEATURE_RTT != 0) out += "rtt"
        if (value and FEATURE_VOLTE != 0) out += "volte"
        return out
    }

    /**
     * Why the platform blocked a call, if it did.
     *
     * Returns null for the overwhelmingly common "not blocked" (0) so the field
     * is absent from the payload rather than present and boring. Mapped from
     * raw ints because the `BLOCK_REASON_*` constants landed at API 30 while
     * the column itself is readable from 24.
     */
    private fun blockReasonName(value: Int?): String? = when (value) {
        null, 0 -> null
        1 -> "unknown"
        2 -> "restricted_mode"
        3 -> "blocked_number"
        4 -> "call_screening_service"
        5 -> "direct_to_voicemail"
        6 -> "not_in_contacts"
        7 -> "pay_phone"
        8 -> "unknown_number"
        else -> "other"
    }

    /**
     * The contact's label for this number — "mobile", "work", or whatever the
     * user typed for a CUSTOM entry.
     */
    private fun numberTypeLabel(type: Int?, custom: String?): String? = when (type) {
        null -> null
        1 -> "home"
        2 -> "mobile"
        3 -> "work"
        4 -> "fax_work"
        5 -> "fax_home"
        6 -> "pager"
        7 -> "other"
        0 -> custom?.takeIf { it.isNotBlank() }
        else -> custom?.takeIf { it.isNotBlank() } ?: "other"
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
