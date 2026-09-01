import '../../../core/platform/native_call_bridge.dart';
import '../../../core/storage/app_database.dart';
import '../../recording/domain/recording_matcher.dart';

/// Where a call record stands with the server.
///
/// Distinct from [RecordingMatchStatus]: a call can be uploaded while its
/// recording is still queued, and re-uploading must never disturb a settled
/// association.
enum UploadState { pending, uploading, uploaded, failed }

/// One call as the UI needs it: the log row, whatever recording was matched to
/// it, and its sync state.
///
/// Deliberately immutable and free of platform types beyond the DTOs, so screens
/// can be built and tested without a device.
class CallEntry {
  const CallEntry({
    required this.row,
    required this.match,
    this.uploadState = UploadState.pending,
    this.contactName,
  });

  final CallLogRow row;
  final RecordingMatch match;
  final UploadState uploadState;

  /// Resolved from Contacts. Null is normal — permission may be denied, or the
  /// number may simply not be saved.
  final String? contactName;

  /// The deterministic identity used for server-side deduplication (brief §28).
  ///
  /// Built from call-log fields rather than broadcast timing, so the same call
  /// yields the same key across process death, reboot and manual retries.
  String idempotencySeed(String deviceId) => [
    deviceId,
    row.number ?? 'withheld',
    row.dateMillis?.toString() ?? '0',
    row.direction.name,
  ].join('|');

  /// What to show as the primary line. Falls back through contact name, cached
  /// name from the log, then a description of why there is no name — never an
  /// empty string.
  String get displayTitle {
    final name = contactName ?? row.cachedName;
    if (name != null && name.trim().isNotEmpty) return name;
    return switch (row.presentation) {
      NumberPresentation.restricted => 'Private number',
      NumberPresentation.payphone => 'Payphone',
      NumberPresentation.unknown => 'Unknown number',
      NumberPresentation.allowed => 'Unknown number',
    };
  }

  bool get hasName =>
      (contactName ?? row.cachedName)?.trim().isNotEmpty ?? false;

  int get durationSeconds => row.durationSeconds ?? 0;

  bool get isConnected => durationSeconds > 0;

  DateTime? get startedAtUtc => row.startedAtUtc;

  RecordingCandidate? get recording =>
      match.status == RecordingMatchStatus.matched ? match.candidate : null;

  bool get needsReview => match.status == RecordingMatchStatus.ambiguous;
}

/// Aggregates for the dashboard. Computed over a day's entries in one pass —
/// with thousands of records on device, four separate `.where()` walks would be
/// four times the work for no benefit.
class CallStats {
  const CallStats({
    required this.incoming,
    required this.outgoing,
    required this.missed,
    required this.rejected,
    required this.neverAttended,
    required this.notPickupByClient,
    required this.uniqueCalls,
    required this.answered,
    required this.talkTimeSeconds,
    required this.incomingDurationSeconds,
    required this.outgoingDurationSeconds,
    required this.recordingsMatched,
    required this.recordingsNeedReview,
    required this.recordingsAbsent,
    required this.recordingsNotApplicable,
    required this.callsByHour,
  });

  final int incoming;
  final int outgoing;
  final int missed;
  final int rejected;
  final int neverAttended;
  final int notPickupByClient;
  final int uniqueCalls;
  final int answered;
  final int talkTimeSeconds;
  final int incomingDurationSeconds;
  final int outgoingDurationSeconds;
  final int recordingsMatched;
  final int recordingsNeedReview;

  /// Connected calls that should have audio and do not.
  ///
  /// Counts only calls that could have been recorded. A missed or rejected call
  /// has no audio by definition, and lumping those in here — as this once did —
  /// makes recording coverage look broken on any day with a normal number of
  /// unanswered calls.
  final int recordingsAbsent;

  /// Calls no recording could ever exist for: missed, rejected, never connected.
  final int recordingsNotApplicable;

  /// Connected-call counts indexed by local hour, 0–23. Drives peak-time.
  final List<int> callsByHour;

  int get total => incoming + outgoing + missed + rejected;

  int get averageDurationSeconds =>
      answered == 0 ? 0 : talkTimeSeconds ~/ answered;

  /// Calls a recording is expected for. The denominator for coverage.
  int get recordingEligible =>
      recordingsMatched + recordingsNeedReview + recordingsAbsent;

  /// Share of recordable calls whose audio was found, 0–100.
  ///
  /// Measured against [recordingEligible], never against [total]: dividing by
  /// every call silently caps this at the answered rate, so a handset capturing
  /// every single recording still reported a number well under 100%.
  double get recordingCoverageRate => recordingEligible == 0
      ? 0
      : recordingsMatched / recordingEligible * 100;

  double get answeredRate => total == 0 ? 0 : answered / total * 100;

  double get missedRate => total == 0 ? 0 : missed / total * 100;

  /// Busiest two-hour band, or null when there is nothing to rank.
  ///
  /// Returned as the start hour of the band in local time. The dashboard used
  /// to print a hardcoded "10 AM – 12 PM" here regardless of the data.
  int? get peakHourStart {
    if (callsByHour.length != 24) return null;
    int? bestHour;
    var bestCount = 0;
    for (var h = 0; h < 24; h++) {
      final count = callsByHour[h] + callsByHour[(h + 1) % 24];
      if (count > bestCount) {
        bestCount = count;
        bestHour = h;
      }
    }
    return bestCount == 0 ? null : bestHour;
  }

  static const empty = CallStats(
    incoming: 0,
    outgoing: 0,
    missed: 0,
    rejected: 0,
    neverAttended: 0,
    notPickupByClient: 0,
    uniqueCalls: 0,
    answered: 0,
    talkTimeSeconds: 0,
    incomingDurationSeconds: 0,
    outgoingDurationSeconds: 0,
    recordingsMatched: 0,
    recordingsNeedReview: 0,
    recordingsAbsent: 0,
    recordingsNotApplicable: 0,
    callsByHour: _noCalls,
  );

  static const _noCalls = <int>[
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ];

  factory CallStats.from(Iterable<CallEntry> entries) {
    var incoming = 0,
        outgoing = 0,
        missed = 0,
        rejected = 0,
        neverAttended = 0,
        notPickupByClient = 0,
        answered = 0,
        talk = 0,
        incomingTalk = 0,
        outgoingTalk = 0,
        matched = 0,
        review = 0,
        absent = 0,
        notApplicable = 0;

    final uniqueNumbers = <String>{};
    final byHour = List<int>.filled(24, 0);

    for (final e in entries) {
      final key = _dedupeKey(e.row.number);
      if (key != null) uniqueNumbers.add(key);

      final startedAt = e.row.startedAtUtc?.toLocal();
      if (startedAt != null && e.isConnected) byHour[startedAt.hour]++;

      switch (e.row.direction) {
        case CallDirection.incoming:
          incoming++;
          if (e.isConnected) {
            incomingTalk += e.durationSeconds;
          } else {
            neverAttended++;
          }
        case CallDirection.outgoing:
          outgoing++;
          if (e.isConnected) {
            outgoingTalk += e.durationSeconds;
          } else {
            notPickupByClient++;
          }
        case CallDirection.missed:
          missed++;
          neverAttended++;
        case CallDirection.rejected:
        case CallDirection.blocked:
          rejected++;
        case CallDirection.voicemail:
        case CallDirection.unknown:
          break;
      }

      if (e.isConnected) {
        answered++;
        talk += e.durationSeconds;
      }

      // Only a call that connected can have audio. Anything else is not a
      // coverage gap and must not be counted as one.
      if (!e.isConnected) {
        notApplicable++;
      } else {
        switch (e.match.status) {
          case RecordingMatchStatus.matched:
            matched++;
          case RecordingMatchStatus.ambiguous:
            review++;
          case RecordingMatchStatus.unmatched:
          case RecordingMatchStatus.notFound:
            absent++;
        }
      }
    }

    return CallStats(
      incoming: incoming,
      outgoing: outgoing,
      missed: missed,
      rejected: rejected,
      neverAttended: neverAttended,
      notPickupByClient: notPickupByClient,
      uniqueCalls: uniqueNumbers.length,
      answered: answered,
      talkTimeSeconds: talk,
      incomingDurationSeconds: incomingTalk,
      outgoingDurationSeconds: outgoingTalk,
      recordingsMatched: matched,
      recordingsNeedReview: review,
      recordingsAbsent: absent,
      recordingsNotApplicable: notApplicable,
      callsByHour: byHour,
    );
  }

  /// Normalises a number down to what makes two records the same client.
  ///
  /// Unique-contact counts used the raw string, so `+919876543210`,
  /// `09876543210` and `98765 43210` — one client — counted as three. Compares
  /// on the last 10 digits, which is the national significant number in the
  /// only market this ships to and is stable across the formats OEM dialers
  /// write into the call log.
  static String? _dedupeKey(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == 'Unknown' || trimmed == 'withheld') {
      return null;
    }
    final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return trimmed.toLowerCase(); // short codes, SIP ids
    return digits.length <= 10
        ? digits
        : digits.substring(digits.length - 10);
  }

  factory CallStats.fromLocalCalls(Iterable<LocalCall> calls) {
    var incoming = 0,
        outgoing = 0,
        missed = 0,
        rejected = 0,
        neverAttended = 0,
        notPickupByClient = 0,
        answered = 0,
        talk = 0,
        incomingTalk = 0,
        outgoingTalk = 0,
        matched = 0,
        review = 0,
        absent = 0,
        notApplicable = 0;

    final uniqueNumbers = <String>{};
    final byHour = List<int>.filled(24, 0);

    for (final c in calls) {
      // Prefer the normalised column the ingest pipeline already computed;
      // fall back to normalising the raw value the same way the feed does, so
      // both factories agree on what "unique" means.
      final key = _dedupeKey(c.normalizedPhoneNumber ?? c.phoneNumber);
      if (key != null) uniqueNumbers.add(key);

      final dir = c.direction.toLowerCase();
      final status = c.status.toLowerCase();
      final isConnected = c.durationSeconds > 0;

      final isMissed = dir == 'missed' || status == 'missed';
      final isRejected = dir == 'rejected' || status == 'rejected';

      if (isMissed) {
        missed++;
        neverAttended++;
      } else if (isRejected) {
        rejected++;
      } else if (dir == 'incoming') {
        incoming++;
        if (isConnected) {
          incomingTalk += c.durationSeconds;
        } else {
          neverAttended++;
        }
      } else if (dir == 'outgoing') {
        outgoing++;
        if (isConnected) {
          outgoingTalk += c.durationSeconds;
        } else {
          notPickupByClient++;
        }
      }

      if (isConnected) {
        answered++;
        talk += c.durationSeconds;
        byHour[c.startedAt.toLocal().hour]++;
      }

      // Mirrors CallStats.from: audio is only expected of a connected call.
      // `review` stays 0 on this path — the ambiguity signal lives in the
      // matcher's output, which the stored row does not carry.
      if (!isConnected) {
        notApplicable++;
      } else if (c.hasRecording) {
        matched++;
      } else {
        absent++;
      }
    }

    return CallStats(
      incoming: incoming,
      outgoing: outgoing,
      missed: missed,
      rejected: rejected,
      neverAttended: neverAttended,
      notPickupByClient: notPickupByClient,
      uniqueCalls: uniqueNumbers.length,
      answered: answered,
      talkTimeSeconds: talk,
      incomingDurationSeconds: incomingTalk,
      outgoingDurationSeconds: outgoingTalk,
      recordingsMatched: matched,
      recordingsNeedReview: review,
      recordingsAbsent: absent,
      recordingsNotApplicable: notApplicable,
      callsByHour: byHour,
    );
  }
}
