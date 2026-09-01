import 'package:flutter_test/flutter_test.dart';

import 'package:zebu_call_tracker/core/platform/native_call_bridge.dart';
import 'package:zebu_call_tracker/core/storage/app_database.dart';
import 'package:zebu_call_tracker/core/storage/sync_state.dart';
import 'package:zebu_call_tracker/features/call_tracking/domain/call_entry.dart';

void main() {
  group('Analytics Data Aggregation Tests', () {
    final t1 = DateTime.utc(2026, 8, 31, 10, 0, 0);
    final t2 = DateTime.utc(2026, 8, 31, 11, 0, 0);
    final t3 = DateTime.utc(2026, 8, 31, 12, 0, 0);
    final t4 = DateTime.utc(2026, 8, 31, 13, 0, 0);

    final mockCalls = [
      LocalCall(
        localId: 1,
        idempotencyKey: 'key-1',
        revision: 1,
        phoneNumber: '+919876543210',
        contactName: 'Client A',
        direction: 'incoming',
        status: 'completed',
        startedAt: t1,
        durationSeconds: 120,
        hasRecording: true,
        recordingUploadStatus: 'uploaded',
        clientCreatedAt: t1,
        syncState: 'synced',
        attemptCount: 1,
      ),
      LocalCall(
        localId: 2,
        idempotencyKey: 'key-2',
        revision: 1,
        phoneNumber: '+919876543210',
        contactName: 'Client A',
        direction: 'incoming',
        status: 'missed',
        startedAt: t2,
        durationSeconds: 0,
        hasRecording: false,
        recordingUploadStatus: 'none',
        clientCreatedAt: t2,
        syncState: 'pending',
        attemptCount: 0,
      ),
      LocalCall(
        localId: 3,
        idempotencyKey: 'key-3',
        revision: 1,
        phoneNumber: '+919123456789',
        contactName: 'Client B',
        direction: 'outgoing',
        status: 'completed',
        startedAt: t3,
        durationSeconds: 180,
        hasRecording: true,
        recordingUploadStatus: 'uploaded',
        clientCreatedAt: t3,
        syncState: 'synced',
        attemptCount: 1,
      ),
      LocalCall(
        localId: 4,
        idempotencyKey: 'key-4',
        revision: 1,
        phoneNumber: '+919123456789',
        contactName: 'Client B',
        direction: 'outgoing',
        status: 'completed',
        startedAt: t4,
        durationSeconds: 0, // Unanswered outgoing
        hasRecording: false,
        recordingUploadStatus: 'none',
        clientCreatedAt: t4,
        syncState: 'failed_retryable',
        attemptCount: 1,
      ),
    ];

    test('CallStats.fromLocalCalls accurately aggregates call metrics', () {
      final stats = CallStats.fromLocalCalls(mockCalls);

      expect(stats.total, equals(4));
      expect(stats.incoming, equals(1));
      expect(stats.outgoing, equals(2));
      expect(stats.missed, equals(1));
      expect(stats.neverAttended, equals(1)); // 1 missed incoming
      expect(stats.notPickupByClient, equals(1)); // 1 unanswered outgoing
      expect(stats.answered, equals(2)); // calls with duration > 0
      expect(stats.talkTimeSeconds, equals(300)); // 120 + 180
      expect(stats.incomingDurationSeconds, equals(120));
      expect(stats.outgoingDurationSeconds, equals(180));
      expect(stats.uniqueCalls, equals(2)); // '+919876543210' and '+919123456789'
      expect(stats.recordingsMatched, equals(2));

      // Only connected calls can have audio. The missed incoming and the
      // unanswered outgoing are not coverage gaps — counting them as such
      // (which this assertion previously did) makes recording coverage look
      // broken on any day with a normal number of unanswered calls.
      expect(stats.recordingsAbsent, isZero);
      expect(stats.recordingsNotApplicable, equals(2));
      expect(stats.recordingEligible, equals(2));
      expect(stats.recordingCoverageRate, equals(100.0));
    });

    test('unique contacts ignore formatting differences', () {
      // The same client, as three OEM dialers would write the number.
      final sameClient = [
        for (final (i, number) in const [
          '+919876543210',
          '09876543210',
          '98765 43210',
        ].indexed)
          LocalCall(
            localId: i + 1,
            idempotencyKey: 'fmt-$i',
            revision: 1,
            phoneNumber: number,
            direction: 'incoming',
            status: 'completed',
            startedAt: t1,
            durationSeconds: 30,
            hasRecording: true,
            recordingUploadStatus: 'uploaded',
            clientCreatedAt: t1,
            syncState: CallSyncState.uploaded,
            attemptCount: 0,
          ),
      ];

      expect(CallStats.fromLocalCalls(sameClient).uniqueCalls, equals(1));
    });

    test('peak window is the busiest two-hour band of connected calls', () {
      final stats = CallStats.fromLocalCalls(mockCalls);

      // t1 (10:00) and t3 (12:00) connected; t2/t4 did not and must not count.
      final hours = stats.callsByHour;
      expect(hours, hasLength(24));
      expect(hours.reduce((a, b) => a + b), equals(2));

      // Both bands starting at 10:00 and 11:00 cover one connected call each;
      // 11:00 covers the 12:00 call too, so it wins outright only if a second
      // call falls in it. Assert the band actually contains a call.
      final peak = stats.peakHourStart;
      expect(peak, isNotNull);
      expect(hours[peak!] + hours[(peak + 1) % 24], greaterThan(0));
    });

    test('peak window is null with nothing to rank', () {
      expect(CallStats.fromLocalCalls(const []).peakHourStart, isNull);
      expect(CallStats.empty.peakHourStart, isNull);
    });
  });

  group('Sync Data Models & Results Tests', () {
    test('every state a writer produces is classified by a reader', () {
      // The defect this guards: Dart wrote 'synced'/'failed_permanent' while
      // the native coordinator wrote 'UPLOADED'/'FAILED' into the same column.
      // No reader matched both, so successful uploads showed as pending
      // forever and every retry query updated zero rows.
      const written = [
        CallSyncState.waiting,
        CallSyncState.uploading,
        CallSyncState.uploaded,
        CallSyncState.retryPending,
        CallSyncState.failed,
      ];

      for (final state in written) {
        expect(CallSyncState.normalize(state), equals(state),
            reason: '$state must be its own canonical form');
      }

      expect(CallSyncState.isUploaded(CallSyncState.uploaded), isTrue);
      expect(CallSyncState.isInFlight(CallSyncState.uploading), isTrue);
      expect(CallSyncState.isFailed(CallSyncState.failed), isTrue);
      expect(CallSyncState.isFailed(CallSyncState.retryPending), isTrue);
      expect(CallSyncState.isPending(CallSyncState.waiting), isTrue);
      expect(CallSyncState.isPending(CallSyncState.uploaded), isFalse);
    });

    test('rows written by the previous vocabulary still classify', () {
      // Installs that predate the unification carry these on disk until the
      // normalisation pass at database open catches them.
      expect(CallSyncState.normalize('synced'), equals(CallSyncState.uploaded));
      expect(CallSyncState.normalize('pending'), equals(CallSyncState.waiting));
      expect(CallSyncState.normalize('failed_permanent'),
          equals(CallSyncState.failed));
      expect(CallSyncState.normalize('failed_retryable'),
          equals(CallSyncState.retryPending));

      expect(CallSyncState.isUploaded('synced'), isTrue);
      expect(CallSyncState.isFailed('failed_permanent'), isTrue);
      expect(CallSyncState.isFailed('failed_retryable'), isTrue);
    });

    test('normalisation SQL rewrites every legacy name', () {
      final statements = CallSyncState.normalizationStatements;

      // One UPDATE per legacy spelling. 'uploading' is included: it differs
      // from 'UPLOADING' by case, and SQLite string comparison is case
      // sensitive, so leaving it out would strand those rows.
      expect(statements, hasLength(6));
      for (final s in statements) {
        expect(s, startsWith('UPDATE local_calls SET sync_state = '));
      }
      expect(
        statements,
        contains(
          "UPDATE local_calls SET sync_state = 'UPLOADING' "
          "WHERE sync_state = 'uploading';",
        ),
      );
      expect(
        statements,
        contains(
          "UPDATE local_calls SET sync_state = 'UPLOADED' "
          "WHERE sync_state = 'synced';",
        ),
      );
    });

    test('IngestSnapshot parses native batches and syncedCalls properly', () {
      final mockData = {
        'batches': [
          {
            'capturedAtMillis': 1725000000000,
            'calls': [],
            'recordings': [],
          }
        ],
        'syncedCalls': [
          {
            'idempotencyKey': 'zebu:call:ext-1:1725000000000',
            'serverCallId': 'srv-101',
            'syncedAtMillis': 1725000010000,
          }
        ],
        'overflowed': false,
      };

      final snapshot = IngestSnapshot.fromPlatform(mockData);

      expect(snapshot.batches.length, equals(1));
      expect(snapshot.syncedCalls.length, equals(1));
      expect(snapshot.syncedCalls.first.idempotencyKey, equals('zebu:call:ext-1:1725000000000'));
      expect(snapshot.syncedCalls.first.serverCallId, equals('srv-101'));
      expect(snapshot.isEmpty, isFalse);
    });
  });
}
