import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/notifications/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Notification channels are created here so they exist before the first
  // foreground frame, which avoids a race with the background service posting
  // a notification before the plugin is initialised.
  await NotificationService.instance.initialize();
  
  runApp(const ProviderScope(child: CallTrackerApp()));
}
