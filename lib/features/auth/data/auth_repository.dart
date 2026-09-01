import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exceptions.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../device/data/device_uuid_store.dart';
import '../domain/session.dart';

abstract interface class AuthRepository {
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
    required String deviceName,
    required String manufacturer,
    required String model,
    required String osVersion,
    required String appVersion,
    required String mobileUniqueId,
  });
  Future<Session?> restore();
  Future<void> signOut();
}

abstract interface class SessionStore {
  Future<Session?> read();
  Future<void> write(Session session);
  Future<void> clear();
}

class SecureSessionStore implements SessionStore {
  const SecureSessionStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;
  static const _key = 'zebu.session.v1';

  @override
  Future<Session?> read() async {
    try {
      return Session.decode(await _storage.read(key: _key));
    } on PlatformException catch (_) {
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

class InMemorySessionStore implements SessionStore {
  Session? _session;

  @override
  Future<Session?> read() async => _session;

  @override
  Future<void> write(Session session) async => _session = session;

  @override
  Future<void> clear() async => _session = null;
}

class RemoteAuthRepository implements AuthRepository {
  RemoteAuthRepository({
    required ApiClient apiClient,
    required SessionStore store,
    DeviceUuidStore? deviceUuidStore,
  })  : _apiClient = apiClient,
        _store = store,
        _deviceUuidStore = deviceUuidStore ?? const DeviceUuidStore();

  final ApiClient _apiClient;
  final SessionStore _store;
  final DeviceUuidStore _deviceUuidStore;
  @override
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
    required String deviceName,
    required String manufacturer,
    required String model,
    required String osVersion,
    required String appVersion,
    required String mobileUniqueId,
  }) async {
    try {
      final uuid = mobileUniqueId.isNotEmpty
          ? mobileUniqueId
          : await _deviceUuidStore.getOrCreateUuid();

      final formattedPhone = phone.startsWith('+')
          ? phone
          : '+91${phone.replaceAll(RegExp(r'\D'), '')}';

      final response = await _apiClient.post<Map<String, dynamic>>(
        ApiEndpoints.registerMobile,
        data: {
          'pairing_word': pairingWord,
          'employee_code': employeeCode,
          'name': name,
          if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
          'phone': formattedPhone,
          'department': department,
          'designation': designation,
          'location': location,
          if (managerName != null && managerName.trim().isNotEmpty)
            'manager_name': managerName.trim(),
          'device_name': deviceName,
          'manufacturer': manufacturer,
          'model': model,
          'os_version': osVersion,
          'app_version': appVersion,
          'mobile_unique_id': uuid,
        },
      );

      final data = response.data ?? {};
      final userMap = data['user'] as Map<String, dynamic>? ?? {};
      final tokensMap = data['tokens'] as Map<String, dynamic>? ?? {};

      final accessToken = ((tokensMap['access_token'] as String?) ??
              (data['access_token'] as String?) ??
              (data['token'] as String?))
          ?.trim();
      if (accessToken == null || accessToken.isEmpty) {
        // Registration without a token is a failed registration, whatever the
        // HTTP status said. Inventing 'session-pairing-<millis>' here left the
        // user apparently signed in and permanently unable to sync.
        throw const AuthFailure(
          AuthFailureKind.server,
          'Registration did not return a session token. '
          'Check the pairing word with your administrator and try again.',
        );
      }
      final refreshToken = (tokensMap['refresh_token'] as String?) ??
          (data['refresh_token'] as String?);

      final session = Session(
        userId: (userMap['id'] as num?)?.toInt() ?? (data['user_id'] as num?)?.toInt(),
        employeeId: (userMap['employee_code'] as String?) ??
            (data['employee_code'] as String?) ??
            employeeCode,
        displayName: (userMap['name'] as String?) ??
            (data['name'] as String?) ??
            name,
        email: userMap['email'] as String?,
        phone: userMap['phone'] as String?,
        role: userMap['role'] as String? ?? designation,
        department: userMap['department'] as String?,
        token: accessToken,
        refreshToken: refreshToken,
        signedInAt: DateTime.now().toUtc(),
        expiresAt: DateTime.tryParse(
          (tokensMap['access_token_expires_at'] as String?) ??
              (data['access_token_expires_at'] as String?) ??
              '',
        )?.toUtc(),
        refreshTokenExpiresAt: DateTime.tryParse(
          (tokensMap['refresh_token_expires_at'] as String?) ??
              (data['refresh_token_expires_at'] as String?) ??
              '',
        )?.toUtc(),
        deviceRegistered: true,
      );

      await _store.write(session);
      return session;
    } on ApiException catch (e) {
      throw _translateApiException(e);
    } catch (e) {
      throw AuthFailure(AuthFailureKind.unknown, e.toString());
    }
  }
  AuthFailure _translateApiException(ApiException e) {
    if (e.code == 'INVALID_CREDENTIALS' || e.statusCode == 401) {
      return const AuthFailure(
        AuthFailureKind.invalidCredentials,
        'Invalid Employee ID, password or pairing word.',
      );
    }
    if (e.code == 'DEVICE_OWNED_BY_ANOTHER_USER' || e.statusCode == 409) {
      return AuthFailure(
        AuthFailureKind.accountDisabled,
        e.message.isNotEmpty
            ? e.message
            : 'This device belongs to another employee. Contact an administrator.',
      );
    }
    if (e.code == 'DEVICE_REVOKED' || e.code == 'ACCOUNT_LOCKED' || e.code == 'ACCOUNT_INACTIVE' || e.statusCode == 403) {
      return AuthFailure(
        AuthFailureKind.accountDisabled,
        e.message.isNotEmpty ? e.message : 'Access denied by administrator.',
      );
    }
    if (e.statusCode != null && e.statusCode! >= 500) {
      return const AuthFailure(
        AuthFailureKind.server,
        'The server is not responding. Try again in a moment.',
      );
    }
    if (e.code == 'NETWORK_ERROR') {
      return const AuthFailure(
        AuthFailureKind.network,
        'No connection. Check your network and try again.',
      );
    }
    return AuthFailure(AuthFailureKind.unknown, e.message);
  }

  @override
  Future<Session?> restore() async {
    final session = await _store.read();
    if (session == null) return null;
    if (session.isExpired && session.refreshToken == null) {
      await _store.clear();
      return null;
    }
    return session;
  }

  @override
  Future<void> signOut() async {
    final session = await _store.read();
    if (session != null && session.refreshToken != null) {
      try {
        await _apiClient.post<dynamic>(
          ApiEndpoints.logout,
          data: {
            'refresh_token': session.refreshToken,
            'all_sessions': false,
          },
        );
      } catch (_) {}
    }
    await _store.clear();
  }
}

class LocalAuthRepository implements AuthRepository {
  const LocalAuthRepository(this._store);

  final SessionStore _store;
  @override
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
    required String deviceName,
    required String manufacturer,
    required String model,
    required String osVersion,
    required String appVersion,
    required String mobileUniqueId,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final session = Session(
      employeeId: employeeCode.toUpperCase(),
      displayName: name,
      phone: phone,
      department: department,
      role: designation,
      token: 'local-pairing-${DateTime.now().microsecondsSinceEpoch}',
      signedInAt: DateTime.now().toUtc(),
      deviceRegistered: true,
    );
    await _store.write(session);
    return session;
  }
  @override
  Future<Session?> restore() => _store.read();

  @override
  Future<void> signOut() => _store.clear();
}

/// Builds the repository around an [ApiClient] the caller owns.
///
/// [apiClient] is required rather than defaulted: constructing one here is how
/// the app ended up with three of them, each refreshing tokens independently
/// against a server that rotates them. There is now exactly one, held by
/// `apiClientProvider`.
AuthRepository buildAuthRepository({required ApiClient apiClient}) {
  const store = SecureSessionStore();

  if (!AppConfig.hasServer) return const LocalAuthRepository(store);

  return RemoteAuthRepository(apiClient: apiClient, store: store);
}
