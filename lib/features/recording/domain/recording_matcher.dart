import 'dart:isolate';
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
  RecordingCandidate({
    required this.mediaStoreId,
    required this.displayName,
    required this.durationMillis,
    required this.sizeBytes,
    required this.dateAddedEpochSeconds,
    required this.dateModifiedEpochSeconds,
    this.mimeType,
    this.relativePath,
    this.source = 'UNKNOWN',
    String? normalizedDigits,
    String? lowerDisplayName,
  })  : _cachedNormalizedDigits = normalizedDigits ??
            (displayName != null
                ? _staticNormalize(displayName)
                : ''),
        _cachedLowerDisplayName =
            lowerDisplayName ?? (displayName?.toLowerCase() ?? '');

  final int mediaStoreId;
  final String? displayName;
  final int durationMillis;
  final int sizeBytes;

  /// When the MediaStore row was created. On an OPEN-stamping dialer (the
  /// Samsung reference device) that is when recording STARTED, roughly when
  /// the call was answered; on an END-stamping one it is the hang-up.
  final int dateAddedEpochSeconds;

  /// When the dialer finished writing — in practice, when recording STOPPED,
  /// whichever convention stamped [dateAddedEpochSeconds].
  final int dateModifiedEpochSeconds;

  final String? mimeType;
  final String? relativePath;
  final String source;

  final String _cachedNormalizedDigits;
  final String _cachedLowerDisplayName;

  String get normalizedDigits => _cachedNormalizedDigits;
  String get lowerDisplayName => _cachedLowerDisplayName;

  double get durationSeconds => durationMillis / 1000.0;

  /// `dateModified - dateAdded`. What it means depends on the dialer:
  ///
  ///  - OPEN-stamped: the file's open-to-close time, so an intact file's
  ///    lifetime reproduces [durationSeconds].
  ///  - END-stamped: the row is created when the file is CLOSED, at hang-up,
  ///    so both stamps sit at the end of the call and the lifetime is about
  ///    zero, or slightly negative when the media scanner indexed it a moment
  ///    after the last write.
  int get lifetimeSeconds =>
      dateModifiedEpochSeconds - dateAddedEpochSeconds;

  /// When recording started, read as an END-stamped file: the close time
  /// minus the audio. [dateModifiedEpochSeconds] is the close (the file's
  /// last write) even when the row was indexed later; [dateAddedEpochSeconds]
  /// stands in when it is missing.
  int get endStampedStartEpochSeconds =>
      (dateModifiedEpochSeconds > 0
          ? dateModifiedEpochSeconds
          : dateAddedEpochSeconds) -
      durationSeconds.round();

  /// When recording most likely started, for screens that hold only the file
  /// and not the matcher's verdict ([MatchSignals.endStamped] says it exactly).
  /// A lifetime of about zero on a file longer than that is the END-stamped
  /// signature; anything else reads as [dateAddedEpochSeconds].
  int get likelyStartEpochSeconds =>
      lifetimeSeconds <= 5 && durationSeconds > 20
          ? endStampedStartEpochSeconds
          : dateAddedEpochSeconds;

  static String _staticNormalize(String name) {
    return name.replaceAll(_nonDigits, '');
  }
}

/// Built once: candidates are constructed by the hundred per scan.
final _nonDigits = RegExp(r'[^0-9]');

/// The subset of a call record the matcher reasons over.
class CallForMatching {
  CallForMatching({
    required this.startedAtEpochMillis,
    required this.durationSeconds,
    this.normalizedNumber,
    this.contactName,
    this.answeredAtEpochMillis,
    String? cachedNumberTail,
    String? cachedLowerContactName,
  })  : _cachedNumberTail = cachedNumberTail ?? _extractTail(normalizedNumber),
        _cachedLowerContactName =
            cachedLowerContactName ?? (contactName?.trim().toLowerCase() ?? '');

  /// `CallLog.Calls.DATE` — when the call STARTED (began ringing/dialling),
  /// not when it was answered.
  final int startedAtEpochMillis;

  /// `CallLog.Calls.DURATION` — CONNECTED seconds only. Ring time is not
  /// included, which is precisely why a recording starts after the call start
  /// rather than on it.
  final int durationSeconds;

  final String? normalizedNumber;
  final String? contactName;

  /// When the call was actually picked up, if the device could say.
  ///
  /// This is the anchor that turns matching from a duration coincidence into a
  /// statement about the same instant: an OEM dialer starts recording when the
  /// call connects, so the recording's estimated start and this value describe
  /// one event and should agree to within a second or two. Null falls back to
  /// the original heuristic scoring.
  final int? answeredAtEpochMillis;

  final String _cachedNumberTail;
  final String _cachedLowerContactName;

  int get startedAtEpochSeconds => startedAtEpochMillis ~/ 1000;

  int? get answeredAtEpochSeconds =>
      answeredAtEpochMillis == null ? null : answeredAtEpochMillis! ~/ 1000;
  String get cachedNumberTail => _cachedNumberTail;
  String get cachedLowerContactName => _cachedLowerContactName;

  static String _extractTail(String? number) {
    if (number == null || number.length < 7) return '';
    final digits = number.replaceAll(_nonDigits, '');
    return digits.substring(math.max(0, digits.length - 10));
  }
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
    this.anchorScore,
    this.anchorDeltaSeconds,
    this.endStamped = false,
  });

  final double durationScore;
  final double timingScore;
  final double identityScore;

  /// How closely the file opened to the known answer instant. Null when no
  /// answer time was available and the heuristic path was taken.
  final double? anchorScore;

  /// |recording duration − call duration|, in seconds.
  final double durationDeltaSeconds;

  /// Estimated recording start − call start. Should be a plausible ring time.
  final int ringGapSeconds;

  /// |recording start − call answer|, in seconds. Null on the heuristic path.
  final int? anchorDeltaSeconds;

  final bool identityMatched;

  /// Which reading of the file's stamps won: true when its start was taken
  /// as `dateModified` minus the audio (stamped at close), false when it was
  /// `dateAdded` (stamped at open).
  final bool endStamped;

  /// True when an answer time was known and the file lines up with it.
  bool get isAnchored => anchorScore != null && anchorScore! > 0;

  @override
  String toString() =>
      'dur=${durationDeltaSeconds.toStringAsFixed(1)}s '
      'ring=${ringGapSeconds}s '
      '${anchorDeltaSeconds == null ? '' : 'anchor=${anchorDeltaSeconds}s '}'
      '${endStamped ? 'end-stamped ' : ''}'
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
    this.rankedCandidates = const [],
  });

  final RecordingMatchStatus status;
  final double confidence;
  final RecordingCandidate? candidate;
  final MatchSignals? signals;
  final double runnerUpConfidence;
  final String reason;

  /// Every candidate that survived the hard gates, best first.
  ///
  /// The review UI needs more than the winner to offer a choice. This used to
  /// be computed and thrown away, which is why "Review required" could be shown
  /// with nothing to review.
  final List<RankedCandidate> rankedCandidates;
}

/// A scored candidate, for the ambiguity UI and the audit trail.
class RankedCandidate {
  const RankedCandidate({
    required this.candidate,
    required this.confidence,
    required this.signals,
  });

  final RecordingCandidate candidate;
  final double confidence;
  final MatchSignals signals;
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
/// The recording's START is estimated per candidate, because dialers disagree
/// on what `date_added` means. That device stamps the file when it OPENS it;
/// other OEMs create the row when the file is CLOSED, at hang-up, leaving a
/// lifetime of about zero. Every timing rule (ring gap, timing score, anchor)
/// measures from the estimate, so both conventions match at any call length.
/// See [_score].
///
/// Filenames are used only as a weak tie-breaker. They are unstable even within
/// one vendor: the reference device carries both
/// `Call recording <name>_YYMMDD_HHMMSS.m4a` (2025 builds) and
/// `Call <name>_YYMMDD_HHMMSS.m4a` (2026 builds), and a contact rename changes
/// them retroactively for future files. Never match on filename alone.
///
/// **Every constant and weight below is mirrored in
/// `android/.../recording/NativeRecordingMatcher.kt`**, which matches while
/// Flutter is closed. Nothing enforces that at build time, so a change here is
/// only half a change until the Kotlin file matches it value for value.
class RecordingMatcher {
  const RecordingMatcher({
    this.durationToleranceSeconds = 5.0,
    this.maxDurationDeltaSeconds = 15.0,
    this.durationDriftRatio = 0.02,
    this.maxRingGapSeconds = 180,
    this.minRingGapSeconds = -15,
    this.matchThreshold = 0.70,
    this.ambiguityMargin = 0.15,
    this.plausibilityFloor = 0.40,
    this.anchorToleranceSeconds = 2.0,
    this.maxAnchorDeltaSeconds = 10,
    this.maxLifetimeDeltaSeconds = 15.0,
    this.maxEndStampLifetimeSeconds = 5,
  });

  /// Beyond this delta the duration score decays to zero. Widened for long
  /// calls; see [durationDriftRatio].
  final double durationToleranceSeconds;

  /// Hard gate: a bigger gap than this is a different call, whatever else lines
  /// up. Widened for long calls; see [durationDriftRatio].
  final double maxDurationDeltaSeconds;

  /// How far a long call's audio may drift from its call-log duration, as a
  /// fraction of that duration. The duration tolerance, its hard gate and the
  /// lifetime gate all widen in proportion beyond 750 s (where 2% passes
  /// 15 s): max(15 s, 2%) is 72 s on an hour-long call. A fixed 15 s rejected
  /// long recordings whose dialer paused or resampled for a few seconds per
  /// ten minutes. Cross-matching stays out of reach because the ring-gap gate
  /// does not widen, and two long calls cannot both start within it.
  final double durationDriftRatio;

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

  /// How far a recording's estimated start may sit from a known answer time
  /// before the anchor scores zero. Both are whole seconds from different
  /// providers, so one second of slack is rounding and two is generous.
  final double anchorToleranceSeconds;

  /// Beyond this the candidate is rejected outright when an answer time is
  /// known. A dialer does not start recording ten seconds away from the moment
  /// the call connected; a file that did belongs to a different call.
  final int maxAnchorDeltaSeconds;

  /// How far a file's open-to-close lifetime may differ from the audio it
  /// contains, read as an OPEN-stamped file, before it is treated as truncated
  /// or still being written. Widened for long calls like the duration gate.
  final double maxLifetimeDeltaSeconds;

  /// A lifetime at or below this reads as END-stamped: the dialer created the
  /// row when it closed the file, so both stamps sit at hang-up.
  final int maxEndStampLifetimeSeconds;

  // Heuristic weights: no answer time available. Duration dominates because it
  // is the signal that held to within ~1s across every observed pair; identity
  // is weakest because a contact rename or a withheld number wipes it out
  // entirely.
  static const _wDuration = 0.45;
  static const _wTiming = 0.35;
  static const _wIdentity = 0.20;

  // Anchored weights: an answer time IS available. The anchor takes half the
  // weight because it is the only signal that identifies a SPECIFIC call rather
  // than a plausible one — it is what separates two back-to-back calls of
  // similar length to the same person, which is precisely the case the
  // heuristic path has to declare ambiguous.
  static const _waAnchor = 0.50;
  static const _waDuration = 0.25;
  static const _waTiming = 0.10;
  static const _waIdentity = 0.15;

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
      scored.add((c: candidate, score: _weigh(signals), s: signals));
    }

    if (scored.isEmpty) {
      // The anchor gate is strict by design. Both stamping conventions are
      // read from the file's own lifetime now, but the answer time can still
      // be off on a handset whose journal is wrong, or whose audio drifts from
      // the wall clock over a long call — and then every candidate is
      // rejected, which is worse than the heuristic this replaced.
      //
      // So when the anchor eliminates EVERYTHING, it is treated as evidence
      // about the device rather than about the recordings, and the call is
      // rescored without it. The heuristic path is the floor; anchoring can
      // only improve on it, never lose to it.
      if (call.answeredAtEpochMillis != null) {
        return match(
          CallForMatching(
            startedAtEpochMillis: call.startedAtEpochMillis,
            durationSeconds: call.durationSeconds,
            normalizedNumber: call.normalizedNumber,
            contactName: call.contactName,
          ),
          candidates,
        );
      }
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
    final ranked = scored
        .map(
          (e) => RankedCandidate(
            candidate: e.c,
            confidence: e.score,
            signals: e.s,
          ),
        )
        .toList(growable: false);

    if (best.score < plausibilityFloor) {
      return RecordingMatch(
        status: RecordingMatchStatus.unmatched,
        confidence: best.score,
        runnerUpConfidence: runnerUp,
        rankedCandidates: ranked,
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
        rankedCandidates: ranked,
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
      rankedCandidates: ranked,
      reason: best.s.isAnchored
          ? 'Recording started at the moment the call was answered.'
          : 'Duration and timing both consistent.',
    );
  }

  /// Applies whichever weight set the available signals justify.
  double _weigh(MatchSignals s) {
    final anchor = s.anchorScore;
    if (anchor != null) {
      return _waAnchor * anchor +
          _waDuration * s.durationScore +
          _waTiming * s.timingScore +
          _waIdentity * s.identityScore;
    }
    return _wDuration * s.durationScore +
        _wTiming * s.timingScore +
        _wIdentity * s.identityScore;
  }

  /// How much the duration and lifetime allowances widen for this call: 1 up
  /// to 750 s, then in proportion to its length. See [durationDriftRatio].
  double _driftScale(CallForMatching call) => math.max(
        1.0,
        call.durationSeconds * durationDriftRatio / maxDurationDeltaSeconds,
      );

  /// Scores the candidate under each stamping convention its own lifetime
  /// allows, and keeps the better reading. Null when neither survives.
  ///
  ///  - OPEN: the recording started at `dateAdded`. Only when the lifetime
  ///    reproduces the audio duration — the lifetime check, which belongs to
  ///    this reading alone — or when there is no `dateModified` to check.
  ///  - END: the recording started at `dateModified` minus the audio. When
  ///    the lifetime is about zero (the row was made at hang-up) or clearly
  ///    shorter than the audio (the row was indexed mid-call).
  ///
  /// A file plausible both ways — a short one, or one with no `dateModified`
  /// — is scored both ways. Its best reading is still ONE candidate, so it
  /// cannot make itself ambiguous. A file held open longer than its audio by
  /// more than the tolerance fits neither: something touched it after the
  /// dialer closed it.
  ///
  /// A zero lifetime on a long file is NOT also read as open-stamped (the old
  /// rule let any lifetime of zero or less through). Its `dateAdded` is the
  /// hang-up, which is exactly where the next call to the same person starts,
  /// so that reading turned every quick call-back into a tie.
  ///
  /// Before this, every rule measured from `dateAdded`, so on a dialer that
  /// stamps at close a call longer than the 180 s ring gate (or, through the
  /// lifetime check, longer than about 15 s) could never be matched, anchor or
  /// not.
  MatchSignals? _score(CallForMatching call, RecordingCandidate candidate) {
    if (candidate.durationMillis <= 0) return null;

    final scale = _driftScale(call);
    final durationDelta = (candidate.durationSeconds - call.durationSeconds)
        .abs();
    if (durationDelta > maxDurationDeltaSeconds * scale) return null;

    final lifetime = candidate.lifetimeSeconds;
    final lifetimeTolerance = maxLifetimeDeltaSeconds * scale;
    final lifetimeDelta = (lifetime - candidate.durationSeconds).abs();

    // A file whose open-to-close lifetime does not reproduce its own audio
    // duration is, read as open-stamped, truncated, still being written, or
    // copied here by something other than the dialer.
    final open = (candidate.dateModifiedEpochSeconds <= 0 ||
            lifetimeDelta <= lifetimeTolerance)
        ? _scoreAt(call, candidate, candidate.dateAddedEpochSeconds,
            endStamped: false, durationDelta: durationDelta, scale: scale)
        : null;
    final end = (lifetime <= maxEndStampLifetimeSeconds ||
            lifetime < candidate.durationSeconds - lifetimeTolerance)
        ? _scoreAt(call, candidate, candidate.endStampedStartEpochSeconds,
            endStamped: true, durationDelta: durationDelta, scale: scale)
        : null;

    if (open == null || end == null) return open ?? end;
    // Ties go to the open reading, the convention the model was built on.
    return _weigh(end) > _weigh(open) ? end : open;
  }

  /// Scores the candidate as a recording that started at [startedAtSeconds].
  MatchSignals? _scoreAt(
    CallForMatching call,
    RecordingCandidate candidate,
    int startedAtSeconds, {
    required bool endStamped,
    required double durationDelta,
    required double scale,
  }) {
    final ringGap = startedAtSeconds - call.startedAtEpochSeconds;
    if (ringGap < minRingGapSeconds || ringGap > maxRingGapSeconds) return null;

    // Hard anchor gate. When the answer instant is known, a file that did not
    // start recording at that instant belongs to another call, however well
    // its duration happens to line up.
    int? anchorDelta;
    double? anchorScore;
    final answeredAtSeconds = call.answeredAtEpochSeconds;
    if (answeredAtSeconds != null) {
      final delta = (startedAtSeconds - answeredAtSeconds).abs();
      if (delta > maxAnchorDeltaSeconds) return null;
      anchorDelta = delta;
      anchorScore = math.max(0.0, 1.0 - (delta / anchorToleranceSeconds));
    }

    // Linear decay to zero at the tolerance edge.
    final durationScore = math.max(
        0.0,
        1.0 - (durationDelta / (durationToleranceSeconds * scale)),
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

    final identityMatched = _identityMatches(call, candidate);

    return MatchSignals(
      durationScore: durationScore,
      timingScore: timingScore,
      // Absence of a filename match is not evidence AGAINST: withheld numbers
      // and unsaved contacts legitimately produce no overlap. Score it neutral
      // rather than zero so it can lift a match but never sink one.
      identityScore: identityMatched ? 1.0 : 0.5,
      anchorScore: anchorScore,
      durationDeltaSeconds: durationDelta,
      ringGapSeconds: ringGap,
      anchorDeltaSeconds: anchorDelta,
      identityMatched: identityMatched,
      endStamped: endStamped,
    );
  }

  bool _identityMatches(CallForMatching call, RecordingCandidate candidate) {
    final lowerDisplayName = candidate._cachedLowerDisplayName;
    if (lowerDisplayName.isEmpty) return false;

    final tail = call._cachedNumberTail;
    if (tail.isNotEmpty) {
      if (candidate._cachedNormalizedDigits.contains(tail)) return true;
    }

    final name = call._cachedLowerContactName;
    if (name.length >= 3) {
      if (lowerDisplayName.contains(name)) return true;
    }
    return false;
  }

  /// Matches a batch of calls against candidates.
  /// Pure Dart function, safe to run inside a background isolate.
  static Map<int, RecordingMatch> matchBatch(
    List<CallForMatching> calls,
    List<RecordingCandidate> candidates, {
    RecordingMatcher matcher = const RecordingMatcher(),
  }) {
    final results = <int, RecordingMatch>{};
    for (final call in calls) {
      results[call.startedAtEpochMillis] = matcher.match(call, candidates);
    }
    return results;
  }

  /// Executes [matchBatch] in a background isolate using [Isolate.run]
  /// to keep CPU-intensive matching off the Flutter UI thread.
  static Future<Map<int, RecordingMatch>> matchBatchInIsolate({
    required List<CallForMatching> calls,
    required List<RecordingCandidate> candidates,
    RecordingMatcher matcher = const RecordingMatcher(),
  }) {
    if (calls.isEmpty || candidates.isEmpty) {
      return Future.value(const {});
    }
    return Isolate.run(() => matchBatch(calls, candidates, matcher: matcher));
  }
}
