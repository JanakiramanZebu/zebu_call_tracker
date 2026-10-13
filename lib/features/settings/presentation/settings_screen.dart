import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../app.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/app_version.dart';
import '../../../core/theme/appearance.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/brand.dart';
import '../../../shared/widgets/ui_kit.dart';
import '../../auth/data/auth_controller.dart';
import '../../auth/domain/session.dart';
import '../../background/data/background_service.dart';
import '../../call_tracking/data/call_feed.dart';
import '../../permissions/domain/permission_ask.dart';
import '../../permissions/presentation/permission_screen.dart';
import '../../synchronization/data/sync_health_provider.dart';
import '../../synchronization/data/sync_service.dart';
import '../../synchronization/domain/sync_health.dart';
import '../../synchronization/presentation/outbox_queue_screen.dart';
import '../../synchronization/presentation/sync_alert_banner.dart';
import 'diagnostics_screen.dart';

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
    final z = context.z;
    final session = ref.watch(authControllerProvider).value;
    final background = ref.watch(backgroundStatusProvider).value;
    final perms = ref.watch(permissionStatusProvider).value;
    final counters = ref.watch(syncCountersProvider).value ?? const {};
    final appearance = ref.watch(appearanceProvider);

    // Counted from the very list the Permissions screen renders, so the two
    // cannot disagree — the card set varies by handset (the WhatsApp card
    // only exists where WhatsApp is installed), so a fixed total cannot.
    final canTrack = perms?.canTrack ?? false;
    final asks = perms == null
        ? null
        : permissionAsks(perms, background: background);
    final permissionsGranted = asks?.grantedCount;
    final permissionsTotal = asks?.length ?? 0;

    final pendingCount = counters['waiting'] ?? 0;
    final backgroundOn = background?.ignoringBatteryOptimizations == true;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Settings'),
      ),
      // A pushed screen with no bottom bar: scrollPadding adds the system
      // navigation bar's height so the footer clears the nav buttons. Rows run
      // edge to edge, so there is no side padding; each row indents itself.
      body: ListView(
        padding: context.scrollPadding(top: 4, bottom: 32, horizontal: 0),
        children: [
          // Every outstanding problem, not just the top two the compact
          // banners on Dashboard and Sync have room for — those point here
          // when they run out of space.
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppTokens.gutter),
            child: SyncAlertBanner(maxAlerts: 99),
          ),

          // ── Profile ──
          _ProfileSummary(
            session: session,
            onTap: () => _showProfileDialog(context, session),
          ),

          // ── Appearance ──
          const SectionLabel('Appearance'),
          DecoratedBox(
            decoration: BoxDecoration(
              color: z.raised,
              border: Border.symmetric(horizontal: BorderSide(color: z.line)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.gutter,
                vertical: 12,
              ),
              child: Semantics(
                label: 'Theme',
                container: true,
                child: SegmentedPicker<Appearance>(
                  segments: {
                    for (final a in const [
                      Appearance.dark,
                      Appearance.light,
                      Appearance.system,
                    ])
                      a: a.label,
                  },
                  selected: appearance,
                  onSelected: (value) =>
                      ref.read(appearanceProvider.notifier).select(value),
                ),
              ),
            ),
          ),

          // ── Account ──
          const SectionLabel('Account'),
          ListGroup(
            children: [
              ListRow(
                title: 'Profile',
                subtitle: session?.displayName ?? 'Not signed in',
                value: session != null ? session.employeeId : '—',
                onTap: () => _showProfileDialog(context, session),
              ),
            ],
          ),

          // ── Tracking ──
          const SectionLabel('Tracking'),
          ListGroup(
            children: [
              // Not a switch: "On" is the system's battery exemption, which
              // only Android settings can grant or take back. The row opens
              // that request while it is still limited.
              ListRow(
                title: 'Background activity',
                subtitle: backgroundOn
                    ? 'Tracks calls even when the app is closed'
                    : 'Battery saver may delay tracking – tap to allow',
                value: backgroundOn ? 'On' : 'Limited',
                valueColor: backgroundOn ? z.ok : z.warn,
                onTap: !backgroundOn
                    ? () => ref
                          .read(backgroundControllerProvider.notifier)
                          .requestBatteryExemption()
                    : null,
              ),
              ListRow(
                title: 'Check for new calls',
                subtitle: 'Looks through your call history now',
                onTap: () {
                  // Said up front: the check runs in the background and has
                  // no "done" moment worth waiting on.
                  showToast(context, 'Checking for new calls…');
                  ref
                      .read(backgroundControllerProvider.notifier)
                      .start(reason: 'manual');
                },
              ),
            ],
          ),

          // ── Sync ──
          //
          // Status, last-sent time, the three counters, "send now" and "retry
          // failed" all live on the Sync tab, one tap away. Repeating them here
          // made Settings a second dashboard that could disagree with the first.
          // What stays is the waiting count, as a way back to the Sync tab.
          //
          // There used to be a "Send recordings on mobile data" switch here,
          // off by default, which held audio until Wi-Fi. Recordings now go
          // over any network, so there is nothing left to choose.
          const SectionLabel('Sync'),
          ListGroup(
            children: [
              ListRow(
                title: 'Calls waiting to send',
                value: pendingCount == 0
                    ? 'None'
                    : '$pendingCount ${pendingCount == 1 ? "call" : "calls"}',
                valueColor: pendingCount > 0 ? z.warn : z.ink3,
                onTap: () {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                  ref.read(homeTabProvider.notifier).show(HomeTab.sync);
                },
              ),
            ],
          ),

          // ── Your data ──
          //
          // What is left here is what a user can act on. The storage internals
          // that used to sit in this group -- integrity checks, journal mode,
          // row counts -- are support-only now: long-press Version.
          const SectionLabel('Your data'),
          ListGroup(
            children: [
              ListRow(
                title: 'How your call data is handled',
                value: 'Encrypted',
                onTap: () => _showPrivacyDialog(context),
              ),
            ],
          ),

          // ── Permissions ──
          const SectionLabel('Permissions'),
          ListGroup(
            children: [
              ListRow(
                title: 'App permissions',
                subtitle: permissionsGranted == null
                    ? 'Checking…'
                    : (permissionsGranted == permissionsTotal
                          ? 'Everything is allowed'
                          : (canTrack
                                ? 'Calls are tracked; some extras are off'
                                : 'Allow phone and call log access to track calls')),
                value: permissionsGranted == null
                    ? '—'
                    : '$permissionsGranted of $permissionsTotal allowed',
                valueColor: permissionsGranted == null
                    ? z.ink3
                    : (permissionsGranted == permissionsTotal
                          ? z.ok
                          : (canTrack ? z.warn : z.danger)),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PermissionScreen(),
                  ),
                ),
              ),
            ],
          ),

          // ── Application ──
          const SectionLabel('Application'),
          ListGroup(
            children: [
              // The only way in to the support screens. Employees never
              // need them, and a visible "Technical details" row invited
              // them into an engineering console. ListRow has no long-press,
              // so an outer InkWell takes it; the row's own InkWell has no
              // tap handler and stays out of the way.
              InkWell(
                onLongPress: () => _showSupportInfo(context),
                child: ListRow(title: 'Version', value: AppVersion.name),
              ),
              ListRow(
                title: 'About this app',
                onTap: () => _showAboutDialog(context),
              ),
            ],
          ),

          // ── Troubleshooting ──
          const SectionLabel('Troubleshooting'),
          ListGroup(
            children: [
              ListRow(
                title: 'Show the setup steps again',
                subtitle: 'Walk through the permissions once more',
                onTap: () => ref.read(onboardingProvider.notifier).reset(),
              ),
              const ListRow(
                title: 'Open Android settings',
                onTap: openAppSettings,
              ),
            ],
          ),

          const SizedBox(height: 32),

          // Footer
          Column(
            children: [
              const ExcludeSemantics(child: ZebuAppMark(size: 28)),
              const SizedBox(height: 10),
              Text(
                '${AppConfig.appName}, version ${AppVersion.name}',
                textAlign: TextAlign.center,
                style: AppType.tabular(
                  AppType.caption,
                ).copyWith(color: z.ink3),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// A dialog's single full-width dismiss button.
  List<Widget> _closeAction(BuildContext context, String label) => [
    ZButton(
      label: label,
      variant: ZButtonVariant.secondary,
      onPressed: () => Navigator.of(context).pop(),
    ),
  ];

  void _showProfileDialog(BuildContext context, Session? session) {
    if (session == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: _Avatar(initials: session.initials, size: 52),
        title: const Text('Your profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _dialogRow(context, 'Name', session.displayName),
            _dialogRow(context, 'Employee code', session.employeeId),
            // Shown only when known. Filling the gap with "Staff" or
            // "Representative" stated things about the user nobody had said.
            if (session.department != null)
              _dialogRow(context, 'Department', session.department!),
            if (session.role != null)
              _dialogRow(context, 'Role', session.role!),
            if (session.email != null)
              _dialogRow(context, 'Email', session.email!),
            if (session.phone != null)
              _dialogRow(context, 'Phone', session.phone!),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        actions: _closeAction(context, 'Close'),
      ),
    );
  }

  void _showPrivacyDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('How your call data is handled'),
        content: const Text(
          'Call details and any recordings are kept on this phone in encrypted '
          'storage until they reach your company server. They are sent over an '
          'encrypted connection, and each recording is checked on arrival so '
          'that a partial upload is never mistaken for a complete one. Only '
          'you and your administrators can see your calls, and every playback '
          'of a recording is written to an audit log.',
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        actions: _closeAction(context, 'Got it'),
      ),
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const ExcludeSemantics(child: ZebuAppMark(size: 52)),
        title: Text(AppConfig.appName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Logs your work calls and sends them to Zebu CRM.'),
            const SizedBox(height: 12),
            Text(
              'Version ${AppVersion.name}',
              style: AppType.tabular(
                AppType.caption,
              ).copyWith(color: context.z.ink3),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        actions: _closeAction(context, 'Close'),
      ),
    );
  }

  /// Support-only entry points, reached by long-pressing Version. Support
  /// staff talk the employee through this over the phone.
  void _showSupportInfo(BuildContext context) {
    void open(Widget screen) {
      Navigator.of(context)
        ..pop()
        ..push(MaterialPageRoute<void>(builder: (_) => screen));
    }

    // Shape, colour and drag handle come from the theme's bottom-sheet style.
    // BottomSafe lifts the rows above the system navigation bar.
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => BottomSafe(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTokens.gutter,
                0,
                AppTokens.gutter,
                12,
              ),
              child: Semantics(
                header: true,
                child: const Text('Support info', style: AppType.heading),
              ),
            ),
            ListGroup(
              children: [
                ListRow(title: 'Version', value: AppVersion.full),
                ListRow(
                  title: 'Technical details',
                  onTap: () => open(const DiagnosticsScreen()),
                ),
                ListRow(
                  title: 'Calls not sent yet',
                  onTap: () => open(const OutboxQueueScreen()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dialogRow(BuildContext context, String label, String value) {
    final z = context.z;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 108,
              child: Text(
                label,
                style: AppType.label.copyWith(
                  color: z.ink3,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: AppType.tabular(
                  AppType.smallStrong,
                ).copyWith(color: z.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }

}

/// The person's monogram on a solid Zebu-blue rounded square.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.initials, this.size = 56});

  final String initials;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: AppTokens.zebuBlue,
      // 18 at the 56px size, scaled with it.
      borderRadius: BorderRadius.circular(size * AppTokens.r18 / 56),
    ),
    child: ExcludeSemantics(
      child: Text(
        initials,
        style: AppType.heading.copyWith(
          color: AppTokens.onBrand,
          fontSize: size * 0.36,
          height: 1,
        ),
      ),
    ),
  );
}

/// The profile block at the top of Settings: monogram, name, employee code
/// and department, and the account's state. Opens "Your profile".
class _ProfileSummary extends StatelessWidget {
  const _ProfileSummary({required this.session, required this.onTap});

  final Session? session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = session;
    final meta = s == null
        ? 'Sign in to set up this phone'
        : (s.department == null
              ? 'Employee ${s.employeeId}'
              : 'Employee ${s.employeeId}, ${s.department}');

    return Semantics(
      button: s != null,
      child: InkWell(
        onTap: s == null ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.gutter,
            8,
            AppTokens.gutter,
            12,
          ),
          child: Row(
            children: [
              _Avatar(initials: s?.initials ?? 'ZB'),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s?.displayName ?? 'Not signed in',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.barTitle,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.tabular(
                        AppType.label,
                      ).copyWith(color: z.ink3, fontWeight: FontWeight.w400),
                    ),
                    if (s != null) ...[
                      const SizedBox(height: 4),
                      const _AccountStatus(),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The account's state in one word, from the same alerts the banners show.
///
/// It used to be the literal 'Active' whenever a session existed — including
/// on a phone the admin had revoked, beside a banner saying access was removed.
class _AccountStatus extends ConsumerWidget {
  const _AccountStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final alerts = ref.watch(syncAlertsProvider);
    final ids = alerts.map((a) => a.id).toSet();
    final (label, color) = ids.contains('blocked')
        ? ('Access removed', z.danger)
        : ids.contains('signed-out')
        ? ('Sign-in needed', z.danger)
        : alerts.any((a) => a.severity == SyncAlertSeverity.critical)
        ? ('Needs attention', z.warn)
        : ('Active', z.ok);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color: color, size: 7),
        const SizedBox(width: 6),
        Text(label, style: AppType.label.copyWith(color: color)),
      ],
    );
  }
}
