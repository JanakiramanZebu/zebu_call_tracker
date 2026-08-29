import 'dart:convert';

/// A signed-in employee and the credential that proves it.
class Session {
  const Session({
    required this.employeeId,
    required this.displayName,
    required this.token,
    required this.signedInAt,
    this.userId,
    this.email,
    this.phone,
    this.role,
    this.department,
    this.refreshToken,
    this.expiresAt,
    this.refreshTokenExpiresAt,
    this.deviceRegistered = false,
    this.mustChangePassword = false,
  });

  final int? userId;
  final String employeeId;
  final String displayName;
  final String? email;
  final String? phone;
  final String? role;
  final String? department;

  /// Access Token
  final String token;
  final String? refreshToken;
  final DateTime signedInAt;
  final DateTime? expiresAt;
  final DateTime? refreshTokenExpiresAt;

  final bool deviceRegistered;
  final bool mustChangePassword;

  bool get isExpired =>
      expiresAt != null && DateTime.now().toUtc().isAfter(expiresAt!);

  /// Two-letter monogram for the settings avatar.
  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '#';
    if (parts.length == 1) {
      return parts.first
          .substring(0, parts.first.length >= 2 ? 2 : 1)
          .toUpperCase();
    }
    return (parts.first[0] + parts[1][0]).toUpperCase();
  }

  Session copyWith({
    int? userId,
    String? employeeId,
    String? displayName,
    String? email,
    String? phone,
    String? role,
    String? department,
    String? token,
    String? refreshToken,
    DateTime? signedInAt,
    DateTime? expiresAt,
    DateTime? refreshTokenExpiresAt,
    bool? deviceRegistered,
    bool? mustChangePassword,
  }) {
    return Session(
      userId: userId ?? this.userId,
      employeeId: employeeId ?? this.employeeId,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      department: department ?? this.department,
      token: token ?? this.token,
      refreshToken: refreshToken ?? this.refreshToken,
      signedInAt: signedInAt ?? this.signedInAt,
      expiresAt: expiresAt ?? this.expiresAt,
      refreshTokenExpiresAt: refreshTokenExpiresAt ?? this.refreshTokenExpiresAt,
      deviceRegistered: deviceRegistered ?? this.deviceRegistered,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
    );
  }

  Map<String, Object?> toJson() => {
        'userId': userId,
        'employeeId': employeeId,
        'displayName': displayName,
        'email': email,
        'phone': phone,
        'role': role,
        'department': department,
        'token': token,
        'refreshToken': refreshToken,
        'signedInAt': signedInAt.toUtc().toIso8601String(),
        'expiresAt': expiresAt?.toUtc().toIso8601String(),
        'refreshTokenExpiresAt': refreshTokenExpiresAt?.toUtc().toIso8601String(),
        'deviceRegistered': deviceRegistered,
        'mustChangePassword': mustChangePassword,
      };

  static Session fromJson(Map<String, Object?> json) => Session(
        userId: (json['userId'] as num?)?.toInt(),
        employeeId: json['employeeId'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        email: json['email'] as String?,
        phone: json['phone'] as String?,
        role: json['role'] as String?,
        department: json['department'] as String?,
        token: json['token'] as String? ?? '',
        refreshToken: json['refreshToken'] as String?,
        signedInAt:
            DateTime.tryParse(json['signedInAt'] as String? ?? '')?.toUtc() ??
                DateTime.now().toUtc(),
        expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? '')?.toUtc(),
        refreshTokenExpiresAt:
            DateTime.tryParse(json['refreshTokenExpiresAt'] as String? ?? '')
                ?.toUtc(),
        deviceRegistered: json['deviceRegistered'] as bool? ?? false,
        mustChangePassword: json['mustChangePassword'] as bool? ?? false,
      );

  String encode() => jsonEncode(toJson());

  static Session? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      return Session.fromJson(map.cast<String, Object?>());
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

enum AuthFailureKind {
  invalidCredentials,
  accountDisabled,
  network,
  server,
  unknown,
}

class AuthFailure implements Exception {
  const AuthFailure(this.kind, this.message);

  final AuthFailureKind kind;
  final String message;

  @override
  String toString() => 'AuthFailure(${kind.name}: $message)';
}
