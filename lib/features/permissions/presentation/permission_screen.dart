import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../shared/widgets/ui_kit.dart';
import '../../call_tracking/data/call_feed.dart';

/// One permission, with the reason the user is being asked.
///
/// The reason is part of the data, not decoration: brief §15 requires the app
/// to explain WHY before requesting, and keeping the copy next to the
/// permission makes it impossible to add one without writing the other.
class _Ask {
  const _Ask({
    required this.permission,
    required this.title,
    required this.why,
    required this.granted,
    this.essential = false,
  });

  final Permission permission;
  final String title;
  final String why;
  final bool granted;

  /// Essential permissions block tracking entirely when denied; the rest only
  /// reduce detail.
  final bool essential;
}

class PermissionScreen extends ConsumerWidget {
  const PermissionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(permissionStatusProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Permissions')),
      body: SafeArea(
        top: false,
        child: snapshot.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not read permissions',
            message: '$e',
          ),
          data: (perms) {
            final asks = <_Ask>[
              _Ask(
                permission: Permission.phone,
                title: 'Phone & call log',
                why:
                    'Detects when a call starts and ends, and reads its final '
                    'duration and status. Without this, nothing is tracked.',
                granted: perms.readCallLog && perms.readPhoneState,
                essential: true,
              ),
              _Ask(
                permission: Permission.contacts,
                title: 'Contacts',
                why:
                    'Shows a name instead of a bare number. Declining keeps the '
                    'number; only the name is missing.',
                granted: perms.readContacts,
              ),
              _Ask(
                permission: Permission.audio,
                title: 'Recordings on this device',
                why:
                    "Finds call recordings your phone's own dialer already made, "
                    'so they can be filed against the right call. The app never '
                    'records anything itself.',
                granted: perms.readMediaAudio,
              ),
              _Ask(
                permission: Permission.notification,
                title: 'Notifications',
                why:
                    'Tells you when an upload fails, so calls do not sit '
                    'unsynced without you noticing.',
                granted: false,
              ),
            ];

            final grantedCount = asks.where((a) => a.granted).length;

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: grantedCount / asks.length,
                          minHeight: 6,
                          backgroundColor: context.palette.tint,
                          color: context.colors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '$grantedCount of ${asks.length}',
                      style: context.text.bodySmall?.copyWith(
                        color: context.palette.muted,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Each permission is requested only when it is needed, and only '
                  'with the reason shown. You can decline any of them — the app '
                  'keeps working with less detail.',
                  style: context.text.bodyMedium?.copyWith(
                    color: context.palette.muted,
                    height: 1.55,
                  ),
                ),
                const SizedBox(height: 16),
                for (final ask in asks) ...[
                  _AskCard(
                    ask: ask,
                    onRequest: () async {
                      final status = await ask.permission.request();
                      if (status.isPermanentlyDenied) {
                        // Requesting again would do nothing and would read as the
                        // app spamming dialogs — send them to Settings instead.
                        await openAppSettings();
                      }
                      ref.invalidate(permissionStatusProvider);
                      ref.read(callFeedProvider.notifier).refresh();
                    },
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

class _AskCard extends StatelessWidget {
  const _AskCard({required this.ask, required this.onRequest});

  final _Ask ask;
  final Future<void> Function() onRequest;

  @override
  Widget build(BuildContext context) {
    final color = ask.granted
        ? context.palette.answered
        : context.colors.primary;

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconChip(
            icon: ask.granted ? Icons.check_rounded : _iconFor(ask.permission),
            color: color,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        ask.title,
                        style: context.text.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (ask.essential && !ask.granted)
                      StatusPill(
                        label: 'Required',
                        color: context.palette.missed,
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  ask.why,
                  style: context.text.bodySmall?.copyWith(
                    color: context.palette.muted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 10),
                if (ask.granted)
                  StatusPill(
                    label: 'Enabled',
                    color: context.palette.answered,
                    icon: Icons.check_rounded,
                  )
                else
                  SizedBox(
                    height: 34,
                    child: FilledButton(
                      onPressed: onRequest,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        textStyle: context.text.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('Enable'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(Permission p) {
    if (p == Permission.phone) return Icons.phone_outlined;
    if (p == Permission.contacts) return Icons.contacts_outlined;
    if (p == Permission.audio) return Icons.graphic_eq_rounded;
    return Icons.notifications_none_rounded;
  }
}
