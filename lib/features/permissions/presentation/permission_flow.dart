import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../domain/permission_ask.dart';

/// Shared request behaviour for every screen that asks for permissions.
///
/// Three things are easy to get wrong and are therefore solved once, here:
///
///  * **Permanently denied.** Android drops the dialog silently after the
///    second refusal, so a naive "request again" button appears to do nothing.
///    The outcome is remembered and the card switches to *Open settings*.
///  * **Coming back from Settings.** There is no permission-changed broadcast,
///    so the only reliable moment to re-read is when the app resumes. Screens
///    that mix this in refresh themselves on resume rather than leaving a
///    granted permission showing as denied. Background activity is read the
///    same way — it can only be changed from a settings screen.
///  * **Non-runtime asks.** Battery exemption has no `request()`; it opens a
///    system prompt and answers later. It goes through the same entry point so
///    the cards stay uniform.
mixin PermissionFlowMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T>, WidgetsBindingObserver {
  final _blocked = <String>{};
  String? _inFlight;

  bool isBlocked(PermissionAsk ask) => _blocked.contains(ask.id);
  bool isBusy(PermissionAsk ask) => _inFlight == ask.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) refreshPermissions();
  }

  void refreshPermissions() {
    if (!mounted) return;
    ref
      ..invalidate(permissionStatusProvider)
      ..invalidate(backgroundStatusProvider);
  }

  /// Grants [ask], by whichever route it actually has.
  Future<void> request(PermissionAsk ask) async {
    if (_inFlight != null) return;

    setState(() => _inFlight = ask.id);
    try {
      switch (ask.kind) {
        case AskKind.backgroundActivity:
          await _requestBackground();
        case AskKind.runtime:
          await _requestRuntime(ask);
      }
    } finally {
      if (mounted) setState(() => _inFlight = null);
    }
  }

  Future<void> _requestBackground() async {
    final controller = ref.read(backgroundControllerProvider.notifier);
    final opened = await controller.requestBatteryExemption();
    // Some OEM builds and MDM policies suppress the standard prompt entirely.
    // Falling through to the vendor screen is better than a button that
    // appears to do nothing at all.
    if (!opened) await controller.openVendorSettings();
    // The answer arrives when the user returns; the resume observer re-reads.
  }

  Future<void> _requestRuntime(PermissionAsk ask) async {
    if (_blocked.contains(ask.id)) {
      await openAppSettings();
      // Status is re-read on resume by the observer above.
      return;
    }

    final outcome = await requestAsk(ask);
    if (!mounted) return;

    setState(() {
      if (outcome == AskOutcome.permanentlyDenied) {
        _blocked.add(ask.id);
      } else if (outcome == AskOutcome.granted) {
        _blocked.remove(ask.id);
      }
    });

    refreshPermissions();
    if (outcome == AskOutcome.granted) {
      // A newly granted permission changes what the feed can see, so it is
      // rebuilt rather than left showing the blocked state.
      await ref.read(callFeedProvider.notifier).refresh();
    }
  }
}
