import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The app's version, read once from the real package metadata.
///
/// There were four hardcoded versions in this app carrying three different
/// values: `AppConfig.version` and the Settings tile said `1.0.0`,
/// `DeviceRepository` sent `1.0.0` to `/devices/register` and `/heartbeat`, and
/// registration sent `1.4.2`. The admin console therefore recorded a version
/// that had never been true, and no amount of care at release time could keep
/// four literals in step.
///
/// `package_info_plus` was already a dependency and unused. This reads
/// `versionName`/`versionCode` straight from the built artifact, so the value
/// is whatever `pubspec.yaml` and the build flags actually produced.
abstract final class AppVersion {
  /// Used until [initialize] completes, and if it fails.
  ///
  /// Kept in step with `pubspec.yaml`'s `version:` by hand — but unlike the
  /// literals it replaces, being stale here is visible only in the seconds
  /// before startup finishes, never in what is sent to the server.
  static const fallback = '1.0.0';

  static String _name = fallback;
  static String _buildNumber = '';

  /// Reads the package metadata. Call once from `main` before `runApp`.
  ///
  /// Never throws: a version string is not worth failing a launch over, and
  /// [fallback] is a truthful-enough answer when the platform channel is
  /// unavailable (a unit test, a platform without the plugin).
  static Future<void> initialize() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) _name = info.version;
      _buildNumber = info.buildNumber;
    } catch (error) {
      debugPrint('[CONFIG] Could not read package version: $error');
    }
  }

  /// `1.0.0` — what the server's `app_version` field expects.
  static String get name => _name;

  /// `1` — the Android `versionCode`. Empty when unknown.
  static String get buildNumber => _buildNumber;

  /// `1.0.0+1`, for display. Falls back to [name] when there is no build number.
  static String get full =>
      _buildNumber.isEmpty ? _name : '$_name+$_buildNumber';
}
