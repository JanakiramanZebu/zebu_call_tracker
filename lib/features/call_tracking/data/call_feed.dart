import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../../core/storage/database_providers.dart';
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
    // Notifications are not in the native inspector's remit: POST_NOTIFICATIONS
    // does not exist below API 33, and permission_handler already reports
    // "granted" there. Checking status never raises a dialog.
    final notifications = await Permission.notification.isGranted;
    final overlay = await bridge.checkOverlayPermission();
    return PermissionSnapshot(
      readPhoneState: calls['readPhoneState'] ?? false,
      readCallLog: calls['readCallLog'] ?? false,
      readContacts: calls['readContacts'] ?? false,
      readMediaAudio: recordings.granted,
      mediaPermissionName: recordings.permission,
      notifications: notifications,
      overlayWindow: overlay,
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
    required this.notifications,
    this.overlayWindow = false,
  });

  final bool readPhoneState;
  final bool readCallLog;
  final bool readContacts;
  final bool readMediaAudio;
  final String mediaPermissionName;
  final bool notifications;

  /// SYSTEM_ALERT_WINDOW — for the post-call overlay card.
  /// Defaults to false so existing call sites do not break.
  final bool overlayWindow;

  /// Call log is the only hard requirement — everything else degrades.
  bool get canTrack => readCallLog;

  int get grantedCount => [
    readPhoneState && readCallLog,
    readContacts,
    readMediaAudio,
    notifications,
    overlayWindow,
  ].where((g) => g).length;

  /// One per entry in `permissionAsks`; the phone/call-log pair counts as one
  /// ask because the user is shown one card for it.
  static const total = 5;
}

/// The call feed: log rows joined to whatever recording matched them.
///
/// Paged deliberately. The reference device holds 2000 call-log rows and 1863
/// recordings; loading either in full would stall the first frame and pin tens
/// of megabytes for a list that shows twenty items.
class CallFeed extends AsyncNotifier<CallFeedState> {
  static const _pageSize = 60;
  static const _recordingPoolSize = 400;

  /// Scanned once and reused for the life of the notifier.
  ///
  /// MediaStore is queried on the *first* page only. Re-scanning per page cost
  /// a full media query for every twenty rows the user scrolled past, for a
  /// pool that barely changes while a list is open. `refresh()` rebuilds it.
  List<RecordingCandidate> _pool = const [];
  bool _poolLoaded = false;

  @override
  Future<CallFeedState> build() => _load(previous: const []);

  /// Loads one page of rows older than [beforeMillis].
  ///
  /// Keyset pagination, not offset: the call log can gain rows between pages,
  /// and an offset would silently skip or repeat entries when it does. Passing
  /// the oldest timestamp already held also means each row is read from the
  /// provider exactly once across the whole scroll, instead of the previous
  /// re-read-everything-and-discard-the-prefix approach.
  Future<CallFeedState> _load({
    required List<CallEntry> previous,
    int beforeMillis = 0,
  }) async {
    final bridge = ref.read(nativeBridgeProvider);
    final matcher = ref.read(recordingMatcherProvider);
    final perms = await ref.read(permissionStatusProvider.future);

    if (!perms.canTrack) {
      return const CallFeedState(entries: [], hasMore: false, blocked: true);
    }

    final rows = await bridge.readCallLog(
      sinceMillis: 0,
      beforeMillis: beforeMillis,
      limit: _pageSize,
    );

    if (!_poolLoaded) {
      _pool = perms.readMediaAudio
          ? await bridge.scanRecordings(
              sinceEpochSeconds: 0,
              limit: _recordingPoolSize,
            )
          : const <RecordingCandidate>[];
      _poolLoaded = true;
    }

    // One platform round-trip for the whole page. Resolving per row meant a
    // channel hop and a PhoneLookup query for each of sixty rows before the
    // page could paint; the native side also caches, so repeat callers — most
    // of a real call log — cost nothing on later pages.
    final names = perms.readContacts
        ? await bridge.resolveContacts([
            for (final r in rows)
              if (r.number != null && r.number!.isNotEmpty) r.number!,
          ])
        : const <String, String>{};

    final dao = ref.read(callsDaoProvider);
    const uuid = Uuid();
    const dnsNamespace = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

    final validRows = rows.where((r) => r.dateMillis != null).toList();
    final keys = validRows.map((r) {
      final date = DateTime.fromMillisecondsSinceEpoch(r.dateMillis!).toUtc();
      final extId = 'android-${r.dateMillis}-${r.number}';
      return uuid.v5(dnsNamespace, 'zebu:call:$extId:${date.millisecondsSinceEpoch}');
    }).toList();

    final localCalls = await dao.findByIdempotencyKeys(keys);
    final localCallMap = {for (final lc in localCalls) lc.idempotencyKey: lc};

    final entries = <CallEntry>[];
    for (int i = 0; i < validRows.length; i++) {
      final row = validRows[i];
      final key = keys[i];
      final localCall = localCallMap[key];

      final name = row.number == null ? null : names[row.number!];
      final match = matcher.match(
        CallForMatching(
          startedAtEpochMillis: row.dateMillis!,
          durationSeconds: row.durationSeconds ?? 0,
          normalizedNumber: row.number,
          contactName: name ?? row.cachedName,
        ),
        _pool,
      );

      UploadState state = UploadState.pending;
      if (localCall != null) {
        if (localCall.syncState == 'synced') {
          state = UploadState.uploaded;
        } else if (localCall.syncState == 'failed_permanent' || localCall.syncState == 'failed_retryable') {
          state = UploadState.failed;
        } else if (localCall.syncState == 'uploading') {
          state = UploadState.uploading;
        }
      }

      entries.add(CallEntry(row: row, match: match, uploadState: state, contactName: name));
    }

    return CallFeedState(
      entries: [...previous, ...entries],
      // A short page means the provider had nothing more to give, which is a
      // reliable end-of-list signal now that each page is a bounded query.
      hasMore: rows.length >= _pageSize,
      recordingPoolSize: _pool.length,
    );
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;

    // The oldest row already held is the cursor for the next page. Null-safe
    // because a row without a timestamp is skipped during load and so can
    // never be the last entry.
    final cursor = current.entries.isEmpty
        ? 0
        : current.entries.last.row.dateMillis ?? 0;

    state = AsyncData(current.copyWith(loadingMore: true));
    state = await AsyncValue.guard(
      () => _load(previous: current.entries, beforeMillis: cursor),
    );
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      ref.invalidate(permissionStatusProvider);
      // A pull-to-refresh is the user saying the device state changed, so the
      // recording pool is rebuilt rather than reused.
      _poolLoaded = false;
      return _load(previous: const []);
    });
  }
}

class CallFeedState {
  const CallFeedState({
    required this.entries,
    required this.hasMore,
    this.loadingMore = false,
    this.blocked = false,
    this.recordingPoolSize = 0,
  });

  final List<CallEntry> entries;
  final bool hasMore;
  final bool loadingMore;

  /// True when the call-log permission is missing, so the UI can explain rather
  /// than render an empty list that looks like "no calls".
  final bool blocked;

  final int recordingPoolSize;

  CallFeedState copyWith({bool? loadingMore}) => CallFeedState(
    entries: entries,
    hasMore: hasMore,
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

enum DashboardPeriod { today, yesterday, week, month }

class DashboardPeriodController extends Notifier<DashboardPeriod> {
  @override
  DashboardPeriod build() => DashboardPeriod.yesterday;

  void select(DashboardPeriod period) => state = period;
}

final dashboardPeriodProvider =
    NotifierProvider<DashboardPeriodController, DashboardPeriod>(
  DashboardPeriodController.new,
);

class PeriodRangeInfo {
  const PeriodRangeInfo({
    required this.start,
    required this.end,
    required this.formattedRange,
  });

  final DateTime start;
  final DateTime end;
  final String formattedRange;
}

final periodRangeInfoProvider = Provider<PeriodRangeInfo>((ref) {
  final period = ref.watch(dashboardPeriodProvider);
  final now = DateTime.now();
  final startOfToday = DateTime(now.year, now.month, now.day);
  final endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59);

  final (start, end) = switch (period) {
    DashboardPeriod.today => (startOfToday, endOfToday),
    DashboardPeriod.yesterday => (
        startOfToday.subtract(const Duration(days: 1)),
        DateTime(now.year, now.month, now.day - 1, 23, 59, 59),
      ),
    DashboardPeriod.week => (
        startOfToday.subtract(Duration(days: (now.weekday - 1).clamp(0, 6))),
        endOfToday,
      ),
    DashboardPeriod.month => (DateTime(now.year, now.month, 1), endOfToday),
  };

  final dateFormat = DateFormat('dd-MMM-yyyy hh:mm a');
  final formatted =
      '${dateFormat.format(start)} - ${dateFormat.format(end)}';

  return PeriodRangeInfo(
    start: start,
    end: end,
    formattedRange: formatted,
  );
});

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

/// Local period aggregates for the dashboard computed directly
/// from local database call records within the active range.
final periodStatsProvider = Provider<CallStats>((ref) {
  final feed = ref.watch(callFeedProvider).value;
  if (feed == null) return CallStats.empty;

  final rangeInfo = ref.watch(periodRangeInfoProvider);

  return CallStats.from(
    feed.entries.where((e) {
      final local = e.startedAtUtc?.toLocal();
      if (local == null) return false;
      return !local.isBefore(rangeInfo.start) && !local.isAfter(rangeInfo.end);
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
