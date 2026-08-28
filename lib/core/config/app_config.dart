/// Build-time configuration, supplied with `--dart-define`.
///
/// Kept in one place so no widget reaches for `String.fromEnvironment` inline,
/// and so "is a server configured?" is a single question with a single answer.
///
/// Example:
/// ```
/// flutter run --dart-define=API_BASE_URL=https://calls.mynt.in/api/v1
/// ```
abstract final class AppConfig {
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// When no base URL is compiled in, sign-in runs against the on-device
  /// repository instead of a server. That path exists so the app is usable and
  /// testable ahead of the backend; it is never a fallback for a server that is
  /// merely unreachable — a configured build that cannot reach its server
  /// reports a network error rather than quietly signing the user in.
  static bool get hasServer => apiBaseUrl.isNotEmpty;

  static const appName = 'Zebu Call Tracker';
  static const version = '1.0.0';

  /// Shown under the login form, so a tester can tell at a glance which build
  /// they are holding.
  static String get buildLabel =>
      hasServer ? 'v$version · ${Uri.parse(apiBaseUrl).host}' : 'v$version · Internal build';
}
