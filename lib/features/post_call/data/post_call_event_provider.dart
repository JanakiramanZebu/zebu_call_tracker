import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../call_tracking/data/call_feed.dart';


/// Emitted when the user taps "View Details" on the post-call overlay card.
///
/// [startedAtMillis] is the epoch-ms timestamp of the call start, matching the
/// `dateMillis` field in [CallLogRow]. HomeShell uses this to find the entry in
/// the loaded feed and push [CallDetailScreen].
class PostCallNavigationEvent {
  const PostCallNavigationEvent(this.startedAtMillis);
  final int startedAtMillis;
}

/// Streams [PostCallNavigationEvent] from the native overlay EventChannel.
///
/// `.autoDispose` so the stream subscription is cancelled when the HomeShell
/// disposes, preventing the channel from holding a stale sink reference.
final postCallEventProvider =
    StreamProvider.autoDispose<PostCallNavigationEvent>((ref) {
  final bridge = ref.watch(nativeBridgeProvider);
  return bridge
      .overlayEventStream()
      .map((e) => PostCallNavigationEvent(
            (e['startedAtMillis'] as num?)?.toInt() ?? 0,
          ));
});