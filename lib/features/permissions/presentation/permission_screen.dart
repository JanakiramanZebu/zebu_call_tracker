import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../background/data/background_service.dart';
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
    final snapshot = ref.watch(permissionStatusProvider);
    final background = ref.watch(backgroundStatusProvider).value;

    return Scaffold(
      backgroundColor: AppTokens.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Permissions',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 22,
            letterSpacing: -0.4,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            onPressed: openAppSettings,
            icon: const Icon(Icons.open_in_new_rounded, size: 20, color: AppTokens.textSecondary),
            tooltip: 'Open Android settings',
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: snapshot.when(
          loading: () => const AskSkeletonList(),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not read permissions',
            message: '$e',
            actionLabel: 'Try again',
            onAction: refreshPermissions,
          ),
          data: (perms) {
            final asks = permissionAsks(perms, background: background);
            final grantedCount = asks.grantedCount;
            final allGranted = asks.allGranted;

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                // ── Hero Shield Illustration ─────────────────────────────────
                Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: allGranted
                          ? AppTokens.success.withValues(alpha: 0.15)
                          : AppTokens.warning.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: allGranted
                            ? AppTokens.success.withValues(alpha: 0.4)
                            : AppTokens.warning.withValues(alpha: 0.4),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: allGranted
                              ? AppTokens.success.withValues(alpha: 0.2)
                              : AppTokens.warning.withValues(alpha: 0.2),
                          blurRadius: 20,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      allGranted ? Icons.verified_user_rounded : Icons.shield_outlined,
                      size: 36,
                      color: allGranted ? AppTokens.success : AppTokens.warning,
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                Center(
                  child: Text(
                    allGranted ? 'All set!' : 'Action Required',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.4,
                    ),
                  ),
                ),
                const SizedBox(height: 6),

                Center(
                  child: Text(
                    allGranted
                        ? 'All required system permissions are active. Tracking is running.'
                        : 'Grant permissions below to enable background call tracking and audio matching.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTokens.textSecondary,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // ── Progress Bar ─────────────────────────────────────────────
                AskProgress(granted: grantedCount, total: asks.length),
                const SizedBox(height: 16),

                // ── Permission Ask Cards ─────────────────────────────────────
                for (final ask in asks) ...[
                  AskCard(
                    ask: ask,
                    blocked: isBlocked(ask),
                    busy: isBusy(ask),
                    onRequest: () => request(ask),
                  ),
                  const SizedBox(height: 10),
                ],

                const SizedBox(height: 16),

                // Always offered. Hiding this until every permission was
                // granted left anyone who had declined an optional one with no
                // way off the screen but the system back gesture.
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: FilledButton.styleFrom(
                      backgroundColor: allGranted
                          ? AppTokens.brandElectric
                          : AppTokens.surface2,
                      foregroundColor:
                          allGranted ? Colors.white : AppTokens.textSecondary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTokens.r12),
                      ),
                    ),
                    child: Text(
                      allGranted ? 'Done' : 'Back to app',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
