import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'core/notifications/notification_service.dart';
import 'features/background/data/background_sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Notification channels are created here so they exist before the first
  // foreground frame, which avoids a race with the background service posting
  // a notification before the plugin is initialised.
  await NotificationService.instance.initialize();
  
  Workmanager().initialize(
    callbackDispatcher, // The top level function
    isInDebugMode: false,
  );
  
  runApp(const ProviderScope(child: CallTrackerApp()));
}
