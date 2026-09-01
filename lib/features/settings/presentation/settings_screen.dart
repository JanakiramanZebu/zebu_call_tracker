import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/app_version.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/storage/database_providers.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
import '../../auth/domain/session.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../permissions/presentation/permission_screen.dart';
import '../../synchronization/data/sync_service.dart';
import 'diagnostics_screen.dart';
import '../../synchronization/data/sync_health_provider.dart';
import '../../synchronization/presentation/outbox_queue_screen.dart';
import '../../synchronization/presentation/sync_alert_banner.dart';

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
      // A background run leaves no trace in Dart, so resume is the moment to
      // re-read what happened while this screen was away.
      ref.invalidate(nativeSyncStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authControllerProvider).value;
    final meteredAllowed =
        ref.watch(recordingsOnMeteredProvider).value ?? false;
    final device = ref.watch(deviceInfoProvider).value;
    final background = ref.watch(backgroundStatusProvider).value;
    final perms = ref.watch(permissionStatusProvider).value;
    final counters = ref.watch(syncCountersProvider).value ?? const {};
    final isOnline = ref.watch(connectivityProvider).value ?? true;
    // What the NATIVE coordinator recorded, not what this Dart session did.
    final nativeSync = ref.watch(nativeSyncStatusProvider).value;

    // Counted the same way the Permissions screen counts, including the
    // background-activity card, so the two screens cannot disagree.
    final canTrack = perms?.canTrack ?? false;
    final permissionsGranted = perms?.grantedCount(
      ignoringBatteryOptimizations:
          background?.ignoringBatteryOptimizations ?? false,
    );

    final isTrackingHealthy = (background?.ignoringBatteryOptimizations ?? false) &&
        canTrack;

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
          // Every outstanding problem, not just the top two the compact
          // banners on Dashboard and Sync have room for — those point here
          // when they run out of space.
          const SyncAlertBanner(maxAlerts: 99),

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
                title: 'Account',
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
                title: 'Background activity',
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
                title: 'Call log access',
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
                title: 'Recordings on this phone',
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
                title: 'Tracking status',
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
                title: 'Look for new calls now',
                subtitle: 'Checks the call log straight away',
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
                title: 'Syncing',
                // The server's own `error.message` is written for people and
                // is safe here; the raw code and request id are not, and the
                // banner above already says what to do about it. Settings is
                // where you look for detail, so a trimmed version stays.
                subtitle: !isOnline
                    ? 'Waiting for a connection'
                    : _lastErrorSummary(nativeSync?.error),
                valueWidget: StatusPill(
                  label: !isOnline
                      ? 'Offline'
                      : (nativeSync?.statusLabel ?? 'Checking…'),
                  color: !isOnline
                      ? AppTokens.danger
                      : (nativeSync == null
                          ? AppTokens.textMuted
                          : (nativeSync.isHealthy
                              ? AppTokens.success
                              : (nativeSync.isUnauthenticated
                                  ? AppTokens.danger
                                  : AppTokens.warning))),
                ),
              ),
              _SettingsTile(
                icon: Icons.schedule_rounded,
                title: 'Last sent',
                // The real timestamp the background coordinator wrote. This
                // tile used to print 'Just now'/'Active'/'Pending' inferred
                // from the current session, which said nothing about whether
                // the phone had actually reached the server.
                subtitle: nativeSync?.hasRun == true
                    ? '${nativeSync!.syncedCount} '
                        '${nativeSync.syncedCount == 1 ? "call" : "calls"} on that run'
                    : 'No background run recorded yet',
                value: nativeSync?.lastSyncLabel ?? '—',
                valueColor: nativeSync?.hasRun == true
                    ? AppTokens.textSecondary
                    : AppTokens.textMuted,
              ),
              _SettingsTile(
                icon: Icons.cloud_done_rounded,
                title: 'Sent to server',
                value: '$uploadedCount calls',
                valueColor: uploadedCount > 0
                    ? AppTokens.success
                    : AppTokens.textMuted,
              ),
              _SettingsTile(
                icon: Icons.cloud_upload_outlined,
                title: 'Waiting to send',
                value: '$pendingCount ${pendingCount == 1 ? "call" : "calls"}',
                valueColor: pendingCount > 0 ? AppTokens.warning : AppTokens.textMuted,
              ),
              _SettingsTile(
                icon: Icons.error_outline_rounded,
                title: 'Could not be sent',
                value: '$failedCount ${failedCount == 1 ? "record" : "records"}',
                valueColor: failedCount > 0 ? AppTokens.danger : AppTokens.textMuted,
              ),
              _SettingsTile(
                icon: Icons.sync_rounded,
                title: 'Send now',
                subtitle: 'Send everything waiting, without waiting for the schedule',
                value: 'Sync',
                valueColor: AppTokens.brandElectric,
                onTap: () async {
                  await ref.read(syncServiceProvider.notifier).triggerSync();
                  ref.invalidate(syncCountersProvider);
                  ref.invalidate(nativeSyncStatusProvider);
                },
              ),
              if (failedCount > 0)
                _SettingsTile(
                  icon: Icons.replay_rounded,
                  title: 'Try failed calls again',
                  value: 'Retry',
                  valueColor: AppTokens.warning,
                  onTap: () async {
                    await ref.read(callsDaoProvider).retryAllFailed();
                    await ref.read(syncServiceProvider.notifier).triggerSync();
                    ref.invalidate(syncCountersProvider);
                    ref.invalidate(nativeSyncStatusProvider);
                  },
                ),
              _SettingsTile(
                icon: Icons.network_cell_rounded,
                title: 'Send recordings on mobile data',
                subtitle: meteredAllowed
                    ? 'Recordings upload on any connection'
                    : 'Recordings wait for Wi-Fi; call details always send',
                valueWidget: Switch.adaptive(
                  value: meteredAllowed,
                  activeThumbColor: AppTokens.brandElectric,
                  onChanged: (value) => ref
                      .read(recordingsOnMeteredProvider.notifier)
                      .set(value),
                ),
              ),
              _SettingsTile(
                icon: Icons.queue_outlined,
                title: 'Calls waiting to send',
                value: 'View',
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

          // ── 5. YOUR DATA ───────────────────────────────────────────────────
          //
          // What is left here is what a user can act on. The storage internals
          // that used to sit in this group -- integrity checks, journal mode,
          // row counts, an invented "storage footprint" -- moved to
          // Technical details, at the bottom of this screen.
          const _SettingsSectionHeader('Your data'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.security_rounded,
                title: 'How your call data is handled',
                value: 'Encrypted',
                valueColor: AppTokens.success,
                onTap: () => _showPrivacyDialog(context),
              ),
              _SettingsTile(
                icon: Icons.build_outlined,
                title: 'Technical details',
                subtitle: 'Storage checks and version info for support',
                value: 'Open',
                valueColor: AppTokens.brandElectric,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DiagnosticsScreen(),
                  ),
                ),
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
                title: 'App permissions',
                subtitle: permissionsGranted == null
                    ? 'Reading current grants…'
                    : (permissionsGranted == PermissionSnapshot.total
                        ? 'All access granted'
                        : (canTrack
                            ? 'Tracking active; some optional access missing'
                            : 'Call log access required to track calls')),
                valueWidget: StatusPill(
                  label: permissionsGranted == null
                      ? '—'
                      : '$permissionsGranted/${PermissionSnapshot.total} Granted',
                  color: permissionsGranted == PermissionSnapshot.total
                      ? AppTokens.success
                      : (canTrack ? AppTokens.warning : AppTokens.danger),
                  icon: permissionsGranted == PermissionSnapshot.total
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
              _SettingsTile(
                icon: Icons.info_outline_rounded,
                title: 'Version',
                value: AppVersion.full,
              ),
              _SettingsTile(
                icon: Icons.numbers_rounded,
                title: 'Build',
                value: AppConfig.buildLabel(AppVersion.name),
              ),
              _SettingsTile(
                icon: Icons.help_outline_rounded,
                title: 'About this app',
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
                title: 'Reload call history',
                subtitle: 'Re-reads recent calls from this phone',
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
                title: 'Show the setup steps again',
                subtitle: 'Walk through the permissions once more',
                onTap: () => ref.read(onboardingProvider.notifier).reset(),
              ),
              _SettingsTile(
                icon: Icons.open_in_new_rounded,
                title: 'Open Android settings',
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
                title: 'Sign out',
                subtitle: 'Signs this phone out and stops syncing',
                destructive: true,
                onTap: () => _confirmSignOut(context, ref),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Footer info
          Center(
            child: Text(
              '${AppConfig.appName} · ${AppConfig.buildLabel(AppVersion.name)}',
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
        title: const Text('How your call data is handled', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Call details and any recordings are kept on this phone in encrypted '
          'storage until they reach your company server. They are sent over an '
          'encrypted connection, and each recording is checked on arrival so '
          'that a partial upload is never mistaken for a complete one. Only '
          'you and your administrators can see your calls, and every playback '
          'of a recording is written to an audit log.',
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
              'Build: ${AppConfig.buildLabel(AppVersion.name)}',
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



/// Trims the coordinator's stored failure into one readable line.
///
/// It stores `CODE: message details` so a report can be diagnosed; the code is
/// the half a user cannot act on, so only the human half is shown, capped so a
/// long validation payload cannot push the rest of the tile off screen.
String? _lastErrorSummary(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final text = raw.contains(': ') ? raw.split(': ').skip(1).join(': ') : raw;
  final clean = text.trim();
  if (clean.isEmpty) return null;
  return clean.length > 140
      ? 'Last problem: ${clean.substring(0, 140)}…'
      : 'Last problem: $clean';
}
