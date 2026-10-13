import '../network/api_response.dart';

class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
    this.details,
    this.requestId,
    this.serverTime,
    this.retryAfterSeconds,
  });

  final String code;
  final String message;
  final int? statusCode;
  final dynamic details;
  final String? requestId;
  final String? serverTime;

  /// `Retry-After` on a 429 (§9), in seconds, when the server sent one.
  final int? retryAfterSeconds;

  factory ApiException.fromEnvelope({
    required ApiErrorPayload error,
    int? statusCode,
    ApiMeta? meta,
    int? retryAfterSeconds,
  }) {
    return ApiException(
      code: error.code,
      message: error.message,
      statusCode: statusCode,
      details: error.details,
      requestId: meta?.requestId,
      serverTime: meta?.serverTime,
      retryAfterSeconds: retryAfterSeconds,
    );
  }

  @override
  String toString() =>
      'ApiException(code: $code, statusCode: $statusCode, message: $message, requestId: $requestId)';
}
