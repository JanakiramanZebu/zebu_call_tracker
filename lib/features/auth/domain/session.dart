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
  /// The setup code (pairing word) was refused. Fixed on the first step.
  invalidCredentials,

  /// The employee account cannot register a phone: deactivated, or an
  /// admin/manager account that signs in on the web console instead.
  accountDisabled,
  network,
  server,
  unknown,
}

class AuthFailure implements Exception {
  const AuthFailure(
    this.kind,
    this.message, {
    this.field,
    this.code,
    this.retryAfterSeconds,
  });

  final AuthFailureKind kind;
  final String message;

  /// The server's `error.code`, when there was one.
  final String? code;

  /// The request field the server refused (`error.details.fields`), when it
  /// named one — lets the form open the step that holds it.
  final String? field;

  /// How long the server asked us to wait, on a rate-limit refusal.
  final int? retryAfterSeconds;

  @override
  String toString() => 'AuthFailure(${kind.name}: $message)';
}

/// What the server already holds for an employee code (`POST /mobile/lookup`).
///
/// Phone and email arrive masked only. The setup code is shared by the whole
/// workforce, so the lookup must not hand anyone a colleague's full number;
/// the form shows the masked value as a hint and sends the field empty, which
/// the server reads as "keep what you have".
class EmployeeLookup {
  const EmployeeLookup({
    required this.employeeCode,
    required this.exists,
    required this.canRegister,
    this.name,
    this.department,
    this.designation,
    this.location,
    this.managerName,
    this.phone,
    this.email,
    this.phoneMasked,
    this.emailMasked,
    this.hasPhone = false,
    this.hasEmail = false,
  });

  /// The code as the server normalised it (trimmed, upper case).
  final String employeeCode;
  final bool exists;

  /// False for a deactivated account or one that is not an ordinary employee.
  final bool canRegister;

  final String? name;
  final String? department;
  final String? designation;
  final String? location;
  final String? managerName;
  /// Full phone and email, when the server sends them (`profile.phone`,
  /// `profile.email`). Today's lookup sends only the masked forms below;
  /// these fill the form as soon as it sends the full ones.
  final String? phone;
  final String? email;
  final String? phoneMasked;
  final String? emailMasked;
  final bool hasPhone;
  final bool hasEmail;

  /// An existing employee whose details can fill the form.
  bool get hasProfile => exists && canRegister && name != null;

  factory EmployeeLookup.fromJson(Map<String, dynamic> json, String fallbackCode) {
    String? text(Map<String, dynamic>? m, String key) {
      final v = m?[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    final profile = json['profile'] as Map<String, dynamic>?;
    return EmployeeLookup(
      employeeCode: text(json, 'employee_code') ?? fallbackCode,
      exists: json['exists'] == true,
      // Absent means the server did not object.
      canRegister: json['can_register'] != false,
      name: text(profile, 'name'),
      department: text(profile, 'department'),
      designation: text(profile, 'designation'),
      location: text(profile, 'location'),
      managerName: text(profile, 'manager_name'),
      phone: text(profile, 'phone'),
      email: text(profile, 'email'),
      phoneMasked: text(profile, 'phone_masked'),
      emailMasked: text(profile, 'email_masked'),
      hasPhone: profile?['has_phone'] == true,
      hasEmail: profile?['has_email'] == true,
    );
  }
}
