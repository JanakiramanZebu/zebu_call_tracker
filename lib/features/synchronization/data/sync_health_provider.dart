import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client_provider.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/platform/native_call_bridge.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../domain/sync_health.dart';
import 'sync_service.dart';

/// Everything the app knows about whether syncing is actually working.
///
/// Deliberately assembled in one provider rather than read piecemeal by each
/// screen. The Sync screen used to derive its own answer from a lifetime
/// counter and reported "Last successful sync: Just now" on a handset that had
/// not reached the server in days — while displaying the correct value, from
/// the native coordinator, a few hundred pixels further down the same page.
/// Two sources, two answers, one of them wrong.
final syncAlertsProvider = Provider<List<SyncAlert>>((ref) {
  final native = ref.watch(nativeSyncStatusProvider).value;
  final counters = ref.watch(syncCountersProvider).value;
  final perms = ref.watch(permissionStatusProvider).value;
  final background = ref.watch(backgroundStatusProvider).value;
  final revoked = ref.watch(sessionRevocationProvider);
  final skew = ref.watch(clockSkewProvider);
  final isOnline = ref.watch(connectivityProvider).value ?? true;

  return resolveSyncAlerts(
    SyncHealthInputs(
      configProblemMessage: AppConfig.problemMessage,
      sessionRevoked: revoked != null,
      nativeStatus: native?.status,
      clockSkewMinutes: skew,
      // Absent while the first read is in flight. Assuming "granted" avoids a
      // critical alert flashing on every cold start.
      canTrackCalls: perms?.canTrack ?? true,
      isOnline: isOnline,
      waitingCount: counters?['waiting'] ?? 0,
      failedCount: counters?['failed'] ?? 0,
      lastErrorDetail: native?.error,
      // Same reasoning: unknown is not the same as "restricted".
      ignoringBatteryOptimizations:
          background?.ignoringBatteryOptimizations ?? true,
    ),
  );
});

/// The single worst thing currently true, for a compact one-line summary.
final topSyncAlertProvider = Provider<SyncAlert?>((ref) {
  final alerts = ref.watch(syncAlertsProvider);
  return alerts.isEmpty ? null : alerts.first;
});


/// Whether the user has allowed recordings to go out over mobile data.
///
/// Default false, deliberately. Mobile API Guide 6.5: audio uploads belong on
/// an unmetered network unless the user opted in. A recording is orders of
/// magnitude larger than the metadata beside it, and the app previously sent
/// every one of them over whatever connection happened to be up, without
/// asking and without a way to say no.
///
/// Stored natively, because the coordinator that enforces it runs with no
/// Flutter engine attached.
final recordingsOnMeteredProvider =
    AsyncNotifierProvider<RecordingsOnMeteredController, bool>(
  RecordingsOnMeteredController.new,
);

class RecordingsOnMeteredController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    try {
      return await MethodChannelNativeCallBridge()
          .getRecordingsOnMeteredNetworks();
    } catch (_) {
      return false;
    }
  }

  Future<void> set(bool allowed) async {
    state = AsyncData(allowed);
    try {
      await MethodChannelNativeCallBridge()
          .setRecordingsOnMeteredNetworks(allowed);
    } catch (_) {
      // Put the switch back where it was rather than showing a setting that
      // did not take.
      state = AsyncData(!allowed);
    }
  }
}
