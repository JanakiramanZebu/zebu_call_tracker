/// The `direction` and `status` vocabulary the server accepts, and the only
/// sanctioned way to derive them from an Android call-log row.
///
/// Taken from the Mobile API Guide, §4.4. These are **contractual**: the server
/// validates both the individual values and the combination, and rejects
/// anything else with `422 VALIDATION_ERROR`, which is flagged
/// `retryable: false` — a permanent drop, not a delay.
///
/// This exists because the client previously sent `status: "completed"`, which
/// is not a member of the enum at all. Every answered call — the overwhelming
/// majority of the queue — was therefore rejected on arrival and discarded. The
/// server's terminal status is `ended`.
///
/// **Mirror of `android/.../call/CallWireFormat.kt`.** The native coordinator
/// does the real uploading, so the two must agree exactly; a call must not be
/// described differently depending on which side happened to capture it.
abstract final class CallWireDirection {
  static const incoming = 'incoming';
  static const outgoing = 'outgoing';
  static const unknown = 'unknown';
}

/// §4.4. `ended`, `missed`, `rejected`, `failed` and `cancelled` are terminal.
abstract final class CallWireStatus {
  static const ringing = 'ringing';
  static const dialing = 'dialing';
  static const answered = 'answered';
  static const missed = 'missed';
  static const rejected = 'rejected';
  static const failed = 'failed';
  static const cancelled = 'cancelled';

  /// The normal terminal state of a call that connected and finished.
  static const ended = 'ended';

  static const unknown = 'unknown';

  static const all = {
    ringing, dialing, answered, missed, rejected,
    failed, cancelled, ended, unknown,
  };

  /// Legacy local values that were never valid on the wire.
  static const _legacy = <String, String>{
    'completed': ended,
  };

  static String normalize(String raw) {
    final lower = raw.trim().toLowerCase();
    return _legacy[lower] ?? (all.contains(lower) ? lower : unknown);
  }

  /// `UPDATE`s that fold legacy rows onto the wire vocabulary.
  ///
  /// Run on every database open beside the sync-state normalisation, so a row
  /// captured by an older build is not re-offered to the server with a status
  /// it will refuse. Idempotent.
  static List<String> get normalizationStatements => [
        for (final entry in _legacy.entries)
          "UPDATE local_calls SET status = '${entry.value}' "
              "WHERE status = '${entry.key}';",
      ];
}

/// A legal `(direction, status)` pair.
typedef CallWireOutcome = ({String direction, String status});

/// Maps an Android call-log row onto a pair the server will accept.
///
/// The combination rules matter as much as the values (§4.4):
///
///  - an **outgoing** call can never be `missed` or `rejected`. An outgoing call
///    that never connected is `cancelled` — the caller rang off. Sending
///    `(outgoing, missed)`, as the previous mapping did for any zero-duration
///    outgoing call, is a `422`.
///  - an **incoming** call can never be `dialing`.
///
/// [rawDirection] accepts the local column value or the call-log direction name;
/// anything unrecognised degrades to `unknown`, which §4.4 explicitly allows and
/// permits narrowing later by re-posting.
CallWireOutcome callWireOutcome({
  required String rawDirection,
  required int durationSeconds,
  String? rawStatus,
}) {
  final direction = rawDirection.trim().toLowerCase();
  final status = rawStatus?.trim().toLowerCase();
  final connected = durationSeconds > 0;

  // An explicit terminal status from the call log wins over inference.
  if (status == CallWireStatus.missed || direction == 'missed') {
    // Only an incoming call can be missed.
    return (
      direction: CallWireDirection.incoming,
      status: CallWireStatus.missed,
    );
  }
  if (status == CallWireStatus.rejected ||
      direction == 'rejected' ||
      direction == 'blocked') {
    return (
      direction: CallWireDirection.incoming,
      status: CallWireStatus.rejected,
    );
  }

  if (direction == CallWireDirection.outgoing || direction.contains('out')) {
    return (
      direction: CallWireDirection.outgoing,
      // Dialled but never answered. NOT `missed` — illegal for outgoing.
      status: connected ? CallWireStatus.ended : CallWireStatus.cancelled,
    );
  }

  if (direction == CallWireDirection.incoming ||
      direction.contains('in') ||
      direction == 'voicemail') {
    return (
      direction: CallWireDirection.incoming,
      status: connected ? CallWireStatus.ended : CallWireStatus.missed,
    );
  }

  return (
    direction: CallWireDirection.unknown,
    status: connected ? CallWireStatus.ended : CallWireStatus.unknown,
  );
}
