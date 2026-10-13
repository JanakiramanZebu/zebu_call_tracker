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
///    [requestAsk] checks for that first and opens app settings in the same
///    tap; a refusal made in this session also turns the card to *Open
///    settings*, so the user can see why the next tap goes there.
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

  /// The ask list as this screen shows it, with the inputs that live outside
  /// [PermissionSnapshot] read in one place.
  List<PermissionAsk> watchAsks(
    PermissionSnapshot perms, {
    bool includeNotifications = true,
  }) => permissionAsks(
    perms,
    background: ref.watch(backgroundStatusProvider).value,
    includeNotifications: includeNotifications,
  );

  /// Grants [ask], by whichever route it actually has.
  Future<void> request(PermissionAsk ask) async {
    if (_inFlight != null) return;

    setState(() => _inFlight = ask.id);
    try {
      switch (ask.kind) {
        case AskKind.backgroundActivity:
          await _requestBackground();
        case AskKind.overlayWindow:
          await _requestOverlay();
        case AskKind.notificationListener:
          // Settings screen; the lifecycle observer re-reads on return.
          await ref.read(nativeBridgeProvider).requestNotificationListenerAccess();
        case AskKind.autostart:
          // Recorded as done natively once the screen opens; the observer
          // re-reads the background status on return.
          await ref.read(nativeBridgeProvider).openAutostartSettings();
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
    // App info, where battery usage can still be set to Unrestricted, when
    // Android's own prompt cannot open.
    if (!opened) await openAppSettings();
  }

  Future<void> _requestOverlay() async {
    final bridge = ref.read(nativeBridgeProvider);
    await bridge.requestOverlayPermission();
    // The user returns from Settings and the lifecycle observer re-reads.
  }

  Future<void> _requestRuntime(PermissionAsk ask) async {
    final permission = ask.permission;
    if (permission == null) return;

    // Opens app settings itself when Android will not show the dialog; the
    // status is then re-read on resume by the observer above.
    final outcome = await requestAsk(permission);
    if (!mounted) return;

    setState(() {
      switch (outcome) {
        case AskOutcome.permanentlyDenied:
        case AskOutcome.openedSettings:
          _blocked.add(ask.id);
        case AskOutcome.granted:
          _blocked.remove(ask.id);
        case AskOutcome.denied:
          break;
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
