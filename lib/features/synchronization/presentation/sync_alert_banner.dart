import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/theme/design_tokens.dart';
import '../../background/data/background_service.dart';
import '../../permissions/presentation/permission_screen.dart';
import '../data/sync_health_provider.dart';
import '../data/sync_service.dart';
import '../domain/sync_health.dart';

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
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              '$hidden more ${hidden == 1 ? 'item needs' : 'items need'} '
              'attention — see Settings.',
              style: const TextStyle(
                color: AppTokens.textMuted,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}

class _AlertCard extends ConsumerWidget {
  const _AlertCard({required this.alert});

  final SyncAlert alert;

  Color get _accent => switch (alert.severity) {
        SyncAlertSeverity.critical => AppTokens.danger,
        SyncAlertSeverity.warning => AppTokens.warning,
        SyncAlertSeverity.info => AppTokens.brandElectric,
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
        if (!opened) await controller.openVendorSettings();
      case SyncAlertAction.openDateSettings:
        // No Flutter API opens the date screen directly; app settings is the
        // closest reliable landing point, and the message says what to change.
        await openAppSettings();
      case SyncAlertAction.retrySync:
        await ref.read(syncServiceProvider.notifier).triggerSync();
      case SyncAlertAction.signIn:
      // Handled by the app shell: clearing the session routes to sign-in on
      // its own, so there is nothing useful to do from here.
      case SyncAlertAction.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasAction = alert.action != SyncAlertAction.none &&
        alert.actionLabel != null &&
        alert.action != SyncAlertAction.signIn;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTokens.r12),
        border: Border.all(color: _accent.withValues(alpha: 0.40)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_icon, size: 20, color: _accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert.title,
                  style: TextStyle(
                    color: _accent,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  alert.message,
                  style: const TextStyle(
                    color: AppTokens.textSecondary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
                if (hasAction) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 32,
                    child: OutlinedButton(
                      onPressed: () => _act(context, ref),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _accent,
                        side: BorderSide(color: _accent.withValues(alpha: 0.6)),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppTokens.r12),
                        ),
                      ),
                      child: Text(
                        alert.actionLabel!,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
