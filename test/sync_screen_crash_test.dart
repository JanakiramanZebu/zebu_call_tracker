import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zebu_call_tracker/features/synchronization/presentation/sync_screen.dart';
import 'package:zebu_call_tracker/core/theme/app_theme.dart';
import 'package:zebu_call_tracker/features/background/data/background_service.dart';
import 'package:zebu_call_tracker/core/platform/native_call_bridge.dart';

import 'package:zebu_call_tracker/features/synchronization/data/sync_service.dart';
import 'package:zebu_call_tracker/features/call_tracking/data/call_feed.dart';

void main() {
  testWidgets('SyncScreen renders with empty entries', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncCountersProvider.overrideWith(
            (ref) => Stream.value(const {
              'uploaded': 0,
              'waiting': 0,
              'failed': 0,
              'total': 0,
            }),
          ),
          callFeedProvider.overrideWith(
            () => CallFeed()
              ..state = const AsyncData(
                CallFeedState(entries: [], hasMore: false, blocked: false),
              ),
          ),
          backgroundStatusProvider.overrideWith((ref) async => const BackgroundStatus(
            ignoringBatteryOptimizations: true,
            manufacturer: 'Google',
            hasVendorSettings: false,
            lastRunAtUtc: null,
            lastRunStatus: null,
            lastRunReason: null,
            runCount: 0,
            capturedCalls: 0,
            overflowed: false,
          )),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          home: const SyncScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SyncScreen), findsOneWidget);
  });
}

