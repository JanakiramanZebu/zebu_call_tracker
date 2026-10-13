import 'package:flutter/material.dart';

import '../../../core/errors/user_facing_error.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../shared/widgets/brand.dart';
import '../../../shared/widgets/ui_kit.dart';

/// Shown while the stored session is being read back from secure storage.
///
/// The plain canvas, the official [ZebuAppMark] app icon tile at the centre,
/// the product name and a slim indeterminate progress bar. Nothing moves but
/// the bar: the screen is up for a moment, and a breathing logo only drew the
/// eye to the wait.
///
/// The system bars stay as the app shell sets them (transparent, edge to
/// edge); the content sits inside a [SafeArea].
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Scaffold(
      backgroundColor: z.canvas,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ZebuAppMark(size: 72),
              const SizedBox(height: 20),
              Text('Zebu Call Tracker', style: AppType.statement),
              const SizedBox(height: 24),

              // Slim indeterminate progress bar
              SizedBox(
                width: 120,
                child: LinearProgressIndicator(
                  minHeight: 3,
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                  color: z.accent,
                  backgroundColor: z.line,
                  semanticsLabel: 'Loading',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cold-start failure fallback widget
class SplashError extends StatelessWidget {
  const SplashError({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Scaffold(
      backgroundColor: z.canvas,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: SingleChildScrollView(
            padding: context.scrollPadding(top: 32, bottom: 32, horizontal: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const ZebuAppMark(size: 72),
                      // Small danger badge on the tile's corner: the app is
                      // fine, starting it is what failed.
                      Positioned(
                        right: -6,
                        bottom: -6,
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            color: z.danger,
                            shape: BoxShape.circle,
                            border: Border.all(color: z.canvas, width: 3),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.priority_high_rounded,
                            size: 14,
                            color: z.canvas,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Semantics(
                    header: true,
                    child: Text(
                      "Couldn't start the app",
                      textAlign: TextAlign.center,
                      style: AppType.statement,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    UserFacingError.from(error).message,
                    textAlign: TextAlign.center,
                    style: AppType.small.copyWith(color: z.ink2),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: 220,
                    child: ZButton(
                      label: 'Try again',
                      icon: Icons.refresh_rounded,
                      onPressed: onRetry,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
