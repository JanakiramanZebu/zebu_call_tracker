import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
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

        // Signed in: the permission walkthrough runs once per install.
        return ref.watch(onboardingProvider).when(
              loading: () => const SplashScreen(key: ValueKey('splash-onb')),
              error: (_, _) => const PermissionOnboardingScreen(
                key: ValueKey('onboarding'),
              ),
              data: (done) => done
                  ? const HomeShell(key: ValueKey('home'))
                  : const PermissionOnboardingScreen(
                      key: ValueKey('onboarding'),
                    ),
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
      await ref.read(syncServiceProvider.notifier).ingestNativeCallLogs();
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