import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../call_tracking/data/call_feed.dart';
import '../domain/permission_ask.dart';
import 'ask_card.dart';
import 'permission_flow.dart';

class PermissionScreen extends ConsumerStatefulWidget {
  const PermissionScreen({super.key});

  @override
  ConsumerState<PermissionScreen> createState() => _PermissionScreenState();
}

class _PermissionScreenState extends ConsumerState<PermissionScreen>
    with WidgetsBindingObserver, PermissionFlowMixin {
  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final snapshot = ref.watch(permissionStatusProvider);

    return Scaffold(
      backgroundColor: z.canvas,
      appBar: AppBar(
        title: const Text('Permissions'),
        actions: [
          TapIcon(
            onTap: openAppSettings,
            icon: Icons.open_in_new_rounded,
            size: 20,
            color: z.ink2,
            tooltip: 'Open Android settings',
          ),
          const SizedBox(width: 8),
        ],
      ),
      // No SafeArea: the list scrolls behind the navigation bar and pads its
      // end clear of it (scrollPadding); the loading and error states do the
      // same for themselves. Rows run edge to edge, so the horizontal padding
      // is zero and each block indents itself by the gutter.
      body: snapshot.when(
        loading: () => ListView(
          padding: context.scrollPadding(top: 8, horizontal: 0),
          physics: const NeverScrollableScrollPhysics(),
          children: const [SizedBox(height: 52), AskSkeletonList(rows: 7)],
        ),
        error: (e, _) => ErrorStateView(
          error: e,
          logContext: 'PERMISSIONS',
          fallbackTitle: 'Could not read permissions',
          icon: Icons.lock_outline_rounded,
          onRetry: refreshPermissions,
        ),
        data: (perms) {
          final asks = watchAsks(perms);
          final grantedCount = asks.grantedCount;
          final allGranted = asks.allGranted;
          final tone = allGranted ? z.ok : z.warn;

          return ListView(
            padding: context.scrollPadding(top: 8, bottom: 32, horizontal: 0),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.gutter,
                  4,
                  AppTokens.gutter,
                  16,
                ),
                child: Semantics(
                  header: true,
                  child: Row(
                    children: [
                      StatusDot(color: tone, size: 10),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          allGranted
                              ? 'All allowed'
                              : '$grantedCount of ${asks.length} allowed',
                          style: AppType.tabular(AppType.heading),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AskList(
                asks: asks,
                isBlocked: isBlocked,
                isBusy: isBusy,
                onRequest: request,
              ),
              // Android Go: the two asks the system refuses are gone from the
              // list, so say what that costs rather than let it look complete.
              if (perms.lowRamDevice)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.gutter,
                    12,
                    AppTokens.gutter,
                    0,
                  ),
                  child: Text(
                    perms.whatsappInstalled
                        ? 'This phone runs Android Go, which does not allow '
                              'WhatsApp call tracking or the on-screen call '
                              'card. Calls are still tracked; the card opens '
                              'from a notification.'
                        : 'This phone runs Android Go, which does not allow '
                              'the on-screen call card. The card opens from a '
                              'notification instead.',
                    style: AppType.small.copyWith(color: z.ink2),
                  ),
                ),
              const SizedBox(height: 24),

              // Always offered. Hiding this until every permission was
              // granted left anyone who had declined an optional one with no
              // way off the screen but the system back gesture.
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.gutter,
                ),
                child: allGranted
                    ? ZButton(
                        label: 'Done',
                        icon: Icons.check_rounded,
                        size: ZButtonSize.large,
                        onPressed: () => Navigator.of(context).pop(),
                      )
                    : ZButton(
                        label: 'Back to app',
                        variant: ZButtonVariant.outline,
                        size: ZButtonSize.large,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
