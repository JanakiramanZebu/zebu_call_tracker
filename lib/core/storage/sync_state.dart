/// The single vocabulary for `local_calls.sync_state` and
/// `local_calls.recording_upload_status`.
///
/// This table is written by BOTH sides of the app:
///
///  - Dart (drift) while the UI is up, and
///  - Kotlin (`NativeCallOutboxDao` / `SyncCoordinator`) while the Flutter
///    engine is dead.
///
/// They share one SQLite file, so they must share one set of literals. An
/// earlier iteration used lowercase names on the Dart side (`synced`,
/// `failed_permanent`, `failed_retryable`, `uploading`) and uppercase ones
/// natively; the two never matched, so completed uploads never surfaced in the
/// UI and every retry query updated zero rows.
///
/// **Any change here must be mirrored in
/// `android/.../background/SyncStates.kt`.** The two files are a contract.
abstract final class CallSyncState {
  /// Captured locally, never sent.
  static const waiting = 'WAITING';

  /// Claimed by the coordinator; an upload is in flight for it right now.
  static const uploading = 'UPLOADING';

  /// Server has the call metadata. Says nothing about the recording — that is
  /// tracked separately by [RecordingUploadStatus].
  static const uploaded = 'UPLOADED';

  /// Failed on something transient. `next_attempt_at` holds the earliest retry.
  static const retryPending = 'RETRY_PENDING';

  /// Failed on something the server will keep rejecting. Only a manual retry
  /// moves it out of here.
  static const failed = 'FAILED';

  /// Rows the coordinator may claim.
  static const claimable = [waiting, retryPending];

  /// States that mean "the server has this call".
  static const terminalSuccess = [uploaded];

  /// Legacy lowercase names, mapped to their current equivalent.
  ///
  /// Retained because installs from before the vocabularies were unified still
  /// have these values on disk. [normalize] is applied on every database open
  /// on both sides, so this map can be dropped once no such install remains.
  static const _legacy = <String, String>{
    'pending': waiting,
    'uploading': uploading,
    'synced': uploaded,
    'skipped': uploaded,
    'failed_retryable': retryPending,
    'failed_permanent': failed,
  };

  /// Maps any historical value onto the current vocabulary.
  static String normalize(String raw) => _legacy[raw] ?? raw;

  static bool isUploaded(String raw) => normalize(raw) == uploaded;

  static bool isFailed(String raw) {
    final s = normalize(raw);
    return s == failed || s == retryPending;
  }

  static bool isPermanentFailure(String raw) => normalize(raw) == failed;

  static bool isInFlight(String raw) => normalize(raw) == uploading;

  /// Anything the server does not yet have.
  static bool isPending(String raw) => !isUploaded(raw);

  /// The `UPDATE` statements that fold legacy rows onto current names.
  ///
  /// Idempotent, and cheap enough to run on every open rather than gating it
  /// behind a schema version — bumping `schemaVersion` would desynchronise
  /// drift from Kotlin's `SQLiteOpenHelper`, which refuses to open a database
  /// newer than its own version and would take background sync down with it.
  static List<String> get normalizationStatements => [
        for (final entry in _legacy.entries)
          if (entry.key != entry.value)
            "UPDATE local_calls SET sync_state = '${entry.value}' "
                "WHERE sync_state = '${entry.key}';",
      ];
}

/// Per-call recording lifecycle, independent of [CallSyncState].
///
/// A call can be `UPLOADED` (server has the metadata) while its recording is
/// still `pending` — that is the normal case for an OEM dialer that writes its
/// audio file a few seconds after the call log row.
abstract final class RecordingUploadStatus {
  /// A recording is linked and waiting to be uploaded.
  static const pending = 'pending';

  /// The call connected, so a recording may still appear. Set at capture time
  /// and expired to [absent] once the discovery window closes.
  static const waitingForRecording = 'waiting_for_recording';

  /// Server has the audio.
  static const uploaded = 'uploaded';

  /// Upload was attempted and rejected.
  static const failed = 'failed';

  /// No recording exists for this call and none is coming.
  static const absent = 'absent';
}
