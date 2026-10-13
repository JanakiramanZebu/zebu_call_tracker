import 'dart:io';

import '../../../core/config/app_version.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import 'device_uuid_store.dart';

class DeviceRegistrationResult {
  const DeviceRegistrationResult({
    required this.created,
    required this.deviceUuid,
    this.message,
  });

  final bool created;
  final String deviceUuid;
  final String? message;
}

class DeviceRepository {
  DeviceRepository({
    required ApiClient apiClient,
    DeviceUuidStore? uuidStore,
  })  : _apiClient = apiClient,
        _uuidStore = uuidStore ?? const DeviceUuidStore();

  final ApiClient _apiClient;
  final DeviceUuidStore _uuidStore;

  Future<String> getDeviceUuid() => _uuidStore.getOrCreateUuid();

  Future<DeviceRegistrationResult> registerDevice({
    required Map<String, Object?> deviceInfo,
  }) async {
    final uuid = await getDeviceUuid();

    final payload = {
      'device_uuid': uuid,
      'device_id': uuid,
      'device_name': deviceInfo['model'] as String? ?? 'Android Device',
      'manufacturer': deviceInfo['manufacturer'] as String? ?? 'Generic',
      'model': deviceInfo['model'] as String? ?? 'Unknown',
      'platform': Platform.isAndroid ? 'android' : 'ios',
      // Native reports it as `osVersion`; `version` never existed, so every
      // registration sent Dart's own platform string instead.
      'os_version': deviceInfo['osVersion'] as String? ??
          Platform.operatingSystemVersion,
      'app_version': AppVersion.name,
      'phone_number': deviceInfo['phone_number'] as String?,
    };

    final response = await _apiClient.post<Map<String, dynamic>>(
      ApiEndpoints.registerDevice,
      data: payload,
    );

    final data = response.data ?? {};
    return DeviceRegistrationResult(
      created: data['created'] as bool? ?? false,
      deviceUuid: uuid,
      message: data['message'] as String?,
    );
  }

  // The heartbeat is sent natively (`NativeCallBridge.sendHeartbeat`), so the
  // foreground, background and push senders share one once-a-minute limit.
}

