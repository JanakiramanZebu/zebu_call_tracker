import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

abstract final class _Ch {
  static const syncReminder = 'sync_reminder';

  /// Posted to by the native workers; created here too so its name and
  /// description match whichever side runs first. Keep the text in step with
  /// the Kotlin side.
  static const syncProgress = 'sync_progress';
}

abstract final class _Id {
  static const reminder = 1001;
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Future<void>? _initializing;

  /// Safe to call more than once: later calls wait on the first.
  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(android: android, iOS: ios);
    await _plugin.initialize(settings);
    await _ensureChannels();
    _ready = true;
  }

  Future<void> _ensureChannels() async {
    final platform = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (platform == null) return;
    await platform.createNotificationChannel(
      const AndroidNotificationChannel(
        _Ch.syncReminder,
        'Unsent calls',
        description: 'Tells you when calls are waiting for a connection.',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      ),
    );
    await platform.createNotificationChannel(
      const AndroidNotificationChannel(
        _Ch.syncProgress,
        'Sending progress',
        description: 'Shows while calls are being sent.',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      ),
    );
  }

  Future<void> showSyncReminder(int pendingCount) async {
    if (!_ready) return;
    await _plugin.show(
      _Id.reminder,
      'Waiting for internet',
      '$pendingCount ${pendingCount == 1 ? 'call' : 'calls'} not sent yet – '
          "they'll send when you're back online.",
      NotificationDetails(
        android: AndroidNotificationDetails(
          _Ch.syncReminder,
          'Unsent calls',
          channelDescription:
              'Tells you when calls are waiting for a connection.',
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          icon: '@mipmap/ic_launcher',
          color: const Color(0xFF6750A4),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: false,
        ),
      ),
    );
  }
}
