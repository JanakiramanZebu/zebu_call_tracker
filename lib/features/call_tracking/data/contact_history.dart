import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../recording/domain/recording_matcher.dart';
import '../domain/call_entry.dart';
import 'call_feed.dart';

/// Every call ever made to or from one number, with its matched recording.
///
/// Queried from the provider rather than filtered out of [callFeedProvider]:
/// the feed is paged sixty rows at a time, so filtering it would show "the
/// calls with this number that happen to be loaded", which is a different and
/// much less useful thing than this contact's history. The native side matches
/// on the last ten digits, so the same person logged as +9197…, 09197… and 97…
/// comes back as one history.
///
/// Family-keyed by number and auto-disposed: a user who opens ten call details
/// should not leave ten histories cached.
final contactHistoryProvider = FutureProvider.autoDispose
    .family<List<CallEntry>, String>((ref, number) async {
      if (number.isEmpty) return const [];

      final bridge = ref.watch(nativeBridgeProvider);
      final matcher = ref.watch(recordingMatcherProvider);
      final perms = await ref.watch(permissionStatusProvider.future);
      // Reading history needs only the call log; see CallFeed._load.
      if (!perms.readCallLog) return const [];

      final rows = await bridge.readCallLogForNumber(number, limit: _limit);
      if (rows.isEmpty) return const [];

      // One lookup for the whole history: every row here is the same person, so
      // the native cache answers all but the first from memory.
      final names = perms.readContacts
          ? await bridge.resolveContacts([number])
          : const <String, String>{};
      final name = names[number];

      // Only the stretch of time these calls cover is scanned. This ran a scan
      // of the newest 400 recordings on the device on every detail open, most
      // of them for other people, and for an older contact still missed the
      // files that mattered.
      //
      // From the earliest START to the latest END (start + ring + talk time):
      // a dialer that dates its file at hang-up writes it a whole call-length
      // after the start, so stopping at the latest start hid the newest long
      // call's recording. The margin covers clock skew and a late media scan.
      final connected = [
        for (final r in rows)
          if (r.dateMillis != null && (r.durationSeconds ?? 0) > 0) r,
      ];
      final pool = perms.readRecordings && connected.isNotEmpty
          ? await bridge.scanRecordings(
              sinceEpochSeconds: connected
                      .map((r) => r.dateMillis! ~/ 1000)
                      .reduce(math.min) -
                  _marginSeconds,
              beforeEpochSeconds: connected
                      .map((r) =>
                          r.dateMillis! ~/ 1000 +
                          _ringAllowanceSeconds +
                          r.durationSeconds!)
                      .reduce(math.max) +
                  _marginSeconds,
              limit: _poolSize,
            )
          : const <RecordingCandidate>[];

      return [
        for (final row in rows)
          if (row.dateMillis != null)
            CallEntry(
              row: row,
              contactName: name,
              match: matcher.match(
                CallForMatching(
                  startedAtEpochMillis: row.dateMillis!,
                  durationSeconds: row.durationSeconds ?? 0,
                  normalizedNumber: row.number,
                  contactName: name ?? row.cachedName,
                ),
                pool,
              ),
            ),
      ];
    });

/// Enough to cover a long-standing client relationship without turning a detail
/// screen into an unbounded query.
const _limit = 100;
const _poolSize = 400;
const _marginSeconds = 5 * 60;

/// The longest ring before pickup, which a call's duration (talk time) leaves
/// out. Same value as [RecordingMatcher.maxRingGapSeconds].
const _ringAllowanceSeconds = 180;

/// Aggregates for a number's history header.
///
/// Reuses [CallStats] rather than defining a parallel summary type: the totals
/// a contact header wants (answered, missed, talk time, recordings) are exactly
/// the ones the dashboard already computes, in one pass.
CallStats contactHistoryStats(List<CallEntry> entries) =>
    CallStats.from(entries);
