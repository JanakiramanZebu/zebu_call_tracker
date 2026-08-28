import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../recording/domain/recording_matcher.dart';
import '../domain/call_entry.dart';

final nativeBridgeProvider = Provider<NativeCallBridge>(
  (ref) => MethodChannelNativeCallBridge(),
);

final recordingMatcherProvider = Provider<RecordingMatcher>(
  (ref) => const RecordingMatcher(),
);

/// Runtime permission state, refreshed on demand rather than watched — Android
/// gives no change notification, so polling would just burn battery.
final permissionStatusProvider = FutureProvider.autoDispose<PermissionSnapshot>(
  (ref) async {
    final bridge = ref.watch(nativeBridgeProvider);
    final calls = await bridge.getPermissionStatus();
    final recordings = await bridge.getRecordingAccess();
    return PermissionSnapshot(
      readPhoneState: calls['readPhoneState'] ?? false,
      readCallLog: calls['readCallLog'] ?? false,
      readContacts: calls['readContacts'] ?? false,
      readMediaAudio: recordings.granted,
      mediaPermissionName: recordings.permission,
    );
  },
);

class PermissionSnapshot {
  const PermissionSnapshot({
    required this.readPhoneState,
    required this.readCallLog,
    required this.readContacts,
    required this.readMediaAudio,
    required this.mediaPermissionName,
  });

  final bool readPhoneState;
  final bool readCallLog;
  final bool readContacts;
  final bool readMediaAudio;
  final String mediaPermissionName;

  /// Call log is the only hard requirement — everything else degrades.
  bool get canTrack => readCallLog;

  int get grantedCount => [
    readPhoneState,
    readCallLog,
    readContacts,
    readMediaAudio,
  ].where((g) => g).length;

  static const total = 4;
}

/// The call feed: log rows joined to whatever recording matched them.
///
/// Paged deliberately. The reference device holds 2000 call-log rows and 1863
/// recordings; loading either in full would stall the first frame and pin tens
/// of megabytes for a list that shows twenty items.
class CallFeed extends AsyncNotifier<CallFeedState> {
  static const _pageSize = 60;
  static const _recordingPoolSize = 400;

  @override
  Future<CallFeedState> build() => _load(page: 0, previous: const []);

  Future<CallFeedState> _load({
    required int page,
    required List<CallEntry> previous,
  }) async {
    final bridge = ref.read(nativeBridgeProvider);
    final matcher = ref.read(recordingMatcherProvider);
    final perms = await ref.read(permissionStatusProvider.future);

    if (!perms.canTrack) {
      return const CallFeedState(entries: [], hasMore: false, blocked: true);
    }

    // Page by timestamp, not offset: the call log can gain rows between pages,
    // and an offset would silently skip or repeat entries when it does.
    final since = 0;
    final rows = await bridge.readCallLog(
      sinceMillis: since,
      limit: _pageSize * (page + 1),
    );

    // The recording pool is scanned once and reused across pages. Matching is
    // pure and cheap; re-scanning MediaStore per page would not be.
    final pool = perms.readMediaAudio
        ? await bridge.scanRecordings(
            sinceEpochSeconds: 0,
            limit: _recordingPoolSize,
          )
        : const <RecordingCandidate>[];

    final entries = <CallEntry>[];
    for (final row in rows.skip(previous.length)) {
      if (row.dateMillis == null) continue;

      final name = perms.readContacts && row.number != null
          ? await bridge.resolveContact(row.number!)
          : null;

      final match = matcher.match(
        CallForMatching(
          startedAtEpochMillis: row.dateMillis!,
          durationSeconds: row.durationSeconds ?? 0,
          normalizedNumber: row.number,
          contactName: name ?? row.cachedName,
        ),
        pool,
      );

      entries.add(CallEntry(row: row, match: match, contactName: name));
    }

    final all = [...previous, ...entries];
    return CallFeedState(
      entries: all,
      hasMore: rows.length >= _pageSize * (page + 1),
      page: page,
      recordingPoolSize: pool.length,
    );
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;

    state = AsyncData(current.copyWith(loadingMore: true));
    final next = await _load(page: current.page + 1, previous: current.entries);
    state = AsyncData(next);
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      ref.invalidate(permissionStatusProvider);
      return _load(page: 0, previous: const []);
    });
  }
}

class CallFeedState {
  const CallFeedState({
    required this.entries,
    required this.hasMore,
    this.page = 0,
    this.loadingMore = false,
    this.blocked = false,
    this.recordingPoolSize = 0,
  });

  final List<CallEntry> entries;
  final bool hasMore;
  final int page;
  final bool loadingMore;

  /// True when the call-log permission is missing, so the UI can explain rather
  /// than render an empty list that looks like "no calls".
  final bool blocked;

  final int recordingPoolSize;

  CallFeedState copyWith({bool? loadingMore}) => CallFeedState(
    entries: entries,
    hasMore: hasMore,
    page: page,
    loadingMore: loadingMore ?? this.loadingMore,
    blocked: blocked,
    recordingPoolSize: recordingPoolSize,
  );

  /// Entries grouped into day buckets, newest first, for sectioned lists.
  List<(String heading, List<CallEntry> calls)> get grouped {
    final out = <(String, List<CallEntry>)>[];
    String? current;
    var bucket = <CallEntry>[];

    for (final e in entries) {
      final utc = e.startedAtUtc;
      if (utc == null) continue;
      final heading = _headingFor(utc);
      if (heading != current) {
        if (current != null) out.add((current, bucket));
        current = heading;
        bucket = [];
      }
      bucket.add(e);
    }
    if (current != null && bucket.isNotEmpty) out.add((current, bucket));
    return out;
  }

  static String _headingFor(DateTime utc) {
    final local = utc.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final delta = today.difference(day).inDays;
    if (delta == 0) return 'Today';
    if (delta == 1) return 'Yesterday';
    return '${day.day}/${day.month}/${day.year}';
  }
}

final callFeedProvider = AsyncNotifierProvider<CallFeed, CallFeedState>(
  CallFeed.new,
);

/// Today's aggregates for the dashboard.
final todayStatsProvider = Provider<CallStats>((ref) {
  final feed = ref.watch(callFeedProvider).value;
  if (feed == null) return CallStats.empty;

  final now = DateTime.now();
  final startOfToday = DateTime(now.year, now.month, now.day);
  return CallStats.from(
    feed.entries.where((e) {
      final local = e.startedAtUtc?.toLocal();
      return local != null && !local.isBefore(startOfToday);
    }),
  );
});

/// Device identity for the settings and detail screens.
final deviceInfoProvider = FutureProvider<Map<String, Object?>>(
  (ref) => ref.watch(nativeBridgeProvider).getDeviceInfo(),
);

final simInfoProvider = FutureProvider<SimInfo>(
  (ref) => ref.watch(nativeBridgeProvider).getSimInfo(),
);
