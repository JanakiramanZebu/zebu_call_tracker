import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../shared/widgets/ui_kit.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../domain/permission_ask.dart';
import 'ask_card.dart';
import 'permission_flow.dart';

/// Permissions as reached from Settings — the same asks as the first-run
/// walkthrough, without the walkthrough's continue gate. A user arriving here
/// has already got into the app; this screen is for changing their mind.
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
    // Background state loads independently: a slow PowerManager read
    // must not hold up the permission cards.
    final background = ref.watch(backgroundStatusProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Permissions'),
        actions: [
          IconButton(
            onPressed: openAppSettings,
            icon: const Icon(Icons.open_in_new_rounded, size: 20),
            tooltip: 'Open app settings',
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
            final grantedCount = asks.where((a) => a.granted).length;

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                AskProgress(granted: grantedCount, total: asks.length),
                const SizedBox(height: 16),
                Text(
                  'Each permission is requested only when it is needed, and '
                  'only with the reason shown. You can decline any of them — '
                  'the app keeps working with less detail.',
                  style: context.text.bodyMedium?.copyWith(
                    color: context.palette.muted,
                    height: 1.55,
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
                  const SizedBox(height: 12),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
