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

  /// One line a person can act on, for the sign-in screen and the alert banner.
  ///
  /// The same words whichever way the build is wrong: the employee can do
  /// nothing about any of them except get a new install. Which way it is wrong
  /// is on the support-only Technical details screen.
  static String? get problemMessage => problem == null
      ? null
      : 'This copy of the app is set up wrongly. Ask IT for a fresh install.';

  static const appName = 'Zebu Echo';

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
