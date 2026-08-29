import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Emits [true] when the device has any network interface and [false] when
/// it is fully offline. Uses the platform broadcast — no polling, no timer.
///
/// The first emission reflects the current state at subscription time;
/// subsequent ones fire on change. Callers that need to react to the
/// offline → online transition should watch the previous value themselves
/// (see [HomeShell._onConnectivityChanged]).
final connectivityProvider = StreamProvider<bool>((ref) {
  return Connectivity()
      .onConnectivityChanged
      .map((results) => results.any((r) => r != ConnectivityResult.none));
});

/// One-shot read for the current connectivity state (avoids a round of
/// async setup in places that only need it once).
Future<bool> checkConnectivity() async {
  final results = await Connectivity().checkConnectivity();
  return results.any((r) => r != ConnectivityResult.none);
}
