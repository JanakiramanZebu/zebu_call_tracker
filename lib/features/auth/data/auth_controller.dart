import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_version.dart';
import '../../../core/network/api_client_provider.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../synchronization/data/sync_service.dart';
import '../domain/session.dart';
import 'auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => buildAuthRepository(apiClient: ref.watch(apiClientProvider)),
);

class AuthController extends AsyncNotifier<Session?> {
  @override
  Future<Session?> build() async {
    final session = await ref.read(authRepositoryProvider).restore();
    if (session != null && session.token.isNotEmpty) {
      try {
        final deviceUuid = await ref.read(deviceRepositoryProvider).getDeviceUuid();
        await ref.read(nativeBridgeProvider).setAuthSession(
          token: session.token,
          refreshToken: session.refreshToken,
          apiBaseUrl: AppConfig.apiBaseUrl,
          deviceUuid: deviceUuid,
        );
      } catch (_) {}
    }
    return session;
  }
  Future<Session> signInWithPairingWord({
    required String pairingWord,
    required String employeeCode,
    required String name,
    String? email,
    required String phone,
    required String department,
    required String designation,
    required String location,
    String? managerName,
    required String mobileUniqueId,
  }) async {
    final repo = ref.read(authRepositoryProvider);

    Map<String, Object?> device;
    try {
      device = await ref.read(deviceInfoProvider.future);
    } on Object {
      device = const {};
    }

    final session = await repo.signInWithPairingWord(
      pairingWord: pairingWord,
      employeeCode: employeeCode,
      name: name,
      email: email,
      phone: phone,
      department: department,
      designation: designation,
      location: location,
      managerName: managerName,
      deviceName: device['model'] as String? ?? 'Android Handset',
      manufacturer: device['manufacturer'] as String? ?? 'Generic',
      model: device['model'] as String? ?? 'Unknown',
      osVersion: device['version'] as String? ?? '14',
      appVersion: AppVersion.name,
      mobileUniqueId: mobileUniqueId,
    );

    state = AsyncData(session);

    // Synchronize native background worker credentials
    try {
      final deviceUuid = await ref.read(deviceRepositoryProvider).getDeviceUuid();
      await ref.read(nativeBridgeProvider).setAuthSession(
        token: session.token,
        refreshToken: session.refreshToken,
        apiBaseUrl: AppConfig.apiBaseUrl,
        deviceUuid: deviceUuid,
      );
    } catch (_) {}

    Future.microtask(() async {
      try {
        await ref.read(syncServiceProvider.notifier).triggerSync();
      } catch (_) {}
    });

    return session;
  }

  Future<void> signOut() async {
    try {
      await ref.read(backgroundControllerProvider.notifier).stop();
      await ref.read(nativeBridgeProvider).clearAuthSession();
    } on Object {
      // Ignore background stop error during sign out
    }

    await ref.read(authRepositoryProvider).signOut();
    state = const AsyncData(null);
    ref.invalidate(callFeedProvider);
    ref.invalidate(syncServiceProvider);
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, Session?>(
  AuthController.new,
);

class OnboardingController extends AsyncNotifier<bool> {
  static const _key = 'zebu.onboarding.permissions.v1';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> complete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
    state = const AsyncData(true);
  }

  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    state = const AsyncData(false);
  }
}

final onboardingProvider = AsyncNotifierProvider<OnboardingController, bool>(
  OnboardingController.new,
);

/// Set when the user chooses to carry on without call-log access.
///
/// The recovery walkthrough is a hard gate: nothing the app exists to do works
/// without this permission. But a hard gate with no way past it traps anyone who
/// genuinely cannot grant it -- a managed handset, a work profile restriction --
/// and takes away the parts that DO still work: the outbox keeps draining
/// already-captured calls, and they can still reach Settings and sign out.
///
/// Deliberately NOT persisted. It lasts for this launch only, so the next cold
/// start puts the problem back in front of them, and the critical alert banner
/// says so on every screen in the meantime.
final permissionRecoveryDismissedProvider =
    NotifierProvider<PermissionRecoveryDismissed, bool>(
  PermissionRecoveryDismissed.new,
);

class PermissionRecoveryDismissed extends Notifier<bool> {
  @override
  bool build() => false;

  void dismiss() => state = true;

  /// Called once access is back, so a later revocation gates again rather than
  /// inheriting a decision the user made about a different situation.
  void reset() {
    if (state) state = false;
  }
}
