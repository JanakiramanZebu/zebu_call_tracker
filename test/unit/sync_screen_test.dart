import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zebu_call_tracker/core/theme/app_theme.dart';
import 'package:zebu_call_tracker/features/synchronization/presentation/sync_screen.dart';

void main() {
  testWidgets('SyncScreen renders without layout errors', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SyncScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SyncScreen), findsOneWidget);
  });
}
