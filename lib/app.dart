import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/network/api_client.dart';
import 'core/network/api_client_provider.dart';
import 'core/network/connectivity_service.dart';
import 'core/notifications/notification_service.dart';
import 'core/theme/app_theme.dart';
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

class CallTrackerApp extends StatelessWidget {
  const CallTrackerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: AppConfig.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.dark, // Dark-first 2026 intelligence UI
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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: AppTokens.bgPrimary,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: screen,
      ),
    );
  }
}

/// Three-tab shell with modern navigation bar.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  int _index = 0;
  bool? _wasConnected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      await NotificationService.instance.initialize();

      final background = ref.read(backgroundControllerProvider.notifier);
      await background.start();
      await background.drain();
      // triggerSync ingests before it hands off, and drain() already folded in
      // whatever the background worker captured. A third standalone ingest here
      // only re-walked the same call log.
      await ref.read(syncServiceProvider.notifier).triggerSync();
      ref.invalidate(syncCountersProvider);

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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
      _triggerAutoSync();
    } else if (!isConnected) {
      _maybeShowOfflineReminder();
    }
  }

  Future<void> _triggerAutoSync() async {
    if (!mounted) return;
    await ref.read(backgroundControllerProvider.notifier).drain();
    await ref.read(syncServiceProvider.notifier).ingestNativeCallLogs();
    await ref.read(syncServiceProvider.notifier).triggerSync();
    ref.invalidate(syncCountersProvider);
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
    if (entries.isEmpty) {
      setState(() => _index = 1);
      return;
    }

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
      setState(() => _index = 1);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && mounted) {
      // Android gives no broadcast when a permission is revoked, so resume is
      // the only reliable moment to re-read. Without this the snapshot stayed
      // as it was at launch: a user could turn call-log access off in Android
      // Settings, come straight back, and the app would carry on showing a
      // healthy dashboard that was no longer recording anything.
      //
      // Both consumers depend on it — the gate in AppGate, which diverts to the
      // recovery walkthrough, and the alert banner.
      ref
        ..invalidate(permissionStatusProvider)
        ..invalidate(backgroundStatusProvider);

      ref.read(backgroundControllerProvider.notifier).drain().then((_) {
        if (!mounted) return;
        ref.read(syncServiceProvider.notifier).ingestNativeCallLogs().then((_) {
          if (!mounted) return;
          ref.read(syncServiceProvider.notifier).triggerSync().then((_) {
            if (mounted) ref.invalidate(syncCountersProvider);
          });
        });
      });
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // Trigger native expedited worker so upload continues uninterrupted when closed/backgrounded
      try {
        ref.read(nativeBridgeProvider).triggerNativeSync();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final countersAsync = ref.watch(syncCountersProvider);
    final waiting = countersAsync.asData?.value['waiting'] ?? 0;

    return Scaffold(
      backgroundColor: AppTokens.bgPrimary,
      body: IndexedStack(
        index: _index,
        children: [
          DashboardScreen(
            onSeeAllCalls: () => setState(() => _index = 1),
            pendingSyncCount: waiting,
          ),
          const CallHistoryScreen(),
          const SyncScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppTokens.bgPrimary,
          border: Border(
            top: BorderSide(color: AppTokens.borderSubtle, width: 1),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          backgroundColor: AppTokens.bgPrimary,
          elevation: 0,
          indicatorColor: AppTokens.brandElectric.withValues(alpha: 0.16),
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.analytics_outlined),
              selectedIcon: Icon(Icons.analytics_rounded, color: AppTokens.brandElectric),
              label: 'Analytics',
            ),
            const NavigationDestination(
              icon: Icon(Icons.call_outlined),
              selectedIcon: Icon(Icons.call_rounded, color: AppTokens.brandElectric),
              label: 'Calls',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: waiting > 0,
                backgroundColor: AppTokens.warning,
                textColor: Colors.black,
                textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 10),
                label: Text(waiting > 999 ? '999+' : '$waiting'),
                child: const Icon(Icons.sync_rounded),
              ),
              selectedIcon: Badge(
                isLabelVisible: waiting > 0,
                backgroundColor: AppTokens.warning,
                textColor: Colors.black,
                textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 10),
                label: Text(waiting > 999 ? '999+' : '$waiting'),
                child: const Icon(Icons.sync_rounded, color: AppTokens.brandElectric),
              ),
              label: 'Sync',
            ),
          ],
        ),
      ),
    );
  }
}