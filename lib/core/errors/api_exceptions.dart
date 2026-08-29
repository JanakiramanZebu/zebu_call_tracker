import '../network/api_response.dart';

class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
    this.details,
    this.requestId,
    this.serverTime,
  });

  final String code;
  final String message;
  final int? statusCode;
  final dynamic details;
  final String? requestId;
  final String? serverTime;

  bool get isTokenExpired => code == 'TOKEN_EXPIRED';
  bool get isInvalidToken => code == 'INVALID_TOKEN' || code == 'UNAUTHENTICATED';
  bool get isDeviceRevoked => code == 'DEVICE_REVOKED' || code == 'ACCOUNT_INACTIVE';
  bool get isDeviceNotRegistered => code == 'DEVICE_NOT_REGISTERED';
  bool get isSyncPolicyViolation => code == 'SYNC_POLICY_VIOLATION';
  bool get isChecksumMismatch => code == 'CHECKSUM_MISMATCH';
  bool get isDuplicate => code == 'DUPLICATE_CALL' || code == 'RECORDING_ALREADY_EXISTS';

  factory ApiException.fromEnvelope({
    required ApiErrorPayload error,
    int? statusCode,
    ApiMeta? meta,
  }) {
    return ApiException(
      code: error.code,
      message: error.message,
      statusCode: statusCode,
      details: error.details,
      requestId: meta?.requestId,
      serverTime: meta?.serverTime,
    );
  }

  @override
  String toString() =>
      'ApiException(code: $code, statusCode: $statusCode, message: $message, requestId: $requestId)';
}
