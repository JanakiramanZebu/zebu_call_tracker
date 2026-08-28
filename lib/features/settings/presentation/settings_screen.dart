import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../shared/widgets/ui_kit.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../permissions/presentation/permission_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(deviceInfoProvider).value;
    final perms = ref.watch(permissionStatusProvider).value;
    final feed = ref.watch(callFeedProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          AppCard(
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: context.colors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    'ZB',
                    style: context.text.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Not signed in',
                        style: context.text.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Sign-in activates once a server is configured',
                        style: context.text.bodySmall?.copyWith(
                          color: context.palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                IconChip(
                  icon: Icons.smartphone_rounded,
                  color: context.palette.answered,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device == null
                            ? 'Reading device…'
                            : '${device["manufacturer"]} ${device["model"]}',
                        style: context.text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        device == null
                            ? ''
                            : 'Android ${device["osVersion"]} · API ${device["sdkInt"]}',
                        style: context.text.bodySmall?.copyWith(
                          color: context.palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                StatusPill(label: 'Unregistered', color: context.palette.muted),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SectionLabel('Tracking'),
          const SizedBox(height: 8),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _Row(
                  icon: Icons.verified_user_outlined,
                  label: 'Permissions',
                  value: perms == null
                      ? '—'
                      : '${perms.grantedCount} of ${PermissionSnapshot.total}',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PermissionScreen(),
                    ),
                  ),
                ),
                _divider(context),
                _Row(
                  icon: Icons.graphic_eq_rounded,
                  label: 'Recording ingestion',
                  value: (perms?.readMediaAudio ?? false) ? 'On' : 'Off',
                ),
                _divider(context),
                _Row(
                  icon: Icons.sync_rounded,
                  label: 'Sync & upload',
                  value: 'Not configured',
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SectionLabel('Data'),
          const SizedBox(height: 8),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _Row(
                  icon: Icons.list_alt_rounded,
                  label: 'Calls loaded',
                  value: '${feed?.entries.length ?? 0}',
                ),
                _divider(context),
                _Row(
                  icon: Icons.audio_file_outlined,
                  label: 'Recordings discovered',
                  value: '${feed?.recordingPoolSize ?? 0}',
                ),
                _divider(context),
                _Row(
                  icon: Icons.lock_outline_rounded,
                  label: 'Privacy',
                  value: '',
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SectionLabel('Actions'),
          const SizedBox(height: 8),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _Row(
                  icon: Icons.refresh_rounded,
                  label: 'Rescan device',
                  value: '',
                  onTap: () => ref.read(callFeedProvider.notifier).refresh(),
                ),
                _divider(context),
                _Row(
                  icon: Icons.open_in_new_rounded,
                  label: 'Open app permissions',
                  value: '',
                  onTap: openAppSettings,
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'Call Tracker 1.0.0 · Internal build',
              style: context.text.bodySmall?.copyWith(
                color: context.palette.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 52),
    child: Divider(height: 1, color: context.colors.outlineVariant),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.last = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  final bool last;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(icon, size: 19, color: context.palette.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: context.text.bodyLarge?.copyWith(fontSize: 15),
            ),
          ),
          if (value.isNotEmpty)
            Text(
              value,
              style: context.text.bodyMedium?.copyWith(
                color: context.palette.muted,
              ),
            ),
          const SizedBox(width: 6),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: context.palette.muted,
          ),
        ],
      ),
    ),
  );
}
