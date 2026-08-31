import 'package:flutter_test/flutter_test.dart';
import 'package:zebu_call_tracker/core/platform/native_call_bridge.dart';
import 'package:zebu_call_tracker/core/storage/app_database.dart';
import 'package:zebu_call_tracker/features/call_tracking/domain/call_entry.dart';
import 'package:zebu_call_tracker/features/synchronization/data/sync_repository.dart';

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
      expect(stats.recordingsAbsent, equals(2));
    });
  });

  group('Sync Data Models & Results Tests', () {
    test('SingleCallSyncResult supports successful and failure payloads', () {
      const successResult = SingleCallSyncResult(
        idempotencyKey: 'key-test-1',
        callId: 'server-call-100',
        revision: 2,
        isSuccess: true,
      );

      expect(successResult.isSuccess, isTrue);
      expect(successResult.callId, equals('server-call-100'));
      expect(successResult.revision, equals(2));

      const failedResult = SingleCallSyncResult(
        idempotencyKey: 'key-test-2',
        errorCode: 'NETWORK_TIMEOUT',
        errorMessage: 'Connection timed out',
        isRetryable: true,
        isSuccess: false,
      );

      expect(failedResult.isSuccess, isFalse);
      expect(failedResult.errorCode, equals('NETWORK_TIMEOUT'));
      expect(failedResult.isRetryable, isTrue);
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
