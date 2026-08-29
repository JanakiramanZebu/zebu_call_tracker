import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class DeviceUuidStore {
  const DeviceUuidStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;
  static const _key = 'zebu.device_uuid.v1';

  /// Retrieves or generates a stable installation device UUID (v4) according to Section 3 of Mobile API Guide.
  Future<String> getOrCreateUuid() async {
    try {
      final existing = await _storage.read(key: _key);
      if (existing != null && existing.isNotEmpty) {
        return existing;
      }
    } catch (_) {}

    final newUuid = const Uuid().v4();
    try {
      await _storage.write(key: _key, value: newUuid);
    } catch (_) {}
    return newUuid;
  }
}
