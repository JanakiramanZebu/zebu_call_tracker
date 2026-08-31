// Every fixture below is REAL data captured from a Samsung SM-M356B running
// Android 16, paired across the call-log and MediaStore content providers.
// Numbers are masked; timestamps and durations are untouched, because those are
// what the matcher actually reasons over.

import 'package:flutter_test/flutter_test.dart';
import 'package:zebu_call_tracker/features/recording/domain/recording_matcher.dart';

const matcher = RecordingMatcher();

RecordingCandidate rec({
  int id = 1,
  String? name = 'Call Ulagas Zebu_260828_095533.m4a',
  required int durationMillis,
  required int addedSeconds,
  int? modifiedSeconds,
  int sizeBytes = 164000,
}) =>
    RecordingCandidate(
      mediaStoreId: id,
      displayName: name,
      durationMillis: durationMillis,
      sizeBytes: sizeBytes,
      dateAddedEpochSeconds: addedSeconds,
      dateModifiedEpochSeconds:
          modifiedSeconds ?? addedSeconds + (durationMillis ~/ 1000),
      mimeType: 'audio/mp4',
      relativePath: 'Recordings/Call/',
      source: 'OEM_RECORDER',
    );

CallForMatching call({
  required int startSeconds,
  required int durationSeconds,
  String? number = '+917397787538',
  String? contactName,
}) =>
    CallForMatching(
      startedAtEpochMillis: startSeconds * 1000,
      durationSeconds: durationSeconds,
      normalizedNumber: number,
      contactName: contactName,
    );

void main() {
  group('real device pairs are matched', () {
    // Captured 2026-08-28. Ring gaps of +14s, +9s and +4s respectively.
    test('114s call pairs with its 114.046s recording', () {
      final result = matcher.match(
        call(startSeconds: 1787890986, durationSeconds: 114),
        [rec(durationMillis: 114046, addedSeconds: 1787890995)],
      );

      expect(result.status, RecordingMatchStatus.matched);
      // 0.896: duration and timing both score full marks; identity sits at the
      // neutral 0.5 because this fixture's number is not in the filename. That
      // is the designed ceiling for a match carried purely by evidence.
      expect(result.confidence, greaterThan(0.85));
      expect(result.signals!.durationDeltaSeconds, lessThan(0.1));
      expect(result.signals!.ringGapSeconds, 9);
    });

    test('45s call pairs with its 44.757s recording across a 14s ring', () {
      final result = matcher.match(
        call(startSeconds: 1787890024, durationSeconds: 45),
        [rec(durationMillis: 44757, addedSeconds: 1787890038)],
      );
      expect(result.status, RecordingMatchStatus.matched);
    });

    test('10s call pairs with its 10.133s recording', () {
      final result = matcher.match(
        call(startSeconds: 1787891129, durationSeconds: 10),
        [rec(durationMillis: 10133, addedSeconds: 1787891133)],
      );
      expect(result.status, RecordingMatchStatus.matched);
    });

    test('the correct candidate wins out of the full day of recordings', () {
      // All four recordings the device produced that morning, offered against
      // the 114s call. Only one should survive.
      final result = matcher.match(
        call(startSeconds: 1787890986, durationSeconds: 114),
        [
          rec(id: 1, durationMillis: 8363, addedSeconds: 1787903339),
          rec(id: 2, durationMillis: 10133, addedSeconds: 1787891133),
          rec(id: 3, durationMillis: 114046, addedSeconds: 1787890995),
          rec(id: 4, durationMillis: 44757, addedSeconds: 1787890038),
        ],
      );

      expect(result.status, RecordingMatchStatus.matched);
      expect(result.candidate!.mediaStoreId, 3);
    });
  });

  group('cases that must NOT be matched', () {
    test('a missed call never takes a recording', () {
      // Real row: +917397787532, type=3 (missed), duration=0, at 1787903372.
      // A 8.363s recording exists 33s earlier, from a DIFFERENT call. Matching
      // it here would attach a stranger's audio to a missed call.
      final result = matcher.match(
        call(startSeconds: 1787903372, durationSeconds: 0),
        [rec(durationMillis: 8363, addedSeconds: 1787903339)],
      );

      expect(result.status, RecordingMatchStatus.notFound);
      expect(result.candidate, isNull);
      expect(result.reason, contains('never connected'));
    });

    test('a recording that starts BEFORE the call is rejected', () {
      final result = matcher.match(
        call(startSeconds: 1787890986, durationSeconds: 114),
        [rec(durationMillis: 114000, addedSeconds: 1787890900)],
      );
      expect(result.status, RecordingMatchStatus.unmatched);
    });

    test('a duration mismatch beyond tolerance is rejected', () {
      final result = matcher.match(
        call(startSeconds: 1787890986, durationSeconds: 114),
        [rec(durationMillis: 60000, addedSeconds: 1787890995)],
      );
      expect(result.status, RecordingMatchStatus.unmatched);
    });

    test('a zero-length recording file is rejected', () {
      final result = matcher.match(
        call(startSeconds: 1787890986, durationSeconds: 114),
        [rec(durationMillis: 0, addedSeconds: 1787890995)],
      );
      expect(result.status, RecordingMatchStatus.unmatched);
    });

    test('no candidates at all reports notFound, not unmatched', () {
      final result = matcher.match(
        call(startSeconds: 1787890986, durationSeconds: 114),
        const [],
      );
      expect(result.status, RecordingMatchStatus.notFound);
    });
  });

  group('ambiguity is surfaced rather than guessed', () {
    test('back-to-back calls of near-identical length go to review', () {
      // The genuinely dangerous case: the same person called twice in a row for
      // about the same time. Both recordings fit. Auto-associating would be a
      // coin flip on whose conversation goes where.
      final result = matcher.match(
        call(startSeconds: 1787890986, durationSeconds: 114),
        [
          rec(id: 10, durationMillis: 114046, addedSeconds: 1787890995),
          rec(id: 11, durationMillis: 114100, addedSeconds: 1787890997),
        ],
      );

      expect(result.status, RecordingMatchStatus.ambiguous);
      expect(result.candidate, isNotNull, reason: 'best guess is kept for review');
      expect(result.runnerUpConfidence, greaterThan(0.5));
    });

    test('an ambiguous result is never treated as associable', () {
      final result = matcher.match(
        call(startSeconds: 1787890986, durationSeconds: 114),
        [
          rec(id: 10, durationMillis: 114046, addedSeconds: 1787890995),
          rec(id: 11, durationMillis: 114100, addedSeconds: 1787890997),
        ],
      );
      expect(result.isAssociable, isFalse);
    });
  });

  group('filename is a tie-breaker, never the decision', () {
    test('a match holds when the filename carries no identity at all', () {
      // Withheld number, unsaved contact: the filename tells us nothing. The
      // duration and timing evidence must still carry the match.
      final result = matcher.match(
        call(startSeconds: 1787890986, durationSeconds: 114, number: null),
        [rec(durationMillis: 114046, addedSeconds: 1787890995, name: null)],
      );
      expect(result.status, RecordingMatchStatus.matched);
      expect(result.signals!.identityMatched, isFalse);
    });

    test('a matching filename cannot rescue contradictory evidence', () {
      // Same contact, but the audio is 60s against a 114s call. The name in the
      // filename is exactly the trap that filename-only matching falls into.
      final result = matcher.match(
        call(
          startSeconds: 1787890986,
          durationSeconds: 114,
          contactName: 'Ulagas Zebu',
        ),
        [
          rec(
            durationMillis: 60000,
            addedSeconds: 1787890995,
            name: 'Call Ulagas Zebu_260828_095315.m4a',
          ),
        ],
      );
      expect(result.status, RecordingMatchStatus.unmatched);
    });

    test('both OEM filename generations resolve the same number', () {
      // 2025 builds wrote "Call recording <x>", 2026 builds write "Call <x>".
      // Both appear on the reference device.
      for (final name in [
        'Call recording +917305739666_250611_092515.m4a',
        'Call +917305739666_260611_092515.m4a',
      ]) {
        final result = matcher.match(
          call(
            startSeconds: 1787890986,
            durationSeconds: 114,
            number: '+917305739666',
          ),
          [rec(durationMillis: 114046, addedSeconds: 1787890995, name: name)],
        );
        expect(result.signals!.identityMatched, isTrue, reason: name);
      }
    });

    test('number identity survives differing prefix formats', () {
      final result = matcher.match(
        call(
          startSeconds: 1787890986,
          durationSeconds: 114,
          number: '+917305739666',
        ),
        [
          rec(
            durationMillis: 114046,
            addedSeconds: 1787890995,
            name: 'Call 7305739666_260611_092515.m4a',
          ),
        ],
      );
      expect(result.signals!.identityMatched, isTrue);
    });
  });

  group('optimized batch and isolate execution', () {
    test('matchBatchInIsolate successfully matches multiple calls concurrently', () async {
      final calls = [
        call(startSeconds: 1787890986, durationSeconds: 114),
        call(startSeconds: 1787890024, durationSeconds: 45),
        call(startSeconds: 1787891129, durationSeconds: 10),
      ];

      final candidates = [
        rec(id: 1, durationMillis: 8363, addedSeconds: 1787903339),
        rec(id: 2, durationMillis: 10133, addedSeconds: 1787891133),
        rec(id: 3, durationMillis: 114046, addedSeconds: 1787890995),
        rec(id: 4, durationMillis: 44757, addedSeconds: 1787890038),
      ];

      final results = await RecordingMatcher.matchBatchInIsolate(
        calls: calls,
        candidates: candidates,
      );

      expect(results.length, 3);
      expect(results[1787890986 * 1000]!.status, RecordingMatchStatus.matched);
      expect(results[1787890986 * 1000]!.candidate!.mediaStoreId, 3);

      expect(results[1787890024 * 1000]!.status, RecordingMatchStatus.matched);
      expect(results[1787890024 * 1000]!.candidate!.mediaStoreId, 4);

      expect(results[1787891129 * 1000]!.status, RecordingMatchStatus.matched);
      expect(results[1787891129 * 1000]!.candidate!.mediaStoreId, 2);
    });

    test('temporal pre-gating discards candidates outside ring gap window', () {
      final testCall = call(startSeconds: 1000000, durationSeconds: 30);
      // Candidates outside [-15s, +180s]
      final candidateWayBefore = rec(id: 1, durationMillis: 30000, addedSeconds: 999900);
      final candidateWayAfter = rec(id: 2, durationMillis: 30000, addedSeconds: 1000300);

      final result = matcher.match(testCall, [candidateWayBefore, candidateWayAfter]);
      expect(result.status, RecordingMatchStatus.unmatched);
    });
  });
}
