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
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(permissionStatusProvider);
    final background = ref.watch(backgroundStatusProvider).value;

    return Scaffold(
      backgroundColor: AppTokens.bgPrimary,
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
                      const SizedBox(height: 16),
                      const Text(
                        'Each permission is requested only when it is needed. You can decline optional permissions — tracking works with essential call logs.',
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
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ZebuAppMark(size: 48),
            SizedBox(height: 16),
            Text(
              'Set up call tracking',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 24,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'Zebu Call Tracker requires system permissions to log calls and match recordings automatically.',
              style: TextStyle(
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
        decoration: const BoxDecoration(
          color: AppTokens.surface1,
          border: Border(top: BorderSide(color: AppTokens.borderDefault)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!essentialGranted)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: AppTokens.warning,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Phone & call log permission is required to proceed.',
                        style: TextStyle(
                          color: AppTokens.warning,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
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
