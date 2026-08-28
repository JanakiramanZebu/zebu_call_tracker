import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/brand.dart';
import '../../../shared/widgets/loaders.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../domain/permission_ask.dart';
import 'ask_card.dart';
import 'permission_flow.dart';

/// First-run walkthrough, shown once between sign-in and the app itself.
///
/// It does not gate on *every* permission — only the call log, without which
/// there is nothing to track. The optional three can be granted here or later
/// from Settings, and saying no to them still lands the user in a working app.
class PermissionOnboardingScreen extends ConsumerStatefulWidget {
  const PermissionOnboardingScreen({super.key});

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
    // No pop: the root gate watches onboardingProvider and swaps the screen.
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(permissionStatusProvider);
    // Background state loads independently: a slow PowerManager read
    // must not hold up the permission cards.
    final background = ref.watch(backgroundStatusProvider).value;

    return Scaffold(
      body: SafeArea(
        child: snapshot.when(
          loading: () => const Column(
            children: [
              _Header(),
              Expanded(child: AskSkeletonList()),
            ],
          ),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not read permissions',
            message: '$e',
            actionLabel: 'Try again',
            onAction: refreshPermissions,
          ),
          data: (perms) {
            final asks = permissionAsks(perms, background: background);
            final essentialGranted = asks
                .where((a) => a.essential)
                .every((a) => a.granted);
            final grantedCount = asks.where((a) => a.granted).length;
            final allGranted = grantedCount == asks.length;

            return Column(
              children: [
                const _Header(),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    children: [
                      AskProgress(granted: grantedCount, total: asks.length),
                      const SizedBox(height: 18),
                      Text(
                        'Each one is requested only when it is needed, and only '
                        'with the reason shown. You can decline the optional '
                        'ones — the app keeps working with less detail.',
                        style: context.text.bodyMedium?.copyWith(
                          color: context.palette.muted,
                          height: 1.55,
                        ),
                      ),
                      const SizedBox(height: 18),
                      for (final ask in asks) ...[
                        AskCard(
                          ask: ask,
                          blocked: isBlocked(ask),
                          busy: isBusy(ask),
                          onRequest: () => request(ask),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
                _Footer(
                  essentialGranted: essentialGranted,
                  allGranted: allGranted,
                  finishing: _finishing,
                  onContinue: _finish,
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
  const _Header();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ZebuAppMark(size: 52),
        const SizedBox(height: 18),
        Text(
          'Set up tracking',
          style: context.text.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Zebu Call Tracker needs a few permissions before it can record '
          'calls against your employee account.',
          style: context.text.bodyMedium?.copyWith(
            color: context.palette.muted,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

/// Sticky action bar. The primary button stays visible while the list scrolls,
/// so the way forward is never something the user has to hunt for.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.essentialGranted,
    required this.allGranted,
    required this.finishing,
    required this.onContinue,
  });

  final bool essentialGranted;
  final bool allGranted;
  final bool finishing;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
    decoration: BoxDecoration(
      color: context.colors.surface,
      border: Border(top: BorderSide(color: context.colors.outlineVariant)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!essentialGranted)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: context.palette.waiting,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Phone & call log access is required to continue.',
                    style: context.text.bodySmall?.copyWith(
                      color: context.palette.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        LoadingFilledButton(
          label: allGranted ? 'Start tracking' : 'Continue',
          loading: finishing,
          onPressed: essentialGranted ? onContinue : null,
        ),
      ],
    ),
  );
}
