import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../errors/api_exceptions.dart';
import '../platform/native_call_bridge.dart';
import '../../features/auth/data/auth_repository.dart';
import 'api_response.dart';

/// Exchanges a refresh token for a new pair.
///
/// Injected rather than called inline so that the one implementation that may
/// touch `/auth/refresh` — the native `TokenRefresher` — is reachable from here
/// without this file depending on the platform provider graph, and so tests can
/// drive the 401 path without a method channel.
typedef TokenRefreshDelegate = Future<TokenRefreshResult> Function(
  String? staleToken,
);

/// Why a session stopped being usable.
enum SessionRevokedReason {
  /// The server refused the refresh token: expired, revoked, or replayed.
  invalidToken,

  /// There was nothing to refresh with — already signed out.
  noSession,
}

class ApiClient {
  ApiClient({
    required SessionStore sessionStore,
    required TokenRefreshDelegate refreshDelegate,
    Dio? dio,
    void Function(SessionRevokedReason reason)? onSessionRevoked,
  })  : _sessionStore = sessionStore,
        _refreshDelegate = refreshDelegate,
        _onSessionRevoked = onSessionRevoked {
    _dio = dio ??
        Dio(
          BaseOptions(
            baseUrl: AppConfig.apiBaseUrl,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 25),
            sendTimeout: const Duration(seconds: 30),
            contentType: Headers.jsonContentType,
            validateStatus: (status) => status != null && status < 500,
          ),
        );

    _setupInterceptors();
  }

  late final Dio _dio;
  final SessionStore _sessionStore;
  final TokenRefreshDelegate _refreshDelegate;
  final void Function(SessionRevokedReason reason)? _onSessionRevoked;
  final _uuid = const Uuid();

  Completer<bool>? _refreshCompleter;

  Dio get rawDio => _dio;

  void _setupInterceptors() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // Send correlation request ID
          options.headers['X-Request-ID'] = _uuid.v4();

          // Attach token if present and not an unauthenticated endpoint
          final session = await _sessionStore.read();
          if (session != null && session.token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer ${session.token}';
          }
          return handler.next(options);
        },
        onResponse: (response, handler) async {
          if (response.statusCode == 401) {
            final path = response.requestOptions.path;
            if (!path.contains('/auth/login') &&
                !path.contains('/mobile/register') &&
                !path.contains('/auth/refresh')) {
              final refreshed = await _refreshTokensSingleFlight();
              if (refreshed) {
                final retriedResponse = await _retryRequest(response.requestOptions);
                return handler.resolve(retriedResponse);
              }
            }
          }
          return handler.next(response);
        },
        onError: (DioException error, handler) async {
          if (error.response?.statusCode == 401) {
            final path = error.requestOptions.path;
            if (!path.contains('/auth/login') &&
                !path.contains('/mobile/register') &&
                !path.contains('/auth/refresh')) {
              final refreshed = await _refreshTokensSingleFlight();
              if (refreshed) {
                try {
                  final retriedResponse =
                      await _retryRequest(error.requestOptions);
                  return handler.resolve(retriedResponse);
                } on DioException catch (retryErr) {
                  return handler.next(retryErr);
                }
              }
            }
          }
          return handler.next(error);
        },
      ),
    );
  }

  /// Refreshes the access token, at most once at a time, per §2.3.
  ///
  /// The exchange itself happens in the native `TokenRefresher`, not here.
  /// That is the correction to the bug this method used to be: three
  /// `ApiClient` instances each held their own `_refreshCompleter`, so the
  /// "single-flight mutex" only ever serialised callers that happened to share
  /// an instance — and the native coordinator refreshed on a fourth path
  /// entirely. `/auth/refresh` rotates, so the second refresher presented a
  /// token the server had already invalidated, and the server responded by
  /// revoking the whole session chain. Users saw it as being signed out at
  /// random.
  ///
  /// The completer below still matters: it collapses the stampede of queued
  /// requests that all 401 at the same moment inside this isolate, so only one
  /// crosses the method channel.
  Future<bool> _refreshTokensSingleFlight() async {
    final inFlight = _refreshCompleter;
    if (inFlight != null) return inFlight.future;

    final completer = Completer<bool>();
    _refreshCompleter = completer;

    try {
      final session = await _sessionStore.read();
      if (session == null ||
          session.refreshToken == null ||
          session.refreshToken!.isEmpty) {
        await _handleRevokedSession(SessionRevokedReason.noSession);
        completer.complete(false);
        return false;
      }

      // The token we came in with. If another caller — Dart or native — has
      // already rotated past it, the refresher hands back the current one
      // instead of starting a second exchange.
      final result = await _refreshDelegate(session.token);

      if (result.isSuccess) {
        final updated = session.copyWith(
          token: result.accessToken,
          // A null replacement means the stored refresh token still stands;
          // overwriting it with null would strand the session.
          refreshToken: result.refreshToken ?? session.refreshToken,
          expiresAt: result.accessTokenExpiresAt,
          refreshTokenExpiresAt:
              result.refreshTokenExpiresAt ?? session.refreshTokenExpiresAt,
        );
        // §2.3 rule 1: persisted before anything is allowed to use it.
        await _sessionStore.write(updated);
        completer.complete(true);
        return true;
      }

      if (result.isTerminal) {
        await _handleRevokedSession(
          result.failure == TokenRefreshFailure.noSession
              ? SessionRevokedReason.noSession
              : SessionRevokedReason.invalidToken,
        );
        completer.complete(false);
        return false;
      }

      // Transient: a timeout, a 5xx, no signal. The session is very probably
      // fine. Clearing it here — which this method used to do for *any*
      // exception — signed the user out every time the network hiccupped.
      completer.complete(false);
      return false;
    } catch (_) {
      // Reaching here means the channel itself failed, not the server. Same
      // reasoning: keep the session, let the caller surface the 401.
      completer.complete(false);
      return false;
    } finally {
      _refreshCompleter = null;
    }
  }

  /// Drops the local session and tells whoever is listening.
  ///
  /// Only called when the server has actually refused the credential. The
  /// callback is what moves the UI to the sign-in screen; without it wired the
  /// app sat on a signed-in shell holding no token until it was force-closed.
  Future<void> _handleRevokedSession(SessionRevokedReason reason) async {
    await _sessionStore.clear();
    _onSessionRevoked?.call(reason);
  }

  Future<Response<dynamic>> _retryRequest(RequestOptions requestOptions) async {
    final session = await _sessionStore.read();
    final options = Options(
      method: requestOptions.method,
      headers: {
        ...requestOptions.headers,
        if (session != null && session.token.isNotEmpty)
          'Authorization': 'Bearer ${session.token}',
      },
    );

    final cleanPath = requestOptions.path.startsWith('/')
        ? requestOptions.path.substring(1)
        : requestOptions.path;

    return _dio.request<dynamic>(
      cleanPath,
      data: requestOptions.data,
      queryParameters: requestOptions.queryParameters,
      options: options,
    );
  }

  /// Request executor with standard envelope parsing and error handling
  Future<ApiResponse<T>> request<T>(
    String path, {
    required String method,
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    T Function(dynamic rawData)? decoder,
  }) async {
    try {
      final opts = options ?? Options();
      opts.method = method;

      final cleanPath = path.startsWith('/') ? path.substring(1) : path;

      final res = await _dio.request<Map<String, dynamic>>(
        cleanPath,
        data: data,
        queryParameters: queryParameters,
        options: opts,
      );

      final body = res.data ?? {};
      final responseEnvelope = ApiResponse<T>.fromJson(
        body,
        decoder ?? (d) => d as T,
      );

      if (!responseEnvelope.success && responseEnvelope.error != null) {
        throw ApiException.fromEnvelope(
          error: responseEnvelope.error!,
          statusCode: res.statusCode,
          meta: responseEnvelope.meta,
        );
      }

      return responseEnvelope;
    } on DioException catch (e) {
      if (e.response?.data is Map<String, dynamic>) {
        final body = e.response!.data as Map<String, dynamic>;
        final responseEnvelope = ApiResponse<T>.fromJson(
          body,
          (d) => d as T,
        );
        if (responseEnvelope.error != null) {
          throw ApiException.fromEnvelope(
            error: responseEnvelope.error!,
            statusCode: e.response?.statusCode,
            meta: responseEnvelope.meta,
          );
        }
      }
      throw ApiException(
        code: 'NETWORK_ERROR',
        message: e.message ?? 'Network connection issue.',
        statusCode: e.response?.statusCode,
      );
    }
  }

  Future<ApiResponse<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    T Function(dynamic rawData)? decoder,
  }) =>
      request<T>(
        path,
        method: 'GET',
        queryParameters: queryParameters,
        decoder: decoder,
      );

  Future<ApiResponse<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    T Function(dynamic rawData)? decoder,
    Options? options,
  }) =>
      request<T>(
        path,
        method: 'POST',
        data: data,
        queryParameters: queryParameters,
        options: options,
        decoder: decoder,
      );

  Future<ApiResponse<T>> patch<T>(
    String path, {
    dynamic data,
    T Function(dynamic rawData)? decoder,
  }) =>
      request<T>(
        path,
        method: 'PATCH',
        data: data,
        decoder: decoder,
      );
}
