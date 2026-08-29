import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/network/connectivity_service.dart';
import 'core/notifications/notification_service.dart';
import 'core/theme/app_theme.dart';
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
    themeMode: ThemeMode.system,
    home: const AppGate(),
  );
}

/// Decides what is on screen: splash, login, first-run permissions, or the app.
///
/// One place, driven by state rather than by imperative navigation. Sign-in and
/// sign-out do not push or pop anything — they change the session, and this
/// rebuilds. That rules out the usual class of bug where a back gesture returns
/// to a screen the user is no longer entitled to see.
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
        return ref
            .watch(onboardingProvider)
            .when(
              loading: () => const SplashScreen(key: ValueKey('splash-onb')),
              error: (_, _) =>
                  const PermissionOnboardingScreen(key: ValueKey('onboarding')),
              data: (done) => done
                  ? const HomeShell(key: ValueKey('home'))
                  : const PermissionOnboardingScreen(key: ValueKey('onboarding')),
            );
      },
    );

    // System chrome is set here rather than per screen. SystemChrome is
    // imperative underneath, so a value pushed by one screen's AnnotatedRegion
    // survives that screen being removed — which is how the splash's brand-blue
    // navigation bar leaked into the login screen.
    final isLight = Theme.of(context).brightness == Brightness.light;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
        statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: Theme.of(context).colorScheme.surface,
        systemNavigationBarIconBrightness: isLight
            ? Brightness.dark
            : Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: screen,
      ),
    );
  }
}

/// Four-tab shell. Each tab keeps its own navigation state via [IndexedStack],
/// so scrolling half way down the call list and stepping into Sync does not
/// throw that position away.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  int _index = 0;

  /// Tracks the previous connectivity state so we only sync on the
  /// offline → online transition, not on every emission.
  bool? _wasConnected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      // Initialize notifications on the first real frame.
      await NotificationService.instance.initialize();

      // Arm background ingest now that the user is signed in and past the
      // permission walkthrough. Deferred past the first frame so it does not
      // compete with the initial paint.
      final background = ref.read(backgroundControllerProvider.notifier);
      await background.start();
      await background.drain();
      await ref.read(syncServiceProvider.notifier).ingestNativeCallLogs();
      await ref.read(syncServiceProvider.notifier).triggerSync();
      ref.invalidate(syncCountersProvider);

      // Set up the connectivity listener for auto-sync.
      ref.listenManual<AsyncValue<bool>>(connectivityProvider, _onConnectivityChanged);

      // Set up the post-call overlay navigation listener.
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

  /// Fires whenever the network state changes.
  ///
  /// Only triggers a sync on the offline → online transition so we are not
  /// spamming the server every time the Riverpod provider re-emits the same
  /// "connected" value.
  void _onConnectivityChanged(
    AsyncValue<bool>? previous,
    AsyncValue<bool> next,
  ) {
    final isConnected = next.asData?.value;
    if (isConnected == null) return;

    final wasConnected = _wasConnected;
    _wasConnected = isConnected;

    if (isConnected && wasConnected == false) {
      // Just came back online — drain the outbox.
      _triggerAutoSync();
    } else if (!isConnected) {
      // Just went offline — show a reminder if there is pending data.
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

  /// Called when the user taps "View Details" on the post-call overlay.
  ///
  /// Tries to find the exact call entry by [startedAtMillis]. If the feed has
  /// it, navigates directly to [CallDetailScreen]. If not (the WorkManager
  /// reconcile hasn't run yet), switches to the Calls tab so the user can
  /// tap it once it appears.
  void _openCallFromOverlay(PostCallNavigationEvent event) {
    if (!mounted) return;

    final entries = ref.read(callFeedProvider).value?.entries ?? const <CallEntry>[];
    if (entries.isEmpty) {
      setState(() => _index = 1);
      return;
    }

    // Find the call by its start timestamp; fall back to the most recent one.
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
      // Reconcile hasn't run yet — switch to Calls tab.
      setState(() => _index = 1);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && mounted) {
      // Coming back to the app: fold in anything the background worker
      // captured, then try to push any queued data to the server.
      ref.read(backgroundControllerProvider.notifier).drain().then((_) {
        if (!mounted) return;
        ref.read(syncServiceProvider.notifier).ingestNativeCallLogs().then((_) {
          if (!mounted) return;
          ref.read(syncServiceProvider.notifier).triggerSync().then((_) {
            if (mounted) ref.invalidate(syncCountersProvider);
          });
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch sync counters so the badge rebuilds when the count changes.
    final countersAsync = ref.watch(syncCountersProvider);
    final waiting = countersAsync.asData?.value['waiting'] ?? 0;

    return Scaffold(
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
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart_rounded),
            label: 'Analytics',
          ),
          const NavigationDestination(
            icon: Icon(Icons.call_outlined),
            selectedIcon: Icon(Icons.call_rounded),
            label: 'Call History',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: waiting > 0,
              label: Text('$waiting'),
              child: const Icon(Icons.sync_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: waiting > 0,
              label: Text('$waiting'),
              child: const Icon(Icons.sync_rounded),
            ),
            label: 'Sync',
          ),
        ],
      ),
    );
  }
}