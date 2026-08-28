import 'package:flutter/services.dart';

import '../../features/recording/domain/recording_matcher.dart';

/// Typed reason a platform call failed, so repositories can branch on a value
/// instead of parsing exception strings.
enum NativeFailureKind { permissionDenied, platformError, unsupportedPlatform }

class NativeFailure implements Exception {
  const NativeFailure(this.kind, this.message);
  final NativeFailureKind kind;
  final String message;
  @override
  String toString() => 'NativeFailure(${kind.name}: $message)';
}

/// The single Dart-side seam onto Android (brief §31).
///
/// No widget or use case ever touches a [MethodChannel]; they depend on this
/// abstraction, which is trivially faked in tests. Method names and channel ids
/// are defined once, here.
abstract interface class NativeCallBridge {
  Future<Map<String, bool>> getPermissionStatus();

  /// Strictly incremental: returns only rows with `date > sinceMillis`, newest
  /// first. The full history is never re-read.
  Future<List<CallLogRow>> readCallLog({
    required int sinceMillis,
    int limit = 100,
  });

  Future<int> getCallLogCount();
  Future<SimInfo> getSimInfo();
  Future<String?> resolveContact(String number);
  Future<RecordingCapability> probeRecordingCapability();

  /// Which permission the recording scan needs on this OS version, and whether
  /// it is held. Read-only: never triggers a dialog.
  Future<({String permission, bool granted})> getRecordingAccess();

  /// Discovers recordings the device's own dialer already wrote. Incremental by
  /// MediaStore DATE_ADDED, which is in SECONDS (the call log is milliseconds).
  Future<List<RecordingCandidate>> scanRecordings({
    required int sinceEpochSeconds,
    int limit = 200,
  });

  /// Streaming SHA-256, computed natively so multi-megabyte audio never crosses
  /// the platform channel. Null when the file has since been deleted.
  Future<({String checksum, int bytesRead})?> hashRecording(int mediaStoreId);
  Future<Map<String, Object?>> getDeviceInfo();
  Future<CallStateJournal> readCallStateJournal();
  Future<void> clearCallStateJournal();

  /// Live call-state transitions. Foreground only — the background path is the
  /// native CallStateReceiver.
  Stream<CallStateEvent> callStateStream();
}

class MethodChannelNativeCallBridge implements NativeCallBridge {
  static const _method = MethodChannel('in.mynt.zebu_call_tracker/native');
  static const _events = EventChannel('in.mynt.zebu_call_tracker/call_state');

  Future<T> _invoke<T>(String name, [Map<String, Object?>? args]) async {
    try {
      return await _method.invokeMethod<T>(name, args) as T;
    } on PlatformException catch (e) {
      throw NativeFailure(
        e.code == 'PERMISSION_DENIED'
            ? NativeFailureKind.permissionDenied
            : NativeFailureKind.platformError,
        e.message ?? e.code,
      );
    } on MissingPluginException {
      throw const NativeFailure(
        NativeFailureKind.unsupportedPlatform,
        'Call tracking is only implemented on Android.',
      );
    }
  }

  @override
  Future<Map<String, bool>> getPermissionStatus() async {
    final raw = await _invoke<Map<Object?, Object?>>('getPermissionStatus');
    return raw.map((k, v) => MapEntry(k! as String, v! as bool));
  }

  @override
  Future<List<CallLogRow>> readCallLog({
    required int sinceMillis,
    int limit = 100,
  }) async {
    final raw = await _invoke<List<Object?>>('readCallLog', {
      'sinceMillis': sinceMillis,
      'limit': limit,
    });
    return raw
        .cast<Map<Object?, Object?>>()
        .map(CallLogRow.fromPlatform)
        .toList(growable: false);
  }

  @override
  Future<int> getCallLogCount() => _invoke<int>('getCallLogCount');

  @override
  Future<SimInfo> getSimInfo() async =>
      SimInfo.fromPlatform(await _invoke<Map<Object?, Object?>>('getSimInfo'));

  @override
  Future<String?> resolveContact(String number) async {
    try {
      return await _method.invokeMethod<String>('resolveContact', {
        'number': number,
      });
    } on PlatformException {
      // Contact resolution is decorative: never fail a call record over it.
      return null;
    }
  }

  @override
  Future<RecordingCapability> probeRecordingCapability() async =>
      RecordingCapability.fromPlatform(
        await _invoke<Map<Object?, Object?>>('probeRecordingCapability'),
      );

  @override
  Future<({String permission, bool granted})> getRecordingAccess() async {
    final raw = await _invoke<Map<Object?, Object?>>('getRecordingAccess');
    return (
      permission: raw['permission']! as String,
      granted: raw['granted']! as bool,
    );
  }

  @override
  Future<List<RecordingCandidate>> scanRecordings({
    required int sinceEpochSeconds,
    int limit = 200,
  }) async {
    final raw = await _invoke<List<Object?>>('scanRecordings', {
      'sinceEpochSeconds': sinceEpochSeconds,
      'limit': limit,
    });
    return raw
        .cast<Map<Object?, Object?>>()
        .map(_candidateFromPlatform)
        .toList(growable: false);
  }

  @override
  Future<({String checksum, int bytesRead})?> hashRecording(
    int mediaStoreId,
  ) async {
    final raw = await _method.invokeMethod<Map<Object?, Object?>>(
      'hashRecording',
      {'mediaStoreId': mediaStoreId},
    );
    if (raw == null) return null;
    return (
      checksum: raw['checksum']! as String,
      bytesRead: (raw['bytesRead']! as num).toInt(),
    );
  }

  @override
  Future<Map<String, Object?>> getDeviceInfo() async {
    final raw = await _invoke<Map<Object?, Object?>>('getDeviceInfo');
    return raw.map((k, v) => MapEntry(k! as String, v));
  }

  @override
  Future<CallStateJournal> readCallStateJournal() async =>
      CallStateJournal.fromPlatform(
        await _invoke<Map<Object?, Object?>>('readCallStateJournal'),
      );

  @override
  Future<void> clearCallStateJournal() async {
    await _method.invokeMethod<void>('clearCallStateJournal');
  }

  @override
  Stream<CallStateEvent> callStateStream() => _events
      .receiveBroadcastStream()
      .map((e) => CallStateEvent.fromPlatform(e as Map<Object?, Object?>));
}

RecordingCandidate _candidateFromPlatform(Map<Object?, Object?> m) =>
    RecordingCandidate(
      mediaStoreId: (m['mediaStoreId']! as num).toInt(),
      displayName: m['displayName'] as String?,
      durationMillis: (m['durationMillis'] as num?)?.toInt() ?? 0,
      sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
      dateAddedEpochSeconds: (m['dateAddedEpochSeconds'] as num?)?.toInt() ?? 0,
      dateModifiedEpochSeconds:
          (m['dateModifiedEpochSeconds'] as num?)?.toInt() ?? 0,
      mimeType: m['mimeType'] as String?,
      relativePath: m['relativePath'] as String?,
      source: m['source'] as String? ?? 'UNKNOWN',
    );

// ---------------------------------------------------------------------------
// Platform DTOs. Deliberately dumb: normalisation, E.164 formatting and the
// idempotency key all belong to the domain layer, not here.
// ---------------------------------------------------------------------------

enum CallDirection {
  incoming,
  outgoing,
  missed,
  voicemail,
  rejected,
  blocked,
  unknown,
}

/// Why a number may be absent. A withheld number is a legitimate call, not an
/// error — the record is still created with a null [CallLogRow.number].
enum NumberPresentation { allowed, restricted, payphone, unknown }

class CallLogRow {
  const CallLogRow({
    required this.systemId,
    required this.number,
    required this.presentation,
    required this.cachedName,
    required this.direction,
    required this.dateMillis,
    required this.durationSeconds,
    required this.phoneAccountId,
  });

  final int? systemId;
  final String? number;
  final NumberPresentation presentation;
  final String? cachedName;
  final CallDirection direction;
  final int? dateMillis;
  final int? durationSeconds;
  final String? phoneAccountId;

  factory CallLogRow.fromPlatform(Map<Object?, Object?> m) => CallLogRow(
    systemId: (m['systemId'] as num?)?.toInt(),
    number: m['number'] as String?,
    presentation: NumberPresentation.values.firstWhere(
      (e) => e.name == m['presentation'],
      orElse: () => NumberPresentation.unknown,
    ),
    cachedName: m['cachedName'] as String?,
    direction: CallDirection.values.firstWhere(
      (e) => e.name == m['type'],
      orElse: () => CallDirection.unknown,
    ),
    dateMillis: (m['dateMillis'] as num?)?.toInt(),
    durationSeconds: (m['durationSeconds'] as num?)?.toInt(),
    phoneAccountId: m['phoneAccountId'] as String?,
  );

  /// Stored in UTC internally; converted to local only for display (brief §5).
  DateTime? get startedAtUtc => dateMillis == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(dateMillis!).toUtc();
}

class SimInfo {
  const SimInfo({required this.simCount, required this.subscriptions});
  final int simCount;
  final List<SimSubscription> subscriptions;

  factory SimInfo.fromPlatform(Map<Object?, Object?> m) => SimInfo(
    simCount: (m['simCount'] as num?)?.toInt() ?? 0,
    subscriptions: (m['subscriptions'] as List<Object?>? ?? const <Object?>[])
        .cast<Map<Object?, Object?>>()
        .map(SimSubscription.fromPlatform)
        .toList(growable: false),
  );
}

class SimSubscription {
  const SimSubscription({
    required this.subscriptionId,
    required this.simSlotIndex,
    required this.carrierName,
    required this.displayName,
    required this.countryIso,
  });

  final int? subscriptionId;
  final int? simSlotIndex;
  final String? carrierName;
  final String? displayName;
  final String? countryIso;

  factory SimSubscription.fromPlatform(Map<Object?, Object?> m) =>
      SimSubscription(
        subscriptionId: (m['subscriptionId'] as num?)?.toInt(),
        simSlotIndex: (m['simSlotIndex'] as num?)?.toInt(),
        carrierName: m['carrierName'] as String?,
        displayName: m['displayName'] as String?,
        countryIso: m['countryIso'] as String?,
      );
}

enum RecordingVerdict {
  supported,
  permissionRequired,
  osRestricted,
  deviceUnsupported,
}

class RecordingCapability {
  const RecordingCapability({
    required this.verdict,
    required this.reason,
    required this.sdkInt,
    required this.oemRecordingDirs,
  });

  final RecordingVerdict verdict;
  final String reason;
  final int sdkInt;
  final List<Map<String, Object?>> oemRecordingDirs;

  bool get isAvailable => verdict == RecordingVerdict.supported;

  factory RecordingCapability.fromPlatform(Map<Object?, Object?> m) {
    const names = <String, RecordingVerdict>{
      'SUPPORTED': RecordingVerdict.supported,
      'PERMISSION_REQUIRED': RecordingVerdict.permissionRequired,
      'OS_RESTRICTED': RecordingVerdict.osRestricted,
      'DEVICE_UNSUPPORTED': RecordingVerdict.deviceUnsupported,
    };
    return RecordingCapability(
      verdict: names[m['verdict']] ?? RecordingVerdict.deviceUnsupported,
      reason: m['reason'] as String? ?? '',
      sdkInt: (m['sdkInt'] as num?)?.toInt() ?? 0,
      oemRecordingDirs:
          (m['oemRecordingDirs'] as List<Object?>? ?? const <Object?>[])
              .cast<Map<Object?, Object?>>()
              .map((e) => e.map((k, v) => MapEntry(k! as String, v)))
              .toList(growable: false),
    );
  }
}

class CallStateEvent {
  const CallStateEvent({required this.state, required this.atMillis});
  final String state;
  final int atMillis;

  factory CallStateEvent.fromPlatform(Map<Object?, Object?> m) =>
      CallStateEvent(
        state: m['state'] as String? ?? 'unknown',
        atMillis: (m['atMillis'] as num?)?.toInt() ?? 0,
      );
}

class CallStateJournal {
  const CallStateJournal({
    required this.entries,
    required this.overflowed,
    required this.reconcilePending,
  });

  final List<CallStateEvent> entries;
  final bool overflowed;
  final bool reconcilePending;

  factory CallStateJournal.fromPlatform(Map<Object?, Object?> m) =>
      CallStateJournal(
        entries: (m['entries'] as List<Object?>? ?? const <Object?>[])
            .cast<Map<Object?, Object?>>()
            .map(CallStateEvent.fromPlatform)
            .toList(growable: false),
        overflowed: m['overflowed'] as bool? ?? false,
        reconcilePending: m['reconcilePending'] as bool? ?? false,
      );
}
