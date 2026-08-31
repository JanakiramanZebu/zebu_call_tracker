import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zebu_call_tracker/core/theme/app_theme.dart';
import 'package:zebu_call_tracker/features/call_tracking/data/call_feed.dart';
import 'package:zebu_call_tracker/features/call_tracking/domain/call_entry.dart';
import 'package:zebu_call_tracker/features/call_tracking/presentation/dashboard_screen.dart';

class FakeCallFeed extends CallFeed {
  @override
  Future<CallFeedState> build() async =>
      const CallFeedState(entries: [], hasMore: false, blocked: false);
}

void main() {
  testWidgets('DashboardScreen renders Analytics dashboard with all 8 metric cards', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          callFeedProvider.overrideWith(FakeCallFeed.new),
          analyticsPeriodStatsProvider.overrideWith((ref) => Stream.value(CallStats.empty)),
          analyticsHourlyActivityProvider.overrideWith((ref) => Stream.value(
                (
                  incoming: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                  outgoing: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                  missed: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                ),
              )),
          analyticsSparklineProvider.overrideWith((ref) => Stream.value(const [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: DashboardScreen(
            onSeeAllCalls: () {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Analytics'), findsOneWidget);
    expect(find.text('Filter'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('Analysis'), findsOneWidget);

    // Verify all 8 metric cards are rendered
    expect(find.text('Total Phone Calls'), findsOneWidget);
    expect(find.text('Incoming Calls'), findsOneWidget);
    expect(find.text('Outgoing Calls'), findsOneWidget);
    expect(find.text('Missed Calls'), findsOneWidget);
    expect(find.text('Rejected Calls'), findsOneWidget);
    expect(find.text('Never Attended'), findsOneWidget);
    expect(find.text('Not Pickup by Client'), findsOneWidget);
    expect(find.text('Unique Calls'), findsOneWidget);

    // Verify the "recordings matched" card is NOT present
    expect(find.textContaining('recordings matched'), findsNothing);
  });
}
