import 'package:uuid/uuid.dart';

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

/// How a call's identity is derived, on both sides of the platform channel.
///
/// Two independent ingesters write the same outbox table: `NativeCallIngestor`
/// in Kotlin and `ingestNativeCallLogs` in Dart. They are allowed to disagree
/// about when they run, but not about what a given call is *called*, because
/// the idempotency key is the only thing stopping the server from storing the
/// same conversation twice.
///
/// They did disagree. For a withheld or private number the call log yields a
/// null number; Kotlin substituted `"Unknown"` while Dart interpolated the null
/// straight into a string and produced the literal text `"null"`. Same call,
/// two external ids, two v5 UUIDs, two rows locally and **two separate call
/// records on the server** — one per ingester, every time somebody rang from a
/// withheld number.
///
/// **Mirror of `CallWireFormat` in `android/.../call/CallWireFormat.kt`.**
/// Changing either without the other re-opens exactly this bug.
abstract final class CallWireIdentity {
  /// RFC 4122 namespace used for the v5 key. Arbitrary but fixed forever:
  /// changing it renames every call that has ever been queued.
  static const dnsNamespace = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

  /// Placeholder for a number the call log withheld.
  ///
  /// The value matches what Kotlin has always written, so this correction
  /// renames no natively-captured call — only the Dart path moves, onto the
  /// name the other side was already using.
  static const withheldNumber = 'Unknown';

  /// The number as it goes into the external id, the key, and the outbox row.
  ///
  /// Only null is folded. An empty string is left alone deliberately: both
  /// sides already produced the same (ugly) id for it, and folding it here
  /// would rename rows that are not broken.
  static String number(String? raw) => raw ?? withheldNumber;

  /// Stable per-call id built from the call log's own timestamp and number.
  static String externalId({required int startedAtMillis, String? rawNumber}) =>
      'android-$startedAtMillis-${number(rawNumber)}';

  /// The name hashed into the v5 UUID. Both languages must build this string
  /// byte-for-byte identically.
  static String keyName({
    required String externalCallId,
    required int startedAtMillis,
  }) =>
      'zebu:call:$externalCallId:$startedAtMillis';

  /// The idempotency key for a call-log row.
  static String key({required int startedAtMillis, String? rawNumber}) {
    final extId = externalId(
      startedAtMillis: startedAtMillis,
      rawNumber: rawNumber,
    );
    return const Uuid().v5(
      dnsNamespace,
      keyName(externalCallId: extId, startedAtMillis: startedAtMillis),
    );
  }

  /// True for an external id built by the Dart path before the two agreed.
  ///
  /// Used by the one-time repair in `CallsDao.repairDivergentWithheldKeys`.
  static bool isLegacyWithheldExternalId(String? externalCallId) =>
      externalCallId != null && externalCallId.endsWith('-null');
}
