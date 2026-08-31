import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zebu_call_tracker/core/platform/native_call_bridge.dart';
import 'package:zebu_call_tracker/core/theme/app_theme.dart';
import 'package:zebu_call_tracker/features/call_logs/presentation/call_history_screen.dart';
import 'package:zebu_call_tracker/features/call_tracking/data/call_feed.dart';
import 'package:zebu_call_tracker/features/call_tracking/domain/call_entry.dart';
import 'package:zebu_call_tracker/features/recording/domain/recording_matcher.dart';

class FakeCallFeedWithEntries extends CallFeed {
  @override
  Future<CallFeedState> build() async {
    final entry1 = CallEntry(
      row: CallLogRow(
        systemId: 1,
        number: '+919876543210',
        direction: CallDirection.incoming,
        durationSeconds: 120,
        dateMillis: DateTime.now().millisecondsSinceEpoch - 10000,
        cachedName: 'Alice Smith',
        presentation: NumberPresentation.allowed,
        phoneAccountId: 'sim_1',
      ),
      match: const RecordingMatch(
        status: RecordingMatchStatus.unmatched,
        confidence: 0,
      ),
      contactName: 'Alice Smith',
    );

    final entry2 = CallEntry(
      row: CallLogRow(
        systemId: 2,
        number: '+919123456789',
        direction: CallDirection.outgoing,
        durationSeconds: 45,
        dateMillis: DateTime.now().millisecondsSinceEpoch - 60000,
        cachedName: 'Bob Jones',
        presentation: NumberPresentation.allowed,
        phoneAccountId: 'sim_1',
      ),
      match: const RecordingMatch(
        status: RecordingMatchStatus.unmatched,
        confidence: 0,
      ),
      contactName: 'Bob Jones',
    );

    return CallFeedState(
      entries: [entry1, entry2],
      hasMore: false,
      blocked: false,
    );
  }
}

void main() {
  testWidgets('CallHistoryScreen displays calls, expands on tap, and has Dial Pad FAB', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          callFeedProvider.overrideWith(FakeCallFeedWithEntries.new),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const CallHistoryScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify calls are displayed
    expect(find.text('Alice Smith'), findsOneWidget);
    expect(find.text('Bob Jones'), findsOneWidget);

    // Verify FAB is present
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byIcon(Icons.dialpad_rounded), findsOneWidget);

    // Call actions shouldn't be visible before expansion
    expect(find.text('Call'), findsNothing);
    expect(find.text('Details'), findsNothing);

    // Tap on Alice Smith row to expand
    await tester.tap(find.text('Alice Smith'));
    await tester.pumpAndSettle();

    // Verify Call and Details buttons appear in expanded view
    expect(find.text('Call'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);

    // Tap Bob Jones row - Alice should collapse and Bob should expand
    await tester.tap(find.text('Bob Jones'));
    await tester.pumpAndSettle();

    // Still exactly one Call & Details button visible (from Bob)
    expect(find.text('Call'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);

    // Tap Bob again to collapse
    await tester.tap(find.text('Bob Jones'));
    await tester.pumpAndSettle();

    expect(find.text('Call'), findsNothing);
    expect(find.text('Details'), findsNothing);
  });
}
