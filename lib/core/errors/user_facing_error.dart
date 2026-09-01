import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../platform/native_call_bridge.dart';
import 'api_exceptions.dart';

/// Turns anything thrown into something worth showing a person.
///
/// Six screens rendered `message: '$e'`, so a storage hiccup reached the user
/// as `SqliteException(11): database disk image is malformed, SQL logic error`
/// and a dropped connection as `DioException [connection error]: ...`. That is
/// a stack trace wearing a UI: it names no cause the reader can act on, and it
/// puts internals in front of someone who cannot use them.
///
/// The exception itself is not discarded — [technical] keeps it for the log and
/// for a diagnostics screen. It is simply not the headline.
class UserFacingError {
  const UserFacingError({
    required this.title,
    required this.message,
    required this.technical,
    this.isRetryable = true,
  });

  /// Short, plain, and about what the reader lost.
  final String title;

  /// What happened and what to do about it.
  final String message;

  /// The original text. For logs and diagnostics — never the headline.
  final String technical;

  /// False when trying again cannot help, so a screen can hide "Try again".
  final bool isRetryable;

  /// Classifies [error] into something sayable.
  ///
  /// Ordered most specific first: an [ApiException] carries a contractual
  /// `error.code` and is the only case where the cause is genuinely known.
  factory UserFacingError.from(Object error) {
    final technical = error.toString();

    if (error is ApiException) {
      return UserFacingError(
        title: _apiTitle(error.code),
        message: _apiMessage(error),
        technical: technical,
        isRetryable: _apiRetryable(error.code),
      );
    }

    if (error is NativeFailure) {
      return UserFacingError(
        title: switch (error.kind) {
          NativeFailureKind.permissionDenied => 'Permission needed',
          NativeFailureKind.unsupportedPlatform => 'Not available here',
          NativeFailureKind.platformError => 'This phone could not be read',
        },
        message: switch (error.kind) {
          NativeFailureKind.permissionDenied =>
            'This needs access that has not been granted yet. Review the app '
                'permissions and try again.',
          NativeFailureKind.unsupportedPlatform =>
            'Call tracking only works on Android.',
          NativeFailureKind.platformError =>
            'The phone reported a problem reading its call data. Try again in '
                'a moment.',
        },
        technical: technical,
        isRetryable: error.kind != NativeFailureKind.unsupportedPlatform,
      );
    }

    if (error is DioException) {
      return UserFacingError(
        title: 'No connection to the server',
        message: 'Your calls are saved on this phone and will be sent '
            'automatically once the connection is back.',
        technical: technical,
      );
    }

    // Local storage. Matched on the message because drift wraps the underlying
    // sqlite3 exception in types this layer should not depend on.
    final lower = technical.toLowerCase();
    if (lower.contains('sqlite') ||
        lower.contains('database') ||
        lower.contains('disk image')) {
      return UserFacingError(
        title: 'Could not read saved calls',
        message: 'The local call store could not be opened. Nothing has been '
            'sent to the server. Try again, and if it keeps happening use '
            'Database Health in Settings.',
        technical: technical,
      );
    }

    return UserFacingError(
      title: 'Something went wrong',
      message: 'This did not work. Try again in a moment.',
      technical: technical,
    );
  }

  static String _apiTitle(String code) => switch (code) {
        'NETWORK_ERROR' => 'No connection to the server',
        'DEVICE_REVOKED' ||
        'ACCOUNT_INACTIVE' =>
          'This phone is no longer allowed to sync',
        'DEVICE_NOT_REGISTERED' || 'DEVICE_INACTIVE' => 'Device not registered',
        'INVALID_TOKEN' || 'UNAUTHENTICATED' => 'Signed out',
        'RATE_LIMIT_EXCEEDED' => 'Too many requests',
        'SYNC_POLICY_VIOLATION' => 'Call too old to send',
        _ => 'The server could not complete that',
      };

  static String _apiMessage(ApiException error) => switch (error.code) {
        'NETWORK_ERROR' =>
          'Your calls are saved on this phone and will be sent automatically '
              'once the connection is back.',
        'DEVICE_REVOKED' || 'ACCOUNT_INACTIVE' =>
          'An administrator has removed access for this device or account. '
              'Contact them to restore it.',
        'DEVICE_NOT_REGISTERED' || 'DEVICE_INACTIVE' =>
          'This phone needs to be registered again before calls can be sent.',
        'INVALID_TOKEN' || 'UNAUTHENTICATED' =>
          'Your session ended. Register this device again to resume syncing.',
        'RATE_LIMIT_EXCEEDED' =>
          'The server asked the app to slow down. It will retry shortly.',
        'SYNC_POLICY_VIOLATION' =>
          'The server does not accept calls this old. Check that the date and '
              'time on this phone are correct.',
        // Server messages are written for humans and are safe to show; the
        // code is not, and neither is the request id.
        _ => error.message.isNotEmpty
            ? error.message
            : 'Try again in a moment.',
      };

  static bool _apiRetryable(String code) => !const {
        'DEVICE_REVOKED',
        'ACCOUNT_INACTIVE',
        'INVALID_TOKEN',
        'UNAUTHENTICATED',
        'SYNC_POLICY_VIOLATION',
        'VALIDATION_ERROR',
      }.contains(code);

  /// One line for the log, keeping the detail out of the UI.
  void log(String context) =>
      debugPrint('[$context] $title — $technical');
}
