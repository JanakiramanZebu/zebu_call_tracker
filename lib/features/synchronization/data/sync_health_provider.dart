import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client_provider.dart';
import '../../../core/network/connectivity_service.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../domain/sync_health.dart';
import 'server_snapshot.dart';
import 'sync_service.dart';

/// Everything the app knows about whether syncing is actually working.
///
/// Deliberately assembled in one provider rather than read piecemeal by each
/// screen. The Sync screen used to derive its own answer from a lifetime
/// counter and reported "Last successful sync: Just now" on a handset that had
/// not reached the server in days — while displaying the correct value, from
/// the native coordinator, a few hundred pixels further down the same page.
/// Two sources, two answers, one of them wrong.
final syncAlertsProvider =
    NotifierProvider<SyncAlertsNotifier, List<SyncAlert>>(
  SyncAlertsNotifier.new,
);

/// A notifier only so [updateShouldNotify] can compare by content.
///
/// Every input is narrowed with `select` to the one field the rules read, and
/// an unchanged list does not notify: the banner sits on three screens and
/// used to rebuild on every counters tick, whether or not anything it says
/// had changed.
/// How long background capture may go without a run before the app says so.
///
/// It runs at least hourly while Android lets it, so this is many missed runs,
/// not a delayed one. Doze can stretch an idle night to several hours; twelve
/// clears that without leaving a killed app unreported for days.
const _captureStaleAfter = Duration(hours: 12);

class SyncAlertsNotifier extends Notifier<List<SyncAlert>> {
  @override
  List<SyncAlert> build() {
    final native = ref.watch(nativeSyncStatusProvider
        .select((s) => (status: s.value?.status, error: s.value?.error)));
    final waiting =
        ref.watch(syncCountersProvider.select((c) => c.value?['waiting'] ?? 0));
    final failed =
        ref.watch(syncCountersProvider.select((c) => c.value?['failed'] ?? 0));
    // Absent while the first read is in flight. Assuming "granted" avoids a
    // critical alert flashing on every cold start.
    final canTrack = ref.watch(
        permissionStatusProvider.select((p) => p.value?.canTrack ?? true));
    final notificationsAllowed = ref.watch(permissionStatusProvider
        .select((p) => p.value?.notifications ?? true));
    final canReadRecordings = ref.watch(
        permissionStatusProvider.select((p) => p.value?.readRecordings ?? true));
    // Same reasoning: unknown is not the same as "restricted".
    final ignoringBattery = ref.watch(backgroundStatusProvider
        .select((b) => b.value?.ignoringBatteryOptimizations ?? true));
    final lastCaptureAt =
        ref.watch(backgroundStatusProvider.select((b) => b.value?.lastRunAtUtc));
    final forceStoppedAt = ref.watch(
        backgroundStatusProvider.select((b) => b.value?.forceStoppedAt));
    final serverDeviceStatus = ref.watch(
        serverSnapshotProvider.select((s) => s.value?.deviceStatus));
    final persistedSkew = ref.watch(
        serverSnapshotProvider.select((s) => s.value?.clockSkewMinutes));
    final revoked = ref.watch(sessionRevocationProvider);
    // The live value once this session has checked; until then, what the last
    // check found — a wrong clock does not fix itself between launches.
    final skew = ref.watch(clockSkewProvider) ?? persistedSkew;
    final isOnline =
        ref.watch(connectivityProvider.select((c) => c.value ?? true));

    return resolveSyncAlerts(
      SyncHealthInputs(
        configProblemMessage: AppConfig.problemMessage,
        sessionRevoked: revoked != null,
        nativeStatus: native.status,
        clockSkewMinutes: skew,
        canTrackCalls: canTrack,
        isOnline: isOnline,
        waitingCount: waiting,
        failedCount: failed,
        lastErrorDetail: native.error,
        ignoringBatteryOptimizations: ignoringBattery,
        notificationsAllowed: notificationsAllowed,
        serverDeviceStatus: serverDeviceStatus,
        canReadRecordings: canReadRecordings,
        captureStaleSince: lastCaptureAt != null &&
                DateTime.now().toUtc().difference(lastCaptureAt) >
                    _captureStaleAfter
            ? lastCaptureAt
            : null,
        forceStoppedAt: forceStoppedAt,
      ),
    );
  }

  @override
  bool updateShouldNotify(List<SyncAlert> previous, List<SyncAlert> next) =>
      !listEquals(previous, next);
}
