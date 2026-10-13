import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exceptions.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_client_provider.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/call_wire_format.dart';
import '../../../core/storage/database_providers.dart';
import '../../call_tracking/domain/call_entry.dart';

/// Why the CRM's copy of a recording cannot be played, in words for the user.
class ServerRecordingUnavailable implements Exception {
  const ServerRecordingUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Plays a call's recording from the server (Mobile API Guide §7).
///
/// The dialer's own file is the first choice, and the only one this app used
/// to have. Dialers rotate and delete their recordings, so a call reviewed a
/// few weeks later showed "None was found on this phone" even though the CRM
/// had the audio all along.
///
/// Uses a playback token rather than the bearer header: the audio player
/// streams in a platform component that cannot attach our `Authorization`, and
/// the token is scoped to one recording for a few minutes. A fresh one is
/// fetched for every play, as §7 asks.
class ServerRecordingRepository {
  ServerRecordingRepository(this._api);

  final ApiClient _api;

  /// A ready-to-stream URL for the recording on [serverCallId].
  ///
  /// Throws [ServerRecordingUnavailable] when there is nothing to play.
  Future<String> streamUrlFor(String serverCallId) async {
    final String recordingId;
    try {
      final call = await _api.get<Map<String, dynamic>>(
        ApiEndpoints.callById(serverCallId),
      );
      final recording = call.data?['recording'];
      if (recording is! Map || recording['id'] is! String) {
        throw const ServerRecordingUnavailable(
          'Zebu CRM has no recording for this call.',
        );
      }
      if (recording['is_playable'] == false) {
        throw const ServerRecordingUnavailable(
          'Zebu CRM is still processing this recording. Try again shortly.',
        );
      }
      recordingId = recording['id'] as String;

      final token = await _api.post<Map<String, dynamic>>(
        ApiEndpoints.recordingPlaybackToken(recordingId),
      );
      final streamPath = token.data?['stream_url'];
      if (streamPath is! String || streamPath.isEmpty) {
        throw const ServerRecordingUnavailable(
          "Zebu CRM didn't return a way to play this recording.",
        );
      }
      return _absolute(streamPath);
    } on ServerRecordingUnavailable {
      rethrow;
    } on ApiException catch (e) {
      throw ServerRecordingUnavailable(switch (e.code) {
        'RECORDING_FILE_MISSING' =>
          'The recording is listed in Zebu CRM but its audio is missing. '
              'Tell your admin.',
        'RECORDING_NOT_READY' =>
          'Zebu CRM is still processing this recording. Try again shortly.',
        'CALL_NOT_FOUND' || 'RECORDING_NOT_FOUND' =>
          'Zebu CRM has no recording for this call.',
        'NETWORK_ERROR' => 'No connection. Check your network and try again.',
        _ => "Couldn't load the recording from Zebu CRM.",
      });
    } catch (_) {
      throw const ServerRecordingUnavailable(
        "Couldn't load the recording from Zebu CRM.",
      );
    }
  }

  /// `stream_url` is a server path (`/api/v1/...`); joined to the origin of
  /// the configured base URL, never to its path, which already ends in
  /// `/api/v1`.
  static String _absolute(String streamPath) {
    final parsed = Uri.tryParse(streamPath);
    if (parsed != null && parsed.hasScheme) return streamPath;
    return Uri.parse(AppConfig.apiBaseUrl).resolve(streamPath).toString();
  }
}

final serverRecordingRepositoryProvider = Provider<ServerRecordingRepository>(
  (ref) => ServerRecordingRepository(ref.watch(apiClientProvider)),
);

/// The outbox key for [entry]'s call, or null for one that has none.
///
/// Both ingesters derive it from the call-log row itself, so it needs nothing
/// the entry does not already carry.
String? outboxKeyFor(CallEntry entry) {
  final startedAt = entry.row.dateMillis;
  if (startedAt == null || entry.isWhatsApp) return null;
  return CallWireIdentity.key(
    startedAtMillis: startedAt,
    rawNumber: entry.row.number,
  );
}

/// The server's id for the call with this outbox key, or null while it has
/// not been sent.
final serverCallIdProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, key) async {
  final local = await ref.watch(callsDaoProvider).findByIdempotencyKey(key);
  final id = local?.serverCallId;
  return id == null || id.isEmpty ? null : id;
});
