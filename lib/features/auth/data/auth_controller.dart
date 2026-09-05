import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_version.dart';
import '../../../core/network/api_client.dart' show SessionRevokedReason;
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
    if (session == null || session.token.isEmpty) return session;

    try {
      return await _reconcileWithNative(session);
    } catch (_) {
      // Reconciliation is best-effort: a channel that is unreachable is not a
      // reason to refuse a session that is probably fine.
      return session;
    }
  }

  /// Brings this process's copy of the token pair in step with the native one.
  ///
  /// The native coordinator refreshes with no Flutter engine attached, and
  /// `POST /auth/refresh` rotates: whatever it sends is dead the instant the
  /// server answers. So after any background sync, the pair in
  /// `flutter_secure_storage` is one generation behind the pair in
  /// `IngestStore`.
  ///
  /// This used to push that stale pair straight back down over the good one on
  /// every cold start. The next 401 then presented an already-rotated refresh
  /// token, which the server treats as theft — it revokes the entire session
  /// chain (`AuthService.refresh`, `token_reuse_detected`) and the handset is
  /// signed out for good, roughly half an hour after pairing, with whatever was
  /// mid-upload stranded behind it.
  ///
  /// The direction of travel is now: native is the store of record for the
  /// refresh token, and this side mirrors it.
  Future<Session?> _reconcileWithNative(Session session) async {
    final bridge = ref.read(nativeBridgeProvider);
    final deviceUuid = await ref.read(deviceRepositoryProvider).getDeviceUuid();

    // Seeds native on first run after an update, refreshes the base URL and
    // device UUID, and — because this is a restore, not a pairing — leaves any
    // refresh token native already holds exactly where it is.
    await bridge.setAuthSession(
      token: session.token,
      refreshToken: session.refreshToken,
      apiBaseUrl: AppConfig.apiBaseUrl,
      deviceUuid: deviceUuid,
      authoritative: false,
      accessTokenExpiresAt: session.expiresAt,
      refreshTokenExpiresAt: session.refreshTokenExpiresAt,
    );

    final native = await bridge.getAuthSession();
    if (native == null) return session;

    // The server refused this session while nothing was listening. The
    // credential is already gone natively; clearing it here is what moves the
    // shell to the sign-in screen instead of leaving it rendering over a
    // session that cannot make a single request.
    if (native.wasRevoked) {
      await ref.read(authRepositoryProvider).signOut();
      // Also drops the tombstone, so the next pairing starts clean.
      await bridge.clearAuthSession();
      ref
          .read(sessionRevocationProvider.notifier)
          .report(SessionRevokedReason.invalidToken);
      return null;
    }

    // Mirror whatever native rotated to. Compared before writing so an
    // unchanged pair does not cost a secure-storage write on every launch.
    final rotated = native.hasTokens &&
        (native.token != session.token ||
            native.refreshToken != session.refreshToken);
    if (rotated) {
      // copyWith cannot write a null, and leaving the previous token's expiry
      // on a token it does not describe is worse than saying nothing: it reads
      // as long expired. Rebuilt explicitly so an absent expiry stays absent.
      final updated = Session(
        userId: session.userId,
        employeeId: session.employeeId,
        displayName: session.displayName,
        email: session.email,
        phone: session.phone,
        role: session.role,
        department: session.department,
        token: native.token!,
        refreshToken: native.refreshToken,
        signedInAt: session.signedInAt,
        expiresAt: native.accessTokenExpiresAt,
        refreshTokenExpiresAt: native.refreshTokenExpiresAt,
        deviceRegistered: session.deviceRegistered,
        mustChangePassword: session.mustChangePassword,
      );
      await const SecureSessionStore().write(updated);
      _triggerStartupSync();
      return updated;
    }

    _triggerStartupSync();
    return session;
  }

  /// The startup sync `MainActivity.onCreate` used to fire.
  ///
  /// It moved here because there it ran before this reconciliation: a run that
  /// started in `onCreate` could refresh the pair natively and then have the
  /// restore below write the pre-rotation token back over it, which is the
  /// exact race described on [_reconcileWithNative]. Fired only once the two
  /// stores agree.
  void _triggerStartupSync() {
    Future.microtask(() async {
      try {
        await ref.read(syncServiceProvider.notifier).triggerSync();
      } catch (_) {}
    });
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

    // Synchronize native background worker credentials.
    //
    // The one caller allowed to be authoritative: this pair came straight from
    // /mobile/register, so it supersedes anything native is holding — including
    // a refresh token belonging to the session this pairing just replaced.
    try {
      final deviceUuid = await ref.read(deviceRepositoryProvider).getDeviceUuid();
      await ref.read(nativeBridgeProvider).setAuthSession(
        token: session.token,
        refreshToken: session.refreshToken,
        apiBaseUrl: AppConfig.apiBaseUrl,
        deviceUuid: deviceUuid,
        authoritative: true,
        accessTokenExpiresAt: session.expiresAt,
        refreshTokenExpiresAt: session.refreshTokenExpiresAt,
      );
    } catch (_) {}

    _triggerStartupSync();

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
