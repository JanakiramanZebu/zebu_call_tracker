import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exceptions.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../device/data/device_uuid_store.dart';
import '../domain/session.dart';

abstract interface class AuthRepository {
  /// What the server holds for [employeeCode], to fill the form before
  /// registering. Throws [AuthFailure].
  Future<EmployeeLookup> lookupEmployee({
    required String pairingWord,
    required String employeeCode,
  });

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

  /// Drops the stored session. Local only: the app has no sign-out, and this
  /// runs only once the server has already refused the session.
  Future<void> clearLocalSession();
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

/// The employee code this phone last registered with.
///
/// Kept after a sign-out or a revoked session so the setup screen can offer it
/// again (Mobile login flow §6). Not a secret — and the setup code, which is,
/// is never stored.
abstract final class LastEmployeeCode {
  static const _key = 'zebu.last_employee_code.v1';

  static Future<String?> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_key);
      return (v != null && v.isNotEmpty) ? v : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, code);
    } catch (_) {}
  }
}

class RemoteAuthRepository implements AuthRepository {
  RemoteAuthRepository({
    required ApiClient apiClient,
    required SessionStore store,
  })  : _apiClient = apiClient,
        _store = store;

  final ApiClient _apiClient;
  final SessionStore _store;
  static const _deviceUuidStore = DeviceUuidStore();

  @override
  Future<EmployeeLookup> lookupEmployee({
    required String pairingWord,
    required String employeeCode,
  }) async {
    try {
      final response = await _apiClient.post<Map<String, dynamic>>(
        ApiEndpoints.lookupEmployee,
        data: {'pairing_word': pairingWord, 'employee_code': employeeCode},
      );
      return EmployeeLookup.fromJson(response.data ?? const {}, employeeCode);
    } on ApiException catch (e) {
      throw _translateApiException(e);
    } on AuthFailure {
      rethrow;
    } catch (_) {
      throw const AuthFailure(
        AuthFailureKind.network,
        "Couldn't check your employee code.",
      );
    }
  }

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

      // Empty means "keep the number on file" (Mobile login flow §3.2). This
      // used to become a bare "+91", which overwrote it.
      final digits = phone.replaceAll(RegExp(r'\D'), '');
      final formattedPhone = phone.trim().isEmpty
          ? ''
          : phone.startsWith('+')
          ? phone
          : '+91$digits';

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
          "Registration didn't finish. Check the setup code with your admin "
          'and try again.',
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
      await LastEmployeeCode.write(session.employeeId);
      return session;
    } on ApiException catch (e) {
      throw _translateApiException(e);
    } on AuthFailure {
      // Already worded for the user. The catch-all below used to swallow it
      // and show "AuthFailure(server: …)" instead.
      rethrow;
    } catch (_) {
      throw const AuthFailure(
        AuthFailureKind.unknown,
        "Couldn't register this phone. Check your connection and try again.",
      );
    }
  }
  AuthFailure _translateApiException(ApiException e) {
    // `error.code` first — it is the contract (Mobile API Guide §1). The
    // status fallbacks below remain for codes this build does not know.
    switch (e.code) {
      case 'INVALID_PAIRING_WORD':
        return const AuthFailure(
          AuthFailureKind.invalidCredentials,
          "That setup code isn't right. Check it with your admin.",
        );
      case 'PAIRING_NOT_CONFIGURED':
        return const AuthFailure(
          AuthFailureKind.accountDisabled,
          "Phone setup isn't turned on yet. Contact your admin.",
        );
      case 'ACCOUNT_INACTIVE':
        return const AuthFailure(
          AuthFailureKind.accountDisabled,
          'This account is not active. Contact your admin.',
        );
      case 'DEVICE_REVOKED':
        return const AuthFailure(
          AuthFailureKind.accountDisabled,
          'This phone has been blocked. Contact your admin.',
        );
      case 'DEVICE_OWNED_BY_ANOTHER_USER':
        return const AuthFailure(
          AuthFailureKind.accountDisabled,
          'This phone is set up for another employee. Ask your admin to '
          'release it.',
        );
      case 'RATE_LIMIT_EXCEEDED':
        // Registration allows 5 a minute per network address, so a team
        // setting up phones on one office Wi-Fi can reach it together.
        final wait = e.retryAfterSeconds;
        return AuthFailure(
          AuthFailureKind.server,
          wait == null
              ? 'Too many attempts. Wait a minute and try again.'
              : 'Too many attempts. Try again in $wait seconds.',
          code: 'RATE_LIMIT_EXCEEDED',
          retryAfterSeconds: wait,
        );
      case 'VALIDATION_ERROR':
        return AuthFailure(
          AuthFailureKind.unknown,
          "Some of your details weren't accepted. Check them and try again.",
          field: _firstInvalidField(e.details),
        );
    }
    if (e.statusCode == 401) {
      return const AuthFailure(
        AuthFailureKind.invalidCredentials,
        "That setup code isn't right. Check it with your admin.",
      );
    }
    if (e.statusCode == 403) {
      return const AuthFailure(
        AuthFailureKind.accountDisabled,
        'Your admin has turned off access. Contact them to restore it.',
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
    return AuthFailure(
      AuthFailureKind.unknown,
      e.message.isNotEmpty
          ? e.message
          : "Couldn't register this phone. Check your connection and try again.",
    );
  }

  /// The first field named in a `VALIDATION_ERROR`'s `details.fields`, which
  /// may be a list of `{field|loc, message}` or a map keyed by field name.
  static String? _firstInvalidField(dynamic details) {
    final fields = details is Map ? details['fields'] : null;
    Object? first;
    if (fields is List && fields.isNotEmpty) {
      final item = fields.first;
      first = item is Map ? (item['field'] ?? item['loc']) : item;
    } else if (fields is Map && fields.isNotEmpty) {
      first = fields.keys.first;
    }
    if (first is List && first.isNotEmpty) first = first.last;
    return first is String ? first : null;
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
  Future<void> clearLocalSession() => _store.clear();
}

class LocalAuthRepository implements AuthRepository {
  const LocalAuthRepository(this._store);

  final SessionStore _store;

  @override
  Future<EmployeeLookup> lookupEmployee({
    required String pairingWord,
    required String employeeCode,
  }) async =>
      EmployeeLookup(employeeCode: employeeCode, exists: false, canRegister: true);
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
  Future<void> clearLocalSession() => _store.clear();
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
