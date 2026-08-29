import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract final class _Ch {
  static const syncReminder = 'sync_reminder';
  static const syncStatus = 'sync_status';
}

abstract final class _Id {
  static const reminder = 1001;
  static const success = 1002;
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> initialize() async {
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
        'Sync reminders',
        description: 'Reminds you to sync call data when offline.',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
      ),
    );
    await platform.createNotificationChannel(
      const AndroidNotificationChannel(
        _Ch.syncStatus,
        'Sync status',
        description: 'Confirms when calls and recordings are uploaded.',
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
      'Sync pending',
      '$pendingCount ${pendingCount == 1 ? 'call' : 'calls'} waiting to upload — connect to sync automatically.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _Ch.syncReminder,
          'Sync reminders',
          channelDescription: 'Reminds you to sync call data when offline.',
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

  Future<void> showSyncSuccess({
    required int syncedCalls,
    required int uploadedRecordings,
  }) async {
    if (!_ready) return;
    if (syncedCalls == 0 && uploadedRecordings == 0) return;
    final body = StringBuffer();
    if (syncedCalls > 0) {
      body.write('$syncedCalls ${syncedCalls == 1 ? 'call' : 'calls'} uploaded');
    }
    if (uploadedRecordings > 0) {
      if (body.isNotEmpty) body.write(' · ');
      body.write('$uploadedRecordings ${uploadedRecordings == 1 ? 'recording' : 'recordings'}');
    }
    await _plugin.show(
      _Id.success,
      'Sync complete',
      body.toString(),
      NotificationDetails(
        android: AndroidNotificationDetails(
          _Ch.syncStatus,
          'Sync status',
          channelDescription: 'Confirms when calls and recordings are uploaded.',
          importance: Importance.low,
          priority: Priority.low,
          onlyAlertOnce: true,
          icon: '@mipmap/ic_launcher',
          color: const Color(0xFF6750A4),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: false,
          presentBadge: false,
          presentSound: false,
        ),
      ),
    );
  }

  Future<void> cancelSyncReminder() async {
    if (!_ready) return;
    await _plugin.cancel(_Id.reminder);
  }

  Future<bool> isReminderVisible() async {
    if (!_ready) return false;
    final active = await _plugin.getActiveNotifications();
    return active.any((n) => n.id == _Id.reminder);
  }
}

final notificationServiceProvider = Provider<NotificationService>(
  (_) => NotificationService.instance,
);
