import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../synchronization/data/sync_service.dart';
import '../domain/session.dart';
import 'auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => buildAuthRepository(),
);

class AuthController extends AsyncNotifier<Session?> {
  @override
  Future<Session?> build() => ref.read(authRepositoryProvider).restore();

  Future<Session> signIn({
    required String clientId,
    required String mobileNumber,
    required String deviceId,
  }) async {
    final repo = ref.read(authRepositoryProvider);

    Map<String, Object?> device;
    try {
      device = await ref.read(deviceInfoProvider.future);
    } on Object {
      device = const {};
    }

    final session = await repo.signIn(
      clientId: clientId,
      mobileNumber: mobileNumber,
      deviceId: deviceId,
      device: device,
    );

    if (!session.deviceRegistered) {
      try {
        final deviceRepo = ref.read(deviceRepositoryProvider);
        await deviceRepo.registerDevice(deviceInfo: device);
      } catch (_) {
        // Device registration attempt failed silently; will retry on sync
      }
    }

    state = AsyncData(session);

    // Initial sync trigger in background after sign-in
    Future.microtask(() async {
      try {
        await ref.read(syncServiceProvider.notifier).triggerSync();
      } catch (_) {
        // Sync trigger failed silently
      }
    });

    return session;
  }

  Future<Session> signInWithPairingWord({
    required String pairingWord,
    required String employeeCode,
    required String name,
    required String phone,
    required String department,
    required String designation,
    required String location,
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
      phone: phone,
      department: department,
      designation: designation,
      location: location,
      deviceName: device['model'] as String? ?? 'Android Handset',
      manufacturer: device['manufacturer'] as String? ?? 'Generic',
      model: device['model'] as String? ?? 'Unknown',
      osVersion: device['version'] as String? ?? '14',
      appVersion: '1.0.0',
      mobileUniqueId: mobileUniqueId,
    );

    state = AsyncData(session);

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
