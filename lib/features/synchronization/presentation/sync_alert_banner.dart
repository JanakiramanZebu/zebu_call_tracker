import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../permissions/domain/permission_ask.dart';
import '../../permissions/presentation/permission_screen.dart';
import '../data/sync_health_provider.dart';
import '../data/sync_service.dart';
import '../domain/sync_health.dart';
import 'outbox_queue_screen.dart';

/// Shows what is stopping — or about to stop — synchronisation.
///
/// The rule this exists to enforce: a failure the app knows about is a failure
/// the user is told about. Before this, the app detected a revoked device, a
/// clock skew that made the server discard calls permanently, and a call-log
/// permission that had been switched off after setup — and displayed none of
/// them. The only symptom was that calls stopped arriving, days later, on
/// somebody else's dashboard.
class SyncAlertBanner extends ConsumerWidget {
  const SyncAlertBanner({super.key, this.maxAlerts = 2});

  /// Everything worth saying at once, but not a wall of them. Alerts are
  /// ordered worst-first, so a cap drops the least important.
  final int maxAlerts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(syncAlertsProvider);
    if (alerts.isEmpty) return const SizedBox.shrink();

    final shown = alerts.take(maxAlerts).toList();
    final hidden = alerts.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final alert in shown) ...[
          _AlertCard(alert: alert),
          const SizedBox(height: 8),
        ],
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '$hidden more ${hidden == 1 ? 'item needs' : 'items need'} '
              'attention — see Settings.',
              style: AppType.caption.copyWith(color: context.z.ink3),
            ),
          ),
      ],
    );
  }
}

/// One alert, drawn as the shared [InfoBanner] so sync problems look like
/// every other inline message in the app: a tinted block, the title, the
/// explanation and — when there is something the user can do — a text
/// action.
class _AlertCard extends ConsumerWidget {
  const _AlertCard({required this.alert});

  final SyncAlert alert;

  BannerTone get _tone => switch (alert.severity) {
    SyncAlertSeverity.critical => BannerTone.danger,
    SyncAlertSeverity.warning => BannerTone.warning,
    SyncAlertSeverity.info => BannerTone.info,
  };

  IconData get _icon => switch (alert.severity) {
    SyncAlertSeverity.critical => Icons.error_outline_rounded,
    SyncAlertSeverity.warning => Icons.warning_amber_rounded,
    SyncAlertSeverity.info => Icons.info_outline_rounded,
  };

  Future<void> _act(BuildContext context, WidgetRef ref) async {
    switch (alert.action) {
      case SyncAlertAction.openPermissions:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const PermissionScreen()),
        );
      case SyncAlertAction.openBatterySettings:
        final controller = ref.read(backgroundControllerProvider.notifier);
        final opened = await controller.requestBatteryExemption();
        if (!opened) await openAppSettings();
      case SyncAlertAction.openBackgroundSettings:
        // Already exempt from Doze yet still stopped: App info is where the
        // remaining battery and background switches live.
        await openAppSettings();
      case SyncAlertAction.openDateSettings:
        // The server re-judges the clock on the way back, so the alert clears
        // as soon as the clock is right instead of half an hour later.
        ref.read(syncServiceProvider.notifier).requestServerCheck();
        final opened =
            await ref.read(nativeBridgeProvider).openDateSettings().catchError((_) => false);
        if (!opened) await openAppSettings();
      case SyncAlertAction.openOutbox:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const OutboxQueueScreen()),
        );
        ref.invalidate(nativeSyncStatusProvider);
      case SyncAlertAction.retrySync:
        // reviveFailed: a deliberate retry also gives calls that failed for
        // good another chance. Without it this button left the count as it
        // was, since FAILED rows are not touched by an ordinary sync.
        await ref
            .read(syncServiceProvider.notifier)
            .triggerSync(reviveFailed: true);
        ref.invalidate(nativeSyncStatusProvider);
      case SyncAlertAction.enableNotifications:
        // Same path as the Permissions card, including the jump to app
        // settings when Android will no longer show the dialog.
        await requestAsk(Permission.notification);
        ref.invalidate(permissionStatusProvider);
      case SyncAlertAction.signIn:
        await _signInAgain(ref);
      case SyncAlertAction.acknowledgeForceStop:
        await ref.read(nativeBridgeProvider).acknowledgeForceStop();
        ref.invalidate(backgroundStatusProvider);
      case SyncAlertAction.none:
        break;
    }
  }

  /// The native uploader has no usable session, though this side may.
  ///
  /// When native still holds tokens the status is only stale — left by a run
  /// from before this sign-in — so a sync is all it takes to replace it.
  /// Otherwise the session is gone for good: clearing it routes to pairing,
  /// and the calls stay queued on the phone for the new session to send.
  Future<void> _signInAgain(WidgetRef ref) async {
    final native = await ref.read(nativeBridgeProvider).getAuthSession();
    if (native != null && native.hasTokens) {
      await ref.read(syncServiceProvider.notifier).triggerSync(afterSignIn: true);
      ref.invalidate(nativeSyncStatusProvider);
      return;
    }
    await ref.read(authControllerProvider.notifier).resetDeadSession();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasAction =
        alert.action != SyncAlertAction.none && alert.actionLabel != null;

    return InfoBanner(
      tone: _tone,
      icon: _icon,
      title: alert.title,
      message: alert.message,
      action: hasAction
          ? ZButton(
              label: alert.actionLabel!,
              variant: ZButtonVariant.text,
              size: ZButtonSize.compact,
              expand: false,
              onPressed: () => _act(context, ref),
            )
          : null,
    );
  }
}
