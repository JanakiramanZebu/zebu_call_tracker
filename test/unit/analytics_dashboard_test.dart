import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zebu_call_tracker/core/theme/app_theme.dart';
import 'package:zebu_call_tracker/features/call_tracking/data/call_feed.dart';
import 'package:zebu_call_tracker/features/call_tracking/presentation/dashboard_screen.dart';
import 'package:zebu_call_tracker/features/synchronization/data/sync_service.dart';

class FakeCallFeed extends CallFeed {
  @override
  Future<CallFeedState> build() async =>
      const CallFeedState(entries: [], hasMore: false, blocked: false);
}

void main() {
  testWidgets('DashboardScreen renders its header and the empty period state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          callFeedProvider.overrideWith(FakeCallFeed.new),
          analyticsPeriodProvider.overrideWith(
            (ref) => Stream.value(PeriodAnalytics.empty),
          ),
          // Drives the trend badges. Without an override this reaches the real
          // DAO and leaves a database timer pending past teardown.
          analyticsPreviousStatsProvider.overrideWith((ref) => Stream.value(null)),
          // The send-status line, for the same reason.
          syncCountersProvider.overrideWith((ref) => Stream.value(const {})),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const DashboardScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Zebu Echo'), findsOneWidget);
    // No calls in the period: the empty state, with the way out of it.
    expect(find.text('No calls in this period'), findsWidgets);
    expect(find.text('Show all time'), findsOneWidget);

    // Verify the "recordings matched" card is NOT present
    expect(find.textContaining('recordings matched'), findsNothing);
  });
}
