import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's theme choice in Settings → Appearance.
enum Appearance {
  system('System'),
  dark('Dark'),
  light('Light');

  const Appearance(this.label);

  final String label;

  ThemeMode get themeMode => switch (this) {
    Appearance.system => ThemeMode.system,
    Appearance.dark => ThemeMode.dark,
    Appearance.light => ThemeMode.light,
  };
}

/// Holds and persists [Appearance].
///
/// The stored value is read once in `main()` through [preload], before the
/// first frame, so a user who picked Light never sees a dark first frame.
///
/// Stored under `appearance` in the plugin's SharedPreferences file. The native
/// post-call card reads the same key (`flutter.appearance` in
/// `FlutterSharedPreferences`) so it matches the app; renaming it breaks that.
class AppearanceController extends Notifier<Appearance> {
  static const prefsKey = 'appearance';

  static Appearance _initial = Appearance.system;

  /// Reads the saved choice. Never throws: a storage failure leaves System.
  static Future<void> preload() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _initial =
          Appearance.values.asNameMap()[prefs.getString(prefsKey)] ??
          Appearance.system;
    } catch (_) {
      _initial = Appearance.system;
    }
  }

  @override
  Appearance build() => _initial;

  Future<void> select(Appearance value) async {
    if (value == state) return;
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, value.name);
    } catch (_) {
      // The choice still applies for this session.
    }
  }
}

final appearanceProvider = NotifierProvider<AppearanceController, Appearance>(
  AppearanceController.new,
);
