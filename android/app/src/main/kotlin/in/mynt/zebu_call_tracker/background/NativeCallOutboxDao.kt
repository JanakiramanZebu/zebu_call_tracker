package `in`.mynt.zebu_call_tracker.background

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.Log
import `in`.mynt.zebu_call_tracker.call.CallWireFormat
import `in`.mynt.zebu_call_tracker.call.SimInfoReader
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
    /**
     * When the call was actually picked up, or null when nothing on the device
     * could say. Never inferred from [startedAtMillis] — see
     * [in.mynt.zebu_call_tracker.background.NativeCallIngestor].
     */
    val answeredAtMillis: Long?,
    /** True end of the call. Null means the uploader must estimate it. */
    val endedAtMillis: Long?,
    val durationSeconds: Int,
    val hasRecording: Boolean,
    val recordingPath: String?,
    val recordingMediaStoreId: Long?,
    val recordingChecksum: String?,
    val recordingUploadStatus: String,
    val simSlot: Int,
    /**
     * Call-log and recording facts with no column of their own, as a JSON
     * object, forwarded verbatim to the server's `metadata` bag. Null when the
     * row predates the field.
     */
    val metadataJson: String?,
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
                recording_upload_status TEXT NOT NULL DEFAULT '${RecordingStates.PENDING}',
                sim_slot INTEGER DEFAULT 1,
                metadata_json TEXT,
                client_created_at INTEGER NOT NULL,
                sync_state TEXT NOT NULL DEFAULT '${SyncStates.WAITING}',
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

    override fun onOpen(db: SQLiteDatabase) {
        super.onOpen(db)

        // Additive columns, applied here rather than through onUpgrade.
        //
        // DATABASE_VERSION cannot move on its own: drift opens this same file
        // and SQLiteOpenHelper throws outright when it meets a database newer
        // than itself, so a one-sided bump takes background sync down silently
        // on the next call. Both owners would have to ship in lockstep, and a
        // user on a mixed build would be broken in between.
        //
        // `ALTER TABLE ... ADD COLUMN` guarded by a column check is the same
        // trick the state normalisation below already uses for the same
        // reason: idempotent, order-independent, and correct whichever side
        // opens the file first. New columns must be nullable, which they are.
        // Caught per column, not around the loop: one column failing must not
        // skip the ones after it, and "duplicate column name" is an expected
        // outcome whenever the other owner won the race to add it.
        for ((column, ddl) in ADDITIVE_COLUMNS) {
            try {
                if (!hasColumn(db, TABLE_LOCAL_CALLS, column)) {
                    db.execSQL("ALTER TABLE $TABLE_LOCAL_CALLS ADD COLUMN $ddl")
                    Log.i(TAG, "Added column $column to $TABLE_LOCAL_CALLS")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not add column $column: ${e.message}")
            }
        }

        // Fold rows still carrying the pre-unification lowercase state names
        // onto the shared vocabulary. Mirrors drift's `beforeOpen`; whichever
        // side opens the file first does the work, and running it twice is a
        // no-op. Deliberately not gated behind DATABASE_VERSION — see the note
        // on that constant.
        try {
            for (statement in SyncStates.normalizationStatements) {
                db.execSQL(statement)
            }
            // Likewise for `status`: rows captured by a build that wrote
            // "completed" would otherwise keep being offered to the server with
            // a value its enum does not contain.
            for (statement in CallWireFormat.normalizationStatements) {
                db.execSQL(statement)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed normalising legacy sync states: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "ZebuDatabaseHelper"

        private const val TABLE_LOCAL_CALLS = "local_calls"

        /**
         * Columns added after the original schema, as `name to DDL`.
         *
         * Applied in [onOpen] against a live database, so every one must be
         * nullable or carry a default — SQLite cannot add a NOT NULL column
         * without one, and rows written by an older build have no value for it.
         *
         * Keep in step with drift's `_additiveColumns` in
         * `lib/core/storage/app_database.dart`. Either owner may create the
         * column; both must tolerate finding it already there.
         */
        private val ADDITIVE_COLUMNS = listOf(
            "metadata_json" to "metadata_json TEXT",
        )

        /** True when [table] already has [column]. */
        private fun hasColumn(db: SQLiteDatabase, table: String, column: String): Boolean =
            try {
                db.rawQuery("PRAGMA table_info($table)", null).use { cursor ->
                    val nameIndex = cursor.getColumnIndex("name")
                    if (nameIndex < 0) return false
                    while (cursor.moveToNext()) {
                        if (cursor.getString(nameIndex) == column) return true
                    }
                    false
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not inspect $table: ${e.message}")
                // Report "absent" and let the ALTER be attempted.
                //
                // The opposite default looks safer and is not: claiming the
                // column exists skips the ALTER, and then every claim query —
                // which names `metadata_json` explicitly — fails, is swallowed
                // by its own catch, and returns an empty list. Sync would stop
                // dead and silently. Attempting the ALTER can only fail with
                // "duplicate column name", which the caller already catches and
                // which means the column was there all along.
                false
            }

        /**
         * **Locked to drift's `AppDatabase.schemaVersion`.**
         *
         * Dart and Kotlin open the same file. `SQLiteOpenHelper` throws when it
         * meets a database newer than its own version, so raising one of the
         * two numbers alone does not migrate anything — it silently takes
         * background sync offline on the next call. Move both or neither.
         */
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
                put("sync_state", SyncStates.WAITING)
            }
            val count = db.update(
                TABLE_LOCAL_CALLS,
                cv,
                "sync_state = ?",
                arrayOf(SyncStates.UPLOADING)
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
     * Claims up to [limit] rows that still owe the server their METADATA.
     *
     * The batch counterpart to [claimNextWaitingCall]. `POST /sync/calls` takes
     * an array and the guide recommends fifty per request (§5.5); the
     * coordinator was sending one, so a backlog of five hundred calls meant
     * five hundred round trips, five hundred sets of headers, and five hundred
     * radio wake-ups to move a few kilobytes.
     *
     * Deliberately narrower than the single-row claim: it takes only rows with
     * no `server_call_id`, because a row that already has one owes audio, not
     * metadata, and audio uploads stay strictly one at a time (§6.5). Those are
     * left for the per-row loop.
     *
     * All claimed rows move to UPLOADING inside one transaction, so a second
     * runner cannot take the same work and a crash leaves them recoverable by
     * [recoverStuckUploadingCalls].
     */
    fun claimMetadataBatch(context: Context, limit: Int): List<CallRecord> =
        synchronized(dbLock) {
            val db = getWritableDb(context) ?: return emptyList()
            if (limit <= 0) return emptyList()

            val claimed = mutableListOf<CallRecord>()
            val nowSec = System.currentTimeMillis() / 1000L

            db.beginTransaction()
            try {
                val query = """
                    SELECT local_id, idempotency_key, external_call_id, server_call_id, phone_number,
                           contact_name, direction, status, started_at, duration_seconds,
                           has_recording, recording_path, recording_media_store_id, recording_checksum,
                           recording_upload_status, sim_slot, attempt_count, sync_state,
                           answered_at, ended_at, metadata_json
                    FROM $TABLE_LOCAL_CALLS
                    WHERE server_call_id IS NULL
                      AND (sync_state = '${SyncStates.WAITING}'
                           OR (sync_state = '${SyncStates.RETRY_PENDING}'
                               AND (next_attempt_at IS NULL OR next_attempt_at <= ?)))
                    ORDER BY started_at DESC
                    LIMIT ?
                """.trimIndent()

                db.rawQuery(query, arrayOf(nowSec.toString(), limit.toString())).use { cursor ->
                    while (cursor.moveToNext()) {
                        claimed += cursor.toCallRecord()
                    }
                }

                for (record in claimed) {
                    val cv = ContentValues().apply { put("sync_state", SyncStates.UPLOADING) }
                    db.update(
                        TABLE_LOCAL_CALLS,
                        cv,
                        "local_id = ?",
                        arrayOf(record.localId.toString()),
                    )
                }
                db.setTransactionSuccessful()
            } catch (e: Exception) {
                Log.e(TAG, "Error claiming metadata batch: ${e.message}")
                claimed.clear()
            } finally {
                db.endTransaction()
            }
            return claimed
        }

    /**
     * Epoch SECONDS as stored, widened to millis.
     *
     * Timestamps go into this table in seconds, but rows written by earlier
     * builds — and by drift, which stores millis — can carry either. Anything
     * below the year-2286 boundary in millis is unambiguously a seconds value.
     */
    private fun toMillis(raw: Long): Long =
        if (raw < 10000000000L) raw * 1000L else raw

    /**
     * Reads one row of the column list shared by both claim queries.
     *
     * Extracted so the batch and single-row claims cannot drift apart in what
     * they read or how they interpret it — the seconds/millis fix-up above in
     * particular is easy to get right once and wrong twice. Both claims now go
     * through it; the single-row claim used to repeat the whole mapping inline,
     * which is exactly the drift this was extracted to prevent.
     */
    private fun android.database.Cursor.toCallRecord(): CallRecord {
        return CallRecord(
            answeredAtMillis = if (isNull(18)) null else toMillis(getLong(18)),
            endedAtMillis = if (isNull(19)) null else toMillis(getLong(19)),
            metadataJson = if (isNull(20)) null else getString(20),
            localId = getLong(0),
            idempotencyKey = getString(1),
            externalCallId = if (isNull(2)) null else getString(2),
            serverCallId = if (isNull(3)) null else getString(3),
            phoneNumber = getString(4) ?: "Unknown",
            contactName = if (isNull(5)) null else getString(5),
            direction = getString(6) ?: "incoming",
            status = getString(7) ?: CallWireFormat.Status.ENDED,
            startedAtMillis = toMillis(getLong(8)),
            durationSeconds = getInt(9),
            hasRecording = getInt(10) == 1,
            recordingPath = if (isNull(11)) null else getString(11),
            recordingMediaStoreId = if (isNull(12)) null else getLong(12),
            recordingChecksum = if (isNull(13)) null else getString(13),
            recordingUploadStatus =
                if (isNull(14)) RecordingStates.PENDING else getString(14),
            simSlot = if (isNull(15)) 1 else getInt(15),
            attemptCount = getInt(16),
            syncState = SyncStates.UPLOADING,
        )
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
            // Three ways a row becomes claimable:
            //  1. never sent,
            //  2. sent and failed on something transient, backoff elapsed,
            //  3. metadata already accepted but the audio is still owed —
            //     the common case, since OEM dialers write the file after the
            //     call-log row and the recording is linked on a later pass.
            //
            // Clause 3 must exclude terminal rows. It once matched on
            // `sync_state != 'UPLOADING'` alone, so a row whose recording had
            // failed permanently stayed eligible forever and the caller's
            // drain loop re-claimed the same record without end.
            //
            // NEWEST FIRST. The server takes one call per request, so the queue
            // drains at a few rows a second at best. Oldest-first put the call
            // the user just made at the BACK of the backlog — on a handset with
            // months of history it would not be sent for hours, which reads as
            // "uploads never happen". The freshest call is also the one someone
            // is watching for, and the one most likely to still have its
            // recording on disk.
            val query = """
                SELECT local_id, idempotency_key, external_call_id, server_call_id, phone_number,
                       contact_name, direction, status, started_at, duration_seconds,
                       has_recording, recording_path, recording_media_store_id, recording_checksum,
                       recording_upload_status, sim_slot, attempt_count, sync_state,
                       answered_at, ended_at, metadata_json
                FROM $TABLE_LOCAL_CALLS
                WHERE sync_state = '${SyncStates.WAITING}'
                   OR (sync_state = '${SyncStates.RETRY_PENDING}'
                       AND (next_attempt_at IS NULL OR next_attempt_at <= ?))
                   OR (sync_state = '${SyncStates.UPLOADED}'
                       AND has_recording = 1
                       AND server_call_id IS NOT NULL
                       AND recording_upload_status = '${RecordingStates.PENDING}'
                       AND (next_attempt_at IS NULL OR next_attempt_at <= ?))
                ORDER BY started_at DESC
                LIMIT 1
            """.trimIndent()

            val cursor = db.rawQuery(query, arrayOf(nowSec.toString(), nowSec.toString()))
            if (cursor.moveToFirst()) {
                // Same mapper as the batch claim. This block used to repeat the
                // whole mapping by hand against the same column list, so every
                // field added to one claim had to be remembered in the other.
                val claimedRecord = cursor.toCallRecord()

                val cv = ContentValues().apply {
                    put("sync_state", SyncStates.UPLOADING)
                }
                db.update(
                    TABLE_LOCAL_CALLS,
                    cv,
                    "local_id = ?",
                    arrayOf(claimedRecord.localId.toString()),
                )

                record = claimedRecord
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
     * Holds a recording back without disturbing the call's own state.
     *
     * Used when audio is waiting for an unmetered network. [markRetryPending]
     * would be wrong here: it moves the row out of UPLOADED, and the sync
     * counters read UPLOADED as "sent" — so a call the server already has would
     * be reported to the user as still waiting, for as long as the deferral
     * lasted. The call IS synced; only its audio is not.
     *
     * Leaves `recording_upload_status` on `pending` so the claim query's
     * recording clause still matches once `next_attempt_at` passes.
     */
    fun deferRecordingUpload(
        context: Context,
        idempotencyKey: String,
        delaySeconds: Long,
    ): Boolean = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return false
        return try {
            val cv = ContentValues().apply {
                put("sync_state", SyncStates.UPLOADED)
                put("next_attempt_at", (System.currentTimeMillis() / 1000L) + delaySeconds)
            }
            db.update(
                TABLE_LOCAL_CALLS,
                cv,
                "idempotency_key = ?",
                arrayOf(idempotencyKey),
            ) > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error deferring recording upload: ${e.message}")
            false
        }
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
                put("recording_upload_status", RecordingStates.UPLOADED)
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
    /**
     * Codes that mean the stored digest no longer describes the file.
     *
     * Clearing it forces the next attempt to hash the bytes again. Without
     * this the coordinator reuses the same stale checksum on every retry and
     * the server refuses the upload identically each time — a retryable error
     * that can never actually succeed, which is the worst of both states.
     */
    private val CHECKSUM_STALE_CODES = setOf("CHECKSUM_MISMATCH", "FILE_SIZE_MISMATCH")

    fun markRecordingFailed(context: Context, idempotencyKey: String, errorCode: String): Boolean = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return false
        return try {
            val cv = ContentValues().apply {
                put("recording_upload_status", RecordingStates.FAILED)
                put("last_error_code", errorCode)
                if (errorCode in CHECKSUM_STALE_CODES) {
                    putNull("recording_checksum")
                }
            }
            val rows = db.update(TABLE_LOCAL_CALLS, cv, "idempotency_key = ?", arrayOf(idempotencyKey))
            rows > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error marking recording failed: ${e.message}")
            false
        }
    }

    /**
     * Records that no audio exists for this call, or that the file the match
     * pointed at can no longer be opened.
     *
     * Terminal, unlike [markRecordingFailed]: there is nothing to retry, so
     * the row must stop matching the recording clause of the claim query or
     * the drain loop picks it up forever.
     */
    fun markRecordingAbsent(context: Context, idempotencyKey: String, reason: String): Boolean = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return false
        return try {
            val cv = ContentValues().apply {
                put("recording_upload_status", RecordingStates.ABSENT)
                put("has_recording", 0)
                put("last_error_code", reason)
            }
            db.update(TABLE_LOCAL_CALLS, cv, "idempotency_key = ?", arrayOf(idempotencyKey)) > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error marking recording absent: ${e.message}")
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
                put("sync_state", SyncStates.UPLOADED)
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
                put("sync_state", SyncStates.RETRY_PENDING)
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
                put("sync_state", SyncStates.FAILED)
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
     *
     * [recordingMatches] is keyed by the call's `dateMillis` and carries
     * whatever the ingester worked out that the call-log row itself does not
     * hold: the matched recording, the real `answered_at`/`ended_at`, a
     * resolved contact name, and the JSON metadata bag. All of it optional —
     * a key that is absent simply leaves the column null, which is what an
     * unknowable value must look like.
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

        // Resolved once for the batch, not per row: SubscriptionManager is a
        // binder call. Empty on single-SIM handsets, which resolve to slot 1.
        val subscriptions = SimInfoReader.activeSubscriptions(context)

        db.beginTransaction()
        try {
            for (c in calls) {
                val dateMillis = (c["dateMillis"] as? Number)?.toLong() ?: System.currentTimeMillis()
                val number = CallWireFormat.Identity.number(c["number"] as? String)
                val rawType = (c["type"] as? String)?.lowercase() ?: "unknown"
                val duration = (c["durationSeconds"] as? Number)?.toInt() ?: 0
                val matchInfo = recordingMatches[dateMillis]
                // CACHED_NAME is null for anyone saved to Contacts AFTER the
                // call, so the ingester's PhoneLookup result wins when the log
                // has nothing.
                val contactName = (c["cachedName"] as? String)?.takeIf { it.isNotBlank() }
                    ?: (matchInfo?.get("contactName") as? String)?.takeIf { it.isNotBlank() }
                val extId = CallWireFormat.Identity.externalId(dateMillis, number)
                val idempotencyKey = CallWireFormat.Identity.keyFor(extId, dateMillis)

                // Stored in the server's vocabulary, so the row is upload-ready
                // as written and the local value cannot drift from the wire one.
                val outcome = CallWireFormat.outcomeFor(rawType, duration)
                val direction = outcome.direction
                val statusStr = outcome.status

                val hasRec = matchInfo?.get("mediaStoreId") != null
                val recPath = matchInfo?.get("recordingPath") as? String
                val mediaStoreId = (matchInfo?.get("mediaStoreId") as? Number)?.toLong()
                val checksum = matchInfo?.get("checksum") as? String
                val recStatus = when {
                    hasRec -> RecordingStates.PENDING
                    duration > 0 -> RecordingStates.WAITING_FOR_RECORDING
                    else -> RecordingStates.ABSENT
                }

                val cv = ContentValues().apply {
                    put("idempotency_key", idempotencyKey)
                    put("external_call_id", extId)
                    put("phone_number", number)
                    if (!contactName.isNullOrBlank()) put("contact_name", contactName)
                    put("direction", direction)
                    put("status", statusStr)
                    put("started_at", dateMillis / 1000L)
                    // Both null unless something on the device could actually
                    // say. `started_at + duration` is NOT an acceptable stand-in
                    // for ended_at: started_at is when the phone began ringing
                    // and duration counts connected time only, so the two
                    // differ by the entire ring. The server recomputes
                    // duration_seconds from this pair when both are present,
                    // which makes a confident wrong answer worse than none.
                    val answeredAtMillis = (matchInfo?.get("answeredAtMillis") as? Number)?.toLong()
                    val endedAtMillis = (matchInfo?.get("endedAtMillis") as? Number)?.toLong()
                    if (answeredAtMillis != null) put("answered_at", answeredAtMillis / 1000L)
                    if (endedAtMillis != null) put("ended_at", endedAtMillis / 1000L)
                    (matchInfo?.get("metadataJson") as? String)?.let {
                        put("metadata_json", it)
                    }
                    put("duration_seconds", duration)
                    put("has_recording", if (hasRec) 1 else 0)
                    if (recPath != null) put("recording_path", recPath)
                    if (mediaStoreId != null) put("recording_media_store_id", mediaStoreId)
                    if (checksum != null) put("recording_checksum", checksum)
                    put("recording_upload_status", recStatus)
                    // Which SIM actually carried the call. Hardcoding 1 here
                    // sent every dual-SIM call to the server attributed to the
                    // wrong line.
                    put(
                        "sim_slot",
                        SimInfoReader.slotForAccountId(
                            c["phoneAccountId"] as? String,
                            subscriptions,
                        ),
                    )
                    put("client_created_at", nowSec)
                    put("sync_state", SyncStates.WAITING)
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
                SELECT local_id, idempotency_key, phone_number, contact_name, started_at,
                       duration_seconds, direction, answered_at, metadata_json
                FROM $TABLE_LOCAL_CALLS
                WHERE duration_seconds > 0
                  AND (has_recording = 0
                       OR recording_upload_status = '${RecordingStates.WAITING_FOR_RECORDING}'
                       OR recording_media_store_id IS NULL)
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
                        "direction" to (if (cursor.isNull(6)) "unknown" else cursor.getString(6)),
                        // Present means something better than the recording's
                        // DATE_ADDED already answered this question.
                        "answeredAtMillis" to
                            (if (cursor.isNull(7)) null else toMillis(cursor.getLong(7))),
                        "metadataJson" to
                            (if (cursor.isNull(8)) null else cursor.getString(8)),
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
        answeredAtMillis: Long? = null,
        endedAtMillis: Long? = null,
        metadataJson: String? = null,
    ): Boolean = synchronized(dbLock) {
        val db = getWritableDb(context) ?: return false
        return try {
            val cv = ContentValues().apply {
                put("has_recording", 1)
                put("recording_path", recordingPath)
                put("recording_media_store_id", mediaStoreId)
                if (checksum != null) put("recording_checksum", checksum)
                put("recording_upload_status", RecordingStates.PENDING)
                if (metadataJson != null) put("metadata_json", metadataJson)
            }

            // Finding the audio is also how a retroactively matched call learns
            // when it was answered: the recording's DATE_ADDED is the pickup and
            // DATE_MODIFIED is the hangup.
            //
            // Written through a guarded UPDATE rather than in the ContentValues
            // above, because these two must only fill a gap. A journal-derived
            // answer time comes from the telephony broadcast itself and is the
            // better of the two; folding it into `cv` would let a later
            // recording match silently overwrite the more accurate value.
            if (answeredAtMillis != null) {
                db.execSQL(
                    "UPDATE $TABLE_LOCAL_CALLS SET answered_at = ? " +
                        "WHERE idempotency_key = ? AND answered_at IS NULL",
                    arrayOf(answeredAtMillis / 1000L, idempotencyKey),
                )
            }
            if (endedAtMillis != null) {
                db.execSQL(
                    "UPDATE $TABLE_LOCAL_CALLS SET ended_at = ? " +
                        "WHERE idempotency_key = ? AND ended_at IS NULL",
                    arrayOf(endedAtMillis / 1000L, idempotencyKey),
                )
            }
            // A row already UPLOADED keeps that state: the server has the
            // metadata and the claim query picks it up on the recording clause.
            // Resetting it to WAITING used to re-post the metadata as well.
            // Terminal rows do need waking, though — a recording discovered
            // after a permanent failure deserves a fresh attempt.
            db.execSQL(
                "UPDATE $TABLE_LOCAL_CALLS SET sync_state = '${SyncStates.WAITING}', next_attempt_at = NULL " +
                    "WHERE idempotency_key = ? AND sync_state = '${SyncStates.FAILED}'",
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
                put("recording_upload_status", RecordingStates.ABSENT)
            }
            val count = db.update(
                TABLE_LOCAL_CALLS,
                cv,
                "recording_upload_status = '${RecordingStates.WAITING_FOR_RECORDING}' AND started_at < ?",
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
     * True when the outbox holds no calls at all.
     *
     * Used to catch a cursor that is lying. The ingest cursor says "everything
     * up to here is captured", but it lives in SharedPreferences while the rows
     * live in SQLite, and the two can part company: the database is wiped and
     * rebuilt empty by the corruption repair in `AppDatabase`, or cleared by
     * hand, while the cursor survives untouched. The ingester then believes it
     * is caught up, never re-reads the call log, and the app shows an empty
     * dashboard for ever — with nothing broken enough to notice.
     *
     * An empty table with a non-zero cursor is that contradiction, and the call
     * log is the durable source that can settle it.
     *
     * Returns false on error: refusing to claim emptiness we could not verify
     * avoids triggering a needless full backfill.
     */
    fun isEmpty(context: Context): Boolean = synchronized(dbLock) {
        val db = getReadableDb(context) ?: return false
        return try {
            db.rawQuery("SELECT EXISTS(SELECT 1 FROM $TABLE_LOCAL_CALLS)", null).use { c ->
                if (c.moveToFirst()) c.getInt(0) == 0 else false
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not test emptiness: ${e.message}")
            false
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
                    SyncStates.UPLOADED -> uploaded += count
                    SyncStates.UPLOADING -> uploading += count
                    SyncStates.FAILED -> failed += count
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
