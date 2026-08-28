package `in`.mynt.zebu_call_tracker.recording

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import android.content.pm.PackageManager
import java.security.MessageDigest

/**
 * DISCOVERS recordings that already exist on the device. It does not create
 * them — this app has no recording engine.
 *
 * Reads through MediaStore rather than the filesystem. That choice is the whole
 * reason this feature is viable:
 *
 *  - /sdcard/Recordings/Call is owned by the system dialer's uid and is mode
 *    drwxrws--- , so File.listFiles() returns EMPTY for a normal app under
 *    scoped storage. (Verified on SM-M356B/Android 16: canRead() reported true
 *    while listFiles() returned nothing — a silently wrong answer.)
 *  - The same files ARE indexed in MediaStore.Audio, complete with DURATION,
 *    SIZE, DATE_ADDED and DATE_MODIFIED — exactly the signals the matcher needs.
 *  - MediaStore access needs READ_MEDIA_AUDIO (a normal runtime permission on
 *    API 33+), NOT MANAGE_EXTERNAL_STORAGE. That keeps the app out of
 *    all-files-access territory entirely.
 *
 * If the device's dialer is not recording, this simply yields nothing. That is
 * a valid outcome, not an error.
 */
object RecordingScanner {

    /**
     * Folders OEM dialers write call recordings into, as MediaStore
     * RELATIVE_PATH prefixes. Add to this list per OEM; unknown devices fall
     * back to [NAME_HINTS].
     */
    private val CALL_RECORDING_PATHS = listOf(
        "Recordings/Call/",              // Samsung (One UI 5+)
        "Sounds/CallRecord/",            // Samsung (legacy)
        "MIUI/sound_recorder/call_rec/", // Xiaomi
        "Record/Call/",                  // Oppo / Realme / OnePlus
        "PhoneRecord/",                  // Vivo
        "Recordings/Calls/",             // Pixel (where permitted by region)
    )

    /**
     * Filename hints, used ONLY to widen discovery on an OEM we have not mapped.
     * Matching a recording to a call NEVER relies on the filename — see
     * RecordingMatcher on the Dart side. Filename formats are unstable even
     * within one vendor: this device carries both
     * "Call recording <name>_YYMMDD_HHMMSS.m4a" (2025 builds) and
     * "Call <name>_YYMMDD_HHMMSS.m4a" (2026 builds).
     */
    private val NAME_HINTS = listOf("Call recording%", "Call %", "%callrec%")

    private val PROJECTION = arrayOf(
        MediaStore.Audio.Media._ID,
        MediaStore.Audio.Media.DISPLAY_NAME,
        MediaStore.Audio.Media.RELATIVE_PATH,
        MediaStore.Audio.Media.DURATION,
        MediaStore.Audio.Media.SIZE,
        MediaStore.Audio.Media.DATE_ADDED,
        MediaStore.Audio.Media.DATE_MODIFIED,
        MediaStore.Audio.Media.MIME_TYPE,
    )

    class MissingPermission : SecurityException("READ_MEDIA_AUDIO not granted")

    /** The runtime permission this scanner needs, by OS version. */
    fun requiredPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            "android.permission.READ_MEDIA_AUDIO"
        } else {
            "android.permission.READ_EXTERNAL_STORAGE"
        }

    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, requiredPermission()) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Incremental by DATE_ADDED, mirroring the call-log cursor. A device
     * carrying thousands of recordings is never re-enumerated in full.
     *
     * @param sinceEpochSeconds exclusive lower bound on DATE_ADDED. MediaStore
     *        stores this in SECONDS, unlike the call log's milliseconds — a
     *        units mismatch here silently returns everything or nothing, so the
     *        Dart side converts once, explicitly.
     */
    fun scan(context: Context, sinceEpochSeconds: Long, limit: Int): List<Map<String, Any?>> {
        if (!hasPermission(context)) throw MissingPermission()

        val where = StringBuilder("(")
        val args = mutableListOf<String>()

        CALL_RECORDING_PATHS.forEachIndexed { i, p ->
            if (i > 0) where.append(" OR ")
            where.append("${MediaStore.Audio.Media.RELATIVE_PATH} LIKE ?")
            args += "$p%"
        }
        NAME_HINTS.forEach { hint ->
            where.append(" OR ${MediaStore.Audio.Media.DISPLAY_NAME} LIKE ?")
            args += hint
        }
        where.append(") AND ${MediaStore.Audio.Media.DATE_ADDED} > ?")
        args += sinceEpochSeconds.toString()

        val rows = mutableListOf<Map<String, Any?>>()
        val sort = "${MediaStore.Audio.Media.DATE_ADDED} DESC"

        // The row cap must NOT be appended to the sort order. Like the call-log
        // provider, MediaStore validates the sort clause and rejects a trailing
        // "LIMIT n" on modern Android. From API 30 the supported mechanism is a
        // query-args Bundle with QUERY_ARG_LIMIT; below that, the legacy inline
        // form is still accepted.
        val cursor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val queryArgs = Bundle().apply {
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, where.toString())
                putStringArray(
                    ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS,
                    args.toTypedArray(),
                )
                putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, sort)
                putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
            }
            context.contentResolver.query(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                PROJECTION,
                queryArgs,
                null,
            )
        } else {
            context.contentResolver.query(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                PROJECTION,
                where.toString(),
                args.toTypedArray(),
                "$sort LIMIT $limit",
            )
        }

        cursor?.use { c ->
            while (c.moveToNext()) rows += mapRow(c)
        }
        return rows
    }

    private fun mapRow(c: Cursor): Map<String, Any?> {
        val id = c.getLongOrNull(MediaStore.Audio.Media._ID)
        return mapOf(
            "mediaStoreId" to id,
            // Kept for display and as ONE weak matching signal among several.
            "displayName" to c.getStringOrNull(MediaStore.Audio.Media.DISPLAY_NAME),
            "relativePath" to c.getStringOrNull(MediaStore.Audio.Media.RELATIVE_PATH),
            // Milliseconds.
            "durationMillis" to c.getLongOrNull(MediaStore.Audio.Media.DURATION),
            "sizeBytes" to c.getLongOrNull(MediaStore.Audio.Media.SIZE),
            // SECONDS (MediaStore convention).
            "dateAddedEpochSeconds" to c.getLongOrNull(MediaStore.Audio.Media.DATE_ADDED),
            "dateModifiedEpochSeconds" to c.getLongOrNull(MediaStore.Audio.Media.DATE_MODIFIED),
            "mimeType" to c.getStringOrNull(MediaStore.Audio.Media.MIME_TYPE),
            "source" to inferSource(c.getStringOrNull(MediaStore.Audio.Media.RELATIVE_PATH)),
        )
    }

    /** Maps the storage location onto the backend's recording `source` enum. */
    private fun inferSource(relativePath: String?): String = when {
        relativePath == null -> "UNKNOWN"
        CALL_RECORDING_PATHS.any { relativePath.startsWith(it) } -> "OEM_RECORDER"
        else -> "UNKNOWN"
    }

    private fun uriFor(id: Long): Uri =
        ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)

    /**
     * Streaming SHA-256 over the content URI. Computed natively and never in
     * Dart: these files run to several megabytes (3.4 GB across 1863 files on
     * the reference device), and pulling the bytes across the platform channel
     * just to hash them would be wasteful and memory-hostile.
     *
     * Returns null if the file has vanished — the user may delete a recording
     * between scan and upload, which is normal and must not throw.
     */
    fun sha256(context: Context, mediaStoreId: Long): Map<String, Any?>? {
        if (!hasPermission(context)) throw MissingPermission()
        return try {
            context.contentResolver.openInputStream(uriFor(mediaStoreId))?.use { input ->
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                    total += read
                }
                mapOf(
                    "checksum" to digest.digest().joinToString("") { "%02x".format(it) },
                    // Server-side size is authoritative, but returning what we
                    // actually read lets the uploader detect a truncated file
                    // before spending bandwidth on it.
                    "bytesRead" to total,
                )
            }
        } catch (e: java.io.FileNotFoundException) {
            null
        }
    }

    private fun Cursor.getStringOrNull(column: String): String? =
        getColumnIndex(column).takeIf { it >= 0 }?.let { if (isNull(it)) null else getString(it) }

    private fun Cursor.getLongOrNull(column: String): Long? =
        getColumnIndex(column).takeIf { it >= 0 }?.let { if (isNull(it)) null else getLong(it) }

    /**
     * The playable content:// URI for a scanned recording.
     *
     * Playback goes through this rather than a filesystem path on purpose:
     * /sdcard/Recordings/Call is owned by the dialer's uid and is not
     * world-readable, so a File path would be unopenable even with the media
     * permission held. The MediaStore URI is, and ExoPlayer resolves it
     * directly — so nothing has to be copied out to play it.
     *
     * Returns the URI without checking the row still exists: the file can be
     * deleted between this call and playback either way, so the player treats a
     * failed open as "recording is gone" and says so.
     */
    fun contentUri(mediaStoreId: Long): String =
        ContentUris.withAppendedId(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            mediaStoreId,
        ).toString()
}
