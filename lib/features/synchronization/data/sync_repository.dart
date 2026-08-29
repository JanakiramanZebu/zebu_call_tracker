import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/storage/app_database.dart';

class SyncPolicy {
  const SyncPolicy({
    this.maxBatchSize = 200,
    this.maxCallAgeDays = 90,
    this.maxClockSkewMinutes = 15,
    this.maxRecordingSizeBytes = 209715200,
    this.allowedExtensions = const [
      '3gp', 'aac', 'amr', 'm4a', 'mp3', 'mp4', 'ogg', 'opus', 'wav'
    ],
    this.recommendedIntervalSeconds = 300,
    this.recommendedBatchSize = 50,
  });

  final int maxBatchSize;
  final int maxCallAgeDays;
  final int maxClockSkewMinutes;
  final int maxRecordingSizeBytes;
  final List<String> allowedExtensions;
  final int recommendedIntervalSeconds;
  final int recommendedBatchSize;

  factory SyncPolicy.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SyncPolicy();
    return SyncPolicy(
      maxBatchSize: (json['max_batch_size'] as num?)?.toInt() ?? 200,
      maxCallAgeDays: (json['max_call_age_days'] as num?)?.toInt() ?? 90,
      maxClockSkewMinutes: (json['max_clock_skew_minutes'] as num?)?.toInt() ?? 15,
      maxRecordingSizeBytes: (json['max_recording_size_bytes'] as num?)?.toInt() ?? 209715200,
      allowedExtensions: (json['allowed_recording_extensions'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['3gp', 'aac', 'amr', 'm4a', 'mp3', 'mp4', 'ogg', 'opus', 'wav'],
      recommendedIntervalSeconds:
          (json['recommended_sync_interval_seconds'] as num?)?.toInt() ?? 300,
      recommendedBatchSize: (json['recommended_batch_size'] as num?)?.toInt() ?? 50,
    );
  }
}

class PendingRecordingItem {
  const PendingRecordingItem({
    required this.callId,
    required this.uploadUrl,
    this.startedAt,
    this.phoneNumber,
  });

  final String callId;
  final String uploadUrl;
  final String? startedAt;
  final String? phoneNumber;

  factory PendingRecordingItem.fromJson(Map<String, dynamic> json) {
    return PendingRecordingItem(
      callId: json['call_id'] as String? ?? '',
      uploadUrl: json['upload_url'] as String? ?? '',
      startedAt: json['started_at'] as String?,
      phoneNumber: json['phone_number'] as String?,
    );
  }
}

class SyncStatusResponse {
  const SyncStatusResponse({
    required this.serverTime,
    required this.deviceStatus,
    required this.deviceRegistered,
    required this.policy,
    required this.pendingRecordingUploads,
  });

  final String serverTime;
  final String deviceStatus;
  final bool deviceRegistered;
  final SyncPolicy policy;
  final List<PendingRecordingItem> pendingRecordingUploads;

  factory SyncStatusResponse.fromJson(Map<String, dynamic> json) {
    final pendingList = json['pending_recording_uploads'] as List? ?? [];
    return SyncStatusResponse(
      serverTime: json['server_time'] as String? ?? DateTime.now().toUtc().toIso8601String(),
      deviceStatus: json['device_status'] as String? ?? 'ACTIVE',
      deviceRegistered: json['device_registered'] as bool? ?? true,
      policy: SyncPolicy.fromJson(json['policy'] as Map<String, dynamic>?),
      pendingRecordingUploads: pendingList
          .map((i) => PendingRecordingItem.fromJson(i as Map<String, dynamic>))
          .toList(),
    );
  }
}

class BatchSuccessItem {
  const BatchSuccessItem({
    required this.idempotencyKey,
    required this.callId,
    required this.revision,
  });

  final String idempotencyKey;
  final String callId;
  final int revision;

  factory BatchSuccessItem.fromJson(Map<String, dynamic> json) {
    return BatchSuccessItem(
      idempotencyKey: json['idempotency_key'] as String? ?? '',
      callId: json['call_id'] as String? ?? '',
      revision: (json['revision'] as num?)?.toInt() ?? 1,
    );
  }
}

class BatchFailedItem {
  const BatchFailedItem({
    required this.idempotencyKey,
    required this.errorCode,
    required this.message,
    required this.retryable,
  });

  final String idempotencyKey;
  final String errorCode;
  final String message;
  final bool retryable;

  factory BatchFailedItem.fromJson(Map<String, dynamic> json) {
    final err = json['error'] as Map<String, dynamic>? ?? {};
    return BatchFailedItem(
      idempotencyKey: json['idempotency_key'] as String? ?? '',
      errorCode: err['code'] as String? ?? 'UNKNOWN_ERROR',
      message: err['message'] as String? ?? '',
      retryable: json['retryable'] as bool? ?? true,
    );
  }
}

class BatchSyncResult {
  const BatchSyncResult({
    required this.successful,
    required this.duplicates,
    required this.failed,
  });

  final List<BatchSuccessItem> successful;
  final List<BatchSuccessItem> duplicates;
  final List<BatchFailedItem> failed;

  factory BatchSyncResult.fromJson(Map<String, dynamic> json) {
    final succList = json['successful'] as List? ?? [];
    final dupList = json['duplicates'] as List? ?? [];
    final failList = json['failed'] as List? ?? [];

    return BatchSyncResult(
      successful: succList
          .map((i) => BatchSuccessItem.fromJson(i as Map<String, dynamic>))
          .toList(),
      duplicates: dupList
          .map((i) => BatchSuccessItem.fromJson(i as Map<String, dynamic>))
          .toList(),
      failed: failList
          .map((i) => BatchFailedItem.fromJson(i as Map<String, dynamic>))
          .toList(),
    );
  }
}

class SyncRepository {
  SyncRepository({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  Future<SyncStatusResponse> getSyncStatus() async {
    final res = await _apiClient.get<Map<String, dynamic>>(ApiEndpoints.syncStatus);
    return SyncStatusResponse.fromJson(res.data ?? {});
  }

  Future<BatchSyncResult> syncBatch({
    required String deviceUuid,
    required List<LocalCall> calls,
  }) async {
    final callPayloads = calls.map((c) {
      return {
        'idempotency_key': c.idempotencyKey,
        'external_call_id': c.externalCallId ?? 'local-${c.localId}',
        'device_uuid': deviceUuid,
        'phone_number': c.phoneNumber,
        'contact_name': c.contactName,
        'direction': c.direction,
        'status': c.status,
        'started_at': c.startedAt.toUtc().toIso8601String(),
        'answered_at': c.answeredAt?.toUtc().toIso8601String(),
        'ended_at': c.endedAt?.toUtc().toIso8601String(),
        'duration_seconds': c.durationSeconds,
        'has_recording': c.hasRecording,
        'sim_slot': c.simSlot ?? 1,
        'client_created_at': c.clientCreatedAt.toUtc().toIso8601String(),
      };
    }).toList();

    final res = await _apiClient.post<Map<String, dynamic>>(
      ApiEndpoints.syncCalls,
      data: {
        'device_uuid': deviceUuid,
        'client_synced_at': DateTime.now().toUtc().toIso8601String(),
        'calls': callPayloads,
      },
    );

    return BatchSyncResult.fromJson(res.data ?? {});
  }

  Future<void> updateCallNoRecording(String serverCallId) async {
    await _apiClient.patch<dynamic>(
      ApiEndpoints.callById(serverCallId),
      data: {'has_recording': false},
    );
  }

  Future<bool> uploadRecording({
    required String serverCallId,
    required File audioFile,
    required String checksumSha256,
    int? durationSeconds,
  }) async {
    final length = await audioFile.length();
    final filename = audioFile.path.split(Platform.pathSeparator).last;

    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        audioFile.path,
        filename: filename,
      ),
      'checksum': checksumSha256,
      'file_size': length.toString(),
      if (durationSeconds != null) 'duration_seconds': durationSeconds.toString(),
    });

    final res = await _apiClient.post<Map<String, dynamic>>(
      ApiEndpoints.callRecording(serverCallId),
      data: formData,
    );

    return res.success;
  }

  static Future<String> computeSha256(File file) async {
    final stream = file.openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString().toLowerCase();
  }

  /// Section 5.4: Recovering from a lost response by looking up idempotency keys
  Future<Map<String, dynamic>> lookupSyncKeys(List<String> idempotencyKeys) async {
    final res = await _apiClient.post<Map<String, dynamic>>(
      ApiEndpoints.syncLookup,
      data: {'idempotency_keys': idempotencyKeys},
    );
    return res.data ?? {};
  }

  /// Section 4: Post single call (upsert)
  Future<Map<String, dynamic>> postSingleCall(Map<String, dynamic> callPayload) async {
    final res = await _apiClient.post<Map<String, dynamic>>(
      ApiEndpoints.calls,
      data: callPayload,
    );
    return res.data ?? {};
  }

  /// Section 7: Obtain playback token for remote recording streaming
  Future<Map<String, dynamic>> getPlaybackToken(String recordingId) async {
    final res = await _apiClient.post<Map<String, dynamic>>(
      ApiEndpoints.playbackToken(recordingId),
    );
    return res.data ?? {};
  }

  /// Section 8: Fetch remote call records with filtering and pagination
  Future<Map<String, dynamic>> fetchRemoteCalls({
    int page = 1,
    int pageSize = 50,
    String? updatedSince,
    String? direction,
    String? status,
  }) async {
    final res = await _apiClient.get<Map<String, dynamic>>(
      ApiEndpoints.calls,
      queryParameters: {
        'page': page,
        'page_size': pageSize,
        'updated_since': ?updatedSince,
        'direction': ?direction,
        'status': ?status,
      },
    );
    return res.data ?? {};
  }

  /// Section 8: Fetch user's call dashboard statistics
  Future<Map<String, dynamic>> fetchRemoteDashboard({String range = 'today'}) async {
    final res = await _apiClient.get<Map<String, dynamic>>(
      ApiEndpoints.dashboard,
      queryParameters: {'range': range},
    );
    return res.data ?? {};
  }
}

