import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/data/auth_controller.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/auth/presentation/splash_screen.dart';
import 'features/background/data/background_service.dart';
import 'features/call_logs/presentation/call_history_screen.dart';
import 'features/call_tracking/presentation/dashboard_screen.dart';
import 'features/permissions/presentation/permission_onboarding_screen.dart';
import 'features/settings/presentation/settings_screen.dart';
import 'features/synchronization/presentation/sync_screen.dart';

class CallTrackerApp extends StatelessWidget {
  const CallTrackerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: AppConfig.appName,
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    // Follows the device. Field staff work in varied light and the palette
    // is defined for both, so there is no reason to force one.
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

        // Signed in: the permission walkthrough runs once per install. Its own
        // provider is async (SharedPreferences), so hold the splash rather than
        // flashing the walkthrough at a user who finished it months ago.
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
    // navigation bar leaked into the login screen. Declaring the app-wide style
    // at the root means every screen without an opinion gets the right one, and
    // the splash's own region simply nests inside and wins while it is shown.
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
      // A cross-fade rather than a page transition: these are swaps of the whole
      // app surface, not steps in a stack, and a slide would imply a back
      // gesture that does not exist.
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Background ingest is armed here rather than at launch: reaching this
    // screen means the user is signed in and past the walkthrough, so calls
    // captured from now on belong to a known employee record.
    //
    // Deferred past the first frame so neither the WorkManager enqueue nor the
    // drain competes with building the dashboard.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final background = ref.read(backgroundControllerProvider.notifier);
      await background.start();
      await background.drain();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Coming back to the app is the moment anything captured while it was
    // closed should appear. `drain` is a no-op when the worker captured
    // nothing, so this is cheap on a resume that follows a quick app switch.
    if (state == AppLifecycleState.resumed && mounted) {
      ref.read(backgroundControllerProvider.notifier).drain();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          DashboardScreen(onSeeAllCalls: () => setState(() => _index = 1)),
          const CallHistoryScreen(),
          const SyncScreen(),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.call_outlined),
            selectedIcon: Icon(Icons.call_rounded),
            label: 'Calls',
          ),
          NavigationDestination(
            icon: Icon(Icons.sync_outlined),
            selectedIcon: Icon(Icons.sync_rounded),
            label: 'Sync',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
