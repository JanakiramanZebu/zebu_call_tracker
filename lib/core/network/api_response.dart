class ApiMeta {
  const ApiMeta({
    required this.requestId,
    this.timestamp,
    this.serverTime,
  });

  final String requestId;
  final String? timestamp;
  final String? serverTime;

  DateTime? get serverDateTime =>
      serverTime != null ? DateTime.tryParse(serverTime!)?.toUtc() : null;

  factory ApiMeta.fromJson(Map<String, dynamic>? json) {
    return ApiMeta(
      requestId: json?['request_id'] as String? ?? '',
      timestamp: json?['timestamp'] as String?,
      serverTime: json?['server_time'] as String?,
    );
  }
}

class ApiPagination {
  const ApiPagination({
    required this.page,
    required this.pageSize,
    required this.total,
    required this.totalPages,
    required this.hasNext,
    required this.hasPrevious,
  });

  final int page;
  final int pageSize;
  final int total;
  final int totalPages;
  final bool hasNext;
  final bool hasPrevious;

  factory ApiPagination.fromJson(Map<String, dynamic>? json) {
    return ApiPagination(
      page: (json?['page'] as num?)?.toInt() ?? 1,
      pageSize: (json?['page_size'] as num?)?.toInt() ?? 50,
      total: (json?['total'] as num?)?.toInt() ?? 0,
      totalPages: (json?['total_pages'] as num?)?.toInt() ?? 1,
      hasNext: json?['has_next'] as bool? ?? false,
      hasPrevious: json?['has_previous'] as bool? ?? false,
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
    this.pagination,
    this.meta,
  });

  final bool success;
  final T? data;
  final ApiErrorPayload? error;
  final ApiPagination? pagination;
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
    final pagination = json['pagination'] is Map<String, dynamic>
        ? ApiPagination.fromJson(json['pagination'] as Map<String, dynamic>)
        : null;

    return ApiResponse<T>(
      success: true,
      data: data,
      pagination: pagination,
      meta: meta,
    );
  }
}
