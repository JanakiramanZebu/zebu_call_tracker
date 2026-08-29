import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zebu_call_tracker/core/storage/app_database.dart';
import 'package:zebu_call_tracker/core/theme/app_theme.dart';
import 'package:zebu_call_tracker/features/synchronization/data/sync_service.dart';
import 'package:zebu_call_tracker/features/synchronization/presentation/outbox_queue_screen.dart';

void main() {
  testWidgets('OutboxQueueScreen renders and displays pending items', (tester) async {
    final List<LocalCall> fakeCalls = [
      LocalCall(
        localId: 1,
        idempotencyKey: 'key-1',
        revision: 0,
        phoneNumber: '+919876543210',
        contactName: 'Test Contact',
        direction: 'incoming',
        status: 'completed',
        startedAt: DateTime.now().subtract(const Duration(minutes: 5)),
        durationSeconds: 120,
        hasRecording: true,
        recordingUploadStatus: 'pending',
        clientCreatedAt: DateTime.now(),
        syncState: 'pending',
        attemptCount: 0,
      ),
      LocalCall(
        localId: 2,
        idempotencyKey: 'key-2',
        revision: 0,
        phoneNumber: '+919123456789',
        contactName: null,
        direction: 'outgoing',
        status: 'completed',
        startedAt: DateTime.now().subtract(const Duration(hours: 1)),
        durationSeconds: 45,
        hasRecording: false,
        recordingUploadStatus: 'pending',
        clientCreatedAt: DateTime.now(),
        syncState: 'failed_retryable',
        attemptCount: 2,
        lastErrorCode: 'NETWORK_ERROR',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          outboxItemsProvider.overrideWith((ref) async => fakeCalls),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const OutboxQueueScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(OutboxQueueScreen), findsOneWidget);
    expect(find.text('Call Metadata Outbox'), findsOneWidget);
    expect(find.text('Test Contact'), findsOneWidget);
    expect(find.text('+919123456789'), findsOneWidget);
    expect(find.text('PENDING'), findsOneWidget);
    expect(find.text('RETRYING'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
