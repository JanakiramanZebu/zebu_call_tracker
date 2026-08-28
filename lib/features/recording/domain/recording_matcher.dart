import 'dart:math' as math;

/// Lifecycle of a recording artifact, from discovery through upload.
///
/// Mirrors the backend `recording_match_status` / `upload_status` vocabulary.
/// This app never creates a recording; it only discovers one the device already
/// made and decides, with evidence, which call it belongs to.
enum RecordingMatchStatus {
  /// One candidate clearly wins. Safe to associate and upload.
  matched,

  /// Candidates existed and were plausible, but none won clearly — or two tied.
  /// Deliberately NOT auto-associated: a wrong association attaches one
  /// employee's conversation to the wrong call record.
  ambiguous,

  /// Candidates existed in the scan window but every one was ruled out.
  unmatched,

  /// No recording candidate exists for this call at all. The common, correct
  /// outcome for a missed call, or on a device whose dialer is not recording.
  notFound,
}

/// A recording file discovered on the device by [RecordingScanner].
class RecordingCandidate {
  const RecordingCandidate({
    required this.mediaStoreId,
    required this.displayName,
    required this.durationMillis,
    required this.sizeBytes,
    required this.dateAddedEpochSeconds,
    required this.dateModifiedEpochSeconds,
    this.mimeType,
    this.relativePath,
    this.source = 'UNKNOWN',
  });

  final int mediaStoreId;
  final String? displayName;
  final int durationMillis;
  final int sizeBytes;

  /// When the dialer created the file — in practice, when recording STARTED,
  /// i.e. roughly when the call was answered.
  final int dateAddedEpochSeconds;

  /// When the dialer finished writing — in practice, when recording STOPPED.
  final int dateModifiedEpochSeconds;

  final String? mimeType;
  final String? relativePath;
  final String source;

  double get durationSeconds => durationMillis / 1000.0;
}

/// The subset of a call record the matcher reasons over.
class CallForMatching {
  const CallForMatching({
    required this.startedAtEpochMillis,
    required this.durationSeconds,
    this.normalizedNumber,
    this.contactName,
  });

  /// `CallLog.Calls.DATE` — when the call STARTED (began ringing/dialling),
  /// not when it was answered.
  final int startedAtEpochMillis;

  /// `CallLog.Calls.DURATION` — CONNECTED seconds only. Ring time is not
  /// included, which is precisely why [dateAddedEpochSeconds] lands after the
  /// call start rather than on it.
  final int durationSeconds;

  final String? normalizedNumber;
  final String? contactName;

  int get startedAtEpochSeconds => startedAtEpochMillis ~/ 1000;
}

/// How a single candidate scored, kept so the UI and the audit trail can
/// explain a decision instead of asserting one.
class MatchSignals {
  const MatchSignals({
    required this.durationScore,
    required this.timingScore,
    required this.identityScore,
    required this.durationDeltaSeconds,
    required this.ringGapSeconds,
    required this.identityMatched,
  });

  final double durationScore;
  final double timingScore;
  final double identityScore;

  /// |recording duration − call duration|, in seconds.
  final double durationDeltaSeconds;

  /// recording start − call start. Should be a plausible ring time.
  final int ringGapSeconds;

  final bool identityMatched;

  @override
  String toString() =>
      'dur=${durationDeltaSeconds.toStringAsFixed(1)}s '
      'ring=${ringGapSeconds}s '
      'id=$identityMatched';
}

class RecordingMatch {
  const RecordingMatch({
    required this.status,
    required this.confidence,
    this.candidate,
    this.signals,
    this.runnerUpConfidence = 0,
    this.reason = '',
  });

  final RecordingMatchStatus status;
  final double confidence;
  final RecordingCandidate? candidate;
  final MatchSignals? signals;
  final double runnerUpConfidence;
  final String reason;

  bool get isAssociable => status == RecordingMatchStatus.matched;
}

/// Confidence-based association between an existing device recording and a
/// call-log entry.
///
/// The model below was derived from real paired data on a Samsung SM-M356B
/// (Android 16), not assumed:
///
///   call start 1787890024, duration  45s -> recording added +14s, 44.76s
///   call start 1787890986, duration 114s -> recording added  +9s, 114.05s
///   call start 1787891129, duration  10s -> recording added  +4s, 10.13s
///
/// Two invariants fall out of that, and they carry most of the weight:
///
///   1. recording duration ~= call CONNECTED duration, within about a second.
///   2. recording start = call start + ring time, so the gap is small and
///      always POSITIVE. `date_modified − date_added` reproduces the duration,
///      which is a useful internal consistency check.
///
/// Filenames are used only as a weak tie-breaker. They are unstable even within
/// one vendor: the reference device carries both
/// `Call recording <name>_YYMMDD_HHMMSS.m4a` (2025 builds) and
/// `Call <name>_YYMMDD_HHMMSS.m4a` (2026 builds), and a contact rename changes
/// them retroactively for future files. Never match on filename alone.
class RecordingMatcher {
  const RecordingMatcher({
    this.durationToleranceSeconds = 5.0,
    this.maxDurationDeltaSeconds = 15.0,
    this.maxRingGapSeconds = 180,
    this.minRingGapSeconds = -15,
    this.matchThreshold = 0.70,
    this.ambiguityMargin = 0.15,
    this.plausibilityFloor = 0.40,
  });

  /// Beyond this delta the duration score decays to zero.
  final double durationToleranceSeconds;

  /// Hard gate: a bigger gap than this is a different call, whatever else lines
  /// up.
  final double maxDurationDeltaSeconds;

  /// Longest plausible ring before answer. Beyond it, the recording belongs to
  /// a later call.
  final int maxRingGapSeconds;

  /// A little negative slack: clocks between the two content providers are not
  /// perfectly aligned, and MediaStore truncates to whole seconds.
  final int minRingGapSeconds;

  /// Confidence needed to auto-associate.
  final double matchThreshold;

  /// The winner must beat the runner-up by at least this much, otherwise the
  /// result is ambiguous even when the winner scores well.
  final double ambiguityMargin;

  /// Below this a candidate is not worth a human's attention either.
  final double plausibilityFloor;

  // Weights. Duration dominates because it is the signal that held to within
  // ~1s across every observed pair; identity is weakest because a contact
  // rename or a withheld number wipes it out entirely.
  static const _wDuration = 0.45;
  static const _wTiming = 0.35;
  static const _wIdentity = 0.20;

  RecordingMatch match(
    CallForMatching call,
    List<RecordingCandidate> candidates,
  ) {
    if (candidates.isEmpty) {
      return const RecordingMatch(
        status: RecordingMatchStatus.notFound,
        confidence: 0,
        reason: 'No recording candidates on this device.',
      );
    }

    // A call that never connected cannot have been recorded. Missed, rejected
    // and failed calls all land here. Skipping this gate is how a neighbouring
    // call's audio gets attached to a missed call.
    if (call.durationSeconds <= 0) {
      return const RecordingMatch(
        status: RecordingMatchStatus.notFound,
        confidence: 0,
        reason: 'Call never connected, so no recording can exist.',
      );
    }

    final scored = <({RecordingCandidate c, double score, MatchSignals s})>[];

    for (final candidate in candidates) {
      final signals = _score(call, candidate);
      if (signals == null) continue; // hard-gated out
      final score =
          _wDuration * signals.durationScore +
          _wTiming * signals.timingScore +
          _wIdentity * signals.identityScore;
      scored.add((c: candidate, score: score, s: signals));
    }

    if (scored.isEmpty) {
      return RecordingMatch(
        status: RecordingMatchStatus.unmatched,
        confidence: 0,
        reason:
            '${candidates.length} candidate(s) examined; none within duration '
            'or timing tolerance.',
      );
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final best = scored.first;
    final runnerUp = scored.length > 1 ? scored[1].score : 0.0;

    if (best.score < plausibilityFloor) {
      return RecordingMatch(
        status: RecordingMatchStatus.unmatched,
        confidence: best.score,
        runnerUpConfidence: runnerUp,
        reason: 'Best candidate scored below the plausibility floor.',
      );
    }

    // Two candidates that both fit is the dangerous case — back-to-back calls
    // of similar length to the same person. Send it for review rather than
    // guessing.
    if (best.score < matchThreshold ||
        (best.score - runnerUp) < ambiguityMargin) {
      return RecordingMatch(
        status: RecordingMatchStatus.ambiguous,
        confidence: best.score,
        candidate: best.c,
        signals: best.s,
        runnerUpConfidence: runnerUp,
        reason: best.score < matchThreshold
            ? 'Best candidate did not reach the confidence threshold.'
            : 'A second candidate scored too close to the best one.',
      );
    }

    return RecordingMatch(
      status: RecordingMatchStatus.matched,
      confidence: best.score,
      candidate: best.c,
      signals: best.s,
      runnerUpConfidence: runnerUp,
      reason: 'Duration and timing both consistent.',
    );
  }

  /// Returns null when the candidate is ruled out outright.
  MatchSignals? _score(CallForMatching call, RecordingCandidate candidate) {
    if (candidate.durationMillis <= 0) return null;

    final durationDelta = (candidate.durationSeconds - call.durationSeconds)
        .abs();
    if (durationDelta > maxDurationDeltaSeconds) return null;

    final ringGap =
        candidate.dateAddedEpochSeconds - call.startedAtEpochSeconds;
    if (ringGap < minRingGapSeconds || ringGap > maxRingGapSeconds) return null;

    // Linear decay to zero at the tolerance edge.
    final durationScore = math.max(
      0.0,
      1.0 - (durationDelta / durationToleranceSeconds),
    );

    // A gap of 0-20s is an ordinary ring and scores full marks; longer gaps are
    // possible but progressively less likely to be THIS call.
    final double timingScore;
    if (ringGap < 0) {
      // Slight negative gap is clock skew, not a real ordering violation.
      timingScore = 0.85;
    } else if (ringGap <= 20) {
      timingScore = 1.0;
    } else {
      timingScore = math.max(
        0.0,
        1.0 - ((ringGap - 20) / (maxRingGapSeconds - 20)),
      );
    }

    final identityMatched = _identityMatches(call, candidate.displayName);

    return MatchSignals(
      durationScore: durationScore,
      timingScore: timingScore,
      // Absence of a filename match is not evidence AGAINST: withheld numbers
      // and unsaved contacts legitimately produce no overlap. Score it neutral
      // rather than zero so it can lift a match but never sink one.
      identityScore: identityMatched ? 1.0 : 0.5,
      durationDeltaSeconds: durationDelta,
      ringGapSeconds: ringGap,
      identityMatched: identityMatched,
    );
  }

  bool _identityMatches(CallForMatching call, String? displayName) {
    if (displayName == null || displayName.isEmpty) return false;
    final haystack = displayName.toLowerCase();

    final number = call.normalizedNumber;
    if (number != null && number.length >= 7) {
      // Compare on the national significant part: the filename may carry
      // +919876543210, 919876543210 or 9876543210 for the same call.
      final digits = number.replaceAll(RegExp(r'[^0-9]'), '');
      final tail = digits.substring(math.max(0, digits.length - 10));
      final haystackDigits = haystack.replaceAll(RegExp(r'[^0-9]'), '');
      if (haystackDigits.contains(tail)) return true;
    }

    final name = call.contactName;
    if (name != null && name.trim().length >= 3) {
      if (haystack.contains(name.trim().toLowerCase())) return true;
    }
    return false;
  }
}
