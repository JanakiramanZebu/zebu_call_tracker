package `in`.mynt.zebu_call_tracker.background

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log
import java.io.File

/**
 * Data structure representing a single call row in SQLite outbox queue.
 */
data class CallRecord(
    val localId: Long,
    val idempotencyKey: String,
    val externalCallId: String?,
    val serverCallId: String?,
    val phoneNumber: String,
    val contactName: String?,
    val direction: String,
    val status: String,
    val startedAtMillis: Long,
    val durationSeconds: Int,
    val hasRecording: Boolean,
    val recordingPath: String?,
    val recordingMediaStoreId: Long?,
    val recordingChecksum: String?,
    val recordingUploadStatus: String,
    val simSlot: Int,
    val attemptCount: Int,
    val syncState: String,
)

/**
 * Managed Thread-Safe SQLite OpenHelper Singleton.
 * Ensures consistent WAL configuration, 10s busy timeouts, and shared connection caching.
 */
class ZebuDatabaseHelper private constructor(context: Context, dbPath: String) : SQLiteOpenHelper(
    context.applicationContext,
    dbPath,
    null,
    DATABASE_VERSION
) {
    override fun onConfigure(db: SQLiteDatabase) {
        super.onConfigure(db)
        try {
            db.enableWriteAheadLogging()
            db.execSQL("PRAGMA busy_timeout=10000;")
            db.execSQL("PRAGMA synchronous=NORMAL;")
        } catch (e: Exception) {
            Log.w(TAG, "Failed configuring SQLite pragmas: ${e.message}")
        }
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS local_calls (
                local_id INTEGER PRIMARY KEY AUTOINCREMENT,
                idempotency_key TEXT NOT NULL UNIQUE,
                external_call_id TEXT,
                server_call_id TEXT,
                revision INTEGER NOT NULL DEFAULT 0,
                phone_number TEXT NOT NULL,
                normalized_phone_number TEXT,
                contact_name TEXT,
                direction TEXT NOT NULL,
                status TEXT NOT NULL,
                started_at INTEGER NOT NULL,
                answered_at INTEGER,
                ended_at INTEGER,
                duration_seconds INTEGER NOT NULL DEFAULT 0,
                has_recording INTEGER NOT NULL DEFAULT 0,
                recording_path TEXT,
                recording_media_store_id INTEGER,
                recording_checksum TEXT,
                recording_upload_status TEXT NOT NULL DEFAULT 'pending',
                sim_slot INTEGER DEFAULT 1,
                client_created_at INTEGER NOT NULL,
                sync_state TEXT NOT NULL DEFAULT 'pending',
                attempt_count INTEGER NOT NULL DEFAULT 0,
                next_attempt_at INTEGER,
                last_error_code TEXT
            );
            """.trimIndent()
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Safe additive migrations if schema version increments
    }

    companion object {
        private const val TAG = "ZebuDatabaseHelper"
        private const val DATABASE_VERSION = 1

        @Volatile
        private var instance: ZebuDatabaseHelper? = null

        fun getInstance(context: Context): ZebuDatabaseHelper {
            return instance ?: synchronized(this) {
                instance ?: run {
                    val dbFile = NativeCallOutboxDao.getDatabaseFile(context)
                    ZebuDatabaseHelper(context.applicationContext, dbFile.absolutePath).also { instance = it }
                }
            }
        }
    }
}

/**
 * Native Kotlin SQLite Outbox Data Access Object.
 *
 * Interacts directly with the shared SQLite database (`zebu_calls.sqlite`)
 * maintained by the application outbox system.
 *
 * Enforces Write-Ahead Logging (WAL Mode), busy timeouts, thread serialization,
 * and database integrity verification to prevent SQLite corruption.
 */
object NativeCallOutboxDao {

    private const val TAG = "NativeCallOutboxDao"
    private const val DB_NAME = "zebu_calls.sqlite"
    private const val TABLE_LOCAL_CALLS = "local_calls"

    private val dbLock = Any()

    /**
     * Resolves the physical database file location.
     * Supports standard Android app databases and Flutter app_flutter directory.
     */
    fun getDatabaseFile(context: Context): File {
        val flutterAppDb = File(context.filesDir.parentFile, "app_flutter/$DB_NAME")
        if (flutterAppDb.exists()) return flutterAppDb

        val standardDb = context.getDatabasePath(DB_NAME)
        if (standardDb.exists()) return standardDb

        val filesDb = File(context.filesDir, DB_NAME)
        if (filesDb.exists()) return filesDb

        flutterAppDb.parentFile?.mkdirs()
        return flutterAppDb
    }

    private fun getWritableDb(context: Context): SQLiteDatabase? {
        return try {
            ZebuDatabaseHelper.getInstance(context).writableDatabase
        } catch (e: Exception) {
            Log.e(TAG, "Error obtaining writable database: ${e.message}")
            checkAndRepairDatabase(context)
            try {
                ZebuDatabaseHelper.getInstance(context).writableDatabase
            } catch (e2: Exception) {
                Log.e(TAG, "Failed second attempt for writable database: ${e2.message}")
                null
            }
        }
    }

    private fun getReadableDb(context: Context): SQLiteDatabase? {
        return try {
            ZebuDatabaseHelper.getInstance(context).readableDatabase
        } catch (e: Exception) {
            Log.e(TAG, "Error obtaining readable database: ${e.message}")
            null
        }
    }

    /**
     * Checks database integrity using PRAGMA integrity_check.
     * Rebuilds indexes via REINDEX if malformed, keeping raw records safe.
     */
    fun checkAndRepairDatabase(context: Context): Boolean = synchronized(dbLock) {
        val file = getDatabaseFile(context)
        if (!file.exists()) return true

        return try {
            val db = ZebuDatabaseHelper.getInstance(context).writableDatabase
            val cursor = db.rawQuery("PRAGMA integrity_check;", null)
            var resultStr = "unknown"
            if (cursor.moveToFirst()) {
                resultStr = cursor.getString(0) ?: "unknown"
            }
            cursor.close()

            if (resultStr == "ok") {
                Log.i(TAG, "Database integrity check passed [OK].")
                true
            } else {
                Log.w(TAG, "Database integrity check failed ($resultStr)! Preserving backup & attempting REINDEX...")
                val backupFile = File(file.parentFile, "${file.name}.corrupt_backup_${System.currentTimeMillis()}")
                try {
                    file.copyTo(backupFile, overwrite = true)
                    Log.i(TAG, "Corrupt database preserved at: ${backupFile.absolutePath}")
                } catch (e: Exception) {
                    Log.w(TAG, "Warning copying backup: ${e.message}")
                }

                db.execSQL("PRAGMA wal_checkpoint(TRUNCATE);")
                db.execSQL("REINDEX;")

                val recheckCursor = db.rawQuery("PRAGMA integrity_check;", null)
                var recheckOk = false
                if (recheckCursor.moveToFirst()) {
                    recheckOk = (recheckCursor.getString(0) == "ok")
                }
                recheckCursor.close()

                if (recheckOk) {
                    Log.i(TAG, "REINDEX successfully restored database integrity!")
                    true
                } else {
                    Log.e(TAG, "REINDEX did not clear corruption. Records preserved in backup.")
                    false
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Database repair operation encountered an exception: ${e.message}")
            false
        }
    }

    /**
     * Recovers any stale records stuck in `UPLOADING` or `uploading` state
     * (e.g. following process death mid-upload) back to `WAITING`.
     */
    fun recoverStuckUploadingCalls(context: Context): Int = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return 0
        return try {
            val cv = ContentValues().apply {
                put("sync_state", "WAITING")
            }
            val count = db.update(
                TABLE_LOCAL_CALLS,
                cv,
                "sync_state = ? OR sync_state = ?",
                arrayOf("UPLOADING", "uploading")
            )
            if (count > 0) {
                Log.i(TAG, "[CRASH_RECOVERY] Recovered $count stale UPLOADING records back to WAITING")
            }
            count
        } catch (e: Exception) {
            Log.e(TAG, "Error recovering stuck uploading calls: ${e.message}")
            0
        }
    }

    /**
     * Atomically selects and claims the next pending record for upload.
     * Sets its state to `UPLOADING` in a single transaction.
     */
    fun claimNextWaitingCall(context: Context): CallRecord? = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return null
        var record: CallRecord? = null
        val nowSec = System.currentTimeMillis() / 1000L

        db.beginTransaction()
        try {
            val query = """
                SELECT local_id, idempotency_key, external_call_id, server_call_id, phone_number,
                       contact_name, direction, status, started_at, duration_seconds,
                       has_recording, recording_path, recording_media_store_id, recording_checksum,
                       recording_upload_status, sim_slot, attempt_count, sync_state
                FROM $TABLE_LOCAL_CALLS
                WHERE (sync_state IN ('WAITING', 'pending'))
                   OR (sync_state IN ('RETRY_PENDING', 'failed_retryable') AND (next_attempt_at IS NULL OR next_attempt_at <= ?))
                   OR (has_recording = 1 AND recording_upload_status IN ('pending', 'failed') AND sync_state != 'UPLOADING' AND (next_attempt_at IS NULL OR next_attempt_at <= ?))
                ORDER BY started_at ASC
                LIMIT 1
            """.trimIndent()

            val cursor = db.rawQuery(query, arrayOf(nowSec.toString(), nowSec.toString()))
            if (cursor.moveToFirst()) {
                val localId = cursor.getLong(0)
                val idempotencyKey = cursor.getString(1)
                val externalCallId = if (cursor.isNull(2)) null else cursor.getString(2)
                val serverCallId = if (cursor.isNull(3)) null else cursor.getString(3)
                val phoneNumber = cursor.getString(4) ?: "Unknown"
                val contactName = if (cursor.isNull(5)) null else cursor.getString(5)
                val direction = cursor.getString(6) ?: "incoming"
                val status = cursor.getString(7) ?: "completed"
                
                val rawStartedAt = cursor.getLong(8)
                val startedAtMillis = if (rawStartedAt < 10000000000L) rawStartedAt * 1000L else rawStartedAt
                
                val durationSec = cursor.getInt(9)
                val hasRecording = cursor.getInt(10) == 1
                val recordingPath = if (cursor.isNull(11)) null else cursor.getString(11)
                val recordingMediaStoreId = if (cursor.isNull(12)) null else cursor.getLong(12)
                val recordingChecksum = if (cursor.isNull(13)) null else cursor.getString(13)
                val recordingUploadStatus = if (cursor.isNull(14)) "pending" else cursor.getString(14)
                val simSlot = if (cursor.isNull(15)) 1 else cursor.getInt(15)
                val attemptCount = cursor.getInt(16)

                val cv = ContentValues().apply {
                    put("sync_state", "UPLOADING")
                }
                db.update(TABLE_LOCAL_CALLS, cv, "local_id = ?", arrayOf(localId.toString()))

                record = CallRecord(
                    localId = localId,
                    idempotencyKey = idempotencyKey,
                    externalCallId = externalCallId,
                    serverCallId = serverCallId,
                    phoneNumber = phoneNumber,
                    contactName = contactName,
                    direction = direction,
                    status = status,
                    startedAtMillis = startedAtMillis,
                    durationSeconds = durationSec,
                    hasRecording = hasRecording,
                    recordingPath = recordingPath,
                    recordingMediaStoreId = recordingMediaStoreId,
                    recordingChecksum = recordingChecksum,
                    recordingUploadStatus = recordingUploadStatus,
                    simSlot = simSlot,
                    attemptCount = attemptCount,
                    syncState = "UPLOADING",
                )
            }
            cursor.close()
            db.setTransactionSuccessful()
        } catch (e: Exception) {
            Log.e(TAG, "Error claiming next waiting call: ${e.message}")
        } finally {
            db.endTransaction()
        }
        return record
    }

    /**
     * Persists server call ID when metadata upload succeeds.
     */
    fun markServerCallId(context: Context, idempotencyKey: String, serverCallId: String, revision: Int): Boolean = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return false
        return try {
            val cv = ContentValues().apply {
                put("server_call_id", serverCallId)
                put("revision", revision)
            }
            val rows = db.update(TABLE_LOCAL_CALLS, cv, "idempotency_key = ?", arrayOf(idempotencyKey))
            rows > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error persisting server call ID: ${e.message}")
            false
        }
    }

    /**
     * Marks recording upload status specifically.
     */
    fun markRecordingUploaded(context: Context, idempotencyKey: String): Boolean = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return false
        return try {
            val cv = ContentValues().apply {
                put("recording_upload_status", "uploaded")
            }
            val rows = db.update(TABLE_LOCAL_CALLS, cv, "idempotency_key = ?", arrayOf(idempotencyKey))
            rows > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error marking recording uploaded: ${e.message}")
            false
        }
    }

    /**
     * Marks recording upload failure specifically.
     */
    fun markRecordingFailed(context: Context, idempotencyKey: String, errorCode: String): Boolean = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return false
        return try {
            val cv = ContentValues().apply {
                put("recording_upload_status", "failed")
                put("last_error_code", errorCode)
            }
            val rows = db.update(TABLE_LOCAL_CALLS, cv, "idempotency_key = ?", arrayOf(idempotencyKey))
            rows > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error marking recording failed: ${e.message}")
            false
        }
    }

    /**
     * Marks a record as successfully uploaded (both metadata and recording if applicable).
     */
    fun markUploaded(context: Context, idempotencyKey: String, serverCallId: String, revision: Int): Boolean = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return false
        return try {
            val cv = ContentValues().apply {
                put("sync_state", "UPLOADED")
                put("server_call_id", serverCallId)
                put("revision", revision)
                putNull("last_error_code")
            }
            val rows = db.update(TABLE_LOCAL_CALLS, cv, "idempotency_key = ?", arrayOf(idempotencyKey))
            rows > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error marking record uploaded: ${e.message}")
            false
        }
    }

    /**
     * Marks a record for retry after a retryable error.
     */
    fun markRetryPending(
        context: Context,
        idempotencyKey: String,
        errorCode: String,
        currentAttemptCount: Int,
        delaySeconds: Long
    ): Boolean = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return false
        return try {
            val nextAttemptSec = (System.currentTimeMillis() / 1000L) + delaySeconds
            val cv = ContentValues().apply {
                put("sync_state", "RETRY_PENDING")
                put("attempt_count", currentAttemptCount + 1)
                put("next_attempt_at", nextAttemptSec)
                put("last_error_code", errorCode)
            }
            val rows = db.update(TABLE_LOCAL_CALLS, cv, "idempotency_key = ?", arrayOf(idempotencyKey))
            rows > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error marking record retry pending: ${e.message}")
            false
        }
    }

    /**
     * Marks a record as permanently failed (non-retryable).
     */
    fun markFailed(
        context: Context,
        idempotencyKey: String,
        errorCode: String,
        currentAttemptCount: Int
    ): Boolean = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return false
        return try {
            val cv = ContentValues().apply {
                put("sync_state", "FAILED")
                put("attempt_count", currentAttemptCount + 1)
                put("last_error_code", errorCode)
            }
            val rows = db.update(TABLE_LOCAL_CALLS, cv, "idempotency_key = ?", arrayOf(idempotencyKey))
            rows > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error marking record failed: ${e.message}")
            false
        }
    }

    /**
     * Inserts captured calls directly into SQLite outbox with matched recording info.
     */
    fun insertCapturedCalls(
        context: Context,
        calls: List<Map<String, Any?>>,
        recordingMatches: Map<Long, Map<String, Any?>> = emptyMap(),
    ): Int = synchronized(dbLock) {
        if (calls.isEmpty()) return 0
        val db = getWritableDb(context) ?: return 0
        var insertedCount = 0
        val nowSec = System.currentTimeMillis() / 1000L

        db.beginTransaction()
        try {
            for (c in calls) {
                val dateMillis = (c["dateMillis"] as? Number)?.toLong() ?: System.currentTimeMillis()
                val number = (c["number"] as? String) ?: "Unknown"
                val rawType = (c["type"] as? String)?.lowercase() ?: "unknown"
                val duration = (c["durationSeconds"] as? Number)?.toInt() ?: 0
                val contactName = c["cachedName"] as? String
                val extId = "android-$dateMillis-$number"
                val idempotencyKey = CallSyncWorker.generateDeterministicIdempotencyKey(extId, dateMillis)

                val (direction, statusStr) = when (rawType) {
                    "incoming" -> Pair("incoming", if (duration > 0) "completed" else "missed")
                    "outgoing" -> Pair("outgoing", "completed")
                    "missed"   -> Pair("incoming", "missed")
                    "rejected" -> Pair("incoming", "rejected")
                    else       -> Pair(if (rawType.contains("out")) "outgoing" else "incoming", if (duration > 0) "completed" else "missed")
                }

                val matchInfo = recordingMatches[dateMillis]
                val hasRec = matchInfo != null
                val recPath = matchInfo?.get("recordingPath") as? String
                val mediaStoreId = (matchInfo?.get("mediaStoreId") as? Number)?.toLong()
                val checksum = matchInfo?.get("checksum") as? String
                val recStatus = when {
                    hasRec -> "pending"
                    duration > 0 -> "waiting_for_recording"
                    else -> "absent"
                }

                val cv = ContentValues().apply {
                    put("idempotency_key", idempotencyKey)
                    put("external_call_id", extId)
                    put("phone_number", number)
                    if (!contactName.isNullOrBlank()) put("contact_name", contactName)
                    put("direction", direction)
                    put("status", statusStr)
                    put("started_at", dateMillis / 1000L)
                    put("duration_seconds", duration)
                    put("has_recording", if (hasRec) 1 else 0)
                    if (recPath != null) put("recording_path", recPath)
                    if (mediaStoreId != null) put("recording_media_store_id", mediaStoreId)
                    if (checksum != null) put("recording_checksum", checksum)
                    put("recording_upload_status", recStatus)
                    put("sim_slot", 1)
                    put("client_created_at", nowSec)
                    put("sync_state", "WAITING")
                    put("attempt_count", 0)
                    put("revision", 0)
                }

                val rowId = db.insertWithOnConflict(
                    TABLE_LOCAL_CALLS,
                    null,
                    cv,
                    SQLiteDatabase.CONFLICT_IGNORE
                )
                if (rowId != -1L) {
                    insertedCount++
                    Log.d(TAG, "[OUTBOX_INSERT] Call: $extId, Duration: ${duration}s, RecordingStatus: $recStatus")
                }
            }
            db.setTransactionSuccessful()
        } catch (e: Exception) {
            Log.e(TAG, "Error inserting captured calls: ${e.message}")
        } finally {
            db.endTransaction()
        }
        return insertedCount
    }

    /**
     * Retrieves recent connected calls that have not yet been linked to a recording candidate.
     */
    fun getCallsNeedingRecordingMatch(context: Context, maxAgeSeconds: Long = 600L): List<Map<String, Any?>> = synchronized(dbLock) {
        val db = getReadableDb(context) ?: return emptyList()
        val list = mutableListOf<Map<String, Any?>>()
        val cutoffSec = (System.currentTimeMillis() / 1000L) - maxAgeSeconds

        try {
            val query = """
                SELECT local_id, idempotency_key, phone_number, contact_name, started_at, duration_seconds
                FROM $TABLE_LOCAL_CALLS
                WHERE duration_seconds > 0
                  AND (has_recording = 0 OR recording_upload_status = 'waiting_for_recording' OR recording_media_store_id IS NULL)
                  AND started_at >= ?
                ORDER BY started_at DESC
                LIMIT 50
            """.trimIndent()

            val cursor = db.rawQuery(query, arrayOf(cutoffSec.toString()))
            while (cursor.moveToNext()) {
                val rawStartedAt = cursor.getLong(4)
                val startedAtMillis = if (rawStartedAt < 10000000000L) rawStartedAt * 1000L else rawStartedAt
                list.add(
                    mapOf(
                        "localId" to cursor.getLong(0),
                        "idempotencyKey" to cursor.getString(1),
                        "phoneNumber" to cursor.getString(2),
                        "contactName" to if (cursor.isNull(3)) null else cursor.getString(3),
                        "startedAtMillis" to startedAtMillis,
                        "durationSeconds" to cursor.getInt(5),
                    )
                )
            }
            cursor.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error getting unlinked calls: ${e.message}")
        }
        return list
    }

    /**
     * Updates an existing call with newly discovered recording match details.
     */
    fun updateRecordingMatch(
        context: Context,
        idempotencyKey: String,
        recordingPath: String,
        mediaStoreId: Long,
        checksum: String?,
    ): Boolean = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return false
        return try {
            val cv = ContentValues().apply {
                put("has_recording", 1)
                put("recording_path", recordingPath)
                put("recording_media_store_id", mediaStoreId)
                if (checksum != null) put("recording_checksum", checksum)
                put("recording_upload_status", "pending")
            }
            // If already marked UPLOADED for metadata, reset sync_state to WAITING so recording is uploaded
            db.execSQL(
                "UPDATE $TABLE_LOCAL_CALLS SET sync_state = 'WAITING' WHERE idempotency_key = ? AND sync_state = 'UPLOADED' AND server_call_id IS NOT NULL",
                arrayOf(idempotencyKey)
            )
            val rows = db.update(TABLE_LOCAL_CALLS, cv, "idempotency_key = ?", arrayOf(idempotencyKey))
            if (rows > 0) {
                Log.i(TAG, "[RECORDING_DISCOVERY] Linked recording to call: $idempotencyKey, mediaStoreId: $mediaStoreId")
            }
            rows > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error updating recording match: ${e.message}")
            false
        }
    }

    /**
     * Sets `recording_upload_status = 'absent'` for calls that exceeded the discovery window without finding a recording.
     */
    fun expireUnmatchedCalls(context: Context, maxAgeSeconds: Long = 300L): Int = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return 0
        val cutoffSec = (System.currentTimeMillis() / 1000L) - maxAgeSeconds
        return try {
            val cv = ContentValues().apply {
                put("recording_upload_status", "absent")
            }
            val count = db.update(
                TABLE_LOCAL_CALLS,
                cv,
                "recording_upload_status = 'waiting_for_recording' AND started_at < ?",
                arrayOf(cutoffSec.toString())
            )
            if (count > 0) {
                Log.d(TAG, "Expired $count unlinked calls to absent status.")
            }
            count
        } catch (e: Exception) {
            Log.e(TAG, "Error expiring unmatched calls: ${e.message}")
            0
        }
    }

    /**
     * Reads sync state counters from SQLite.
     */
    fun getSyncCounters(context: Context): Map<String, Int> = synchronized(dbLock) {
        val db = getReadableDb(context) ?: return mapOf(
            "uploaded" to 0, "uploading" to 0, "waiting" to 0, "failed" to 0, "total" to 0
        )
        var uploaded = 0
        var uploading = 0
        var waiting = 0
        var failed = 0
        var total = 0

        try {
            val cursor = db.rawQuery("SELECT sync_state, COUNT(*) FROM $TABLE_LOCAL_CALLS GROUP BY sync_state", null)
            while (cursor.moveToNext()) {
                val state = cursor.getString(0)
                val count = cursor.getInt(1)
                total += count
                when (state) {
                    "UPLOADED", "synced", "skipped" -> uploaded += count
                    "UPLOADING", "uploading" -> uploading += count
                    "FAILED", "failed_permanent" -> failed += count
                    else -> waiting += count
                }
            }
            cursor.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error reading sync counters: ${e.message}")
        }

        return mapOf(
            "uploaded" to uploaded,
            "uploading" to uploading,
            "waiting" to waiting,
            "failed" to failed,
            "total" to total,
        )
    }
}
