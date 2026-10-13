import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/app_version.dart';
import 'core/notifications/notification_service.dart';
import 'core/theme/appearance.dart';

Future<void> main() async {
  // Release builds log nothing: several debugPrint sites carry phone numbers
  // or server errors, and logcat is readable by anyone with a USB cable.
  if (kReleaseMode) debugPrint = (String? message, {int? wrapWidth}) {};

  WidgetsFlutterBinding.ensureInitialized();

  // Draw behind the status and navigation bars on every Android version, not
  // only on 15+ where it is forced. One layout model everywhere: the screens
  // pad themselves clear of the system bars (see SafeAreaX in ui_kit.dart).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // The bundled IBM Plex Sans font is SIL OFL, which asks for its licence to
  // ship with the app; this puts it on Flutter's licence page.
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/fonts/LICENSE.txt');
    yield LicenseEntryWithLineBreaks(const ['IBM Plex Sans'], license);
  });

  await Future.wait([
    // Before anything can report a version to the server or the user. Cheap,
    // and it removes the last reason to keep a version literal anywhere else.
    AppVersion.initialize(),
    // Notification channels are created here so they exist before the first
    // foreground frame, which avoids a race with the background service
    // posting a notification before the plugin is initialised.
    NotificationService.instance.initialize(),
    // The saved Light/Dark/System choice, so the first frame is already in
    // the right theme.
    AppearanceController.preload(),
  ]);

  runApp(const ProviderScope(child: CallTrackerApp()));
}
