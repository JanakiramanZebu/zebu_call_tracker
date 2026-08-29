import 'dart:io';

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
      'os_version': deviceInfo['version'] as String? ?? Platform.operatingSystemVersion,
      'app_version': '1.0.0',
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

  Future<void> sendHeartbeat({
    int pendingCalls = 0,
    int pendingRecordings = 0,
  }) async {
    final uuid = await getDeviceUuid();
    await _apiClient.post<dynamic>(
      ApiEndpoints.heartbeat(uuid),
      data: {
        'app_version': '1.0.0',
        'os_version': Platform.operatingSystemVersion,
        'pending_calls': pendingCalls,
        'pending_recordings': pendingRecordings,
      },
    );
  }

  Future<List<Map<String, dynamic>>> getMyDevices() async {
    final response = await _apiClient.get<List<dynamic>>(ApiEndpoints.myDevices);
    final rawList = response.data ?? [];
    return rawList.whereType<Map<String, dynamic>>().toList();
  }

  Future<bool> updateDevice({
    required String deviceUuid,
    String? deviceName,
    String? appVersion,
    String? osVersion,
  }) async {
    final response = await _apiClient.patch<Map<String, dynamic>>(
      ApiEndpoints.updateDevice(deviceUuid),
      data: {
        'device_name': ?deviceName,
        'app_version': ?appVersion,
        'os_version': ?osVersion,
      },
    );
    return response.success;
  }
}

