import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';

/// The one limit from `GET /sync/status` that Dart acts on itself.
///
/// The full policy object is forwarded to the native coordinator as raw JSON
/// (`SyncStatusResponse.rawPolicy`), which is what enforces batch size,
/// recording ceiling and formats.
class SyncPolicy {
  const SyncPolicy({this.maxClockSkewMinutes = 15});

  final int maxClockSkewMinutes;

  factory SyncPolicy.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const SyncPolicy();
    return SyncPolicy(
      maxClockSkewMinutes:
          (json['max_clock_skew_minutes'] as num?)?.toInt() ?? 15,
    );
  }
}

class PendingRecordingItem {
  const PendingRecordingItem({
    required this.callId,
    this.startedAt,
    this.phoneNumber,
    this.uploadUrl,
    this.externalCallId,
    this.requested = false,
    this.requestId,
  });

  final String callId;
  final String? startedAt;
  final String? phoneNumber;
  final String? uploadUrl;
  final String? externalCallId;

  /// An administrator pressed "Request from phone" for this call. Answered by
  /// the native `RequestedRecordingUploadWorker`, never by the reconciliation
  /// pass. False on servers that predate the field.
  final bool requested;
  final int? requestId;

  factory PendingRecordingItem.fromJson(Map<String, dynamic> json) {
    final rawRequestId = json['request_id'];
    return PendingRecordingItem(
      callId: json['call_id'] as String? ?? '',
      startedAt: json['started_at'] as String?,
      phoneNumber: json['phone_number'] as String?,
      uploadUrl: json['upload_url'] as String?,
      externalCallId: json['external_call_id'] as String?,
      requested: json['requested'] == true,
      requestId: rawRequestId is int
          ? rawRequestId
          : int.tryParse(rawRequestId?.toString() ?? ''),
    );
  }

  /// The item as the server sent it, for handing to the native worker.
  Map<String, Object?> toJson() => {
        'call_id': callId,
        'started_at': startedAt,
        'phone_number': phoneNumber,
        'upload_url': uploadUrl,
        'external_call_id': externalCallId,
        'requested': requested,
        'request_id': requestId,
      };
}

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

class SyncStatusResponse {
  const SyncStatusResponse({
    required this.serverTime,
    required this.deviceStatus,
    required this.deviceRegistered,
    required this.policy,
    required this.pendingRecordingUploads,
    this.rawPolicy,
    this.lastSyncAt,
    this.lastCallAt,
    this.totalCalls,
    this.callsToday,
    this.callsLast7Days,
    this.recordingsStored,
  });

  final String serverTime;
  final String deviceStatus;
  final bool deviceRegistered;
  final SyncPolicy policy;
  final List<PendingRecordingItem> pendingRecordingUploads;

  /// The `policy` object exactly as the server sent it.
  ///
  /// Kept alongside the parsed form because the native coordinator is what
  /// actually enforces these limits, and handing it the original JSON means the
  /// two sides cannot disagree about what the server said.
  final Map<String, dynamic>? rawPolicy;

  /// What the server itself holds for this employee — the only proof that
  /// calls arrived, as opposed to the phone's belief that they were sent.
  /// Null when the server did not say.
  final DateTime? lastSyncAt;
  final DateTime? lastCallAt;
  final int? totalCalls;
  final int? callsToday;
  final int? callsLast7Days;
  final int? recordingsStored;

  factory SyncStatusResponse.fromJson(Map<String, dynamic> json) {
    final pendingList = json['pending_recording_uploads'] as List? ?? [];
    return SyncStatusResponse(
      serverTime: json['server_time'] as String? ?? DateTime.now().toUtc().toIso8601String(),
      deviceStatus: json['device_status'] as String? ?? 'ACTIVE',
      deviceRegistered: json['device_registered'] as bool? ?? true,
      policy: SyncPolicy.fromJson(json['policy'] as Map<String, dynamic>?),
      rawPolicy: json['policy'] as Map<String, dynamic>?,
      pendingRecordingUploads: pendingList
          .map((i) => PendingRecordingItem.fromJson(i as Map<String, dynamic>))
          .toList(),
      lastSyncAt: _time(json['last_sync_at']),
      lastCallAt: _time(json['last_call_at']),
      totalCalls: (json['total_calls'] as num?)?.toInt(),
      callsToday: (json['calls_today'] as num?)?.toInt(),
      callsLast7Days: (json['calls_last_7_days'] as num?)?.toInt(),
      recordingsStored: (json['recordings_stored'] as num?)?.toInt(),
    );
  }
}

/// The Dart half of the server conversation: everything EXCEPT the upload.
///
/// Posting calls and recordings belongs to the native `SyncCoordinator` and to
/// it alone, because that is the only path that still runs with the Flutter
/// engine dead — which is the entire premise of the product. This class once
/// carried a parallel `uploadSingleCall`/`syncBatch`/`uploadRecording`
/// implementation of the same endpoints; nothing called it, and had anything
/// started to, the two writers would have raced over the same outbox rows.
///
/// What is left is the half the coordinator cannot do: reading back what the
/// server thinks it has, so local state can be corrected against it.
class SyncRepository {
  SyncRepository({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  Future<SyncStatusResponse> getSyncStatus() async {
    final res = await _apiClient.get<Map<String, dynamic>>(ApiEndpoints.syncStatus);
    return SyncStatusResponse.fromJson(res.data ?? {});
  }

  /// Tells the server a call it expects audio for is never getting any.
  ///
  /// Without this the server keeps the call in `pending_recording_uploads`
  /// forever, and every reconciliation pass re-offers a recording that does
  /// not exist.
  Future<void> updateCallNoRecording(String serverCallId) async {
    await _apiClient.patch<dynamic>(
      ApiEndpoints.callById(serverCallId),
      data: {'has_recording': false},
    );
  }
}

