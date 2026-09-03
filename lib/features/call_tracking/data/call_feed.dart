import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/storage/database_providers.dart';
import '../../../core/storage/sync_state.dart';
import '../../../core/network/call_wire_format.dart';
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

  /// Counted against [total], which must stay in step with `permissionAsks`.
  ///
  /// Background activity is included because the walkthrough shows a card for
  /// it. Leaving it out is why Settings used to report "5/5 granted" on a
  /// handset the Permissions screen showed as 5 of 6.
  int grantedCount({bool ignoringBatteryOptimizations = false}) => [
    readPhoneState && readCallLog,
    ignoringBatteryOptimizations,
    readContacts,
    readMediaAudio,
    notifications,
    overlayWindow,
  ].where((g) => g).length;

  /// One per entry in `permissionAsks`; the phone/call-log pair counts as one
  /// ask because the user is shown one card for it.
  static const total = 6;
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

    final validRows = rows.where((r) => r.dateMillis != null).toList();
    // Third copy of this derivation, now removed. It has to agree with what the
    // ingesters wrote or this lookup silently misses: a withheld number is
    // stored under `android-<millis>-Unknown`, and a hand-rolled key built from
    // a null `r.number` would look for `-null` and find nothing, leaving the
    // call with no sync state in the history list.
    final keys = validRows
        .map((r) => CallWireIdentity.key(
              startedAtMillis: r.dateMillis!,
              rawNumber: r.number,
            ))
        .toList();

    List<LocalCall> localCalls = const [];
    try {
      localCalls = await dao.findByIdempotencyKeys(keys);
    } catch (e) {
      // Storage failure diagnostics are tracked without crashing the whole feed pipeline
      localCalls = const [];
    }
    final localCallMap = {for (final lc in localCalls) lc.idempotencyKey: lc};

    final entries = <CallEntry>[];
    for (int i = 0; i < validRows.length; i++) {
      final row = validRows[i];
      final key = keys[i];
      final localCall = localCallMap[key];

      final name = row.number == null ? null : names[row.number!];

      // A recording the ingester already settled on is not re-litigated here.
      // This feed rescores every visible row against the whole candidate pool,
      // so without this it could disagree with the row it is displaying — and
      // show "Review required" for a call whose audio was matched, uploaded and
      // long since agreed with the server.
      final RecordingMatch match;
      final storedMediaStoreId = localCall?.recordingMediaStoreId;
      if (localCall != null &&
          localCall.hasRecording &&
          storedMediaStoreId != null) {
        final stored = _pool
            .where((c) => c.mediaStoreId == storedMediaStoreId)
            .firstOrNull;
        match = RecordingMatch(
          status: RecordingMatchStatus.matched,
          confidence: 1,
          candidate: stored,
          reason: 'Recording confirmed for this call.',
        );
      } else {
        match = matcher.match(
          CallForMatching(
            startedAtEpochMillis: row.dateMillis!,
            durationSeconds: row.durationSeconds ?? 0,
            normalizedNumber: row.number,
            contactName: name ?? row.cachedName,
            // The measured answer instant, when the row has one. It is what
            // separates two back-to-back calls of similar length, and it is
            // the difference between offering a real choice and asking the
            // user to break a tie the app could have broken itself.
            answeredAtEpochMillis:
                localCall?.answeredAt?.millisecondsSinceEpoch,
          ),
          _pool,
        );
      }

      UploadState state = UploadState.pending;
      if (localCall != null) {
        state = _uploadStateOf(localCall.syncState);
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

  /// Attaches a recording the user picked for an ambiguous call, and queues it.
  ///
  /// This is what the "Review required" state was missing. The matcher can be
  /// confident that several files are plausible and unable to choose between
  /// them; until now the UI said so and offered nothing, the row kept
  /// `has_recording = 0`, and the audio was never uploaded — the app asked for
  /// a decision it had no way to accept.
  ///
  /// A person picking the wrong file here is a smaller harm than the automatic
  /// association the thresholds exist to prevent: it is deliberate, attributable
  /// and visible, where a wrong auto-match is silent.
  Future<void> confirmRecording({
    required int startedAtMillis,
    required String? rawNumber,
    required RecordingCandidate candidate,
  }) async {
    final dao = ref.read(callsDaoProvider);
    final bridge = ref.read(nativeBridgeProvider);

    final key = CallWireIdentity.key(
      startedAtMillis: startedAtMillis,
      rawNumber: rawNumber,
    );

    // The URI is resolved before the write: a file deleted between the scan
    // and the tap must not leave the row pointing at audio that is not there,
    // which the uploader would then retry until it gave up.
    final uri = await bridge.getRecordingUri(candidate.mediaStoreId);
    await dao.updateRecordingInfo(
      idempotencyKey: key,
      recordingPath: uri,
      mediaStoreId: candidate.mediaStoreId,
    );

    // Hand it to the native coordinator rather than uploading from here: it
    // owns the outbox, holds the single-flight lock, and is what runs when the
    // app is closed.
    try {
      await bridge.triggerNativeSync();
    } catch (_) {}

    await refresh();
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

enum DashboardPeriod { today, yesterday, week, month, all }

class DashboardPeriodController extends Notifier<DashboardPeriod> {
  @override
  DashboardPeriod build() => DashboardPeriod.today;

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
  final startOfToday = DateTime(now.year, now.month, now.day, 0, 0, 0);
  final endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);

  final (start, end) = switch (period) {
    DashboardPeriod.today => (startOfToday, endOfToday),
    DashboardPeriod.yesterday => (
        startOfToday.subtract(const Duration(days: 1)),
        startOfToday.subtract(const Duration(milliseconds: 1)),
      ),
    DashboardPeriod.week => (
        startOfToday.subtract(Duration(days: (now.weekday - 1).clamp(0, 6))),
        endOfToday,
      ),
    DashboardPeriod.month => (DateTime(now.year, now.month, 1, 0, 0, 0), endOfToday),
    DashboardPeriod.all => (DateTime.fromMillisecondsSinceEpoch(0), endOfToday.add(const Duration(days: 365))),
  };

  final dateFormat = DateFormat('dd-MMM-yyyy hh:mm a');
  final formatted = period == DashboardPeriod.all
      ? 'All Time'
      : '${dateFormat.format(start)} - ${dateFormat.format(end)}';

  return PeriodRangeInfo(
    start: start,
    end: end,
    formattedRange: formatted,
  );
});

class AnalyticsExcludeInternalController extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
  void set(bool val) => state = val;
}

final analyticsExcludeInternalProvider =
    NotifierProvider<AnalyticsExcludeInternalController, bool>(
  AnalyticsExcludeInternalController.new,
);

/// Reactive Stream of CallStats directly computed from SQLite database records
/// matching the active date period and filter parameters.
final analyticsPeriodStatsProvider = StreamProvider<CallStats>((ref) {
  final dao = ref.watch(callsDaoProvider);
  final rangeInfo = ref.watch(periodRangeInfoProvider);
  final excludeInternal = ref.watch(analyticsExcludeInternalProvider);

  return dao.watchCallsForAnalytics(
    startUtc: rangeInfo.start.toUtc(),
    endUtc: rangeInfo.end.toUtc(),
    excludeInternal: excludeInternal,
  ).map(CallStats.fromLocalCalls);
});

/// The same-length window immediately before [periodRangeInfoProvider].
///
/// Exists so the dashboard's trend deltas are measured against something real.
/// Null for "All time", which has no preceding period to compare with.
final previousPeriodRangeProvider = Provider<({DateTime start, DateTime end})?>(
  (ref) {
    final period = ref.watch(dashboardPeriodProvider);
    if (period == DashboardPeriod.all) return null;

    final current = ref.watch(periodRangeInfoProvider);
    final span = current.end.difference(current.start);
    final end = current.start.subtract(const Duration(milliseconds: 1));
    return (start: end.subtract(span), end: end);
  },
);

/// Stats for the preceding window, used only to derive trends.
final analyticsPreviousStatsProvider = StreamProvider<CallStats?>((ref) {
  final range = ref.watch(previousPeriodRangeProvider);
  if (range == null) return Stream.value(null);

  final dao = ref.watch(callsDaoProvider);
  final excludeInternal = ref.watch(analyticsExcludeInternalProvider);

  return dao
      .watchCallsForAnalytics(
        startUtc: range.start.toUtc(),
        endUtc: range.end.toUtc(),
        excludeInternal: excludeInternal,
      )
      .map<CallStats?>(CallStats.fromLocalCalls);
});

/// Period-over-period change for one metric, as the dashboard renders it.
///
/// Returns null when there is nothing honest to show — no previous period, or
/// a previous value of zero, where a percentage is undefined. Every metric card
/// used to display a fixed string ('+8%', '-5%', …) that was never computed
/// from anything.
String? trendLabel(num current, num? previous) {
  if (previous == null) return null;
  if (previous == 0) return current == 0 ? null : 'New';

  final delta = (current - previous) / previous * 100;
  if (delta.abs() < 0.5) return '0%';
  final sign = delta > 0 ? '+' : '-';
  return '$sign${delta.abs().toStringAsFixed(0)}%';
}

/// Reactive hourly call activity point distribution for dashboard charts.
final analyticsHourlyActivityProvider = StreamProvider<({List<double> incoming, List<double> outgoing, List<double> missed})>((ref) {
  final dao = ref.watch(callsDaoProvider);
  final rangeInfo = ref.watch(periodRangeInfoProvider);
  final excludeInternal = ref.watch(analyticsExcludeInternalProvider);

  return dao.watchCallsForAnalytics(
    startUtc: rangeInfo.start.toUtc(),
    endUtc: rangeInfo.end.toUtc(),
    excludeInternal: excludeInternal,
  ).map((calls) {
    final incoming = List.filled(6, 0.0);
    final outgoing = List.filled(6, 0.0);
    final missed = List.filled(6, 0.0);

    for (final c in calls) {
      final localDt = c.startedAt.toLocal();
      final hour = localDt.hour;
      final bucket = (hour ~/ 4).clamp(0, 5);
      final dir = c.direction.toLowerCase();
      final status = c.status.toLowerCase();

      if (dir == 'incoming') {
        incoming[bucket]++;
      } else if (dir == 'outgoing') {
        outgoing[bucket]++;
      } else if (dir == 'missed' || dir == 'rejected' || status == 'missed' || status == 'rejected') {
        missed[bucket]++;
      }
    }

    return (incoming: incoming, outgoing: outgoing, missed: missed);
  });
});

/// Reactive sparkline data point distribution.
final analyticsSparklineProvider = StreamProvider<List<double>>((ref) {
  final dao = ref.watch(callsDaoProvider);
  final rangeInfo = ref.watch(periodRangeInfoProvider);
  final excludeInternal = ref.watch(analyticsExcludeInternalProvider);

  return dao.watchCallsForAnalytics(
    startUtc: rangeInfo.start.toUtc(),
    endUtc: rangeInfo.end.toUtc(),
    excludeInternal: excludeInternal,
  ).map((calls) {
    if (calls.isEmpty) return const [0, 0, 0, 0, 0, 0, 0, 0];
    final buckets = List.filled(8, 0.0);
    for (final c in calls) {
      final hour = c.startedAt.toLocal().hour;
      final b = (hour ~/ 3).clamp(0, 7);
      buckets[b]++;
    }
    return buckets;
  });
});

CallEntry callEntryFromLocalCall(LocalCall lc) {
  final dir = switch (lc.direction.toLowerCase()) {
    'incoming' => CallDirection.incoming,
    'outgoing' => CallDirection.outgoing,
    'missed' => CallDirection.missed,
    'rejected' => CallDirection.rejected,
    _ => CallDirection.unknown,
  };

  final match = lc.hasRecording && lc.recordingPath != null
      ? RecordingMatch(
          status: RecordingMatchStatus.matched,
          confidence: 1.0,
          candidate: RecordingCandidate(
            mediaStoreId: lc.recordingMediaStoreId ?? 0,
            displayName: lc.recordingPath?.split('/').last,
            durationMillis: lc.durationSeconds * 1000,
            sizeBytes: 0,
            dateAddedEpochSeconds: lc.startedAt.millisecondsSinceEpoch ~/ 1000,
            dateModifiedEpochSeconds: lc.startedAt.millisecondsSinceEpoch ~/ 1000,
          ),
        )
      : const RecordingMatch(
          status: RecordingMatchStatus.notFound,
          confidence: 0.0,
        );

  final upState = _uploadStateOf(lc.syncState);

  return CallEntry(
    row: CallLogRow(
      systemId: lc.localId,
      number: lc.phoneNumber,
      presentation: NumberPresentation.allowed,
      cachedName: lc.contactName,
      direction: dir,
      dateMillis: lc.startedAt.millisecondsSinceEpoch,
      durationSeconds: lc.durationSeconds,
      phoneAccountId: lc.simSlot?.toString(),
    ),
    match: match,
    uploadState: upState,
    contactName: lc.contactName,
  );
}

/// Reactive entries matching active period and filter for drilldown popups.
final analyticsPeriodEntriesProvider = StreamProvider<List<CallEntry>>((ref) {
  final dao = ref.watch(callsDaoProvider);
  final rangeInfo = ref.watch(periodRangeInfoProvider);
  final excludeInternal = ref.watch(analyticsExcludeInternalProvider);

  return dao.watchCallsForAnalytics(
    startUtc: rangeInfo.start.toUtc(),
    endUtc: rangeInfo.end.toUtc(),
    excludeInternal: excludeInternal,
  ).map((calls) => calls.map(callEntryFromLocalCall).toList());
});

/// Aggregates for the dashboard computed from database when available,
/// with immediate fallback to feed entries during initialization or tests.
final periodStatsProvider = Provider<CallStats>((ref) {
  final statsAsync = ref.watch(analyticsPeriodStatsProvider);
  if (statsAsync.hasValue) return statsAsync.requireValue;

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

/// Today's aggregates for the dashboard.
final todayStatsProvider = Provider<CallStats>((ref) {
  final statsAsync = ref.watch(analyticsPeriodStatsProvider);
  if (statsAsync.hasValue) return statsAsync.requireValue;

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

/// Maps a stored `sync_state` onto what the call list shows.
///
/// Goes through [CallSyncState] rather than comparing literals: the same row
/// is written by Dart and by the native coordinator, and matching on one
/// side's spelling is how every uploaded call previously rendered as pending.
UploadState _uploadStateOf(String syncState) {
  if (CallSyncState.isUploaded(syncState)) return UploadState.uploaded;
  if (CallSyncState.isInFlight(syncState)) return UploadState.uploading;
  if (CallSyncState.isFailed(syncState)) return UploadState.failed;
  return UploadState.pending;
}
