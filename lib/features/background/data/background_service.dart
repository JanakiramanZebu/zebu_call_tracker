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

/// Arms and disarms the background ingest pipeline.
///
/// The native worker captures calls and their recordings straight into the
/// shared SQLite table while the app is closed, so there is nothing to fold
/// back in here; the app only re-reads that table.
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

  /// Opens the Doze exemption prompt. Returns false when no screen resolved,
  /// so the caller can fall back to App info instead of silently doing
  /// nothing.
  Future<bool> requestBatteryExemption() async {
    final opened = await ref
        .read(nativeBridgeProvider)
        .requestBatteryExemption();
    // The result lands when the user comes back, not now; the permission screen
    // re-reads on resume.
    return opened;
  }
}

final backgroundControllerProvider =
    AsyncNotifierProvider<BackgroundController, void>(BackgroundController.new);
