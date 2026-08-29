import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/config/app_config.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
import '../../auth/domain/session.dart';
import '../../background/data/background_service.dart';
import '../../background/presentation/background_card.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../permissions/presentation/permission_screen.dart';
import '../../synchronization/data/sync_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && mounted) {
      // Permissions may have changed in the system settings panel.
      ref.invalidate(permissionStatusProvider);
      // Battery optimisation state may have changed too.
      ref.invalidate(backgroundStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(deviceInfoProvider).value;
    final perms = ref.watch(permissionStatusProvider).value;
    final feed = ref.watch(callFeedProvider).value;
    final session = ref.watch(authControllerProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _AccountCard(session: session),
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
                StatusPill(
                  label: session == null ? 'Unregistered' : 'Registered',
                  color: session == null
                      ? context.palette.muted
                      : context.palette.answered,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const SectionLabel('Tracking'),
          const SizedBox(height: 8),
          const BackgroundStatusCard(),
          const SizedBox(height: 12),
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
                  icon: Icons.autorenew_rounded,
                  label: 'Run a check now',
                  value: '',
                  onTap: () => ref
                      .read(backgroundControllerProvider.notifier)
                      .start(reason: 'manual'),
                ),
                _divider(context),
                _Row(
                  icon: Icons.sync_rounded,
                  label: 'Sync & upload',
                  value: AppConfig.hasServer
                      ? Uri.parse(AppConfig.apiBaseUrl).host
                      : 'Not configured',
                  onTap: () async {
                    await ref.read(syncServiceProvider.notifier).triggerSync();
                    ref.invalidate(syncCountersProvider);
                  },
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
                ),
                _divider(context),
                _Row(
                  icon: Icons.restart_alt_rounded,
                  label: 'Redo setup walkthrough',
                  value: '',
                  onTap: () => ref.read(onboardingProvider.notifier).reset(),
                ),
                _divider(context),
                _Row(
                  icon: Icons.logout_rounded,
                  label: 'Sign out',
                  value: '',
                  destructive: true,
                  onTap: () => _confirmSignOut(context, ref),
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '${AppConfig.appName} · ${AppConfig.buildLabel}',
              style: context.text.bodySmall?.copyWith(
                color: context.palette.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Calls already recorded on this device stay on it. You will need '
          'your employee ID and password to sign back in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              minimumSize: const Size(0, 44),
            ),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(authControllerProvider.notifier).signOut();
    }
  }

  Widget _divider(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 52),
        child: Divider(height: 1, color: context.colors.outlineVariant),
      );
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.session});

  final Session? session;

  @override
  Widget build(BuildContext context) => AppCard(
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
                session?.initials ?? 'ZB',
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
                    session?.displayName ?? 'Not signed in',
                    style: context.text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Builder(builder: (context) {
                    final currentSession = session;
                    return Text(
                      currentSession != null
                          ? 'Employee ${currentSession.employeeId} · '
                              '${currentSession.department ?? "Staff"}'
                          : 'Sign in to register this device',
                      style: context.text.bodySmall?.copyWith(
                        color: context.palette.muted,
                      ),
                    );
                  }),
                ],
              ),
            ),
            if (session != null)
              StatusPill(
                label: 'Active',
                color: context.palette.answered,
                icon: Icons.check_rounded,
              ),
          ],
        ),
      );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.last = false,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
  final bool last;
  final bool destructive;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                icon,
                size: 19,
                color: destructive
                    ? context.palette.missed
                    : context.palette.muted,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: context.text.bodyLarge?.copyWith(
                    fontSize: 15,
                    color: destructive ? context.palette.missed : null,
                  ),
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