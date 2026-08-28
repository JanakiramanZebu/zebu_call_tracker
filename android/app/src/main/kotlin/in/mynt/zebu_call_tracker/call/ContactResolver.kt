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
 *
 * [resolveBatch] exists because the call list resolves a name per row: doing
 * that one platform round-trip at a time cost sixty channel hops and sixty
 * provider queries to paint one page. Batching collapses it to a single hop,
 * and the cache means the repeat callers that dominate a real call log are
 * looked up once per process rather than once per appearance.
 */
object ContactResolver {

    /**
     * Bounded so a long scroll cannot pin an unbounded map, and cleared when
     * the app is signed out. A null value is cached too — "this number is not
     * in Contacts" is an expensive answer to recompute.
     */
    private const val CACHE_LIMIT = 500
    private val cache = object : LinkedHashMap<String, String?>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: Map.Entry<String, String?>) =
            size > CACHE_LIMIT
    }

    /**
     * Resolves many numbers in one call. Returns only the numbers that matched,
     * so the Dart side can treat a missing key as "no name" without carrying
     * nulls across the channel.
     */
    fun resolveBatch(context: Context, numbers: List<String>): Map<String, String> {
        if (!PermissionInspector.isGranted(context, PermissionInspector.CONTACTS)) {
            return emptyMap()
        }

        val out = HashMap<String, String>(numbers.size)
        for (number in numbers.distinct()) {
            if (number.isBlank()) continue

            var cached = false
            var name: String? = null
            synchronized(cache) {
                cached = cache.containsKey(number)
                if (cached) name = cache[number]
            }

            if (!cached) {
                name = resolve(context, number)
                synchronized(cache) { cache[number] = name }
            }

            name?.let { out[number] = it }
        }
        return out
    }

    /** Dropped on sign-out: the next user must not see the previous one's names. */
    fun clearCache() {
        synchronized(cache) { cache.clear() }
    }

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
