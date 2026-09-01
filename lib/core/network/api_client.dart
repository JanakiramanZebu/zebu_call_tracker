import 'dart:async';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../errors/api_exceptions.dart';
import '../../features/auth/data/auth_repository.dart';
import 'api_endpoints.dart';
import 'api_response.dart';

class ApiClient {
  ApiClient({
    required SessionStore sessionStore,
    Dio? dio,
    void Function()? onSessionRevoked,
  })  : _sessionStore = sessionStore,
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
  final void Function()? _onSessionRevoked;
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

  /// Single-flight mutex for token refresh according to Section 2.3 of Mobile API Guide
  Future<bool> _refreshTokensSingleFlight() async {
    if (_refreshCompleter != null) {
      return _refreshCompleter!.future;
    }

    final completer = Completer<bool>();
    _refreshCompleter = completer;

    try {
      final session = await _sessionStore.read();
      if (session == null || session.refreshToken == null || session.refreshToken!.isEmpty) {
        await _handleRevokedSession();
        completer.complete(false);
        return false;
      }

      // Dedicated un-intercepted Dio instance for auth refresh to prevent loops
      final refreshDio = Dio(
        BaseOptions(
          baseUrl: AppConfig.apiBaseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          contentType: Headers.jsonContentType,
        ),
      );

      final cleanRefreshPath = ApiEndpoints.refresh.startsWith('/')
          ? ApiEndpoints.refresh.substring(1)
          : ApiEndpoints.refresh;

      final res = await refreshDio.post<Map<String, dynamic>>(
        cleanRefreshPath,
        data: {'refresh_token': session.refreshToken},
      );

      final body = res.data ?? {};
      final success = body['success'] as bool? ?? false;
      if (!success || !body.containsKey('data')) {
        await _handleRevokedSession();
        completer.complete(false);
        return false;
      }

      final data = body['data'] as Map<String, dynamic>;

      // `/auth/refresh` answers with a bare TokenPair — `data.access_token` —
      // while `/auth/login` and `/mobile/register` nest the same object under
      // `data.tokens`. Reading only the nested shape found nothing on every
      // refresh, and the `null` was read as "session revoked": the store was
      // cleared and the user thrown back to the login screen 30 minutes after
      // signing in, with the queued calls still unsent.
      final tokens = data['tokens'] as Map<String, dynamic>? ?? data;
      if (tokens['access_token'] is! String) {
        await _handleRevokedSession();
        completer.complete(false);
        return false;
      }

      final newAccessToken = tokens['access_token'] as String;
      final newRefreshToken = tokens['refresh_token'] as String;
      final expiresAtStr = tokens['access_token_expires_at'] as String?;
      final refreshExpiresAtStr = tokens['refresh_token_expires_at'] as String?;

      final updatedSession = session.copyWith(
        token: newAccessToken,
        refreshToken: newRefreshToken,
        expiresAt: expiresAtStr != null ? DateTime.tryParse(expiresAtStr)?.toUtc() : null,
        refreshTokenExpiresAt:
            refreshExpiresAtStr != null ? DateTime.tryParse(refreshExpiresAtStr)?.toUtc() : null,
      );

      // Rule 1: Persist the new refresh token before using the new access token.
      await _sessionStore.write(updatedSession);
      completer.complete(true);
      return true;
    } catch (e) {
      await _handleRevokedSession();
      completer.complete(false);
      return false;
    } finally {
      _refreshCompleter = null;
    }
  }

  Future<void> _handleRevokedSession() async {
    await _sessionStore.clear();
    _onSessionRevoked?.call();
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
