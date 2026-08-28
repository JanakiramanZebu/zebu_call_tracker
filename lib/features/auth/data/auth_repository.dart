import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/config/app_config.dart';
import '../domain/session.dart';

/// Where a [Session] comes from and where it is kept.
///
/// Sign-in and persistence sit behind one interface so the login screen never
/// learns whether it is talking to a server, and so tests can drive the whole
/// flow with a hand-written fake.
abstract interface class AuthRepository {
  /// Throws [AuthFailure] on every failure path, never a raw [DioException].
  Future<Session> signIn({
    required String employeeId,
    required String password,
    required Map<String, Object?> device,
  });

  Future<Session?> restore();
  Future<void> signOut();
}

/// Where the session blob lives between launches.
///
/// An interface rather than a concrete class so the repositories — and the
/// sign-in flow above them — can be tested without a platform keystore.
abstract interface class SessionStore {
  Future<Session?> read();
  Future<void> write(Session session);
  Future<void> clear();
}

/// Backed by the platform keystore, so the token survives a reboot without
/// sitting in plaintext.
class SecureSessionStore implements SessionStore {
  const SecureSessionStore(this._storage);

  final FlutterSecureStorage _storage;

  static const _key = 'zebu.session.v1';

  @override
  Future<Session?> read() async {
    try {
      return Session.decode(await _storage.read(key: _key));
    } on PlatformException catch (_) {
      // A keystore that was invalidated (device re-encrypted, app restored to a
      // new device) makes the blob unreadable. Dropping it is correct: the user
      // signs in again rather than being stuck on a screen that never resolves.
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(Session session) =>
      _storage.write(key: _key, value: session.encode());

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Process-lifetime store, for tests and for widget previews.
class InMemorySessionStore implements SessionStore {
  Session? _session;

  @override
  Future<Session?> read() async => _session;

  @override
  Future<void> write(Session session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
}

/// Talks to the fleet backend.
class RemoteAuthRepository implements AuthRepository {
  RemoteAuthRepository({required Dio dio, required SessionStore store})
    : _dio = dio,
      _store = store;

  final Dio _dio;
  final SessionStore _store;

  @override
  Future<Session> signIn({
    required String employeeId,
    required String password,
    required Map<String, Object?> device,
  }) async {
    try {
      final res = await _dio.post<Map<String, Object?>>(
        '/auth/login',
        data: {
          'employeeId': employeeId,
          'password': password,
          // The device is registered as part of sign-in (brief: calls are
          // attributed to the employee record via the device that made them).
          'device': device,
        },
      );

      final body = res.data ?? const {};
      final token = body['token'] as String?;
      if (token == null || token.isEmpty) {
        throw const AuthFailure(
          AuthFailureKind.server,
          'The server did not return a session. Contact your administrator.',
        );
      }

      final session = Session(
        employeeId: body['employeeId'] as String? ?? employeeId,
        displayName: body['displayName'] as String? ?? employeeId,
        token: token,
        signedInAt: DateTime.now().toUtc(),
        expiresAt: DateTime.tryParse(body['expiresAt'] as String? ?? ''),
      );
      await _store.write(session);
      return session;
    } on DioException catch (e) {
      throw _translate(e);
    }
  }

  AuthFailure _translate(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401 || status == 403) {
      return const AuthFailure(
        AuthFailureKind.invalidCredentials,
        'Employee ID or password is incorrect.',
      );
    }
    if (status == 423 || status == 410) {
      return const AuthFailure(
        AuthFailureKind.accountDisabled,
        'This account is not active. Contact your administrator.',
      );
    }
    if (status != null && status >= 500) {
      return const AuthFailure(
        AuthFailureKind.server,
        'The server is not responding. Try again in a moment.',
      );
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => const AuthFailure(
        AuthFailureKind.network,
        'No connection. Check your network and try again.',
      ),
      _ => AuthFailure(
        AuthFailureKind.unknown,
        e.message ?? 'Sign-in failed. Try again.',
      ),
    };
  }

  @override
  Future<Session?> restore() async {
    final session = await _store.read();
    if (session == null) return null;
    if (session.isExpired) {
      await _store.clear();
      return null;
    }
    return session;
  }

  @override
  Future<void> signOut() => _store.clear();
}

/// On-device sign-in, used while no `API_BASE_URL` is compiled in.
///
/// It is a real gate, not a bypass: the ID must match the issued format and the
/// password the minimum length, and the session it mints is stored and restored
/// exactly like a server one, so the rest of the app exercises the same code
/// path it will use in production. What it cannot do is verify the password
/// against anything — which is why the login screen labels the build.
class LocalAuthRepository implements AuthRepository {
  const LocalAuthRepository(this._store);

  final SessionStore _store;

  /// `EMP-4471` — the format the design and the admin console both use.
  static final employeeIdPattern = RegExp(r'^[A-Z]{2,4}-\d{3,6}$');

  static const minPasswordLength = 6;

  @override
  Future<Session> signIn({
    required String employeeId,
    required String password,
    required Map<String, Object?> device,
  }) async {
    // Deliberate latency so the loading states are exercised on every run
    // rather than only against a slow network.
    await Future<void>.delayed(const Duration(milliseconds: 700));

    final id = employeeId.trim().toUpperCase();
    if (!employeeIdPattern.hasMatch(id)) {
      throw const AuthFailure(
        AuthFailureKind.invalidCredentials,
        'Employee ID should look like EMP-4471.',
      );
    }
    if (password.length < minPasswordLength) {
      throw const AuthFailure(
        AuthFailureKind.invalidCredentials,
        'Employee ID or password is incorrect.',
      );
    }

    final session = Session(
      employeeId: id,
      displayName: id,
      token: 'local-${DateTime.now().microsecondsSinceEpoch}',
      signedInAt: DateTime.now().toUtc(),
    );
    await _store.write(session);
    return session;
  }

  @override
  Future<Session?> restore() => _store.read();

  @override
  Future<void> signOut() => _store.clear();
}

/// Builds the repository the current build should use.
AuthRepository buildAuthRepository() {
  const store = SecureSessionStore(FlutterSecureStorage());

  if (!AppConfig.hasServer) return const LocalAuthRepository(store);

  final dio = Dio(
    BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      contentType: Headers.jsonContentType,
      // Non-2xx is handled by _translate, so let Dio raise for everything and
      // keep one error path.
      validateStatus: (s) => s != null && s >= 200 && s < 300,
    ),
  );
  return RemoteAuthRepository(dio: dio, store: store);
}
