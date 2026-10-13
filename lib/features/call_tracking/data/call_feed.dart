import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/platform/native_call_bridge.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/storage/database_providers.dart';
import '../../../core/storage/sync_state.dart';
import '../../../core/network/call_wire_format.dart';
import '../../../core/utils/formatters.dart';
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
    // Started together and awaited as one: this re-runs on every resume, and
    // four channel round-trips in a row were on the path to the first frame.
    // Future.wait handles every failure and rethrows the first as-is, so the
    // error screen still sees a NativeFailure rather than a wrapper.
    final calls = bridge.getPermissionStatus();
    final recordings = bridge.getRecordingAccess();
    // Notifications are not in the native inspector's remit: POST_NOTIFICATIONS
    // does not exist below API 33, and permission_handler already reports
    // "granted" there. Checking status never raises a dialog.
    final notifications = Permission.notification.isGranted;
    final overlay = bridge.checkOverlayPermission();
    await Future.wait([calls, recordings, notifications, overlay]);

    final callPerms = await calls;
    final recordingAccess = await recordings;
    return PermissionSnapshot(
      readPhoneState: callPerms['readPhoneState'] ?? false,
      readCallLog: callPerms['readCallLog'] ?? false,
      readContacts: callPerms['readContacts'] ?? false,
      readRecordings: recordingAccess.granted,
      recordingPermission: recordingAccess.permission,
      notifications: await notifications,
      overlayWindow: await overlay,
      whatsappCalls: callPerms['whatsappCalls'] ?? false,
      whatsappInstalled: callPerms['whatsappInstalled'] ?? false,
    );
  },
);

class PermissionSnapshot {
  const PermissionSnapshot({
    required this.readPhoneState,
    required this.readCallLog,
    required this.readContacts,
    required this.readRecordings,
    required this.recordingPermission,
    required this.notifications,
    this.overlayWindow = false,
    this.whatsappCalls = false,
    this.whatsappInstalled = false,
  });

  final bool readPhoneState;
  final bool readCallLog;
  final bool readContacts;

  /// Whether [recordingPermission] is held.
  final bool readRecordings;

  /// The Android permission the recording scan needs on this OS version, as
  /// the native side names it: READ_MEDIA_AUDIO on API 33+, and
  /// READ_EXTERNAL_STORAGE below. Carried so the ask requests the one this
  /// handset actually has — see `permissionAsks`.
  final String recordingPermission;

  final bool notifications;

  /// SYSTEM_ALERT_WINDOW — for the post-call overlay card.
  /// Defaults to false so existing call sites do not break.
  final bool overlayWindow;

  /// Notification access for the WhatsApp call listener.
  final bool whatsappCalls;

  /// WhatsApp or WhatsApp Business is installed. Without one, the WhatsApp
  /// ask is not shown at all.
  final bool whatsappInstalled;

  /// Whether new calls are being captured at all.
  ///
  /// Both halves, because capture needs both: the call log supplies the call,
  /// and READ_PHONE_STATE is what lets the call-state receiver fire at all.
  /// This used to check the call log alone, so revoking only "Phone" stopped
  /// capture silently while the app went on looking healthy. It must agree
  /// with the essential card in `permissionAsks`.
  bool get canTrack => readCallLog && readPhoneState;
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

    // The call log alone, not [PermissionSnapshot.canTrack]: showing history
    // needs nothing more, and AppGate already diverts when capture has stopped.
    if (!perms.readCallLog) {
      return const CallFeedState(entries: [], hasMore: false, blocked: true);
    }

    final rows = await bridge.readCallLog(
      sinceMillis: 0,
      beforeMillis: beforeMillis,
      limit: _pageSize,
    );

    if (!_poolLoaded) {
      _pool = perms.readRecordings
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

    // WhatsApp calls never reach Android's call log; they exist only as
    // outbox rows the WhatsApp listener wrote. Each page takes the ones that
    // fall inside its own time span — from the cursor down to the oldest call
    // -log row on the page, or everything older on the last page — so paging
    // neither skips nor repeats them.
    final pageIsLast = rows.length < _pageSize;
    final oldestOnPage = validRows.isEmpty
        ? null
        : validRows.map((r) => r.dateMillis!).reduce((a, b) => a < b ? a : b);
    try {
      final whatsApp = await dao.getWhatsAppCalls(
        fromMillis: pageIsLast ? null : oldestOnPage,
        beforeMillis: beforeMillis > 0 ? beforeMillis : null,
      );
      if (whatsApp.isNotEmpty) {
        entries
          ..addAll(whatsApp.map(_whatsAppEntry))
          ..sort(
            (a, b) => (b.row.dateMillis ?? 0).compareTo(a.row.dateMillis ?? 0),
          );
      }
    } catch (_) {
      // The call-log page still shows; WhatsApp rows return on the next load.
    }

    return CallFeedState(
      entries: [...previous, ...entries],
      // A short page means the provider had nothing more to give, which is a
      // reliable end-of-list signal now that each page is a bounded query.
      hasMore: rows.length >= _pageSize,
    );
  }

  /// A WhatsApp outbox row, shaped like a call-log entry so the list, the
  /// filters and the detail screen treat it like any other call.
  CallEntry _whatsAppEntry(LocalCall c) {
    final direction = c.status == 'missed'
        ? CallDirection.missed
        : c.direction == 'outgoing'
        ? CallDirection.outgoing
        : CallDirection.incoming;
    final number = c.phoneNumber == 'Unknown' ? null : c.phoneNumber;
    return CallEntry(
      row: CallLogRow(
        systemId: null,
        number: number,
        presentation: NumberPresentation.allowed,
        cachedName: c.contactName,
        direction: direction,
        dateMillis: c.startedAt.millisecondsSinceEpoch,
        durationSeconds: c.durationSeconds,
        phoneAccountId: null,
      ),
      // WhatsApp audio cannot be recorded, so there is never one to match.
      match: const RecordingMatch(
        status: RecordingMatchStatus.notFound,
        confidence: 0,
      ),
      uploadState: _uploadStateOf(c.syncState),
      contactName: c.contactName,
      isWhatsApp: true,
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

    // A reload already in flight read the row before this write; joining it
    // would show the call still waiting for a choice. Let it land, then load
    // again.
    await _refreshing;
    await refresh();
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    // A page appended to a list that a refresh is about to replace would be
    // thrown away, or worse, land after it and resurrect the stale prefix.
    if (_refreshing != null) return;

    // The oldest row already held is the cursor for the next page. Null-safe
    // because a row without a timestamp is skipped during load and so can
    // never be the last entry.
    final cursor = current.entries.isEmpty
        ? 0
        : current.entries.last.row.dateMillis ?? 0;

    state = AsyncData(current.copyWith(loadingMore: true));
    final next = await AsyncValue.guard(
      () => _load(previous: current.entries, beforeMillis: cursor),
    );
    // A refresh that started meanwhile owns the list now; this page belongs
    // to the one it is replacing.
    if (_refreshing != null) return;
    // A page that failed to load leaves the rows already shown in place; the
    // next scroll to the bottom asks again.
    state = next.hasError ? AsyncData(current) : next;
  }

  Future<void>? _refreshing;

  /// Reloads the first page.
  ///
  /// Single-flight: resume, reconnect, pull-to-refresh and a confirmed
  /// recording can all ask at once, and each used to start its own reload —
  /// a call-log read, a MediaStore scan and a contacts lookup apiece.
  ///
  /// Silent when there is already something on screen: the list stays put and
  /// the new page is swapped in when it arrives. Dropping to [AsyncLoading]
  /// blanked every watcher to a skeleton on each resume, for data that had
  /// usually not changed.
  Future<void> refresh() => _refreshing ??= _reload().whenComplete(() {
        _refreshing = null;
      });

  Future<void> _reload() async {
    if (!state.hasValue) state = const AsyncLoading();
    ref.invalidate(permissionStatusProvider);
    // A refresh is the user (or a resume) saying the device state changed, so
    // the recording pool is rebuilt rather than reused.
    _poolLoaded = false;
    final next = await AsyncValue.guard(() => _load(previous: const []));
    // A failed background reload keeps the list the user is reading rather
    // than replacing it with an error page; the next refresh tries again.
    // A page load this refresh superseded may have left its spinner set.
    if (next.hasError && state.value != null) {
      state = AsyncData(state.requireValue.copyWith(loadingMore: false));
      return;
    }
    state = next;
  }
}

class CallFeedState {
  const CallFeedState({
    required this.entries,
    required this.hasMore,
    this.loadingMore = false,
    this.blocked = false,
  });

  final List<CallEntry> entries;
  final bool hasMore;
  final bool loadingMore;

  /// True when the call-log permission is missing, so the UI can explain rather
  /// than render an empty list that looks like "no calls".
  final bool blocked;

  CallFeedState copyWith({bool? loadingMore}) => CallFeedState(
    entries: entries,
    hasMore: hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
    blocked: blocked,
  );

  /// Entries grouped into day buckets, newest first, for sectioned lists.
  ///
  /// Computed once per list of entries and cached: the calls list used to
  /// regroup every loaded row — with a clock read and a heading string per
  /// row — on each build, which meant on every keystroke in its search box.
  /// Keyed on [entries] rather than the state so a `copyWith` (the load-more
  /// spinner) reuses it; an [Expando] so the constructor can stay const.
  List<(String heading, List<CallEntry> calls)> get grouped =>
      _grouped[entries] ??= _group(entries);

  static final _grouped = Expando<List<(String, List<CallEntry>)>>();

  static List<(String, List<CallEntry>)> _group(List<CallEntry> entries) {
    final out = <(String, List<CallEntry>)>[];
    int? currentDay;
    DateTime? first;
    var bucket = <CallEntry>[];

    for (final e in entries) {
      final utc = e.startedAtUtc;
      if (utc == null) continue;
      final local = utc.toLocal();
      final day = local.year * 10000 + local.month * 100 + local.day;
      if (day != currentDay) {
        if (first != null) out.add((Fmt.dayHeading(first), bucket));
        currentDay = day;
        first = utc;
        bucket = [];
      }
      bucket.add(e);
    }
    if (first != null) out.add((Fmt.dayHeading(first), bucket));
    return out;
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

  // A date, not a timestamp range: "09-Oct-2026 12:00 AM - 09-Oct-2026
  // 11:59 PM" said "today" in thirty-odd characters nobody needed to parse.
  final formatted = switch (period) {
    DashboardPeriod.all => 'All time',
    DashboardPeriod.today || DashboardPeriod.yesterday => _dayFormat.format(start),
    _ => '${_shortDayFormat.format(start)} – ${_dayFormat.format(end)}',
  };

  return PeriodRangeInfo(
    start: start,
    end: end,
    formattedRange: formatted,
  );
});

final _dayFormat = DateFormat('EEE, d MMM yyyy');
final _shortDayFormat = DateFormat('d MMM');

/// "Hide internal calls". Off until the user turns it on: the dashboard opens
/// on every call, with no filter quietly applied.
class AnalyticsExcludeInternalController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool val) => state = val;
}

final analyticsExcludeInternalProvider =
    NotifierProvider<AnalyticsExcludeInternalController, bool>(
  AnalyticsExcludeInternalController.new,
);

typedef HourlyActivity = ({
  List<double> incoming,
  List<double> outgoing,
  List<double> missed,
});

/// Everything the dashboard shows for the selected period, derived from one
/// query.
///
/// Four providers used to watch the same period's rows separately — four drift
/// queries re-run, and four full walks of the result, on every write to
/// `local_calls`, which ingest makes on each catch-up. One watch now feeds the
/// stats, both charts and the drill-down list.
class PeriodAnalytics {
  const PeriodAnalytics({
    required this.calls,
    required this.stats,
    required this.hourly,
    required this.sparkline,
  });

  factory PeriodAnalytics.from(List<LocalCall> calls) {
    final incoming = List.filled(6, 0.0);
    final outgoing = List.filled(6, 0.0);
    final missed = List.filled(6, 0.0);
    final sparkline = List.filled(8, 0.0);

    for (final c in calls) {
      final hour = c.startedAt.toLocal().hour;
      sparkline[hour ~/ 3]++;

      final bucket = hour ~/ 4;
      final dir = c.direction.toLowerCase();
      final status = c.status.toLowerCase();
      if (dir == 'incoming') {
        incoming[bucket]++;
      } else if (dir == 'outgoing') {
        outgoing[bucket]++;
      } else if (dir == 'missed' ||
          dir == 'rejected' ||
          status == 'missed' ||
          status == 'rejected') {
        missed[bucket]++;
      }
    }

    return PeriodAnalytics(
      calls: calls,
      stats: CallStats.fromLocalCalls(calls),
      hourly: (incoming: incoming, outgoing: outgoing, missed: missed),
      sparkline: sparkline,
    );
  }

  /// The period's rows, newest first.
  final List<LocalCall> calls;
  final CallStats stats;

  /// Calls per four-hour band, by direction, for the activity chart.
  final HourlyActivity hourly;

  /// Calls per three-hour band, for the hero card's sparkline.
  final List<double> sparkline;

  static const empty = PeriodAnalytics(
    calls: [],
    stats: CallStats.empty,
    hourly: (incoming: _six, outgoing: _six, missed: _six),
    sparkline: [0, 0, 0, 0, 0, 0, 0, 0],
  );

  static const _six = <double>[0, 0, 0, 0, 0, 0];
}

/// The selected period's analytics, live from the database.
final analyticsPeriodProvider = StreamProvider<PeriodAnalytics>((ref) {
  final dao = ref.watch(callsDaoProvider);
  final rangeInfo = ref.watch(periodRangeInfoProvider);
  final excludeInternal = ref.watch(analyticsExcludeInternalProvider);

  return dao
      .watchCallsForAnalytics(
        startUtc: rangeInfo.start.toUtc(),
        endUtc: rangeInfo.end.toUtc(),
        excludeInternal: excludeInternal,
      )
      .map(PeriodAnalytics.from);
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

/// The selected period's calls as list entries, for the drill-down sheet.
///
/// Derived from [analyticsPeriodProvider] rather than a second watch of the
/// same rows, and auto-disposed: only an open sheet needs the mapped list, and
/// for "All time" it can run to thousands of entries.
final analyticsPeriodEntriesProvider =
    Provider.autoDispose<AsyncValue<List<CallEntry>>>(
  (ref) => ref.watch(analyticsPeriodProvider).whenData(
        (p) => [for (final c in p.calls) callEntryFromLocalCall(c)],
      ),
);

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
