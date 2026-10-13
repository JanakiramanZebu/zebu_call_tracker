import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/network/api_client.dart';
import 'core/network/api_client_provider.dart';
import 'core/network/connectivity_service.dart';
import 'core/notifications/notification_service.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/appearance.dart';
import 'core/theme/design_tokens.dart';
import 'features/auth/data/auth_controller.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/auth/presentation/splash_screen.dart';
import 'features/background/data/background_service.dart';
import 'features/call_logs/presentation/call_history_screen.dart';
import 'features/call_tracking/data/call_feed.dart';
import 'features/call_tracking/domain/call_entry.dart';
import 'features/call_tracking/presentation/call_detail_screen.dart';
import 'features/call_tracking/presentation/dashboard_screen.dart';
import 'features/permissions/presentation/permission_onboarding_screen.dart';
import 'features/post_call/data/post_call_event_provider.dart';
import 'features/synchronization/data/sync_service.dart';
import 'features/synchronization/presentation/sync_screen.dart';
import 'shared/widgets/ui_kit.dart';

class CallTrackerApp extends ConsumerWidget {
  const CallTrackerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
        title: AppConfig.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        // Settings → Appearance. System by default, so the app follows the
        // phone's own dark-mode switch.
        themeMode: ref.watch(appearanceProvider).themeMode,
        home: const AppGate(),
      );
}

/// Decides what is on screen: splash, login, first-run permissions, or the app.
class AppGate extends ConsumerWidget {
  const AppGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The server has refused this session and ApiClient has cleared it. Until
    // this listener existed the app carried on showing the signed-in shell
    // holding no credential, failing every request, until it was force-closed.
    // Rebuilding the controller re-reads storage, finds nothing, and routes to
    // sign-in; LoginScreen reads the reason and says why.
    ref.listen<SessionRevokedReason?>(sessionRevocationProvider, (_, next) {
      if (next != null) ref.invalidate(authControllerProvider);
    });

    final auth = ref.watch(authControllerProvider);

    final screen = auth.when(
      loading: () => const SplashScreen(key: ValueKey('splash')),
      error: (e, _) => SplashError(
        key: const ValueKey('splash-error'),
        error: e,
        onRetry: () => ref.invalidate(authControllerProvider),
      ),
      data: (session) {
        if (session == null) return const LoginScreen(key: ValueKey('login'));

        // Signed in. The walkthrough runs once per install — but finishing it
        // is not a promise that the permissions are still there. Android lets
        // the user revoke call-log access at any time afterwards, and the flag
        // below is a one-way `SharedPreferences` bool that cannot notice.
        // Before this check, revoking it left the user inside the app looking
        // at an empty dashboard with no explanation and no way back.
        return ref.watch(onboardingProvider).when(
              loading: () => const SplashScreen(key: ValueKey('splash-onb')),
              error: (_, _) => const PermissionOnboardingScreen(
                key: ValueKey('onboarding'),
              ),
              data: (done) {
                if (!done) {
                  return const PermissionOnboardingScreen(
                    key: ValueKey('onboarding'),
                  );
                }

                // Only divert on a KNOWN revocation. While the first read is in
                // flight the value is null, and treating that as "revoked"
                // would flash this screen on every cold start.
                final perms = ref.watch(permissionStatusProvider).value;
                final dismissed =
                    ref.watch(permissionRecoveryDismissedProvider);

                if (perms != null && perms.canTrack) {
                  // Access is back. Clear any earlier "carry on anyway" so a
                  // future revocation gates again instead of inheriting a
                  // decision made about a different situation. Guarded on
                  // `dismissed` so the common path schedules nothing.
                  if (dismissed) {
                    Future.microtask(
                      () => ref
                          .read(permissionRecoveryDismissedProvider.notifier)
                          .reset(),
                    );
                  }
                } else if (perms != null && !dismissed) {
                  return const PermissionOnboardingScreen(
                    key: ValueKey('permission-recovery'),
                    recovery: true,
                  );
                }

                return const HomeShell(key: ValueKey('home'));
              },
            );
      },
    );

    final dark = context.z.isDark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Edge to edge: both system bars are transparent and the app draws
      // behind them. Every screen pads itself clear of them (SafeAreaX in
      // ui_kit.dart), so no content sits under the status bar or nav buttons.
      // Icons follow the theme; the Home summary panel, which is brand blue in
      // both themes, sets light icons over itself.
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness:
            dark ? Brightness.light : Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: screen,
      ),
    );
  }
}

/// The tabs of [HomeShell], in display order.
enum HomeTab { home, calls, sync }

/// Which [HomeShell] tab is showing.
///
/// A provider rather than shell-local state so screens pushed on top of the
/// shell (Settings, a call's details) can send the user to a tab: pop back to
/// the root, then `ref.read(homeTabProvider.notifier).show(HomeTab.sync)`.
class HomeTabController extends Notifier<HomeTab> {
  @override
  HomeTab build() => HomeTab.home;

  void show(HomeTab tab) => state = tab;
}

final homeTabProvider =
    NotifierProvider<HomeTabController, HomeTab>(HomeTabController.new);

/// Three-tab shell with modern navigation bar.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  /// A resume sooner than this after the last catch-up skips the heavy work.
  /// The native side ingests and syncs on its own schedule; resume only has to
  /// bring the screens up to date, not race it.
  static const _catchUpInterval = Duration(seconds: 60);

  bool? _wasConnected;

  /// Set on a real `paused`. `inactive` alone (notification shade, the recents
  /// switcher, an incoming-call heads-up) does not leave the app, so a resume
  /// from it has nothing new to fetch.
  bool _wasPaused = false;
  DateTime? _lastCatchUp;
  Future<void>? _catchUpInFlight;

  /// Native's "a call row appeared" pings (WhatsApp calls). The call-log
  /// observer never fires for those, and a resume can land before the
  /// tracker has finished writing the row.
  StreamSubscription<void>? _callsChanged;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _callsChanged = ref
        .read(nativeBridgeProvider)
        .callsChangedStream()
        .listen(
          (_) {
            if (mounted) ref.read(callFeedProvider.notifier).refresh();
          },
          // No engine, or not Android: there is nothing to listen to.
          onError: (Object _) {},
        );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      await ref.read(backgroundControllerProvider.notifier).start();
      await _catchUp(force: true);
      if (!mounted) return;

      ref.listenManual<AsyncValue<bool>>(
        connectivityProvider,
        _onConnectivityChanged,
      );

      ref.listenManual<AsyncValue<PostCallNavigationEvent>>(
        postCallEventProvider,
        (_, next) {
          final event = next.asData?.value;
          if (event != null) _openCallFromOverlay(event);
        },
      );
    });
  }

  @override
  void dispose() {
    _callsChanged?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Ingests and hands off to the native uploader, then refreshes the call
  /// list — once.
  ///
  /// The single owner of this sequence. Launch, resume and reconnect each used
  /// to run their own copy, and a resume ran three ingests back to back, each
  /// one rewriting the table every watched query reads from.
  Future<void> _catchUp({bool force = false}) {
    final inFlight = _catchUpInFlight;
    if (inFlight != null) return inFlight;

    final last = _lastCatchUp;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _catchUpInterval) {
      return Future.value();
    }

    return _catchUpInFlight = () async {
      try {
        // triggerSync ingests before it hands off to the native coordinator.
        await ref.read(syncServiceProvider.notifier).triggerSync();
        if (!mounted) return;
        await ref.read(callFeedProvider.notifier).refresh();
        if (!mounted) return;
        // What native last did — its capture run, its upload — is read on
        // demand, and both have usually moved on by the time this returns.
        // Without it a stale "tracking paused" or "blocked" alert outlived
        // the run that fixed it until the next resume.
        ref
          ..invalidate(backgroundStatusProvider)
          ..invalidate(nativeSyncStatusProvider);
      } finally {
        _lastCatchUp = DateTime.now();
        _catchUpInFlight = null;
      }
    }();
  }

  void _onConnectivityChanged(
    AsyncValue<bool>? previous,
    AsyncValue<bool> next,
  ) {
    final isConnected = next.asData?.value;
    if (isConnected == null) return;

    final wasConnected = _wasConnected;
    _wasConnected = isConnected;

    if (isConnected && wasConnected == false) {
      if (mounted) _catchUp();
    } else if (!isConnected) {
      _maybeShowOfflineReminder();
    }
  }

  Future<void> _maybeShowOfflineReminder() async {
    if (!mounted) return;
    final counters = await ref.read(syncCountersProvider.future);
    final waiting = counters['waiting'] ?? 0;
    if (waiting > 0) {
      await NotificationService.instance.showSyncReminder(waiting);
    }
  }

  void _openCallFromOverlay(PostCallNavigationEvent event) {
    if (!mounted) return;

    final entries =
        ref.read(callFeedProvider).value?.entries ?? const <CallEntry>[];
    final match = entries.cast<CallEntry?>().firstWhere(
          (e) => e!.row.dateMillis == event.startedAtMillis,
          orElse: () => null,
        );

    if (match != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CallDetailScreen(entry: match),
        ),
      );
    } else {
      ref.read(homeTabProvider.notifier).show(HomeTab.calls);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        if (!mounted) return;
        // Android gives no broadcast when a permission is revoked, so resume
        // is the only reliable moment to re-read. Without this the snapshot
        // stayed as it was at launch: a user could turn call-log access off in
        // Android Settings, come straight back, and the app would carry on
        // showing a healthy dashboard that was no longer recording anything.
        //
        // Both consumers depend on it — the gate in AppGate, which diverts to
        // the recovery walkthrough, and the alert banner.
        ref
          ..invalidate(permissionStatusProvider)
          ..invalidate(backgroundStatusProvider);

        if (_wasPaused) {
          _wasPaused = false;
          // Back from a settings screen the alert sent them to: check now,
          // not after the usual interval.
          _catchUp(
            force: ref.read(syncServiceProvider.notifier).serverCheckRequested,
          );
        }
      case AppLifecycleState.paused:
        _wasPaused = true;
        // Hand the queue to the native worker so uploads carry on once the
        // app is backgrounded. Not on `inactive`: that fires for a pulled-down
        // notification shade, and each enqueue there replaced the upload
        // already running.
        //
        // Only when something is queued. Every pause used to wake the
        // coordinator, which spends a network round-trip finding an empty
        // queue. The counters are live (the Sync tab icon watches them); an
        // unknown value still hands off, since skipping a real backlog costs
        // more than one wasted run.
        final counters = ref.read(syncCountersProvider).value;
        final queued = counters == null ||
            (counters['waiting'] ?? 0) +
                    (counters['failed'] ?? 0) +
                    (counters['uploading'] ?? 0) >
                0;
        if (queued) {
          ref.read(nativeBridgeProvider).triggerNativeSync().ignore();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(homeTabProvider);

    return Scaffold(
      body: IndexedStack(
        index: tab.index,
        children: [
          // TickerMode stops hidden tabs' animations (skeleton shimmer,
          // spinners) from running every frame behind the visible one.
          TickerMode(
            enabled: tab == HomeTab.home,
            child: const DashboardScreen(),
          ),
          TickerMode(
            enabled: tab == HomeTab.calls,
            child: const CallHistoryScreen(),
          ),
          TickerMode(
            enabled: tab == HomeTab.sync,
            child: const SyncScreen(),
          ),
        ],
      ),
      bottomNavigationBar: _HomeNavBar(
        selected: tab,
        onSelected: (t) => ref.read(homeTabProvider.notifier).show(t),
      ),
    );
  }
}

/// The shell's bottom navigation.
///
/// Custom rather than [NavigationBar] for two reasons: the Material 3 bar
/// paints a pressed state layer over the destination (the app uses a ripple
/// only), and it sized its safe-area padding from a MediaQuery the app's own
/// edge-to-edge setup had already consumed on some launchers. This bar adds
/// the system navigation inset itself, so its labels always sit above the
/// gesture pill / three-button bar.
///
/// The selected tab is marked by a short accent rule along the bar's top edge
/// plus a heavier label — position and weight, not colour alone.
class _HomeNavBar extends StatelessWidget {
  const _HomeNavBar({required this.selected, required this.onSelected});

  final HomeTab selected;
  final ValueChanged<HomeTab> onSelected;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: z.navBg,
        border: Border(top: BorderSide(color: z.line)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 0, 8, 4 + bottom),
        child: Row(
          children: [
            _NavItem(
              label: 'Home',
              icon: Icons.home_outlined,
              selectedIcon: Icons.home_rounded,
              selected: selected == HomeTab.home,
              onTap: () => onSelected(HomeTab.home),
            ),
            _NavItem(
              label: 'Calls',
              icon: Icons.format_list_bulleted_rounded,
              selectedIcon: Icons.format_list_bulleted_rounded,
              selected: selected == HomeTab.calls,
              onTap: () => onSelected(HomeTab.calls),
            ),
            _NavItem(
              label: 'Sync',
              iconBuilder: (sel) => _SyncTabIcon(selected: sel),
              selected: selected == HomeTab.sync,
              onTap: () => onSelected(HomeTab.sync),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.selectedIcon,
    this.iconBuilder,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final IconData? selectedIcon;
  final Widget Function(bool selected)? iconBuilder;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final color = selected ? z.ink : z.ink3;

    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: '$label tab',
        excludeSemantics: true,
        child: InkResponse(
          onTap: onTap,
          highlightColor: Colors.transparent,
          splashColor: z.accent.withValues(alpha: 0.14),
          radius: 40,
          child: SizedBox(
            height: 62,
            child: Stack(
              alignment: Alignment.topCenter,
              children: [
                AnimatedContainer(
                  duration: AppTokens.fast,
                  curve: AppTokens.ease,
                  width: 28,
                  height: 3,
                  decoration: BoxDecoration(
                    color: selected ? z.accent : Colors.transparent,
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(3),
                    ),
                  ),
                ),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconTheme(
                      data: IconThemeData(color: color, size: 22),
                      child: iconBuilder?.call(selected) ??
                          Icon(selected ? selectedIcon : icon),
                    ),
                    const SizedBox(height: 4),
                    AnimatedDefaultTextStyle(
                      duration: AppTokens.fast,
                      style: AppType.caption.copyWith(
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                        color: color,
                      ),
                      child: Text(label),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Sync tab icon, badged only when calls could not be sent.
///
/// Its own widget so a change in the queue rebuilds this icon and nothing
/// else. A badge on every waiting call lit up after every single call — that
/// is the queue working normally, not something the user has to act on.
class _SyncTabIcon extends ConsumerWidget {
  const _SyncTabIcon({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = context.z;
    final failed = ref.watch(
      syncCountersProvider.select((a) => a.value?['failed'] ?? 0),
    );
    return Badge(
      isLabelVisible: failed > 0,
      backgroundColor: z.danger,
      textColor: Colors.white,
      textStyle: AppType.micro.copyWith(fontWeight: FontWeight.w700),
      label: Text(failed > 99 ? '99+' : '$failed'),
      child: Icon(
        Icons.sync_rounded,
        color: selected ? z.ink : z.ink3,
      ),
    );
  }
}
