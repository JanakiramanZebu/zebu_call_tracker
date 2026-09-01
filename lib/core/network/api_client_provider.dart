import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/data/auth_repository.dart';
import '../config/app_config.dart';
import '../platform/native_call_bridge.dart';
import 'api_client.dart';

/// The one [ApiClient] in the app.
///
/// There used to be three, built independently by `buildAuthRepository`,
/// `syncRepositoryProvider` and `deviceRepositoryProvider`. Each carried its
/// own `_refreshCompleter`, so the "single-flight" refresh guard only ever
/// serialised callers that happened to share an instance — and `/auth/refresh`
/// rotates its token, so two of them refreshing meant the second replayed a
/// token the server had already retired. The documented response to that is to
/// revoke the whole session chain, which is exactly what users experienced as
/// being signed out for no reason.
///
/// One client, one queue, one refresh.
final apiClientProvider = Provider<ApiClient>((ref) {
  const store = SecureSessionStore();
  final bridge = MethodChannelNativeCallBridge();

  return ApiClient(
    sessionStore: store,
    refreshDelegate: (staleToken) => _refreshTokens(bridge, staleToken),
    onSessionRevoked: (reason) {
      ref.read(sessionRevocationProvider.notifier).report(reason);
    },
  );
});

/// Hands the refresh to the native `TokenRefresher`.
///
/// Android only, and deliberately so: the background coordinator has to be able
/// to refresh with no Flutter engine attached, so the exchange lives natively.
/// Routing Dart through the same gate is what keeps the two from racing over a
/// token the server rotates on every use.
///
/// On any other platform there is no native store to race with, so there is
/// nothing to serialise and no refresh path — the caller sees the 401 and the
/// session is left alone.
Future<TokenRefreshResult> _refreshTokens(
  NativeCallBridge bridge,
  String? staleToken,
) async {
  if (!Platform.isAndroid) {
    return const TokenRefreshResult.failed(TokenRefreshFailure.unsupported);
  }
  try {
    return await bridge.refreshAuthTokens(
      staleToken: staleToken,
      apiBaseUrl: AppConfig.apiBaseUrl,
    );
  } on NativeFailure {
    // The channel is unreachable — no engine, or the platform side is missing.
    // Not evidence that the session is bad, so it is reported as transient and
    // the session survives.
    return const TokenRefreshResult.failed(TokenRefreshFailure.transient);
  }
}

/// Set when the server has refused this session and it has been cleared.
///
/// Read by the app shell, which is what actually moves the user to the sign-in
/// screen. Before this existed, `ApiClient` cleared the stored session and told
/// nobody: the app stayed on the signed-in shell holding no credential, failing
/// every request, until it was force-closed.
final sessionRevocationProvider =
    NotifierProvider<SessionRevocationController, SessionRevokedReason?>(
  SessionRevocationController.new,
);

class SessionRevocationController extends Notifier<SessionRevokedReason?> {
  @override
  SessionRevokedReason? build() => null;

  void report(SessionRevokedReason reason) {
    if (state == reason) return;
    state = reason;
  }

  /// Called once the shell has acted on it, so a later sign-in starts clean.
  void acknowledge() => state = null;
}
