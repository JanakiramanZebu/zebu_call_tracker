import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/brand.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../domain/permission_ask.dart';
import 'ask_card.dart';
import 'permission_flow.dart';

class PermissionOnboardingScreen extends ConsumerStatefulWidget {
  const PermissionOnboardingScreen({super.key, this.recovery = false});

  /// True when the walkthrough is being shown again because an essential
  /// permission was revoked after setup, rather than for first-run setup.
  ///
  /// Only the wording changes. Telling a user who has been using the app for
  /// weeks to "set up call tracking" reads as though their data is gone, and
  /// gives no hint that they are here because something was switched off.
  final bool recovery;

  @override
  ConsumerState<PermissionOnboardingScreen> createState() =>
      _PermissionOnboardingScreenState();
}

class _PermissionOnboardingScreenState
    extends ConsumerState<PermissionOnboardingScreen>
    with WidgetsBindingObserver, PermissionFlowMixin {
  bool _finishing = false;

  Future<void> _finish() async {
    setState(() => _finishing = true);
    await ref.read(onboardingProvider.notifier).complete();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(permissionStatusProvider);
    final background = ref.watch(backgroundStatusProvider).value;

    return Scaffold(
      backgroundColor: AppTokens.bgPrimary,
      body: SafeArea(
        child: snapshot.when(
          loading: () => Column(
            children: [
              _Header(recovery: widget.recovery),
              Expanded(child: AskSkeletonList()),
            ],
          ),
          error: (e, _) => ErrorStateView(
            error: e,
            logContext: 'ONBOARDING',
            fallbackTitle: 'Could not read permissions',
            icon: Icons.lock_outline_rounded,
            onRetry: refreshPermissions,
          ),
          data: (perms) {
            final asks = permissionAsks(perms, background: background);

            return Column(
              children: [
                _Header(recovery: widget.recovery),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    children: [
                      AskProgress(
                        granted: asks.grantedCount,
                        total: asks.length,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Phone and call log access is required to track calls at '
                        'all. The rest are optional — each one adds detail, and '
                        'you can grant them later from Settings.',
                        style: TextStyle(
                          color: AppTokens.textSecondary,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 16),
                      for (final ask in asks) ...[
                        AskCard(
                          ask: ask,
                          blocked: isBlocked(ask),
                          busy: isBusy(ask),
                          onRequest: () => request(ask),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
                ),
                _Footer(
                  asks: asks,
                  finishing: _finishing,
                  recovery: widget.recovery,
                  onContinue: _finish,
                  onSkip: widget.recovery
                      ? () => ref
                          .read(permissionRecoveryDismissedProvider.notifier)
                          .dismiss()
                      : null,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({this.recovery = false});

  final bool recovery;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ZebuAppMark(size: 48),
            const SizedBox(height: 16),
            Text(
              recovery ? 'Call tracking has stopped' : 'Set up call tracking',
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 24,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              recovery
                  // Says what is true and what is not: capture has stopped, but
                  // nothing already saved has been lost. A user who thinks
                  // their history is gone reacts very differently.
                  ? 'Permission to read the call log was turned off, so no new '
                      'calls are being recorded. Calls already saved on this '
                      'phone are safe and will still be sent.'
                  : 'Zebu Call Tracker requires system permissions to log '
                      'calls, upload recordings, and sync data in the '
                      'background.',
              style: const TextStyle(
                color: AppTokens.textMuted,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ],
        ),
      );
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.asks,
    required this.finishing,
    required this.onContinue,
    this.recovery = false,
    this.onSkip,
  });

  final List<PermissionAsk> asks;
  final bool finishing;
  final VoidCallback onContinue;
  final bool recovery;

  /// Recovery only: lets the user into the app without the permission. Null
  /// during first-run setup, where there is nothing to go back to.
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        decoration: const BoxDecoration(
          color: AppTokens.surface1,
          border: Border(top: BorderSide(color: AppTokens.borderDefault)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!asks.canProceed)
              _FooterNote(
                icon: Icons.lock_outline_rounded,
                color: AppTokens.danger,
                message:
                    'Grant ${_join(asks.missingEssential.map((a) => a.title))} '
                    'to start tracking calls.',
              )
            else if (asks.missingOptional.isNotEmpty)
              _FooterNote(
                icon: Icons.info_outline_rounded,
                color: AppTokens.warning,
                message:
                    '${asks.missingOptional.length} optional '
                    '${asks.missingOptional.length == 1 ? "permission is" : "permissions are"} '
                    'not granted. You can add them any time from Settings.',
              ),
            LoadingFilledButton(
              label: recovery
                  ? 'Resume call tracking'
                  : (asks.allGranted ? 'Start tracking' : 'Continue'),
              loading: finishing,
              onPressed: asks.canProceed ? onContinue : null,
            ),
            if (onSkip != null && !asks.canProceed)
              TextButton(
                onPressed: onSkip,
                child: const Text(
                  'Continue without call tracking',
                  style: TextStyle(
                    color: AppTokens.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      );
}

/// Joins titles into readable prose: "A", "A and B", "A, B and C".
String _join(Iterable<String> parts) {
  final list = parts.toList();
  if (list.isEmpty) return '';
  if (list.length == 1) return list.single;
  return '${list.take(list.length - 1).join(', ')} and ${list.last}';
}

class _FooterNote extends StatelessWidget {
  const _FooterNote({
    required this.icon,
    required this.color,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      );
}
