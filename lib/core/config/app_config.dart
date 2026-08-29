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
  static const defaultApiBaseUrl = 'http://192.168.5.46:8001/api/v1';

  static const _rawApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: defaultApiBaseUrl,
  );

  /// Sanitized and normalized base URL ending with `/api/v1` and proper `:port` format
  static String get apiBaseUrl {
    var url = _rawApiBaseUrl.trim();
    if (url.isEmpty) return '';

    // Fix typo where /8001/ was written instead of :8001/
    url = url.replaceAll(RegExp(r'(https?://[^:/]+)/8001'), r'$1:8001');

    // Ensure trailing slash is removed first for clean append
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    // Ensure /api/v1 suffix is present per Mobile API Guide Section "Base URL: https://<your-host>/api/v1"
    if (!url.endsWith('/api/v1')) {
      if (url.endsWith('/api')) {
        url = '$url/v1';
      } else {
        url = '$url/api/v1';
      }
    }

    // Dio requires a trailing slash on baseUrl so relative paths resolve correctly
    return '$url/';
  }

  static bool get hasServer => apiBaseUrl.isNotEmpty;

  static const appName = 'Zebu Call Tracker';
  static const version = '1.0.0';

  /// Shown under the login form, so a tester can tell at a glance which build
  /// they are holding.
  static String get buildLabel {
    if (!hasServer) return 'v$version · Internal build';
    final uri = Uri.tryParse(apiBaseUrl);
    final host = uri?.host ?? '';
    final port = (uri != null && uri.hasPort) ? ':${uri.port}' : '';
    return 'v$version · $host$port';
  }
}
