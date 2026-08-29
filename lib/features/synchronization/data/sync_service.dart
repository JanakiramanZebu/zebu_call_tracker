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
import '../../../core/storage/database_providers.dart';
import '../../auth/data/auth_repository.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../device/data/device_repository.dart';
import '../../recording/domain/recording_matcher.dart';
import 'sync_repository.dart';



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

/// Shared sync counters — stream-backed for instant UI updates.
final syncCountersProvider = StreamProvider.autoDispose<Map<String, int>>((ref) {
  final dao = ref.watch(callsDaoProvider);
  return dao.watchSyncCounters();
});

enum OutboxFilter { all, pending, failed, synced }

class OutboxFilterController extends Notifier<OutboxFilter> {
  @override
  OutboxFilter build() => OutboxFilter.pending;

  void select(OutboxFilter filter) => state = filter;
}

final outboxFilterProvider =
    NotifierProvider<OutboxFilterController, OutboxFilter>(
  OutboxFilterController.new,
);

final outboxItemsProvider = FutureProvider.autoDispose<List<LocalCall>>((ref) async {
  final dao = ref.watch(callsDaoProvider);
  final filter = ref.watch(outboxFilterProvider);
  final filterKey = switch (filter) {
    OutboxFilter.all => null,
    OutboxFilter.pending => 'pending',
    OutboxFilter.failed => 'failed',
    OutboxFilter.synced => 'synced',
  };
  return dao.getOutboxItems(filter: filterKey);
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

  Future<void> retryCall(String idempotencyKey) async {
    final dao = ref.read(callsDaoProvider);
    await dao.retryCall(idempotencyKey);
    ref.invalidate(outboxItemsProvider);
    await triggerSync();
  }

  Future<void> retryAllFailed() async {
    final dao = ref.read(callsDaoProvider);
    await dao.retryAllFailed();
    ref.invalidate(outboxItemsProvider);
    await triggerSync();
  }

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
      // Scan the recording pool once for the whole ingest operation.
      List<RecordingCandidate> pool = const [];
      try {
        final access = await bridge.getRecordingAccess();
        if (access.granted) {
          pool = await bridge.scanRecordings(sinceEpochSeconds: 0, limit: 2000);
          pool = await bridge.scanRecordings(sinceEpochSeconds: 0, limit: 100000);
        }
      } catch (_) {
        // Recording access is optional; call metadata can still be ingested.
      }

      int totalIngested = 0;
      int beforeMillis = 0;
      int maxPages = 30; // up to 15,000 historical call rows
      int maxPages = 1000; // unlimited historical call rows
      int pageCount = 0;

      while (pageCount < maxPages) {
        pageCount++;
        final rows = await bridge.readCallLog(
          sinceMillis: 0,
          beforeMillis: beforeMillis,
          limit: 500,
        );

        if (rows.isEmpty) break;

        int pageIngested = 0;
        for (final r in rows) {
          if (r.dateMillis == null) continue;
          final date = DateTime.fromMillisecondsSinceEpoch(r.dateMillis!).toUtc();

          final extId = 'android-${r.dateMillis}-${r.number}';
          final idempotencyKey = _uuid.v5(
            _dnsNamespace,
            'zebu:call:$extId:${date.millisecondsSinceEpoch}',
          );

          final existing = await dao.findByIdempotencyKey(idempotencyKey);
          if (existing != null) {
            // Check if unlinked call can now be linked to a recording candidate
            if ((!existing.hasRecording || existing.recordingMediaStoreId == null) &&
                pool.isNotEmpty &&
                (r.durationSeconds ?? 0) > 0) {
              final callForMatch = CallForMatching(
                startedAtEpochMillis: r.dateMillis!,
                durationSeconds: r.durationSeconds ?? 0,
                normalizedNumber: r.number,
                contactName: r.cachedName,
              );
              final result = matcher.match(callForMatch, pool);
              if (result.status == RecordingMatchStatus.matched && result.candidate != null) {
                try {
                  final recPath = await bridge.getRecordingUri(result.candidate!.mediaStoreId);
                  await dao.updateRecordingInfo(
                    idempotencyKey: idempotencyKey,
                    recordingPath: recPath,
                    mediaStoreId: result.candidate!.mediaStoreId,
                  );
                } catch (_) {}
              }
            }
            continue;
          }

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

          String? recordingPath;
          if (matched != null) {
            try {
              recordingPath = await bridge.getRecordingUri(matched.mediaStoreId);
            } catch (_) {
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
          pageIngested++;
        }

        totalIngested += pageIngested;

        final lastDate = rows.last.dateMillis;
        if (lastDate == null || lastDate == beforeMillis) break;
        beforeMillis = lastDate;
      }

      // Secondary retroactive pass: re-scan database calls that connected but lack recording link
      if (pool.isNotEmpty) {
        final unlinked = await dao.getCallsNeedingRecordingMatch();
        for (final call in unlinked) {
          final callForMatch = CallForMatching(
            startedAtEpochMillis: call.startedAt.millisecondsSinceEpoch,
            durationSeconds: call.durationSeconds,
            normalizedNumber: call.normalizedPhoneNumber,
            contactName: call.contactName,
          );
          final result = matcher.match(callForMatch, pool);
          if (result.status == RecordingMatchStatus.matched && result.candidate != null) {
            try {
              final recPath = await bridge.getRecordingUri(result.candidate!.mediaStoreId);
              await dao.updateRecordingInfo(
                idempotencyKey: call.idempotencyKey,
                recordingPath: recPath,
                mediaStoreId: result.candidate!.mediaStoreId,
              );
            } catch (_) {}
          }
        }
      }

      return totalIngested;
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

    int totalAttemptedCalls = 0;
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
      final bridge = ref.read(nativeBridgeProvider);

      // Loop multi-batch processing until ALL pending calls and ALL pending recording uploads are completed.
      bool continueSyncing = true;
      int maxLoops = 20; // safety ceiling for large backlogs
      int maxLoops = 1000; // safety ceiling for large backlogs
      int loopCount = 0;

      while (continueSyncing && loopCount < maxLoops) {
        loopCount++;
        continueSyncing = false;

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
          validCalls.add(call);
        }

        if (validCalls.isNotEmpty) {
          totalAttemptedCalls += validCalls.length;
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

          // If there were valid calls processed, check if more remain in next loop
          if (batchResult.successful.isNotEmpty || batchResult.duplicates.isNotEmpty) {
            continueSyncing = true;
          }
        }

        // Step 4: Recording Audio Uploads.
        final pendingUploads = await dao.getPendingRecordingUploads();

        if (pendingUploads.isNotEmpty) {
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
                continueSyncing = true;
              }
            } catch (e) {
              // Log or ignore so one bad file doesn't stop the whole queue
            } finally {
              if (await tempFile.exists()) await tempFile.delete();
            }
          }
        }
      }

      final summary = SyncResultSummary(
        attemptedCalls: totalAttemptedCalls,
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
        attemptedCalls: totalAttemptedCalls,
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
    try {
      final success = await bridge.exportRecordingToFile(mediaStoreId, dest.path);
      if (success) {
        return;
      }
    } catch (_) {
      // Fall through to legacy exportBytes or file copy
    }

    try {
      final bytes = await bridge.exportRecordingBytes(mediaStoreId);
      if (bytes != null && bytes.isNotEmpty) {
        await dest.writeAsBytes(bytes);
        return;
      }
    } catch (_) {
      // Fall through to filesystem copy if native export fails
    }

    final uri = await bridge.getRecordingUri(mediaStoreId);
    if (!uri.startsWith('content://') && await File(uri).exists()) {
      await File(uri).copy(dest.path);
      return;
    }

    throw Exception('Could not read recording audio for mediaStoreId: $mediaStoreId');
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