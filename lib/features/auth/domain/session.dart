import 'dart:convert';

/// A signed-in employee and the credential that proves it.
///
/// Persisted whole into secure storage rather than split across stores: the
/// token and the identity it belongs to must never get out of step, and a
/// half-restored session is harder to reason about than none at all.
class Session {
  const Session({
    required this.employeeId,
    required this.displayName,
    required this.token,
    required this.signedInAt,
    this.expiresAt,
  });

  final String employeeId;
  final String displayName;
  final String token;
  final DateTime signedInAt;

  /// Null means "no expiry advertised by the server" — treated as valid until
  /// a request is rejected, not as already expired.
  final DateTime? expiresAt;

  bool get isExpired =>
      expiresAt != null && DateTime.now().toUtc().isAfter(expiresAt!);

  /// Two-letter monogram for the settings avatar.
  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '#';
    if (parts.length == 1) {
      return parts.first.substring(0, parts.first.length >= 2 ? 2 : 1)
          .toUpperCase();
    }
    return (parts.first[0] + parts[1][0]).toUpperCase();
  }

  Map<String, Object?> toJson() => {
    'employeeId': employeeId,
    'displayName': displayName,
    'token': token,
    'signedInAt': signedInAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
  };

  static Session fromJson(Map<String, Object?> json) => Session(
    employeeId: json['employeeId']! as String,
    displayName: json['displayName'] as String? ?? '',
    token: json['token']! as String,
    signedInAt:
        DateTime.tryParse(json['signedInAt'] as String? ?? '')?.toUtc() ??
        DateTime.now().toUtc(),
    expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? '')?.toUtc(),
  );

  String encode() => jsonEncode(toJson());

  /// Returns null for anything that does not decode cleanly — a corrupt blob in
  /// secure storage should land the user on the login screen, not crash the app
  /// on every launch.
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

/// Why a sign-in attempt failed, as a value the UI can switch on instead of
/// pattern-matching an error string.
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

  /// Already user-facing: repositories phrase these for the person holding the
  /// phone, because the login screen has nowhere better to get the wording.
  final String message;

  @override
  String toString() => 'AuthFailure(${kind.name}: $message)';
}
