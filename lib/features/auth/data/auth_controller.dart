import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../domain/session.dart';
import 'auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => buildAuthRepository(),
);

/// The signed-in session, or null.
///
/// The controller's own state is only ever *restoring* (on launch) or settled.
/// A sign-in attempt deliberately does NOT flip it back to loading: the login
/// screen owns that spinner, and putting the whole app back on the splash for
/// three quarters of a second would be a worse experience than a busy button.
class AuthController extends AsyncNotifier<Session?> {
  @override
  Future<Session?> build() => ref.read(authRepositoryProvider).restore();

  /// Throws [AuthFailure]; the caller renders the message.
  Future<Session> signIn({
    required String employeeId,
    required String password,
  }) async {
    final repo = ref.read(authRepositoryProvider);

    // Device identity is registered alongside the credentials, so the server
    // can attribute calls to this handset. A device that cannot be read is not
    // a reason to block sign-in.
    Map<String, Object?> device;
    try {
      device = await ref.read(deviceInfoProvider.future);
    } on Object {
      device = const {};
    }

    final session = await repo.signIn(
      employeeId: employeeId,
      password: password,
      device: device,
    );
    state = AsyncData(session);
    return session;
  }

  Future<void> signOut() async {
    // Stop capturing FIRST. A handset with no signed-in employee has no record
    // to attribute calls to, and continuing to snapshot them after sign-out
    // would collect data with nowhere legitimate to send it.
    try {
      await ref.read(backgroundControllerProvider.notifier).stop();
    } on Object {
      // A scheduler that refuses to cancel must not trap the user in a session
      // they asked to leave.
    }

    await ref.read(authRepositoryProvider).signOut();
    state = const AsyncData(null);
    // The next user of this handset must not inherit the previous one's call
    // list, so the feed is dropped rather than left cached.
    ref.invalidate(callFeedProvider);
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, Session?>(
  AuthController.new,
);

/// True once the user has been walked through the permission screen at least
/// once. Stored per install, not per session: the grants themselves are the
/// real state, and this only decides whether the *walkthrough* is shown.
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

  /// Used by "Redo setup" in Settings.
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    state = const AsyncData(false);
  }
}

final onboardingProvider = AsyncNotifierProvider<OnboardingController, bool>(
  OnboardingController.new,
);
