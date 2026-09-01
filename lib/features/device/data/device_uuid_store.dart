import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// The installation's stable device identity.
///
/// This value is the whole basis of device identity on the server: it is sent
/// as `mobile_unique_id` at registration, the backend adopts it verbatim as the
/// device's `device_uuid`, and every subsequent `POST /sync/calls` is attributed
/// with it. If it ever changes, the handset becomes an unregistered device and
/// the server rejects everything in the outbox with `DEVICE_NOT_REGISTERED`.
///
/// So it must survive: a keystore reset, a restore from backup, and a secure
/// storage plugin that throws on a particular OEM ROM. The previous version
/// swallowed every storage failure and fell through to `Uuid().v4()`, which
/// meant a device whose secure storage was unreadable minted a **new identity on
/// every call** — registering as one device and then syncing as another, for as
/// long as the condition lasted.
///
/// Three layers, in order of durability:
///
/// 1. an in-memory cache, so one bad read cannot change the answer mid-session;
/// 2. secure storage, the preferred home;
/// 3. shared preferences, which is plain-text but far more reliable.
///
/// Plain-text is an acceptable home for this. The UUID is an identifier, not a
/// credential — it authorises nothing on its own, and every request carrying it
/// is already authenticated by a bearer token. A stable identifier in plain
/// text is worth more than a secret one that changes.
class DeviceUuidStore {
  const DeviceUuidStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;
  static const _key = 'zebu.device_uuid.v1';

  /// Survives a failed write within the process; layers 2 and 3 survive restarts.
  static String? _cached;

  /// The stable installation UUID, creating one on first run.
  Future<String> getOrCreateUuid() async {
    if (_cached != null) return _cached!;

    final secure = await _readSecure();
    if (secure != null) {
      _cached = secure;
      // Mirror forward so a later keystore failure has something to find.
      await _writePrefs(secure);
      return secure;
    }

    final fallback = await _readPrefs();
    if (fallback != null) {
      _cached = fallback;
      // Try to promote it back into secure storage, but do not depend on it.
      await _writeSecure(fallback);
      return fallback;
    }

    final created = const Uuid().v4();
    _cached = created;
    // Written to both, because either may be the one that survives.
    await _writeSecure(created);
    await _writePrefs(created);
    return created;
  }

  Future<String?> _readSecure() async {
    try {
      final value = await _storage.read(key: _key);
      return (value != null && value.isNotEmpty) ? value : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSecure(String value) async {
    try {
      await _storage.write(key: _key, value: value);
    } catch (_) {}
  }

  Future<String?> _readPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_key);
      return (value != null && value.isNotEmpty) ? value : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePrefs(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_key) != value) {
        await prefs.setString(_key, value);
      }
    } catch (_) {}
  }

  /// Test seam: forget the in-process cache.
  static void resetCacheForTesting() => _cached = null;
}
