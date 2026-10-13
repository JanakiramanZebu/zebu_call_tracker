import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zebu_call_tracker/core/theme/app_theme.dart';
import 'package:zebu_call_tracker/features/auth/data/auth_controller.dart';
import 'package:zebu_call_tracker/features/auth/domain/session.dart';
import 'package:zebu_call_tracker/features/settings/presentation/settings_screen.dart';
import 'package:zebu_call_tracker/features/synchronization/data/sync_service.dart';

class FakeAuthController extends AuthController {
  FakeAuthController(this._session);
  final Session _session;

  @override
  Future<Session?> build() async => _session;
}

void main() {
  testWidgets('SettingsScreen renders with all required sections and tiles', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final fakeSession = Session(
      userId: 1,
      employeeId: 'ZE770',
      displayName: 'John Doe',
      email: 'john@zebu.com',
      phone: '9876543210',
      role: 'Support Lead',
      department: 'IT',
      token: 'jwt-token-xyz',
      signedInAt: DateTime.now(),
      deviceRegistered: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(() => FakeAuthController(fakeSession)),
          syncCountersProvider.overrideWith(
            (ref) => Stream.value({'uploaded': 10, 'waiting': 2, 'failed': 0, 'total': 12}),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const SettingsScreen(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Screen Title
    expect(find.text('Settings'), findsOneWidget);

    // Profile card & Profile tile
    expect(find.text('John Doe'), findsNWidgets(2));
    expect(find.text('Employee ZE770, IT'), findsOneWidget);

    // Grouped section headers
    for (final section in const [
      'Appearance',
      'Account',
      'Tracking',
      'Sync',
      'Your data',
      'Permissions',
      'Application',
      'Troubleshooting',
    ]) {
      expect(find.text(section), findsOneWidget, reason: section);
    }

    // Key settings tiles
    expect(find.text('Background activity'), findsOneWidget);
    expect(find.text('Check for new calls'), findsOneWidget);
    // Recordings go over any network; the Wi-Fi-only switch is gone.
    expect(find.text('Send recordings on mobile data'), findsNothing);
    expect(find.text('Calls waiting to send'), findsOneWidget);
    expect(find.text('2 calls'), findsOneWidget);
    // No sign-out: a handset changes hands by being reset and paired again.
    expect(find.textContaining('Sign out'), findsNothing);
  });
}
