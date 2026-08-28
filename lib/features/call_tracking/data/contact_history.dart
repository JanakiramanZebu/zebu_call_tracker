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
      if (!perms.canTrack) return const [];

      final rows = await bridge.readCallLogForNumber(number, limit: _limit);
      if (rows.isEmpty) return const [];

      // One lookup for the whole history: every row here is the same person, so
      // the native cache answers all but the first from memory.
      final names = perms.readContacts
          ? await bridge.resolveContacts([number])
          : const <String, String>{};
      final name = names[number];

      final pool = perms.readMediaAudio
          ? await bridge.scanRecordings(sinceEpochSeconds: 0, limit: _poolSize)
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

/// Aggregates for a number's history header.
///
/// Reuses [CallStats] rather than defining a parallel summary type: the totals
/// a contact header wants (answered, missed, talk time, recordings) are exactly
/// the ones the dashboard already computes, in one pass.
CallStats contactHistoryStats(List<CallEntry> entries) =>
    CallStats.from(entries);
