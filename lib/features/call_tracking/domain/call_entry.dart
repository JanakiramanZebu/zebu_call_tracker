import '../../../core/platform/native_call_bridge.dart';
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
  final int recordingsAbsent;

  int get total => incoming + outgoing + missed + rejected;

  int get averageDurationSeconds =>
      answered == 0 ? 0 : talkTimeSeconds ~/ answered;

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
  );

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
        absent = 0;

    final uniqueNumbers = <String>{};

    for (final e in entries) {
      final number = e.row.number?.trim() ?? '';
      if (number.isNotEmpty) {
        uniqueNumbers.add(number);
      }

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
    );
  }
}
