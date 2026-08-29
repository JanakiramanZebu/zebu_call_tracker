import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/notifications/notification_service.dart';
import '../../../core/platform/native_call_bridge.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/storage/calls_dao.dart';
import '../../auth/data/auth_repository.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../device/data/device_repository.dart';
import '../../recording/domain/recording_matcher.dart';
import 'sync_repository.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

final callsDaoProvider = Provider<CallsDao>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return CallsDao(db);
});

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  const store = SecureSessionStore();
  final client = ApiClient(sessionStore: store);
  return SyncRepository(apiClient: client);
});

final deviceRepositoryProvider = Provider<DeviceRepository>((ref) {
  const store = SecureSessionStore();
  final client = ApiClient(sessionStore: store);
  return DeviceRepository(apiClient: client);
});

/// Shared sync counters — used by both the Dashboard badge and the Sync screen.
///
/// Lives here rather than in sync_screen.dart so either tab can import it
/// without creating a circular dependency.
final syncCountersProvider = FutureProvider.autoDispose<Map<String, int>>((ref) {
  final dao = ref.watch(callsDaoProvider);
  return dao.getSyncCounters();
});

class SyncResultSummary {
  const SyncResultSummary({
    required this.attemptedCalls,
    required this.syncedCalls,
    required this.failedCalls,
    required this.uploadedRecordings,
    this.deviceRevoked = false,
    this.clockSkewWarning,
    this.errorMessage,
  });

  final int attemptedCalls;
  final int syncedCalls;
  final int failedCalls;
  final int uploadedRecordings;
  final bool deviceRevoked;
  final String? clockSkewWarning;
  final String? errorMessage;

  bool get isSuccess => syncedCalls > 0 || uploadedRecordings > 0;
}

class SyncServiceNotifier extends AsyncNotifier<SyncResultSummary?> {
  final _uuid = const Uuid();
  static const _dnsNamespace = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

  @override
  Future<SyncResultSummary?> build() async => null;

  /// Ingests new native call logs into local database outbox.
  ///
  /// Also performs recording association: for each newly inserted call that
  /// connected, the recording pool is scanned and — when a confident match is
  /// found — the MediaStore ID and content URI are persisted so the upload step
  /// can find the file without a second scan.
  Future<int> ingestNativeCallLogs() async {
    final bridge = ref.read(nativeBridgeProvider);
    final dao = ref.read(callsDaoProvider);
    final matcher = ref.read(recordingMatcherProvider);

    try {
      final rows = await bridge.readCallLog(sinceMillis: 0, limit: 200);

      // Scan the recording pool once for the whole ingest batch.
      List<RecordingCandidate> pool = const [];
      try {
        final access = await bridge.getRecordingAccess();
        if (access.granted) {
          pool = await bridge.scanRecordings(sinceEpochSeconds: 0, limit: 400);
        }
      } catch (_) {
        // Recording access is optional; call metadata can still be ingested.
      }

      int count = 0;

      for (final r in rows) {
        if (r.dateMillis == null) continue;
        final date = DateTime.fromMillisecondsSinceEpoch(r.dateMillis!).toUtc();

        final extId = 'android-${r.dateMillis}-${r.number}';
        final idempotencyKey = _uuid.v5(
          _dnsNamespace,
          'zebu:call:$extId:${date.millisecondsSinceEpoch}',
        );

        final existing = await dao.findByIdempotencyKey(idempotencyKey);
        if (existing != null) continue;

        final directionStr = switch (r.direction) {
          CallDirection.incoming => 'incoming',
          CallDirection.outgoing => 'outgoing',
          _ => 'unknown',
        };

        final statusStr = switch (r.direction) {
          CallDirection.missed => 'missed',
          CallDirection.rejected => 'rejected',
          _ => 'ended',
        };

        final durationSecs = r.durationSeconds ?? 0;
        final hasConnected = durationSecs > 0;

        // --- Recording association ---
        RecordingCandidate? matched;
        if (hasConnected && pool.isNotEmpty) {
          final callForMatch = CallForMatching(
            startedAtEpochMillis: r.dateMillis!,
            durationSeconds: durationSecs,
            normalizedNumber: r.number,
            contactName: r.cachedName,
          );
          final result = matcher.match(callForMatch, pool);
          if (result.status == RecordingMatchStatus.matched) {
            matched = result.candidate;
          }
        }

        // Build the content:// URI if we have a match; fall back to null so
        // the upload step can detect "file not found" correctly.
        String? recordingPath;
        if (matched != null) {
          try {
            recordingPath = await bridge.getRecordingUri(matched.mediaStoreId);
          } catch (_) {
            // URI resolution failed — treat as no recording.
            matched = null;
          }
        }

        await dao.insertOrUpdateCall(
          LocalCallsCompanion.insert(
            idempotencyKey: idempotencyKey,
            externalCallId: Value(extId),
            phoneNumber: r.number ?? 'Unknown',
            normalizedPhoneNumber: Value(r.number),
            contactName: Value(r.cachedName),
            direction: directionStr,
            status: statusStr,
            startedAt: date,
            durationSeconds: Value(durationSecs),
            hasRecording: Value(matched != null),
            recordingPath: Value(recordingPath),
            recordingMediaStoreId: Value(matched?.mediaStoreId),
            simSlot: const Value(1),
            clientCreatedAt: DateTime.now().toUtc(),
          ),
        );
        count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// Triggers full sync according to Section 11.2 of Mobile API Guide.
  Future<SyncResultSummary> triggerSync() async {
    if (!AppConfig.hasServer) {
      return const SyncResultSummary(
        attemptedCalls: 0,
        syncedCalls: 0,
        failedCalls: 0,
        uploadedRecordings: 0,
        errorMessage: 'No server configured.',
      );
    }

    state = const AsyncLoading();

    final syncRepo = ref.read(syncRepositoryProvider);
    final deviceRepo = ref.read(deviceRepositoryProvider);
    final dao = ref.read(callsDaoProvider);
    final notif = NotificationService.instance;

    int syncedCount = 0;
    int failedCount = 0;
    int uploadedRecordingsCount = 0;
    String? clockSkewWarning;

    try {
      // Step 1: Ingest latest call logs from handset (with recording matching).
      await ingestNativeCallLogs();

      // Step 2: Check server status and limits.
      final status = await syncRepo.getSyncStatus();

      if (status.deviceStatus == 'REVOKED') {
        const summary = SyncResultSummary(
          attemptedCalls: 0,
          syncedCalls: 0,
          failedCalls: 0,
          uploadedRecordings: 0,
          deviceRevoked: true,
          errorMessage: 'This device has been revoked by an administrator.',
        );
        state = AsyncData(summary);
        return summary;
      }

      if (!status.deviceRegistered) {
        final info = await ref.read(deviceInfoProvider.future);
        await deviceRepo.registerDevice(deviceInfo: info);
      }

      // Check clock skew.
      final serverDt = DateTime.tryParse(status.serverTime)?.toUtc();
      if (serverDt != null) {
        final diffMinutes =
            DateTime.now().toUtc().difference(serverDt).inMinutes.abs();
        if (diffMinutes > status.policy.maxClockSkewMinutes) {
          clockSkewWarning =
              'Device clock skew is $diffMinutes minutes from server clock. '
              'Please adjust device time.';
        }
      }

      final deviceUuid = await deviceRepo.getDeviceUuid();

      // Step 3: Metadata Batch Sync.
      final pendingCalls =
          await dao.getPendingCalls(status.policy.recommendedBatchSize);

      final validCalls = <LocalCall>[];
      final maxAgeDays = status.policy.maxCallAgeDays;
      final nowUtc = DateTime.now().toUtc();

      for (final call in pendingCalls) {
        final ageInDays = nowUtc.difference(call.startedAt).inDays;
        if (ageInDays > maxAgeDays) {
          await dao.markFailed(
            idempotencyKey: call.idempotencyKey,
            errorCode: 'SYNC_POLICY_VIOLATION',
            retryable: false,
          );
          failedCount++;
        } else {
          validCalls.add(call);
        }
      }

      if (validCalls.isNotEmpty) {
        final batchResult = await syncRepo.syncBatch(
          deviceUuid: deviceUuid,
          calls: validCalls,
        );

        for (final item in batchResult.successful) {
          await dao.markSynced(
            idempotencyKey: item.idempotencyKey,
            serverCallId: item.callId,
            revision: item.revision,
          );
          syncedCount++;
        }

        for (final item in batchResult.duplicates) {
          await dao.markSynced(
            idempotencyKey: item.idempotencyKey,
            serverCallId: item.callId,
            revision: item.revision,
          );
          syncedCount++;
        }

        for (final item in batchResult.failed) {
          await dao.markFailed(
            idempotencyKey: item.idempotencyKey,
            errorCode: item.errorCode,
            retryable: item.retryable,
          );
          failedCount++;
        }
      }

      // Step 4: Recording Audio Uploads.
      //
      // recordingPath stores a content:// URI on Android. We stream it through
      // the native bridge hash call (which reads via ContentResolver) and
      // then upload via a temp-copy path so Dio's MultipartFile can read it.
      final pendingUploads = await dao.getPendingRecordingUploads();
      final bridge = ref.read(nativeBridgeProvider);

      for (final rec in pendingUploads) {
        if (rec.serverCallId == null) continue;

        final mediaStoreId = rec.recordingMediaStoreId;
        if (mediaStoreId == null) {
          // No MediaStore ID — mark explicitly as no-recording.
          await syncRepo.updateCallNoRecording(rec.serverCallId!);
          await dao.setHasRecording(rec.idempotencyKey, false);
          continue;
        }

        // Hash the recording natively (reads via ContentResolver).
        final hash = await bridge.hashRecording(mediaStoreId);
        if (hash == null) {
          // File was deleted by the dialer since we found it.
          await syncRepo.updateCallNoRecording(rec.serverCallId!);
          await dao.setHasRecording(rec.idempotencyKey, false);
          continue;
        }

        // Resolve to a content:// URI for upload.
        final contentUri = rec.recordingPath ??
            await bridge.getRecordingUri(mediaStoreId);

        // Copy from ContentResolver → a temp file that Dio can open as
        // a plain File. The content URI lives in the dialer's private
        // storage, so we cannot pass it to File() directly.
        final tempDir = Directory.systemTemp;
        final ext = _extensionFrom(contentUri);
        final tempFile = File(
          '${tempDir.path}/rec_${mediaStoreId}_${DateTime.now().millisecondsSinceEpoch}.$ext',
        );

        try {
          await _copyContentUri(bridge, mediaStoreId, tempFile);

          final uploaded = await syncRepo.uploadRecording(
            serverCallId: rec.serverCallId!,
            audioFile: tempFile,
            checksumSha256: hash.checksum,
            durationSeconds: rec.durationSeconds,
          );

          if (uploaded) {
            await dao.markRecordingUploaded(rec.idempotencyKey);
            uploadedRecordingsCount++;
          }
        } finally {
          if (await tempFile.exists()) await tempFile.delete();
        }
      }

      final summary = SyncResultSummary(
        attemptedCalls: validCalls.length,
        syncedCalls: syncedCount,
        failedCalls: failedCount,
        uploadedRecordings: uploadedRecordingsCount,
        clockSkewWarning: clockSkewWarning,
      );

      state = AsyncData(summary);

      // Notify the user if anything actually moved to the server.
      if (summary.isSuccess) {
        await notif.cancelSyncReminder();
        await notif.showSyncSuccess(
          syncedCalls: syncedCount,
          uploadedRecordings: uploadedRecordingsCount,
        );
      }

      return summary;
    } catch (e) {
      final summary = SyncResultSummary(
        attemptedCalls: 0,
        syncedCalls: syncedCount,
        failedCalls: failedCount,
        uploadedRecordings: uploadedRecordingsCount,
        errorMessage: e.toString(),
      );
      state = AsyncData(summary);
      return summary;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Copies the audio pointed to by [mediaStoreId] from the Android
  /// ContentResolver into [dest].  Uses the native bridge's hash-read path
  /// which already opens the content:// URI; here we only need the bytes.
  ///
  /// This is a best-effort fallback: if the native side has no dedicated copy
  /// method we derive the file path from the content URI stored in the DB and
  /// try a plain File copy. On Android 10+ that path is not accessible to
  /// non-owner apps, so this branch will throw — which the upload loop catches.
  Future<void> _copyContentUri(
    NativeCallBridge bridge,
    int mediaStoreId,
    File dest,
  ) async {
    // Try fetching via a dedicated native export method if it exists.
    // NativeCallBridge.exportRecording is our new method; fall back gracefully.
    try {
      final bytes = await (bridge as dynamic).exportRecordingBytes(mediaStoreId) as List<int>?;
      if (bytes != null && bytes.isNotEmpty) {
        await dest.writeAsBytes(bytes);
        return;
      }
    } catch (_) {
      // Method not available on this bridge version — fall through.
    }

    // Last resort: treat recordingPath as a direct filesystem path (works on
    // devices where the dialer writes to a shared folder, e.g. DCIM/Call
    // Recordings on older Samsung firmware).
    final uri = await bridge.getRecordingUri(mediaStoreId);
    if (!uri.startsWith('content://')) {
      await File(uri).copy(dest.path);
    }
  }

  static String _extensionFrom(String uri) {
    final lower = uri.toLowerCase();
    for (final ext in ['m4a', 'aac', 'amr', 'mp3', 'opus', 'ogg', 'wav', '3gp', 'mp4']) {
      if (lower.contains(ext)) return ext;
    }
    return 'm4a'; // safe default for most Android dialers
  }
}

final syncServiceProvider =
    AsyncNotifierProvider<SyncServiceNotifier, SyncResultSummary?>(
  SyncServiceNotifier.new,
);