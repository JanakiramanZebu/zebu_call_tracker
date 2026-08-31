import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/config/app_config.dart';
import '../../../core/storage/database_providers.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
import '../../auth/domain/session.dart';
import '../../background/data/background_service.dart';
import '../../background/presentation/background_card.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../permissions/presentation/permission_screen.dart';
import '../../synchronization/data/sync_service.dart';
import '../../synchronization/presentation/outbox_queue_screen.dart';

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
      ref.invalidate(permissionStatusProvider);
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
      backgroundColor: AppTokens.bgPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Settings',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 22,
            letterSpacing: -0.4,
            color: Colors.white,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          // ── 1. PROFILE SECTION ─────────────────────────────────────────────
          _AccountCard(session: session),
          const SizedBox(height: 12),

          // ── 2. DEVICE SECTION ──────────────────────────────────────────────
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                const IconChip(
                  icon: Icons.smartphone_rounded,
                  color: AppTokens.success,
                  size: 38,
                  iconSize: 20,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device == null
                            ? 'Reading device…'
                            : '${device["manufacturer"] ?? "Device"} ${device["model"] ?? ""}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        device == null
                            ? ''
                            : 'Android ${device["osVersion"] ?? ""} · API ${device["sdkInt"] ?? ""}',
                        style: const TextStyle(
                          color: AppTokens.textMuted,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                StatusPill(
                  label: session == null ? 'Unregistered' : 'Registered',
                  color: session == null ? AppTokens.textMuted : AppTokens.success,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ── 3. TRACKING SECTION ────────────────────────────────────────────
          const SectionLabel('Tracking & Ingestion'),
          const SizedBox(height: 8),
          const BackgroundStatusCard(),
          const SizedBox(height: 10),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SettingsRow(
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
                _divider(),
                _SettingsRow(
                  icon: Icons.graphic_eq_rounded,
                  label: 'Recording ingestion',
                  value: (perms?.readMediaAudio ?? false) ? 'Active' : 'Disabled',
                  valueColor: (perms?.readMediaAudio ?? false)
                      ? AppTokens.success
                      : AppTokens.warning,
                ),
                _divider(),
                _SettingsRow(
                  icon: Icons.autorenew_rounded,
                  label: 'Run a check now',
                  value: 'Trigger scan',
                  onTap: () => ref
                      .read(backgroundControllerProvider.notifier)
                      .start(reason: 'manual'),
                ),
                _divider(),
                _SettingsRow(
                  icon: Icons.sync_rounded,
                  label: 'Sync & upload server',
                  value: AppConfig.hasServer
                      ? Uri.parse(AppConfig.apiBaseUrl).host
                      : 'Local sandbox',
                  onTap: () async {
                    await ref.read(syncServiceProvider.notifier).triggerSync();
                    ref.invalidate(syncCountersProvider);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ── 4. DATA & STORAGE SECTION ──────────────────────────────────────
          const SectionLabel('Data & Storage'),
          const SizedBox(height: 8),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SettingsRow(
                  icon: Icons.inventory_2_outlined,
                  label: 'Call metadata outbox',
                  value: 'View queue',
                  valueColor: AppTokens.brandElectric,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const OutboxQueueScreen(),
                    ),
                  ),
                ),
                _divider(),
                _SettingsRow(
                  icon: Icons.list_alt_rounded,
                  label: 'Calls loaded in memory',
                  value: '${feed?.entries.length ?? 0}',
                ),
                _divider(),
                _SettingsRow(
                  icon: Icons.lock_outline_rounded,
                  label: 'Privacy & Security',
                  value: 'Encrypted',
                  valueColor: AppTokens.success,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ── 5. ACTIONS SECTION ─────────────────────────────────────────────
          const SectionLabel('System Actions'),
          const SizedBox(height: 8),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _SettingsRow(
                  icon: Icons.refresh_rounded,
                  label: 'Rescan device call logs',
                  value: '',
                  onTap: () => ref.read(callFeedProvider.notifier).refresh(),
                ),
                _divider(),
                _SettingsRow(
                  icon: Icons.open_in_new_rounded,
                  label: 'Open Android app settings',
                  value: '',
                  onTap: openAppSettings,
                ),
                _divider(),
                _SettingsRow(
                  icon: Icons.restart_alt_rounded,
                  label: 'Redo setup walkthrough',
                  value: '',
                  onTap: () => ref.read(onboardingProvider.notifier).reset(),
                ),
                _divider(),
                _SettingsRow(
                  icon: Icons.logout_rounded,
                  label: 'Sign out',
                  value: '',
                  destructive: true,
                  onTap: () => _confirmSignOut(context, ref),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── 6. BUILD FOOTER ────────────────────────────────────────────────
          Center(
            child: Text(
              '${AppConfig.appName} · v${AppConfig.buildLabel}',
              style: const TextStyle(
                color: AppTokens.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final dao = ref.read(callsDaoProvider);
    final unsyncedCount = await dao.getUnsyncedCount();

    if (!context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTokens.surface1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.r16),
          side: const BorderSide(color: AppTokens.borderDefault),
        ),
        title: const Text('Sign out?', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (unsyncedCount > 0) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTokens.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTokens.r8),
                  border: Border.all(
                    color: AppTokens.warning.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: AppTokens.warning,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '$unsyncedCount calls waiting in local outbox.',
                        style: const TextStyle(
                          color: AppTokens.warning,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              unsyncedCount > 0
                  ? 'Unsynced records remain securely stored on this device, but will not sync until an employee signs back in.'
                  : 'Calls recorded on this device remain saved. You will need your employee credentials to sign back in.',
              style: const TextStyle(
                color: AppTokens.textSecondary,
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel', style: TextStyle(color: AppTokens.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.danger,
              minimumSize: const Size(0, 42),
            ),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      if (context.mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      await ref.read(authControllerProvider.notifier).signOut();
    }
  }

  Widget _divider() => const Padding(
        padding: EdgeInsets.only(left: 52),
        child: Divider(height: 1, color: AppTokens.borderSubtle),
      );
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.session});

  final Session? session;

  @override
  Widget build(BuildContext context) => AppCard(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTokens.surface2,
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppTokens.brandElectric.withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
              child: Text(
                session?.initials ?? 'ZB',
                style: const TextStyle(
                  color: AppTokens.brandElectric,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
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
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    session != null
                        ? 'Employee ${session!.employeeId} · ${session!.department ?? "Staff"}'
                        : 'Sign in to register device',
                    style: const TextStyle(
                      color: AppTokens.textMuted,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            if (session != null)
              const StatusPill(
                label: 'Active',
                color: AppTokens.success,
                icon: Icons.check_rounded,
              ),
          ],
        ),
      );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: destructive ? AppTokens.danger : AppTokens.textMuted,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: destructive ? AppTokens.danger : Colors.white,
                  ),
                ),
              ),
              if (value.isNotEmpty) ...[
                Text(
                  value,
                  style: TextStyle(
                    color: valueColor ?? AppTokens.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
              ],
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppTokens.textMuted,
              ),
            ],
          ),
        ),
      );
}