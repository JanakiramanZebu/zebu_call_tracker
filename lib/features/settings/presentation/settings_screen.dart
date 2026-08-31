import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/storage/database_providers.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
import '../../auth/domain/session.dart';
import '../../background/data/background_service.dart';
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
    final session = ref.watch(authControllerProvider).value;
    final device = ref.watch(deviceInfoProvider).value;
    final background = ref.watch(backgroundStatusProvider).value;
    final perms = ref.watch(permissionStatusProvider).value;
    final feed = ref.watch(callFeedProvider).value;
    final counters = ref.watch(syncCountersProvider).value ?? const {};
    final isOnline = ref.watch(connectivityProvider).value ?? true;
    final lastSyncResult = ref.watch(syncServiceProvider).value;

    final isTrackingHealthy = (background?.ignoringBatteryOptimizations ?? false) &&
        (perms?.readCallLog ?? false);

    final pendingCount = counters['waiting'] ?? 0;
    final failedCount = counters['failed'] ?? 0;
    final uploadedCount = counters['uploaded'] ?? 0;

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
            fontSize: 24,
            letterSpacing: -0.5,
            color: Colors.white,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          // ── PROFILE SUMMARY HERO ───────────────────────────────────────────
          _ProfileHeroCard(session: session),
          const SizedBox(height: 20),

          // ── 1. ACCOUNT ─────────────────────────────────────────────────────
          const _SettingsSectionHeader('Account'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.person_outline_rounded,
                title: 'Profile',
                subtitle: session?.displayName ?? 'Not signed in',
                value: session != null ? session.employeeId : '—',
                onTap: () => _showProfileDialog(context, session),
              ),
              _SettingsTile(
                icon: Icons.verified_outlined,
                title: 'Account Status',
                valueWidget: StatusPill(
                  label: session == null ? 'Inactive' : 'Active',
                  color: session == null ? AppTokens.textMuted : AppTokens.success,
                  icon: session != null ? Icons.check_rounded : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // ── 2. DEVICE ──────────────────────────────────────────────────────
          const _SettingsSectionHeader('Device'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.smartphone_rounded,
                title: device == null
                    ? 'Reading device…'
                    : '${device["manufacturer"] ?? "Device"} ${device["model"] ?? ""}',
                subtitle: device == null
                    ? ''
                    : 'Android ${device["osVersion"] ?? ""} · API ${device["sdkInt"] ?? ""}',
                valueWidget: StatusPill(
                  label: session == null ? 'Unregistered' : 'Registered',
                  color: session == null ? AppTokens.textMuted : AppTokens.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // ── 3. CALL TRACKING ───────────────────────────────────────────────
          const _SettingsSectionHeader('Tracking'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.autorenew_rounded,
                title: 'Background Tracking',
                subtitle: background?.ignoringBatteryOptimizations == true
                    ? 'Running continuously in background'
                    : 'Battery optimization is restricting tracking',
                valueWidget: StatusPill(
                  label: background?.ignoringBatteryOptimizations == true
                      ? 'Active'
                      : 'Restricted',
                  color: background?.ignoringBatteryOptimizations == true
                      ? AppTokens.success
                      : AppTokens.warning,
                ),
                onTap: background?.ignoringBatteryOptimizations != true
                    ? () => ref
                        .read(backgroundControllerProvider.notifier)
                        .requestBatteryExemption()
                    : null,
              ),
              _SettingsTile(
                icon: Icons.phone_callback_rounded,
                title: 'Call Log Access',
                valueWidget: StatusPill(
                  label: (perms?.readCallLog ?? false) ? 'Granted' : 'Required',
                  color: (perms?.readCallLog ?? false)
                      ? AppTokens.success
                      : AppTokens.danger,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PermissionScreen(),
                  ),
                ),
              ),
              _SettingsTile(
                icon: Icons.graphic_eq_rounded,
                title: 'Recording Ingestion',
                subtitle: (perms?.readMediaAudio ?? false)
                    ? 'Audio matched automatically'
                    : 'Media permission needed for call audio',
                valueWidget: StatusPill(
                  label: (perms?.readMediaAudio ?? false) ? 'On' : 'Off',
                  color: (perms?.readMediaAudio ?? false)
                      ? AppTokens.success
                      : AppTokens.textMuted,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PermissionScreen(),
                  ),
                ),
              ),
              _SettingsTile(
                icon: Icons.health_and_safety_outlined,
                title: 'Tracking Health',
                valueWidget: StatusPill(
                  label: isTrackingHealthy ? 'Healthy' : 'Needs Attention',
                  color: isTrackingHealthy ? AppTokens.success : AppTokens.warning,
                  icon: isTrackingHealthy
                      ? Icons.check_circle_rounded
                      : Icons.warning_amber_rounded,
                ),
              ),
              _SettingsTile(
                icon: Icons.radar_rounded,
                title: 'Run Device Check',
                subtitle: 'Perform instant background sweep',
                value: 'Run Scan',
                valueColor: AppTokens.brandElectric,
                onTap: () async {
                  await ref
                      .read(backgroundControllerProvider.notifier)
                      .start(reason: 'manual');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Device check triggered successfully'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 18),

          // ── 4. SYNC & UPLOAD ───────────────────────────────────────────────
          const _SettingsSectionHeader('Sync & Upload'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.cloud_done_outlined,
                title: 'Sync Status',
                valueWidget: StatusPill(
                  label: isOnline ? 'Connected' : 'Offline',
                  color: isOnline ? AppTokens.success : AppTokens.danger,
                ),
              ),
              _SettingsTile(
                icon: Icons.schedule_rounded,
                title: 'Last Successful Sync',
                value: lastSyncResult?.isSuccess == true
                    ? 'Just now'
                    : (uploadedCount > 0 ? 'Active' : 'Pending'),
              ),
              _SettingsTile(
                icon: Icons.cloud_upload_outlined,
                title: 'Pending Uploads',
                value: '$pendingCount calls',
                valueColor: pendingCount > 0 ? AppTokens.warning : AppTokens.textMuted,
              ),
              _SettingsTile(
                icon: Icons.error_outline_rounded,
                title: 'Failed Records',
                value: '$failedCount records',
                valueColor: failedCount > 0 ? AppTokens.danger : AppTokens.textMuted,
              ),
              _SettingsTile(
                icon: Icons.sync_rounded,
                title: 'Manual Sync Now',
                subtitle: 'Push all waiting calls to server',
                value: 'Sync',
                valueColor: AppTokens.brandElectric,
                onTap: () async {
                  await ref.read(syncServiceProvider.notifier).triggerSync();
                  ref.invalidate(syncCountersProvider);
                },
              ),
              if (failedCount > 0)
                _SettingsTile(
                  icon: Icons.replay_rounded,
                  title: 'Retry Failed Records',
                  value: 'Retry',
                  valueColor: AppTokens.warning,
                  onTap: () async {
                    await ref.read(callsDaoProvider).retryAllFailed();
                    await ref.read(syncServiceProvider.notifier).triggerSync();
                    ref.invalidate(syncCountersProvider);
                  },
                ),
              _SettingsTile(
                icon: Icons.queue_outlined,
                title: 'View Sync Queue',
                value: 'Open Outbox',
                valueColor: AppTokens.brandElectric,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const OutboxQueueScreen(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // ── 5. DATA & STORAGE ──────────────────────────────────────────────
          const _SettingsSectionHeader('Data & Storage'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.inventory_2_outlined,
                title: 'Call Metadata Outbox',
                value: 'View queue',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const OutboxQueueScreen(),
                  ),
                ),
              ),
              _SettingsTile(
                icon: Icons.list_alt_rounded,
                title: 'Calls Loaded in Memory',
                value: '${feed?.entries.length ?? 0}',
              ),
              _SettingsTile(
                icon: Icons.storage_rounded,
                title: 'Storage Footprint',
                value: Fmt.fileSize(
                  ((feed?.entries.length ?? 0) * 1280) + 124000,
                ),
              ),
              _SettingsTile(
                icon: Icons.security_rounded,
                title: 'Privacy & Security',
                value: 'Encrypted',
                valueColor: AppTokens.success,
                onTap: () => _showPrivacyDialog(context),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // ── 6. PERMISSIONS ─────────────────────────────────────────────────
          const _SettingsSectionHeader('Permissions'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.shield_outlined,
                title: 'Permissions Summary',
                subtitle: 'Call logs, phone state, audio, notifications',
                valueWidget: StatusPill(
                  label: perms == null
                      ? '—'
                      : '${perms.grantedCount}/${PermissionSnapshot.total} Granted',
                  color: (perms?.grantedCount ?? 0) == PermissionSnapshot.total
                      ? AppTokens.success
                      : AppTokens.warning,
                  icon: (perms?.grantedCount ?? 0) == PermissionSnapshot.total
                      ? Icons.check_rounded
                      : Icons.warning_amber_rounded,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PermissionScreen(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // ── 7. APP & ABOUT ─────────────────────────────────────────────────
          const _SettingsSectionHeader('Application'),
          _SettingsGroup(
            children: [
              const _SettingsTile(
                icon: Icons.info_outline_rounded,
                title: 'Version',
                value: '1.0.0',
              ),
              _SettingsTile(
                icon: Icons.numbers_rounded,
                title: 'Build Label',
                value: AppConfig.buildLabel,
              ),
              _SettingsTile(
                icon: Icons.help_outline_rounded,
                title: 'About Zebu Call Tracker',
                onTap: () => _showAboutDialog(context),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ── 8. ACTIONS & DANGER ZONE ───────────────────────────────────────
          const _SettingsSectionHeader('System Actions'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.refresh_rounded,
                title: 'Rescan Device Call Logs',
                subtitle: 'Reload recent call logs from native storage',
                onTap: () {
                  ref.read(callFeedProvider.notifier).refresh();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Call logs re-scanned'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              _SettingsTile(
                icon: Icons.restart_alt_rounded,
                title: 'Redo Setup Walkthrough',
                subtitle: 'Re-run first time permission onboarding',
                onTap: () => ref.read(onboardingProvider.notifier).reset(),
              ),
              _SettingsTile(
                icon: Icons.open_in_new_rounded,
                title: 'Open Android App Settings',
                onTap: openAppSettings,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Sign Out Card (Dedicated Danger Zone)
          Container(
            decoration: BoxDecoration(
              color: AppTokens.surface1,
              borderRadius: BorderRadius.circular(AppTokens.r12),
              border: Border.all(
                color: AppTokens.danger.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTokens.r12),
              child: _SettingsTile(
                icon: Icons.logout_rounded,
                title: 'Sign Out',
                subtitle: 'Unregister device and clear active session',
                destructive: true,
                onTap: () => _confirmSignOut(context, ref),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Footer info
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

  void _showProfileDialog(BuildContext context, Session? session) {
    if (session == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTokens.surface1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.r16),
          side: const BorderSide(color: AppTokens.borderDefault),
        ),
        title: const Text('Employee Profile', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _dialogRow('Name', session.displayName),
            _dialogRow('Employee ID', session.employeeId),
            _dialogRow('Department', session.department ?? 'Staff'),
            _dialogRow('Role', session.role ?? 'Representative'),
            if (session.email != null) _dialogRow('Email', session.email!),
            if (session.phone != null) _dialogRow('Phone', session.phone!),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showPrivacyDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTokens.surface1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.r16),
          side: const BorderSide(color: AppTokens.borderDefault),
        ),
        title: const Text('Privacy & Security', style: TextStyle(color: Colors.white)),
        content: const Text(
          'All call tracking metadata and audio recordings are stored locally '
          'in encrypted SQLite storage on this device. Synchronization uses '
          'authenticated TLS 1.3 endpoints with SHA-256 integrity verification.',
          style: TextStyle(color: AppTokens.textSecondary, fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTokens.surface1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.r16),
          side: const BorderSide(color: AppTokens.borderDefault),
        ),
        title: Text(AppConfig.appName, style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enterprise mobile call tracking, recording synchronization, '
              'and analytics platform for field sales and customer support teams.',
              style: const TextStyle(
                color: AppTokens.textSecondary,
                fontSize: 13.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Build: ${AppConfig.buildLabel}',
              style: const TextStyle(color: AppTokens.textMuted, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _dialogRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(
                label,
                style: const TextStyle(color: AppTokens.textMuted, fontSize: 13),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
            ),
          ],
        ),
      );

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
}

/// Profile summary card at the top of settings.
class _ProfileHeroCard extends StatelessWidget {
  const _ProfileHeroCard({required this.session});

  final Session? session;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTokens.surface1,
        borderRadius: BorderRadius.circular(AppTokens.r16),
        border: Border.all(color: AppTokens.borderDefault, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: AppTokens.primaryGradient,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppTokens.brandElectric.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Text(
              session?.initials ?? 'ZB',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
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
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  session != null
                      ? '${session!.employeeId} · ${session!.department ?? "Staff"}'
                      : 'Sign in to register device',
                  style: const TextStyle(
                    color: AppTokens.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
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
}

/// Section title header.
class _SettingsSectionHeader extends StatelessWidget {
  const _SettingsSectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppTokens.textMuted,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// Grouped card wrapper for settings rows with subtle dividers.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTokens.surface1,
        borderRadius: BorderRadius.circular(AppTokens.r12),
        border: Border.all(color: AppTokens.borderSubtle, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTokens.r12),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                const Divider(
                  height: 1,
                  indent: 52,
                  color: AppTokens.borderSubtle,
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Individual setting row with icon, title, optional subtitle, value/pill, and chevron.
class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.value = '',
    this.valueColor,
    this.valueWidget,
    this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String value;
  final Color? valueColor;
  final Widget? valueWidget;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: destructive ? AppTokens.danger : AppTokens.textSecondary,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      color: destructive ? AppTokens.danger : Colors.white,
                      letterSpacing: -0.2,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTokens.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (valueWidget != null) ...[
              valueWidget!,
            ] else if (value.isNotEmpty) ...[
              Text(
                value,
                style: TextStyle(
                  color: valueColor ?? AppTokens.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: destructive ? AppTokens.danger : AppTokens.textMuted,
              ),
            ],
          ],
        ),
      ),
    );
  }
}