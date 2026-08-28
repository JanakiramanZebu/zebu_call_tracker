package `in`.mynt.zebu_call_tracker.call

import android.content.Context
import android.net.Uri
import android.provider.ContactsContract
import `in`.mynt.zebu_call_tracker.permissions.PermissionInspector

/**
 * Resolves a phone number to a local contact name.
 *
 * PhoneLookup does the number matching itself, so it tolerates formatting
 * differences (+91 vs 0 vs spaced) without us normalising first. Denial of
 * READ_CONTACTS is NOT an error: the call record keeps its number and simply
 * carries a null contactName.
 */
object ContactResolver {

    fun resolve(context: Context, number: String?): String? {
        if (number.isNullOrBlank()) return null
        if (!PermissionInspector.isGranted(context, PermissionInspector.CONTACTS)) return null

        val uri: Uri = Uri.withAppendedPath(
            ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
            Uri.encode(number),
        )
        return try {
            context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null
            }
        } catch (e: SecurityException) {
            null
        }
    }
}
