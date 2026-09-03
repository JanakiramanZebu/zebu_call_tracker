import 'dart:convert';

import '../../../core/network/call_wire_format.dart';
import '../../../core/platform/native_call_bridge.dart';
import '../../recording/domain/recording_matcher.dart';

/// Turns a call-log row plus whatever else the device knows into the two things
/// the outbox cannot derive for itself: real `answered_at` / `ended_at`
/// timestamps, and the JSON `metadata` bag the server accepts alongside them.
///
/// **Mirror of `android/.../call/CallEnrichment.kt`.** Two ingesters write the
/// same outbox table and the server must not be able to tell which one produced
/// a record, so every rule below has a counterpart there.
///
/// The governing rule throughout: **a null is an answer.** Every field here is
/// optional on the wire, and the server recomputes `duration_seconds` from
/// `answered_at`/`ended_at` whenever both are present — so a confident wrong
/// pair corrupts a record that an absent pair would merely have left thin.
abstract final class CallEnrichment {
  /// The server rejects a `metadata` object larger than this.
  static const maxMetadataBytes = 8 * 1024;

  /// How closely a recording's open-to-close lifetime must reproduce its audio
  /// duration before `dateAdded` is trusted as the answer instant.
  static const openStampToleranceSeconds = 5;

  /// Largest gap between the log's date and the matching journal transition.
  static const _searchSkewMillis = 5000;

  /// Longest plausible ring, matching [RecordingMatcher]'s own bound.
  static const _maxRingMillis = 180000;

  /// How far the journal's measured talk time may differ from `DURATION`.
  static const _corroborationToleranceMillis = 5000;

  /// Whether this file's timestamps follow the open-stamped convention.
  ///
  /// A dialer that stamps `dateAdded` when it opens the file leaves
  /// `dateModified - dateAdded` equal to the audio duration. One that stamps
  /// both at close leaves a lifetime of roughly zero. Only in the first case
  /// does `dateAdded` mean "the call was answered", so the device tells us
  /// which reading is safe instead of us assuming one.
  static bool isOpenStamped(RecordingCandidate candidate) {
    final lifetime =
        candidate.dateModifiedEpochSeconds - candidate.dateAddedEpochSeconds;
    if (lifetime <= 0) return false;
    return (lifetime - candidate.durationSeconds).abs() <=
        openStampToleranceSeconds;
  }

  /// Locates the `ringing`/`offhook`/`idle` transitions belonging to one call.
  ///
  /// Returns null when nothing in the journal corroborates it. All-or-nothing
  /// on purpose: half a window paired with a guessed other half is how a wrong
  /// `answered_at` reaches the server.
  static CallWindow? windowFor(
    List<CallStateEvent> journal,
    int startedAtMillis,
    int durationSeconds,
  ) {
    if (journal.isEmpty) return null;

    final durationMillis = durationSeconds * 1000;
    final from = startedAtMillis - _searchSkewMillis;
    final until =
        startedAtMillis + _maxRingMillis + durationMillis + _searchSkewMillis;

    final inWindow = journal
        .where((e) => e.atMillis >= from && e.atMillis <= until)
        .toList(growable: false);
    if (inWindow.isEmpty) return null;

    int? firstAt(bool Function(CallStateEvent) test) {
      for (final e in inWindow) {
        if (test(e)) return e.atMillis;
      }
      return null;
    }

    final ringing = firstAt((e) => e.state == 'ringing');
    final offHook = firstAt((e) => e.state == 'offhook');
    final idle = firstAt(
      (e) => e.state == 'idle' && (offHook == null || e.atMillis > offHook),
    );

    if (offHook == null || idle == null) return null;

    // A call that connected must show at least as much talk time as the log
    // reports. An incoming call's offhook..idle span should very nearly equal
    // it; an outgoing call's also contains the ring, so it may be longer.
    final measured = idle - offHook;
    if (measured < durationMillis - _corroborationToleranceMillis) return null;

    final isIncoming = ringing != null;
    if (isIncoming &&
        measured > durationMillis + _corroborationToleranceMillis) {
      return null;
    }
    if (!isIncoming && measured > durationMillis + _maxRingMillis) return null;

    return CallWindow(
      ringingAtMillis: ringing,
      offHookAtMillis: offHook,
      idleAtMillis: idle,
    );
  }

  /// Resolves when the call was answered and when it ended.
  ///
  /// The ladder, strongest first:
  ///
  ///  1. **Journal.** `offhook` is the pickup — but only for an INCOMING call.
  ///     An outgoing call has no ringing state: `offhook` fires when dialling
  ///     starts, and the remote party answering produces no broadcast at all.
  ///     `ACTION_PHONE_STATE_CHANGED` cannot report an outgoing answer, so
  ///     using it there would report dial time as talk time and inflate every
  ///     outgoing call by its ring. `idle` is the hangup in both directions.
  ///  2. **Recording.** `dateAdded` / `dateModified`, where [isOpenStamped]
  ///     confirms the device means what we think by them.
  ///  3. **Derived.** `answered + duration` for the end, once the answer is
  ///     known from either source above.
  ///  4. **Null.** Backfill, missed calls, and anything the receiver was not
  ///     alive for.
  static CallTimes resolveTimes({
    required String direction,
    required int durationSeconds,
    CallWindow? window,
    RecordingCandidate? recording,
  }) {
    final isIncoming =
        direction.trim().toLowerCase() == CallWireDirection.incoming;
    final openStamped = recording != null && isOpenStamped(recording);

    int? answeredAt;
    String? answeredSource;

    final offHook = window?.offHookAtMillis;
    if (isIncoming && offHook != null) {
      answeredAt = offHook;
      answeredSource = TimingSource.journal;
    } else if (openStamped) {
      answeredAt = recording.dateAddedEpochSeconds * 1000;
      answeredSource = TimingSource.recording;
    }

    int? endedAt;
    String? endedSource;

    final idle = window?.idleAtMillis;
    if (idle != null) {
      endedAt = idle;
      endedSource = TimingSource.journal;
    } else if (openStamped) {
      endedAt = recording.dateModifiedEpochSeconds * 1000;
      endedSource = TimingSource.recording;
    } else if (answeredAt != null) {
      endedAt = answeredAt + (durationSeconds * 1000);
      endedSource = TimingSource.derived;
    }

    return CallTimes(
      answeredAtMillis: answeredAt,
      endedAtMillis: endedAt,
      answeredAtSource: answeredSource,
      endedAtSource: endedSource,
    );
  }

  /// Builds the `metadata` object for one call, encoded.
  ///
  /// Everything in here is a fact the call-log row or the MediaStore entry
  /// already carried and that had no column of its own. The server treats the
  /// bag as opaque and non-queryable, so anything that later needs filtering
  /// has to graduate to a real column; until then this is where it lives
  /// rather than nowhere.
  ///
  /// Absent values are omitted rather than sent as null.
  static String? buildMetadata({
    required Map<String, Object?> row,
    required CallTimes times,
    RecordingCandidate? recording,
    MatchSignals? signals,
    double? confidence,
    int? appBuild,
  }) {
    final json = <String, Object?>{};

    // The call log's own row id. NOT reused as `external_call_id`: that field
    // feeds the v5 idempotency key, so changing how it is derived renames every
    // call already queued and the server stores duplicates for anything in
    // flight. It belongs here, where it is merely useful.
    _put(json, 'call_log_id', row['systemId']);
    _put(json, 'presentation', row['presentation']);
    _put(json, 'geocoded_location', _truncate(row['geocodedLocation'], 128));
    _put(json, 'country_iso', row['countryIso']);
    _put(json, 'data_usage_bytes', row['dataUsageBytes']);
    _put(json, 'via_number', row['viaNumber']);
    _put(json, 'post_dial_digits', row['postDialDigits']);
    _put(json, 'block_reason', row['blockReason']);
    _put(json, 'number_label', row['numberLabel']);
    _put(json, 'phone_account_id', _truncate(row['phoneAccountId'], 128));
    _put(
      json,
      'phone_account_component',
      _truncate(row['phoneAccountComponent'], 200),
    );
    _put(json, 'app_build', appBuild);

    final features = row['features'];
    if (features is List && features.isNotEmpty) {
      json['features'] = features;
    }

    // How much of the timing above is measured and how much is inferred.
    // Without this the server cannot tell a journal-accurate answer time from
    // one reconstructed off a file timestamp.
    final timing = <String, Object?>{};
    _put(timing, 'answered_at_source', times.answeredAtSource);
    _put(timing, 'ended_at_source', times.endedAtSource);
    if (timing.isNotEmpty) json['timing'] = timing;

    if (recording != null) {
      json['recording'] = recordingObject(recording, signals, confidence);
    }

    if (json.isEmpty) return null;
    return _encodeWithinCap(json);
  }

  /// Folds a newly discovered recording into metadata built before it existed.
  ///
  /// The retroactive matcher runs minutes after the call was ingested, by which
  /// point the row already carries a metadata object describing everything
  /// except the audio, and the call-log row behind it is long out of scope.
  /// Metadata we cannot parse is discarded rather than propagated.
  static String? remergeRecordingMetadata({
    required String? existingJson,
    required CallTimes times,
    required RecordingCandidate recording,
    MatchSignals? signals,
    double? confidence,
  }) {
    var json = <String, Object?>{};
    if (existingJson != null && existingJson.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(existingJson);
        if (decoded is Map<String, dynamic>) json = Map.of(decoded);
      } catch (_) {
        json = <String, Object?>{};
      }
    }

    final timing = <String, Object?>{};
    _put(timing, 'answered_at_source', times.answeredAtSource);
    _put(timing, 'ended_at_source', times.endedAtSource);
    if (timing.isNotEmpty) json['timing'] = timing;

    json['recording'] = recordingObject(recording, signals, confidence);
    return _encodeWithinCap(json);
  }

  static Map<String, Object?> recordingObject(
    RecordingCandidate recording,
    MatchSignals? signals,
    double? confidence,
  ) {
    final rec = <String, Object?>{
      'media_store_id': recording.mediaStoreId,
      'size_bytes': recording.sizeBytes,
      'duration_seconds': _round(recording.durationSeconds),
      'date_added': recording.dateAddedEpochSeconds,
      'date_modified': recording.dateModifiedEpochSeconds,
    };
    _put(rec, 'display_name', _truncate(recording.displayName, 200));
    _put(rec, 'relative_path', _truncate(recording.relativePath, 200));
    _put(rec, 'source', recording.source);
    _put(rec, 'mime_type', recording.mimeType);
    if (confidence != null) rec['match_confidence'] = _round(confidence);
    if (signals != null) {
      rec['match_anchored'] = signals.isAnchored;
      rec['duration_delta_seconds'] = _round(signals.durationDeltaSeconds);
      rec['ring_gap_seconds'] = signals.ringGapSeconds;
      rec['identity_matched'] = signals.identityMatched;
      _put(rec, 'anchor_delta_seconds', signals.anchorDeltaSeconds);
    }
    return rec;
  }

  /// Encodes, shedding the recording detail rather than letting an oversized
  /// bag cost the whole call a 422 for the sake of a filename.
  static String? _encodeWithinCap(Map<String, Object?> json) {
    final encoded = jsonEncode(json);
    if (utf8.encode(encoded).length <= maxMetadataBytes) return encoded;

    json.remove('recording');
    final trimmed = jsonEncode(json);
    return utf8.encode(trimmed).length <= maxMetadataBytes ? trimmed : null;
  }

  /// Two decimal places; JSON has no use for a double's full tail.
  static double _round(double value) => (value * 100).round() / 100;

  static String? _truncate(Object? value, int max) {
    if (value is! String || value.trim().isEmpty) return null;
    return value.length <= max ? value : value.substring(0, max);
  }

  static void _put(Map<String, Object?> json, String key, Object? value) {
    if (value == null) return;
    if (value is String && value.trim().isEmpty) return;
    json[key] = value;
  }
}

/// Where a timestamp came from, so the server can weigh it.
abstract final class TimingSource {
  /// Measured from the telephony broadcast. The best available.
  static const journal = 'journal';

  /// Taken from the matched recording's MediaStore timestamps.
  static const recording = 'recording';

  /// Computed from a known answer time plus the log's duration.
  static const derived = 'derived';
}

/// The raw transition timestamps belonging to one call-log row.
class CallWindow {
  const CallWindow({
    this.ringingAtMillis,
    this.offHookAtMillis,
    this.idleAtMillis,
  });

  final int? ringingAtMillis;

  /// **Not an answer time on its own** — see [CallEnrichment.resolveTimes].
  final int? offHookAtMillis;

  /// The end of the call, in both directions.
  final int? idleAtMillis;
}

class CallTimes {
  const CallTimes({
    this.answeredAtMillis,
    this.endedAtMillis,
    this.answeredAtSource,
    this.endedAtSource,
  });

  final int? answeredAtMillis;
  final int? endedAtMillis;
  final String? answeredAtSource;
  final String? endedAtSource;

  DateTime? get answeredAtUtc => answeredAtMillis == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(answeredAtMillis!).toUtc();

  DateTime? get endedAtUtc => endedAtMillis == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(endedAtMillis!).toUtc();
}
