package `in`.mynt.zebu_call_tracker.background

/**
 * The single vocabulary for `local_calls.sync_state`.
 *
 * Mirror of `lib/core/storage/sync_state.dart`. The Dart and Kotlin sides
 * write the same SQLite file, so these literals are a contract: change one
 * file and you must change the other.
 */
object SyncStates {
    const val WAITING = "WAITING"
    const val UPLOADING = "UPLOADING"
    const val UPLOADED = "UPLOADED"
    const val RETRY_PENDING = "RETRY_PENDING"
    const val FAILED = "FAILED"

    /**
     * Legacy lowercase names from before the vocabularies were unified,
     * mapped onto their current equivalent. Applied on every database open so
     * an upgraded install converges without a schema-version bump — bumping
     * the version here would make `SQLiteOpenHelper` and drift disagree, and
     * whichever is older would refuse to open the file at all.
     */
    private val LEGACY = linkedMapOf(
        "pending" to WAITING,
        "synced" to UPLOADED,
        "skipped" to UPLOADED,
        "uploading" to UPLOADING,
        "failed_retryable" to RETRY_PENDING,
        "failed_permanent" to FAILED,
    )

    val normalizationStatements: List<String>
        get() = LEGACY.entries
            .filter { it.key != it.value }
            .map { "UPDATE local_calls SET sync_state = '${it.value}' WHERE sync_state = '${it.key}';" }
}

/**
 * Per-call recording lifecycle, independent of [SyncStates].
 *
 * A call can be UPLOADED (server has the metadata) while its recording is
 * still pending — the normal case for an OEM dialer that writes its audio
 * file seconds after the call-log row appears.
 */
object RecordingStates {
    const val PENDING = "pending"
    const val WAITING_FOR_RECORDING = "waiting_for_recording"
    const val UPLOADED = "uploaded"
    const val FAILED = "failed"
    const val ABSENT = "absent"
}
