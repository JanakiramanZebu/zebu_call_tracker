import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/notifications/notification_service.dart';
import '../../synchronization/data/sync_service.dart';
import 'background_service.dart';

const String backgroundSyncTaskName = "sync_calls_task";

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    await NotificationService.instance.initialize();
    
    final container = ProviderContainer();
    
    try {
      final bgNotifier = container.read(backgroundControllerProvider.notifier);
      await bgNotifier.drain();

      final syncNotifier = container.read(syncServiceProvider.notifier);
      await syncNotifier.ingestNativeCallLogs();
      await syncNotifier.triggerSync();
      return Future.value(true);
    } catch (err) {
      // If sync fails due to network, workmanager can retry based on policy.
      return Future.value(false);
    } finally {
      container.dispose();
    }
  });
}

