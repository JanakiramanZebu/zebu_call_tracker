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
    expect(find.text('ZE770 · IT'), findsOneWidget);

    // Grouped section headers
    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.text('DEVICE'), findsOneWidget);
    expect(find.text('TRACKING'), findsOneWidget);
    expect(find.text('SYNC & UPLOAD'), findsOneWidget);
    expect(find.text('DATA & STORAGE'), findsOneWidget);
    expect(find.text('PERMISSIONS'), findsOneWidget);
    expect(find.text('APPLICATION'), findsOneWidget);
    expect(find.text('SYSTEM ACTIONS'), findsOneWidget);

    // Key settings tiles
    expect(find.text('Background Tracking'), findsOneWidget);
    expect(find.text('Call Log Access'), findsOneWidget);
    expect(find.text('Recording Ingestion'), findsOneWidget);
    expect(find.text('Tracking Health'), findsOneWidget);
    expect(find.text('Run Device Check'), findsOneWidget);
    expect(find.text('Sync Status'), findsOneWidget);
    expect(find.text('Pending Uploads'), findsOneWidget);
    expect(find.text('Call Metadata Outbox'), findsOneWidget);
    expect(find.text('Sign Out'), findsOneWidget);
  });
}
