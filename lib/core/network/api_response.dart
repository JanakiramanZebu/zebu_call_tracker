class ApiMeta {
  const ApiMeta({
    required this.requestId,
    this.timestamp,
    this.serverTime,
  });

  final String requestId;
  final String? timestamp;
  final String? serverTime;

  factory ApiMeta.fromJson(Map<String, dynamic>? json) {
    return ApiMeta(
      requestId: json?['request_id'] as String? ?? '',
      timestamp: json?['timestamp'] as String?,
      serverTime: json?['server_time'] as String?,
    );
  }
}

class ApiErrorPayload {
  const ApiErrorPayload({
    required this.code,
    required this.message,
    this.details,
  });

  final String code;
  final String message;
  final dynamic details;

  factory ApiErrorPayload.fromJson(Map<String, dynamic>? json) {
    return ApiErrorPayload(
      code: json?['code'] as String? ?? 'UNKNOWN_ERROR',
      message: json?['message'] as String? ?? 'An unexpected error occurred.',
      details: json?['details'],
    );
  }
}

class ApiResponse<T> {
  const ApiResponse({
    required this.success,
    this.data,
    this.error,
    this.meta,
  });

  final bool success;
  final T? data;
  final ApiErrorPayload? error;
  final ApiMeta? meta;

  factory ApiResponse.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic rawData) fromJsonT,
  ) {
    final success = json['success'] as bool? ?? false;
    final meta = json['meta'] is Map<String, dynamic>
        ? ApiMeta.fromJson(json['meta'] as Map<String, dynamic>)
        : null;

    if (!success || json.containsKey('error')) {
      final errMap = json['error'] is Map<String, dynamic>
          ? json['error'] as Map<String, dynamic>
          : null;
      return ApiResponse<T>(
        success: false,
        error: ApiErrorPayload.fromJson(errMap),
        meta: meta,
      );
    }

    final rawData = json['data'];
    final data = rawData != null ? fromJsonT(rawData) : null;
    return ApiResponse<T>(
      success: true,
      data: data,
      meta: meta,
    );
  }
}
