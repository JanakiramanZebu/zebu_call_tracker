import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../call_tracking/data/call_feed.dart';

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

  /// Folds what the worker captured back into the app, then clears it.
  ///
  /// Ordering matters: the batches are only cleared after the feed has been
  /// rebuilt from the device, so a crash in between costs a repeated fold
  /// (harmless — the call log is the source of truth) rather than lost
  /// snapshots.
  Future<IngestSnapshot> drain() async {
    final bridge = ref.read(nativeBridgeProvider);
    final snapshot = await bridge.readIngestBatches();
    if (snapshot.isEmpty) return snapshot;

    await ref.read(callFeedProvider.notifier).refresh();
    await bridge.clearIngestBatches();
    ref.invalidate(backgroundStatusProvider);
    return snapshot;
  }
}

final backgroundControllerProvider =
    AsyncNotifierProvider<BackgroundController, void>(BackgroundController.new);
