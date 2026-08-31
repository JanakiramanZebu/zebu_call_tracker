import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../../core/storage/database_providers.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../synchronization/data/sync_service.dart';


/// Whether background ingest can run, and what it last did.
///
/// Read on demand rather than watched. There is no change notification for
/// battery-optimisation state or for a WorkManager run completing, so this is
/// invalidated at the moments it can plausibly have changed: app resume, after
/// the exemption prompt, and after a manual sweep.
final backgroundStatusProvider = FutureProvider.autoDispose<BackgroundStatus>(
  (ref) => ref.watch(nativeBridgeProvider).getBackgroundStatus(),
);

/// Arms, disarms and drains the background ingest pipeline.
///
/// The worker captures call rows and — the part that actually needs to happen
/// while the app is closed — the recording listing as it stood at the time of
/// the call. This controller folds those snapshots back into the app the next
/// time it runs.
class BackgroundController extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  /// Idempotent: keeps any existing periodic schedule and runs one sweep now.
  ///
  /// Called once the user is signed in and past the permission walkthrough —
  /// not at launch, because capturing calls for a handset nobody has claimed
  /// would attribute them to no employee record.
  Future<void> start({String reason = 'app-start'}) async {
    await ref.read(nativeBridgeProvider).startBackgroundTracking(reason: reason);
    ref.invalidate(backgroundStatusProvider);
  }


  Future<void> stop() async {
    await ref.read(nativeBridgeProvider).stopBackgroundTracking();
    ref.invalidate(backgroundStatusProvider);
  }

  /// Opens the Doze exemption prompt. Returns false when no screen resolved,
  /// so the caller can offer the OEM route instead of silently doing nothing.
  Future<bool> requestBatteryExemption() async {
    final opened = await ref
        .read(nativeBridgeProvider)
        .requestBatteryExemption();
    // The result lands when the user comes back, not now; the permission screen
    // re-reads on resume.
    return opened;
  }

  Future<bool> openVendorSettings() =>
      ref.read(nativeBridgeProvider).openVendorBackgroundSettings();

  /// Folds what the worker captured back into the app, reconciles SQLite states, then clears native batches.
  Future<IngestSnapshot> drain() async {
    final bridge = ref.read(nativeBridgeProvider);
    final snapshot = await bridge.readIngestBatches();
    if (snapshot.isEmpty) return snapshot;

    final dao = ref.read(callsDaoProvider);

    // 1. Reconcile any calls synced natively while the app was closed
    for (final s in snapshot.syncedCalls) {
      if (s.idempotencyKey.isNotEmpty) {
        await dao.markSynced(
          idempotencyKey: s.idempotencyKey,
          serverCallId: s.serverCallId,
          revision: 1,
        );
      }
    }

    // 2. Ingest native call logs into SQLite so newly captured calls land in DB
    await ref.read(syncServiceProvider.notifier).ingestNativeCallLogs();

    // 3. Refresh feeds and clear drained native batches
    await ref.read(callFeedProvider.notifier).refresh();
    await bridge.clearIngestBatches();
    ref.invalidate(backgroundStatusProvider);
    ref.invalidate(syncCountersProvider);
    return snapshot;
  }
}

final backgroundControllerProvider =
    AsyncNotifierProvider<BackgroundController, void>(BackgroundController.new);
