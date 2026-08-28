import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/brand.dart';

/// Shown while the stored session is being read back from secure storage.
///
/// Deliberately identical to `res/drawable/launch_background.xml` — brand blue
/// with the mark at the same size — so the hand-off from the OS window to the
/// first Flutter frame is invisible. Anything else produces a flash of a
/// different colour on every cold start.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    // Brand blue is dark, so the status bar icons must be light regardless of
    // the device theme.
    value: SystemUiOverlayStyle.light.copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: AppColors.brand,
    ),
    child: Scaffold(
      backgroundColor: AppColors.brand,
      body: Stack(
        children: [
          const Center(child: ZebuMark(size: 84, color: Colors.white)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 56,
            child: Column(
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    message!,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Cold-start failure: secure storage or the platform channel refused. Rare,
/// but a blue screen that never resolves is the worst possible outcome, so
/// there is always a way out.
class SplashError extends StatelessWidget {
  const SplashError({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.brand,
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ZebuMark(size: 56, color: Colors.white),
            const SizedBox(height: 28),
            const Text(
              'Could not start',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: 200,
              child: FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.brand,
                ),
                child: const Text('Try again'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
