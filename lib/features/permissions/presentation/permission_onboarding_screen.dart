import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/brand.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
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

    return Scaffold(
      backgroundColor: context.z.canvas,
      // Top edge only. The pinned footer pads itself clear of the system
      // navigation bar (BottomSafe).
      body: SafeArea(
        bottom: false,
        child: snapshot.when(
          loading: () => ListView(
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _Header(recovery: widget.recovery),
              const AskSkeletonList(),
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
            final asks = watchAsks(perms);

            return Column(
              children: [
                Expanded(
                  child: ListView(
                    // The pinned footer sits between this list and the
                    // navigation bar, so no system inset is added here. The
                    // ask list runs edge to edge; the header indents itself.
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      _Header(recovery: widget.recovery),
                      AskList(
                        asks: asks,
                        isBlocked: isBlocked,
                        isBusy: isBusy,
                        onRequest: request,
                      ),
                    ],
                  ),
                ),
                _Footer(
                  canProceed: asks.canProceed,
                  allGranted: asks.allGranted,
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

/// Mark, title and one short line.
class _Header extends StatelessWidget {
  const _Header({this.recovery = false});

  final bool recovery;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.gutter,
        32,
        AppTokens.gutter,
        24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              const ZebuAppMark(size: 48),
              // Recovery: a danger badge on the tile says "something
              // stopped" before a word is read.
              if (recovery)
                Positioned(
                  right: -5,
                  bottom: -5,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: z.danger,
                      shape: BoxShape.circle,
                      border: Border.all(color: z.canvas, width: 3),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.priority_high_rounded,
                      size: 12,
                      color: z.canvas,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Semantics(
            header: true,
            child: Text(
              recovery ? 'Call tracking has stopped' : 'Allow access',
              style: AppType.title,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            recovery
                // Says what is true and what is not: capture has stopped, but
                // nothing already saved has been lost. A user who thinks their
                // history is gone reacts very differently.
                ? 'Phone or call log access was turned off. Calls already '
                      'saved are safe.'
                : 'So your work calls are logged automatically.',
            style: AppType.body.copyWith(color: z.ink2),
          ),
        ],
      ),
    );
  }
}

/// Bottom-pinned action bar. Pads itself up from the system navigation bar
/// so the primary button never sits under the nav buttons.
///
/// Just the button: it stays disabled until the required access is allowed,
/// and the list already marks that row "Required".
class _Footer extends StatelessWidget {
  const _Footer({
    required this.canProceed,
    required this.allGranted,
    required this.finishing,
    required this.onContinue,
    this.recovery = false,
    this.onSkip,
  });

  final bool canProceed;
  final bool allGranted;
  final bool finishing;
  final VoidCallback onContinue;
  final bool recovery;

  /// Recovery only: lets the user into the app without the permission. Null
  /// during first-run setup, where there is nothing to go back to.
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: z.canvas,
        border: Border(top: BorderSide(color: z.line)),
      ),
      child: BottomSafe(
        minimum: 14,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.gutter,
            14,
            AppTokens.gutter,
            0,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ZButton(
                label: recovery
                    ? 'Resume call tracking'
                    : (allGranted ? 'Start tracking' : 'Continue'),
                size: ZButtonSize.large,
                loading: finishing,
                onPressed: canProceed ? onContinue : null,
              ),
              if (onSkip != null && !canProceed) ...[
                const SizedBox(height: 4),
                ZButton(
                  label: 'Continue without call tracking',
                  variant: ZButtonVariant.text,
                  size: ZButtonSize.regular,
                  onPressed: onSkip,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
