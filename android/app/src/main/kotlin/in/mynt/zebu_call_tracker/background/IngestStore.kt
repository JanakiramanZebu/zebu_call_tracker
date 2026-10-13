package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys

/**
 * The background pipeline's small persistent state: the call-log cursor, run
 * and sync statistics for the status screens, and the auth session the
 * workers upload with.
 *
 * It used to hold a bounded JSON log of every captured call and recording
 * listing as well, for a Dart drain that matched recordings in the app. The
 * native ingester writes straight to the shared SQLite outbox now, and nothing
 * read those batches any more — but every pass still rewrote the whole blob.
 */
object IngestStore {

    private const val PREFS = "call_ingest_store"
    private const val KEY_CALL_CURSOR = "call_cursor_millis"

    /** Where an interrupted first backfill picks up. See [saveBackfillProgress]. */
    private const val KEY_BACKFILL_STARTED_AT = "backfill_started_at_millis"
    private const val KEY_BACKFILL_BEFORE = "backfill_before_millis"

    /**
     * Run and sync statistics, in their own file.
     *
     * They are written on every pass and every sync, and SharedPreferences
     * rewrites the whole XML file on each commit. Sharing a file with the
     * cursor, the sync policy and (formerly) the batch log made each of those
     * small writes rewrite all of it.
     */
    private const val STATS_PREFS = "call_ingest_stats"
    private const val KEY_LAST_RUN_AT = "last_run_at_millis"
    private const val KEY_LAST_RUN_STATUS = "last_run_status"
    private const val KEY_LAST_RUN_REASON = "last_run_reason"
    private const val KEY_RUN_COUNT = "run_count"
    private const val KEY_CAPTURED_CALLS = "captured_calls"
    private const val KEY_STATS_MIGRATED = "migrated_from_store"
    private const val KEY_REVIVAL_REQUESTED = "failure_revival_requested"
    private const val KEY_LAST_REVIVAL_AT = "last_failure_revival_at_millis"

    /** Statistics older builds kept in [PREFS]; moved by [statsPrefs]. */
    private val MIGRATED_STATS_KEYS = setOf(
        KEY_LAST_RUN_AT, KEY_LAST_RUN_STATUS, KEY_LAST_RUN_REASON, KEY_RUN_COUNT,
        KEY_CAPTURED_CALLS, KEY_LAST_SYNC_AT, KEY_LAST_SYNC_STATUS,
        KEY_LAST_SYNCED_COUNT, KEY_LAST_SYNC_ERROR,
    )

    /** Left behind in [PREFS] by older builds; removed by [statsPrefs]. */
    private val LEGACY_BATCH_KEYS = listOf(
        "batches", "synced_calls", "overflowed", "recording_cursor_seconds",
    )

    /** Cursor and backfill progress — no secrets, plain storage. */
    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Volatile
    private var statsMigrated = false

    /**
     * The statistics file, after moving any values an older build left in
     * [PREFS] so the status screen keeps showing the last run across the
     * upgrade. The dead batch log goes in the same step.
     */
    private fun statsPrefs(context: Context): SharedPreferences {
        val stats = context.getSharedPreferences(STATS_PREFS, Context.MODE_PRIVATE)
        if (statsMigrated) return stats
        synchronized(this) {
            if (!statsMigrated && !stats.getBoolean(KEY_STATS_MIGRATED, false)) {
                val legacy = prefs(context)
                stats.edit().apply {
                    legacy.all.forEach { (key, value) ->
                        if (key !in MIGRATED_STATS_KEYS) return@forEach
                        when (value) {
                            is Long -> putLong(key, value)
                            is Int -> putInt(key, value)
                            is String -> putString(key, value)
                        }
                    }
                    putBoolean(KEY_STATS_MIGRATED, true)
                }.commit()
                legacy.edit().apply {
                    (MIGRATED_STATS_KEYS + LEGACY_BATCH_KEYS).forEach { remove(it) }
                }.apply()
            }
            statsMigrated = true
        }
        return stats
    }

    private const val SECURE_PREFS = "call_ingest_secure"
    private const val TAG = "IngestStore"

    @Volatile
    private var securePrefsInstance: SharedPreferences? = null

    /**
     * Separate, encrypted store for the background worker's auth session.
     *
     * The access and refresh tokens used to live in [prefs] as plain XML, which
     * put them within reach of any root/backup extraction while the Dart side's
     * copy of the very same tokens sat in flutter_secure_storage. This closes
     * that asymmetry.
     *
     * Falls back to the plain store if the keystore is unavailable — some
     * devices fail EncryptedSharedPreferences construction outright, and an app
     * that cannot sync at all is a worse outcome than one that stores its token
     * the way it always did. The fallback is logged.
     *
     * The fallback is never cached. It used to be, for the life of the
     * process, so one transient keystore failure left the background reading
     * an empty plain store while the session sat in the encrypted one, and
     * any token written meanwhile stayed in the clear. Now every access tries
     * the keystore again; once it answers, [migrateLegacyPlaintextSession]
     * moves whatever the fallback holds into it and clears the plain copy.
     */
    private fun securePrefs(context: Context): SharedPreferences {
        securePrefsInstance?.let { return it }
        return synchronized(this) {
            securePrefsInstance ?: run {
                val store = try {
                    // security-crypto 1.0.0 API. The MasterKey.Builder form
                    // belongs to the 1.1.0 alphas, which this project does not
                    // take: see pubspec/build.gradle notes on holding stable
                    // versions against the pinned AGP.
                    val masterKeyAlias = MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC)
                    EncryptedSharedPreferences.create(
                        SECURE_PREFS,
                        masterKeyAlias,
                        context.applicationContext,
                        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "EncryptedSharedPreferences unavailable (${e.message}); using plain store for now.")
                    return@run prefs(context)
                }
                migrateLegacyPlaintextSession(context, store)
                securePrefsInstance = store
                store
            }
        }
    }

    /**
     * Moves a session written by an earlier build out of the plaintext store.
     *
     * Without this an already-signed-in handset would keep its tokens in the
     * clear until the user next signed in, and background sync would break
     * immediately on upgrade because the new store starts empty.
     */
    private fun migrateLegacyPlaintextSession(context: Context, target: SharedPreferences) {
        if (target === prefs(context)) return
        val legacy = prefs(context)
        val legacyToken = legacy.getString(KEY_AUTH_TOKEN, null) ?: return

        target.edit().apply {
            putString(KEY_AUTH_TOKEN, legacyToken)
            legacy.getString(KEY_REFRESH_TOKEN, null)?.let { putString(KEY_REFRESH_TOKEN, it) }
            legacy.getString(KEY_API_BASE_URL, null)?.let { putString(KEY_API_BASE_URL, it) }
            legacy.getString(KEY_DEVICE_UUID, null)?.let { putString(KEY_DEVICE_UUID, it) }
        }.apply()

        legacy.edit()
            .remove(KEY_AUTH_TOKEN)
            .remove(KEY_REFRESH_TOKEN)
            .remove(KEY_API_BASE_URL)
            .remove(KEY_DEVICE_UUID)
            .apply()

        Log.i(TAG, "Migrated background auth session out of plaintext preferences.")
    }

    // ------------------------------------------------------------- cursor

    fun callCursorMillis(context: Context): Long =
        prefs(context).getLong(KEY_CALL_CURSOR, 0L)

    /**
     * Moves the cursor forward to the newest call actually captured.
     *
     * Only ever to a captured row's own timestamp, never to "now": a row
     * written to the call log a moment after the query would otherwise be
     * skipped for ever. Never backwards.
     */
    fun advanceCallCursor(context: Context, newestCallMillis: Long) {
        val current = callCursorMillis(context)
        if (newestCallMillis <= current) return
        prefs(context).edit().putLong(KEY_CALL_CURSOR, newestCallMillis).apply()
    }

    // ------------------------------------------------------------- backfill

    /** When the unfinished first backfill began, or 0 when none is in progress. */
    fun backfillStartedAtMillis(context: Context): Long =
        prefs(context).getLong(KEY_BACKFILL_STARTED_AT, 0L)

    /** The exclusive upper bound the next backfill page reads below. */
    fun backfillBeforeMillis(context: Context): Long =
        prefs(context).getLong(KEY_BACKFILL_BEFORE, 0L)

    /**
     * Records how far down the call log the first backfill has got.
     *
     * Pages run newest to oldest, so the call cursor cannot simply be advanced
     * per page — it would claim the older pages not yet read were captured.
     * This keeps a separate resume point instead, and the cursor is only set
     * once by [finishBackfill]. An interrupted backfill used to start again
     * from today on the next run.
     */
    fun saveBackfillProgress(context: Context, startedAtMillis: Long, beforeMillis: Long) {
        prefs(context).edit()
            .putLong(KEY_BACKFILL_STARTED_AT, startedAtMillis)
            .putLong(KEY_BACKFILL_BEFORE, beforeMillis)
            .apply()
    }

    /** Drops a resume point, so the next first run starts afresh. */
    fun clearBackfillProgress(context: Context) {
        prefs(context).edit()
            .remove(KEY_BACKFILL_STARTED_AT)
            .remove(KEY_BACKFILL_BEFORE)
            .apply()
    }

    /** Ends the backfill: one write, so the cursor and the resume point never disagree. */
    fun finishBackfill(context: Context, cursorMillis: Long) {
        prefs(context).edit()
            .putLong(KEY_CALL_CURSOR, cursorMillis)
            .remove(KEY_BACKFILL_STARTED_AT)
            .remove(KEY_BACKFILL_BEFORE)
            .apply()
    }

    // ------------------------------------------------------------- run stats

    /**
     * How stale the persisted "last run" may get while nothing else changes.
     *
     * Event-driven capture means many passes that find nothing — a content
     * trigger from an unrelated media change, the hourly safety net on a quiet
     * afternoon — and each one used to rewrite this XML file (and fsync it)
     * just to move a timestamp. Such a run is now held in memory, which is
     * what [runStatus] reports while the process lives, and written through
     * at most this often. A run that captured something or changed the status
     * is always written at once.
     */
    private const val RUN_PERSIST_INTERVAL_MILLIS = 30L * 60L * 1000L

    private data class UnpersistedRun(val atMillis: Long, val status: String, val reason: String)

    private val runLock = Any()

    /** The newest run not yet written; null when the file is current. */
    private var unpersistedRun: UnpersistedRun? = null

    /** Runs counted since the file was last written. */
    private var unpersistedRunCount = 0

    fun recordRun(context: Context, status: String, reason: String, capturedCalls: Int = 0) {
        val now = System.currentTimeMillis()
        val p = statsPrefs(context)
        synchronized(runLock) {
            unpersistedRunCount++
            val mustPersist = capturedCalls > 0 ||
                status != p.getString(KEY_LAST_RUN_STATUS, null) ||
                now - p.getLong(KEY_LAST_RUN_AT, 0L) >= RUN_PERSIST_INTERVAL_MILLIS
            if (!mustPersist) {
                unpersistedRun = UnpersistedRun(now, status, reason)
                return
            }
            p.edit()
                .putLong(KEY_LAST_RUN_AT, now)
                .putString(KEY_LAST_RUN_STATUS, status)
                .putString(KEY_LAST_RUN_REASON, reason)
                .putInt(KEY_RUN_COUNT, p.getInt(KEY_RUN_COUNT, 0) + unpersistedRunCount)
                .putInt(KEY_CAPTURED_CALLS, p.getInt(KEY_CAPTURED_CALLS, 0) + capturedCalls)
                .apply()
            unpersistedRun = null
            unpersistedRunCount = 0
        }
    }

    /**
     * What `getBackgroundStatus` reports, with the keys it has always had.
     *
     * The last run comes from memory when a newer one is held there than the
     * file records (see [RUN_PERSIST_INTERVAL_MILLIS]), so the status screen
     * stays truthful within the process; after process death it can lag by at
     * most that interval.
     *
     * `overflowed` and `syncedCalls` described the batch log, which no longer
     * exists: nothing can overflow, and nothing was ever recorded as synced
     * there. Both are kept, constant, for the Dart side that still reads them.
     */
    fun runStatus(context: Context): Map<String, Any?> {
        val p = statsPrefs(context)
        val (pending, pendingCount) = synchronized(runLock) { unpersistedRun to unpersistedRunCount }
        return mapOf(
            "syncedCalls" to emptyList<Map<String, Any?>>(),
            "overflowed" to false,
            "lastRunAtMillis" to (pending?.atMillis ?: p.getLong(KEY_LAST_RUN_AT, 0L)),
            "lastRunStatus" to (pending?.status ?: p.getString(KEY_LAST_RUN_STATUS, null)),
            "lastRunReason" to (pending?.reason ?: p.getString(KEY_LAST_RUN_REASON, null)),
            "runCount" to p.getInt(KEY_RUN_COUNT, 0) + pendingCount,
            "capturedCalls" to p.getInt(KEY_CAPTURED_CALLS, 0),
            "callCursorMillis" to callCursorMillis(context),
        )
    }

    // ------------------------------------------------------- failure revival

    /** Asks the next sync to give FAILED rows another chance. See [SyncCoordinator]. */
    fun requestFailureRevival(context: Context) {
        statsPrefs(context).edit().putBoolean(KEY_REVIVAL_REQUESTED, true).apply()
    }

    /**
     * True — once — when FAILED rows should be revived now: on request, or
     * when the last revival is more than [maxAgeMillis] old. Consuming it
     * records the revival, so the next run returns false again.
     */
    /**
     * The same question as [consumeFailureRevival], without consuming it.
     * For deciding whether a sync is worth enqueuing at all.
     */
    fun isFailureRevivalDue(context: Context, maxAgeMillis: Long): Boolean {
        val p = statsPrefs(context)
        return p.getBoolean(KEY_REVIVAL_REQUESTED, false) ||
            System.currentTimeMillis() - p.getLong(KEY_LAST_REVIVAL_AT, 0L) > maxAgeMillis
    }

    fun consumeFailureRevival(context: Context, maxAgeMillis: Long): Boolean {
        val p = statsPrefs(context)
        val now = System.currentTimeMillis()
        val requested = p.getBoolean(KEY_REVIVAL_REQUESTED, false)
        val stale = now - p.getLong(KEY_LAST_REVIVAL_AT, 0L) > maxAgeMillis
        if (!requested && !stale) return false
        p.edit()
            .putBoolean(KEY_REVIVAL_REQUESTED, false)
            .putLong(KEY_LAST_REVIVAL_AT, now)
            .apply()
        return true
    }

    // ------------------------------------------------------------- auth & sync session

    private const val KEY_AUTH_TOKEN = "auth_token"
    private const val KEY_REFRESH_TOKEN = "refresh_token"
    private const val KEY_API_BASE_URL = "api_base_url"
    private const val KEY_DEVICE_UUID = "device_uuid"

    /**
     * When the server last refused this session outright.
     *
     * A tombstone, not a credential: it outlives [clearAuthSession] on purpose,
     * because its whole job is to tell Dart why the credential it expected to
     * find is gone. Cleared by a fresh pairing.
     */
    private const val KEY_SESSION_REVOKED_AT = "session_revoked_at_millis"

    /** RFC 3339, as the server sent it. Absent means the server did not say. */
    private const val KEY_ACCESS_EXPIRES_AT = "access_token_expires_at"
    private const val KEY_REFRESH_EXPIRES_AT = "refresh_token_expires_at"

    /**
     * Handset time the current access token arrived. Its age is measured from
     * here, not from the token's `iat`, so a phone with a wrong clock cannot
     * make [TokenRefresher.ensureFresh] think every token is already old.
     */
    private const val KEY_ACCESS_RECEIVED_AT = "access_token_received_at_millis"
    private const val KEY_LAST_SYNC_AT = "last_sync_at_millis"
    private const val KEY_LAST_SYNC_STATUS = "last_sync_status"
    private const val KEY_LAST_SYNCED_COUNT = "last_synced_count"
    private const val KEY_LAST_SYNC_ERROR = "last_sync_error"

    /**
     * Writes the session Dart is holding into the native store of record.
     *
     * [authoritative] decides what happens to the refresh token, and getting it
     * wrong is what used to kill sessions roughly half an hour after pairing.
     *
     * `POST /auth/refresh` ROTATES: the token you send is dead the moment the
     * server answers, and presenting a rotated one is treated as theft — the
     * server revokes the entire session chain (Mobile API Guide §2.3 rule 2,
     * and `AuthService.refresh`'s `token_reuse_detected` branch).
     *
     * The background coordinator refreshes with no Flutter engine attached, so
     * it rotates the pair here and Dart's `flutter_secure_storage` copy goes
     * stale the instant that happens. `AuthController.build()` then pushed that
     * stale copy straight back down on the next cold start, and the next 401
     * replayed an already-rotated token — signing the handset out for good and
     * stranding whatever was mid-upload.
     *
     * So: only a fresh sign-in may REPLACE the refresh token. Every other
     * caller is restoring a session this store already knows more about than
     * Dart does, and may only SEED one when there is nothing stored.
     */
    fun saveAuthSession(
        context: Context,
        token: String,
        refreshToken: String?,
        apiBaseUrl: String,
        deviceUuid: String,
        authoritative: Boolean,
        accessTokenExpiresAt: String? = null,
        refreshTokenExpiresAt: String? = null,
    ) {
        val prefs = securePrefs(context)
        val stored = prefs.getString(KEY_REFRESH_TOKEN, null)
        // A restore carrying a refresh token other than the stored one is
        // older than this store: only TokenRefresher rotates, and it writes
        // here first. Its access token is from the same stale pair, so it is
        // not written either. Overwriting it was survivable — a stale access
        // token costs one 401 and one refresh — but it was never correct.
        val callerIsStale = !authoritative &&
            !stored.isNullOrBlank() &&
            !refreshToken.isNullOrBlank() &&
            refreshToken != stored
        val tokenIsNew = !callerIsStale && prefs.getString(KEY_AUTH_TOKEN, null) != token
        prefs.edit().apply {
            if (!callerIsStale) putString(KEY_AUTH_TOKEN, token)
            // Only for a token this store has not seen. A restore re-sending the
            // stored one must not make it look freshly issued.
            if (tokenIsNew) putLong(KEY_ACCESS_RECEIVED_AT, System.currentTimeMillis())
            if (!refreshToken.isNullOrBlank() && (authoritative || stored.isNullOrBlank())) {
                putString(KEY_REFRESH_TOKEN, refreshToken)
            } else if (callerIsStale) {
                Log.i(TAG, "Keeping the stored token pair; caller offered an older one.")
            }
            // Expiries travel with the token they describe. Only recorded when
            // the caller is replacing that token, so a restore cannot re-date a
            // pair this store has since rotated.
            if (!accessTokenExpiresAt.isNullOrBlank() && !callerIsStale) {
                putString(KEY_ACCESS_EXPIRES_AT, accessTokenExpiresAt)
            }
            if (!refreshTokenExpiresAt.isNullOrBlank() &&
                (authoritative || stored.isNullOrBlank())
            ) {
                putString(KEY_REFRESH_EXPIRES_AT, refreshTokenExpiresAt)
            }
            putString(KEY_API_BASE_URL, apiBaseUrl)
            putString(KEY_DEVICE_UUID, deviceUuid)
        }.commit()
        if (authoritative) {
            // A new pairing clears the tombstone from whatever killed the last
            // session, so the shell does not bounce the user straight back out.
            prefs.edit().remove(KEY_SESSION_REVOKED_AT).apply()
            // And the next sync asks the server at once: a block recorded
            // against the previous session is lifted only by a check-in.
            NativeStatusCheckIn.markDue(context)
        }
    }

    /**
     * The pair this store currently holds, for Dart to mirror.
     *
     * The counterpart to [saveAuthSession]: native rotates the tokens, so Dart
     * has to read them back rather than assume its own copy is current.
     * `sessionRevokedAtMillis` is non-zero when a refresh was refused outright
     * and the session was cleared — the app shell reads it to move the user to
     * sign-in instead of sitting on a shell with no usable credential.
     */
    fun getAuthSession(context: Context): Map<String, Any?> {
        val p = securePrefs(context)
        return mapOf(
            "token" to p.getString(KEY_AUTH_TOKEN, null),
            "refreshToken" to p.getString(KEY_REFRESH_TOKEN, null),
            "apiBaseUrl" to p.getString(KEY_API_BASE_URL, null),
            "deviceUuid" to p.getString(KEY_DEVICE_UUID, null),
            "accessTokenExpiresAt" to p.getString(KEY_ACCESS_EXPIRES_AT, null),
            "refreshTokenExpiresAt" to p.getString(KEY_REFRESH_EXPIRES_AT, null),
            "sessionRevokedAtMillis" to p.getLong(KEY_SESSION_REVOKED_AT, 0L),
        )
    }

    /**
     * Records that the server refused this session, before it is cleared.
     *
     * Written by [TokenRefresher] on a 401/403/422 from `/auth/refresh`. The
     * native side has no way to push anything to Dart when no engine is
     * running, so it leaves this behind and Dart collects it on next start.
     */
    fun recordSessionRevoked(context: Context) {
        securePrefs(context).edit()
            .putLong(KEY_SESSION_REVOKED_AT, System.currentTimeMillis())
            .commit()
    }

    fun clearSessionRevoked(context: Context) {
        securePrefs(context).edit().remove(KEY_SESSION_REVOKED_AT).apply()
    }

    /**
     * Stores a pair this process just obtained from `/auth/refresh`.
     *
     * Unlike [saveAuthSession] this is always authoritative: the caller is
     * [TokenRefresher], which is the only thing in the app permitted to perform
     * the exchange, and the tokens it is holding are by definition the newest
     * that exist.
     *
     * The expiries are RFC 3339 exactly as the server sent them. They are
     * stored so [getAuthSession] can hand Dart a complete session rather than a
     * new token wearing the previous one's expiry — which would read as already
     * expired and mislead anything that decides to refresh proactively.
     */
    fun updateAuthTokens(
        context: Context,
        accessToken: String,
        refreshToken: String?,
        accessTokenExpiresAt: String? = null,
        refreshTokenExpiresAt: String? = null,
    ) {
        securePrefs(context).edit().apply {
            putString(KEY_AUTH_TOKEN, accessToken)
            putLong(KEY_ACCESS_RECEIVED_AT, System.currentTimeMillis())
            if (!refreshToken.isNullOrBlank()) {
                putString(KEY_REFRESH_TOKEN, refreshToken)
            }
            // Absent means "the server did not say", which must not be confused
            // with "expires at the previous token's time": drop the old value
            // rather than let it describe a token it does not belong to.
            if (accessTokenExpiresAt.isNullOrBlank()) {
                remove(KEY_ACCESS_EXPIRES_AT)
            } else {
                putString(KEY_ACCESS_EXPIRES_AT, accessTokenExpiresAt)
            }
            if (!refreshTokenExpiresAt.isNullOrBlank()) {
                putString(KEY_REFRESH_EXPIRES_AT, refreshTokenExpiresAt)
            }
            // commit, not apply: §2.3 rule 1. The refresh token just sent is
            // already dead server-side. An apply() still queued when the process
            // dies brings it back on restart, and presenting it again revokes
            // the whole session chain.
        }.commit()
    }

    fun clearAuthSession(context: Context) {
        securePrefs(context).edit()
            .remove(KEY_AUTH_TOKEN)
            .remove(KEY_REFRESH_TOKEN)
            .remove(KEY_ACCESS_EXPIRES_AT)
            .remove(KEY_ACCESS_RECEIVED_AT)
            .remove(KEY_REFRESH_EXPIRES_AT)
            .remove(KEY_API_BASE_URL)
            .remove(KEY_DEVICE_UUID)
            .apply()
    }

    fun getAuthToken(context: Context): String? =
        securePrefs(context).getString(KEY_AUTH_TOKEN, null)

    /** When the current access token arrived, or null if that was never recorded. */
    fun getAccessTokenReceivedAt(context: Context): Long? =
        securePrefs(context).getLong(KEY_ACCESS_RECEIVED_AT, 0L).takeIf { it > 0L }

    /**
     * Whether a signed-in employee owns this handset right now.
     *
     * The gate for capture and scheduling: a signed-out phone has nobody to
     * attribute a call to. Cleared by sign-out and by TokenRefresher when the
     * server refuses the session.
     */
    fun hasSession(context: Context): Boolean = !getAuthToken(context).isNullOrBlank()

    fun getRefreshToken(context: Context): String? =
        securePrefs(context).getString(KEY_REFRESH_TOKEN, null)

    fun getApiBaseUrl(context: Context): String? =
        securePrefs(context).getString(KEY_API_BASE_URL, null)

    fun getDeviceUuid(context: Context): String? =
        securePrefs(context).getString(KEY_DEVICE_UUID, null)

    fun recordSyncOutcome(
        context: Context,
        status: String,
        syncedCount: Int,
        error: String? = null,
    ) {
        statsPrefs(context).edit()
            .putLong(KEY_LAST_SYNC_AT, System.currentTimeMillis())
            .putString(KEY_LAST_SYNC_STATUS, status)
            .putInt(KEY_LAST_SYNCED_COUNT, syncedCount)
            .putString(KEY_LAST_SYNC_ERROR, error)
            .apply()
    }

    fun getLastSyncInfo(context: Context): Map<String, Any?> {
        val p = statsPrefs(context)
        return mapOf(
            "lastSyncAtMillis" to p.getLong(KEY_LAST_SYNC_AT, 0L),
            "lastSyncStatus" to p.getString(KEY_LAST_SYNC_STATUS, null),
            "lastSyncedCount" to p.getInt(KEY_LAST_SYNCED_COUNT, 0),
            "lastSyncError" to p.getString(KEY_LAST_SYNC_ERROR, null),
        )
    }
}
