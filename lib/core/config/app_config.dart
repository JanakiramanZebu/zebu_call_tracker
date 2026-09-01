import 'package:flutter/foundation.dart';

/// What is wrong with the build's server configuration, if anything.
///
/// Exists because the previous arrangement had no way to be wrong out loud. A
/// release APK built without `--dart-define=API_BASE_URL=…` inherited a
/// hardcoded LAN address, `hasServer` answered `true`, the UI showed a signed-in
/// shell, and every request died in the TLS stack against a manifest that
/// forbids cleartext. The build was broken and nothing said so.
enum ConfigProblem {
  /// No `API_BASE_URL` was supplied at build time.
  missingServerUrl,

  /// Supplied, but not a URL with a scheme and a host.
  malformedServerUrl,

  /// `http://` in a release build. `android:usesCleartextTraffic="false"` means
  /// the platform will refuse every request, so this cannot work — it is a
  /// broken build, not a lax one.
  insecureServerUrl,
}

/// Build-time configuration, supplied with `--dart-define`.
///
/// Kept in one place so no widget reaches for `String.fromEnvironment` inline,
/// and so "is a server configured?" is a single question with a single answer.
///
/// ```
/// flutter build apk --release --dart-define=API_BASE_URL=https://calls.mynt.in
/// ```
///
/// or, for a whole environment at once:
///
/// ```
/// flutter build apk --release --dart-define-from-file=env/production.json
/// ```
///
/// See `env/example.json`.
abstract final class AppConfig {
  /// Deliberately no default.
  ///
  /// This used to fall back to a developer's LAN address
  /// (`http://192.168.5.46:8001`). That made an unconfigured release build
  /// indistinguishable from a configured one right up until the first request
  /// failed, on a handset, in the field.
  static const _rawApiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// Non-null when the build cannot reach a server, whatever the reason.
  static ConfigProblem? get problem => _resolved.problem;

  /// Normalized base URL ending in `/api/v1/`, or empty when [problem] is set.
  static String get apiBaseUrl => _resolved.url;

  /// True only when a usable server is configured. Everything that gates on
  /// "can we sync?" reads this, so a misconfigured build degrades to a visible
  /// offline state rather than a silent failure loop.
  static bool get hasServer => apiBaseUrl.isNotEmpty;

  /// One line a person can act on, for the sign-in and settings screens.
  static String? get problemMessage => switch (problem) {
        ConfigProblem.missingServerUrl =>
          'This build has no server address. It was compiled without '
              'API_BASE_URL and cannot sync. Ask for a correctly built app.',
        ConfigProblem.malformedServerUrl =>
          'This build has an invalid server address and cannot sync. '
              'Ask for a correctly built app.',
        ConfigProblem.insecureServerUrl =>
          'This build points at an insecure (http) server address, which '
              'release builds refuse to contact. Ask for a correctly built app.',
        null => null,
      };

  static const appName = 'Zebu Call Tracker';

  /// Shown under the sign-in form so a tester can tell at a glance which build
  /// they are holding. Version comes from `AppVersion`, which reads the real
  /// package metadata rather than a constant somebody has to remember to bump.
  static String buildLabel(String version) {
    final message = switch (problem) {
      ConfigProblem.missingServerUrl => 'no server configured',
      ConfigProblem.malformedServerUrl => 'invalid server address',
      ConfigProblem.insecureServerUrl => 'insecure server address',
      null => null,
    };
    if (message != null) return 'v$version · $message';

    final uri = Uri.tryParse(apiBaseUrl);
    final host = uri?.host ?? '';
    final port = (uri != null && uri.hasPort) ? ':${uri.port}' : '';
    return 'v$version · $host$port';
  }

  static final _Resolved _resolved = _resolve(_rawApiBaseUrl);

  static _Resolved _resolve(String raw) {
    var url = raw.trim();
    if (url.isEmpty) {
      return const _Resolved(problem: ConfigProblem.missingServerUrl);
    }

    // No silent rewriting. There used to be a rule here meant to repair a
    // mistyped define that wrote the port as a path segment
    // (`https://host/8001` for `https://host:8001`). It never worked:
    // `String.replaceAll` takes a literal replacement, so `$1` was not a
    // backreference and any URL it matched came out as the four characters
    // `$1:8001`. It corrupted exactly the input it claimed to fix. A wrong URL
    // is now reported as wrong instead of being quietly rewritten into a
    // different wrong URL.

    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return const _Resolved(problem: ConfigProblem.malformedServerUrl);
    }

    if (uri.scheme == 'http' && kReleaseMode) {
      // Reporting this as "no server" is the honest answer: the network stack
      // will not carry a single request, so pretending otherwise only moves the
      // failure somewhere harder to diagnose.
      return const _Resolved(problem: ConfigProblem.insecureServerUrl);
    }

    if (url.endsWith('/')) url = url.substring(0, url.length - 1);

    // The guide fixes the base at `https://<host>/api/v1`. Accepting a URL with
    // or without it means one less way for a deployment to be subtly wrong.
    if (!url.endsWith('/api/v1')) {
      url = url.endsWith('/api') ? '$url/v1' : '$url/api/v1';
    }

    // Dio requires the trailing slash for relative paths to resolve.
    return _Resolved(url: '$url/');
  }
}

class _Resolved {
  const _Resolved({this.url = '', this.problem});

  final String url;
  final ConfigProblem? problem;
}
