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
  ///
  /// [beforeMillis] adds an exclusive upper bound so the history list can page
  /// backwards by keyset — "older than the oldest row I hold" — instead of
  /// re-reading every earlier page with a growing limit. Pass 0 for no bound.
  Future<List<CallLogRow>> readCallLog({
    required int sinceMillis,
    int limit = 100,
    int beforeMillis = 0,
  });

  Future<int> getCallLogCount();

  /// Every call with this number, newest first — the history on a call's
  /// detail screen.
  ///
  /// Matched on the last ten digits natively, so the same person logged as
  /// +9197…, 09197… and 97… returns as one history rather than three.
  Future<List<CallLogRow>> readCallLogForNumber(String number, {int limit = 50});

  /// Opens the system dialer with [number] filled in. Returns false when the
  /// device has no dialer to open.
  Future<bool> dialNumber(String number);

  /// The playable `content://` URI for a scanned recording. The file lives in
  /// the dialer's private directory, so this URI — not a path — is the only
  /// way to read it.
  Future<String> getRecordingUri(int mediaStoreId);
  Future<SimInfo> getSimInfo();
  Future<String?> resolveContact(String number);

  /// Resolves a whole page of numbers in one round-trip.
  ///
  /// Keys are the numbers that matched a contact; a number absent from the
  /// result simply has no saved name. Prefer this over looping
  /// [resolveContact]: per-row resolution costs a platform hop and a
  /// PhoneLookup query each, which is what made the first paint of the call
  /// list slow.
  Future<Map<String, String>> resolveContacts(List<String> numbers);
  Future<RecordingCapability> probeRecordingCapability();

  /// Which permission the recording scan needs on this OS version, and whether
  /// it is held. Read-only: never triggers a dialog.
  Future<({String permission, bool granted})> getRecordingAccess();

  /// Discovers recordings the device's own dialer already wrote. Incremental by
  /// MediaStore DATE_ADDED, which is in SECONDS (the call log is milliseconds).
  /// Pass [beforeEpochSeconds] to bound queries within a sliding window.
  Future<List<RecordingCandidate>> scanRecordings({
    required int sinceEpochSeconds,
    int beforeEpochSeconds = 0,
    int limit = 200,
  });

  /// Streaming SHA-256, computed natively so multi-megabyte audio never crosses
  /// the platform channel. Null when the file has since been deleted.
  Future<({String checksum, int bytesRead})?> hashRecording(int mediaStoreId);

  /// Exports raw recording bytes via ContentResolver so the file can be stored
  /// in a temporary location for Dio upload.
  Future<List<int>?> exportRecordingBytes(int mediaStoreId);

  /// Exports raw recording bytes natively to a destination path, bypassing
  /// memory limits of MethodChannel that cause TransactionTooLargeException.
  Future<bool> exportRecordingToFile(int mediaStoreId, String destinationPath);

  Future<Map<String, Object?>> getDeviceInfo();
  Future<CallStateJournal> readCallStateJournal();
  Future<void> clearCallStateJournal();

  /// Live call-state transitions. Foreground only — the background path is the
  /// native CallStateReceiver.
  Stream<CallStateEvent> callStateStream();

  // --- background execution ------------------------------------------------

  /// Whether background ingest is actually able to run, and what it last did.
  /// Cheap: reads SharedPreferences and one PowerManager flag.
  Future<BackgroundStatus> getBackgroundStatus();

  /// Drains what the background worker captured while the app was closed.
  ///
  /// Returns the snapshots as-is; matching is applied by the Dart matcher, so
  /// the rules live in exactly one place.
  Future<IngestSnapshot> readIngestBatches();

  /// Call only after the batches have been folded in — this is not idempotent
  /// with respect to unprocessed data.
  Future<void> clearIngestBatches();

  /// Saves active auth session and device credentials for autonomous native sync.
  Future<void> setAuthSession({
    required String token,
    String? refreshToken,
    required String apiBaseUrl,
    required String deviceUuid,
  });

  /// Clears native auth credentials on sign out.
  Future<void> clearAuthSession();

  /// Exchanges the stored refresh token for a new pair.
  ///
  /// Dart does not call `POST /auth/refresh` itself on Android. The native
  /// coordinator has to be able to refresh with no Flutter engine attached, so
  /// it owns the exchange; routing Dart's refreshes through the same gate is
  /// what stops the two from racing.
  ///
  /// [staleToken] is the access token the caller held when it received a 401.
  /// When another caller has already refreshed past it, the current token comes
  /// straight back and no request is made.
  Future<TokenRefreshResult> refreshAuthTokens({
    String? staleToken,
    String? apiBaseUrl,
  });

  /// Hands the server's published limits to the native coordinator.
  ///
  /// §5.1 says to read `policy` at runtime rather than hardcode it: an
  /// administrator can change the batch size, the recording ceiling and the
  /// allowed formats. Dart does the fetching; the coordinator does the work,
  /// so the values have to cross the channel.
  Future<bool> setSyncPolicy(String policyJson);

  /// Whether the user opted in to sending recordings over mobile data.
  Future<bool> getRecordingsOnMeteredNetworks();

  Future<void> setRecordingsOnMeteredNetworks(bool allowed);

  /// Reads last native sync attempt status and timestamps.
  Future<Map<String, Object?>> getNativeSyncStatus();

  /// Enqueues immediate native background sync worker.
  Future<void> triggerNativeSync();

  /// Arms the periodic sweep and runs one capture now. Idempotent.
  Future<void> startBackgroundTracking({String reason = 'app-start'});

  /// Cancels all scheduled ingest. Used on sign-out.
  Future<void> stopBackgroundTracking();

  /// Opens the Doze exemption prompt. Returns false when no screen resolved.
  Future<bool> requestBatteryExemption();

  /// Opens the OEM background-restriction screen, falling back to app info.
  Future<bool> openVendorBackgroundSettings();

  // --- post-call overlay ---------------------------------------------------

  /// Returns true when [SYSTEM_ALERT_WINDOW] is held.
  ///
  /// This is polled on Settings screen resume, not broadcast, because Android
  /// has no "overlay permission changed" callback.
  Future<bool> checkOverlayPermission();

  /// Opens the "Display over other apps" settings page for this package.
  ///
  /// Returns true if the intent resolved (settings page opened); false on
  /// exotic OEM builds that lack the screen. The actual grant state must be
  /// checked via [checkOverlayPermission] after the user returns.
  Future<bool> requestOverlayPermission();

  /// Emits an event when the user taps "View Details" on the post-call overlay.
  ///
  /// Each event is a `Map<String, Object?>` with `startedAtMillis` (int) —
  /// use this to find the matching call entry in the local DB and push
  /// [CallDetailScreen].
  Stream<Map<String, Object?>> overlayEventStream();
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
    int beforeMillis = 0,
  }) async {
    final raw = await _invoke<List<Object?>>('readCallLog', {
      'sinceMillis': sinceMillis,
      'beforeMillis': beforeMillis,
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
  Future<List<CallLogRow>> readCallLogForNumber(
    String number, {
    int limit = 50,
  }) async {
    final raw = await _invoke<List<Object?>>('readCallLogForNumber', {
      'number': number,
      'limit': limit,
    });
    return raw
        .cast<Map<Object?, Object?>>()
        .map(CallLogRow.fromPlatform)
        .toList(growable: false);
  }

  @override
  Future<bool> dialNumber(String number) =>
      _invoke<bool>('dialNumber', {'number': number});

  @override
  Future<String> getRecordingUri(int mediaStoreId) =>
      _invoke<String>('getRecordingUri', {'mediaStoreId': mediaStoreId});

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
  Future<Map<String, String>> resolveContacts(List<String> numbers) async {
    if (numbers.isEmpty) return const {};
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>(
        'resolveContacts',
        {'numbers': numbers},
      );
      return (raw ?? const {}).map(
        (k, v) => MapEntry(k! as String, v! as String),
      );
    } on PlatformException {
      // Contact resolution is decorative: never fail a page of calls over it.
      return const {};
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
    int beforeEpochSeconds = 0,
    int limit = 200,
  }) async {
    final raw = await _invoke<List<Object?>>('scanRecordings', {
      'sinceEpochSeconds': sinceEpochSeconds,
      'beforeEpochSeconds': beforeEpochSeconds,
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
  Future<List<int>?> exportRecordingBytes(int mediaStoreId) async {
    final bytes = await _method.invokeMethod<Uint8List?>(
      'exportRecordingBytes',
      {'mediaStoreId': mediaStoreId},
    );
    return bytes;
  }

  @override
  Future<bool> exportRecordingToFile(int mediaStoreId, String destinationPath) async {
    final success = await _method.invokeMethod<bool>(
      'exportRecordingToFile',
      {'mediaStoreId': mediaStoreId, 'destinationPath': destinationPath},
    );
    return success ?? false;
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

  @override
  Future<BackgroundStatus> getBackgroundStatus() async =>
      BackgroundStatus.fromPlatform(
        await _invoke<Map<Object?, Object?>>('getBackgroundStatus'),
      );

  @override
  Future<IngestSnapshot> readIngestBatches() async =>
      IngestSnapshot.fromPlatform(
        await _invoke<Map<Object?, Object?>>('readIngestBatches'),
      );

  @override
  Future<void> clearIngestBatches() async {
    await _method.invokeMethod<void>('clearIngestBatches');
  }

  @override
  Future<void> setAuthSession({
    required String token,
    String? refreshToken,
    required String apiBaseUrl,
    required String deviceUuid,
  }) async {
    await _invoke<void>('setAuthSession', {
      'token': token,
      'refreshToken': ?refreshToken,
      'apiBaseUrl': apiBaseUrl,
      'deviceUuid': deviceUuid,
    });
  }

  @override
  Future<void> clearAuthSession() async {
    await _method.invokeMethod<void>('clearAuthSession');
  }

  @override
  Future<TokenRefreshResult> refreshAuthTokens({
    String? staleToken,
    String? apiBaseUrl,
  }) async {
    final raw = await _invoke<Map<Object?, Object?>>('refreshAuthTokens', {
      'staleToken': ?staleToken,
      'apiBaseUrl': ?apiBaseUrl,
    });
    return TokenRefreshResult.fromPlatform(raw);
  }

  @override
  Future<bool> setSyncPolicy(String policyJson) async {
    return await _invoke<bool>('setSyncPolicy', {'policyJson': policyJson});
  }

  @override
  Future<bool> getRecordingsOnMeteredNetworks() async {
    return await _invoke<bool>('getRecordingsOnMeteredNetworks');
  }

  @override
  Future<void> setRecordingsOnMeteredNetworks(bool allowed) async {
    await _invoke<void>('setRecordingsOnMeteredNetworks', {'allowed': allowed});
  }

  @override
  Future<Map<String, Object?>> getNativeSyncStatus() async {
    final raw = await _invoke<Map<Object?, Object?>>('getNativeSyncStatus');
    return raw.map((k, v) => MapEntry(k! as String, v));
  }

  @override
  Future<void> triggerNativeSync() async {
    await _method.invokeMethod<void>('triggerNativeSync');
  }

  @override
  Future<void> startBackgroundTracking({String reason = 'app-start'}) async {
    await _invoke<void>('startBackgroundTracking', {'reason': reason});
  }

  @override
  Future<void> stopBackgroundTracking() async {
    await _invoke<void>('stopBackgroundTracking');
  }

  @override
  Future<bool> requestBatteryExemption() =>
      _invoke<bool>('requestBatteryExemption');

  @override
  Future<bool> openVendorBackgroundSettings() =>
      _invoke<bool>('openVendorBackgroundSettings');

  @override
  Future<bool> checkOverlayPermission() =>
      _invoke<bool>('checkOverlayPermission');

  @override
  Future<bool> requestOverlayPermission() =>
      _invoke<bool>('requestOverlayPermission');

  static const _overlayEvents =
      EventChannel('in.mynt.zebu_call_tracker/overlay_events');

  @override
  Stream<Map<String, Object?>> overlayEventStream() =>
      _overlayEvents
          .receiveBroadcastStream()
          .map((e) => (e as Map<Object?, Object?>).map(
                (k, v) => MapEntry(k! as String, v),
              ));
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

/// Why a token refresh produced nothing.
///
/// The distinction between [transient] and [invalid] is the whole point of the
/// type. Treating a timeout as proof the session is dead is what used to sign
/// users out whenever they walked through a tunnel.
enum TokenRefreshFailure {
  /// The server refused the refresh token. Terminal — sign in again.
  invalid,

  /// Timeout, 5xx, no connectivity. Keep the session; try again later.
  transient,

  /// Nothing to refresh with: signed out, or never signed in.
  noSession,

  /// The platform channel is unavailable — not Android, or no engine.
  unsupported,
}

/// Outcome of [NativeCallBridge.refreshAuthTokens].
class TokenRefreshResult {
  const TokenRefreshResult({
    this.accessToken,
    this.refreshToken,
    this.accessTokenExpiresAt,
    this.refreshTokenExpiresAt,
    this.failure,
  });

  final String? accessToken;

  /// Null when the server returned no replacement, in which case the stored
  /// one is still current.
  final String? refreshToken;

  /// Carried through so the Dart session does not keep an expiry belonging to
  /// the token it just replaced.
  final DateTime? accessTokenExpiresAt;
  final DateTime? refreshTokenExpiresAt;

  final TokenRefreshFailure? failure;

  bool get isSuccess => accessToken != null && accessToken!.isNotEmpty;

  /// True only when the session is genuinely unusable. A [failure] of
  /// [TokenRefreshFailure.transient] must NOT clear the session.
  bool get isTerminal =>
      failure == TokenRefreshFailure.invalid ||
      failure == TokenRefreshFailure.noSession;

  const TokenRefreshResult.failed(TokenRefreshFailure reason)
      : accessToken = null,
        refreshToken = null,
        accessTokenExpiresAt = null,
        refreshTokenExpiresAt = null,
        failure = reason;

  factory TokenRefreshResult.fromPlatform(Map<Object?, Object?> m) {
    final ok = m['ok'] as bool? ?? false;
    if (ok) {
      return TokenRefreshResult(
        accessToken: m['accessToken'] as String?,
        refreshToken: m['refreshToken'] as String?,
        accessTokenExpiresAt: _parseUtc(m['accessTokenExpiresAt'] as String?),
        refreshTokenExpiresAt: _parseUtc(m['refreshTokenExpiresAt'] as String?),
      );
    }
    return TokenRefreshResult(
      failure: switch (m['failure'] as String?) {
        'INVALID' => TokenRefreshFailure.invalid,
        'NO_SESSION' => TokenRefreshFailure.noSession,
        _ => TokenRefreshFailure.transient,
      },
    );
  }

  static DateTime? _parseUtc(String? raw) =>
      raw == null ? null : DateTime.tryParse(raw)?.toUtc();
}

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
    this.phoneAccountComponent,
    this.geocodedLocation,
    this.countryIso,
    this.features = const [],
    this.dataUsageBytes,
    this.viaNumber,
    this.postDialDigits,
    this.blockReason,
    this.numberLabel,
  });

  final int? systemId;
  final String? number;
  final NumberPresentation presentation;
  final String? cachedName;
  final CallDirection direction;
  final int? dateMillis;
  final int? durationSeconds;
  final String? phoneAccountId;

  /// Disambiguates [phoneAccountId], which is often an opaque ICCID or null.
  final String? phoneAccountComponent;

  final String? geocodedLocation;
  final String? countryIso;

  /// Decoded `CallLog.Calls.FEATURES` bits — `video`, `hd`, `wifi`, `volte`…
  /// Empty for a plain voice call.
  final List<String> features;

  final int? dataUsageBytes;
  final String? viaNumber;
  final String? postDialDigits;

  /// Why the platform blocked this call. Null when it did not.
  final String? blockReason;

  /// The contact's label for this number — "mobile", "work", or a custom one.
  final String? numberLabel;

  /// The shape [CallEnrichment] reads. Kept as the raw platform vocabulary so
  /// the Dart metadata bag and the Kotlin one are keyed identically — the
  /// server must not be able to tell which ingester wrote a record.
  Map<String, Object?> toMetadataRow() => {
    'systemId': systemId,
    'presentation': presentation.name,
    'phoneAccountId': phoneAccountId,
    'phoneAccountComponent': phoneAccountComponent,
    'geocodedLocation': geocodedLocation,
    'countryIso': countryIso,
    'features': features,
    'dataUsageBytes': dataUsageBytes,
    'viaNumber': viaNumber,
    'postDialDigits': postDialDigits,
    'blockReason': blockReason,
    'numberLabel': numberLabel,
  };

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
    phoneAccountComponent: m['phoneAccountComponent'] as String?,
    geocodedLocation: m['geocodedLocation'] as String?,
    countryIso: m['countryIso'] as String?,
    features:
        (m['features'] as List<Object?>? ?? const <Object?>[])
            .whereType<String>()
            .toList(growable: false),
    dataUsageBytes: (m['dataUsageBytes'] as num?)?.toInt(),
    viaNumber: m['viaNumber'] as String?,
    postDialDigits: m['postDialDigits'] as String?,
    blockReason: m['blockReason'] as String?,
    numberLabel: m['numberLabel'] as String?,
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

/// How the last background run went, and whether the next one can happen.
class BackgroundStatus {
  const BackgroundStatus({
    required this.ignoringBatteryOptimizations,
    required this.manufacturer,
    required this.hasVendorSettings,
    required this.lastRunAtUtc,
    required this.lastRunStatus,
    required this.lastRunReason,
    required this.runCount,
    required this.capturedCalls,
    required this.overflowed,
  });

  /// False means the OS may defer scheduled ingest for hours. Not fatal — the
  /// call log is durable — but a dialer recording can be rotated away first.
  final bool ignoringBatteryOptimizations;

  final String manufacturer;

  /// Whether an OEM background-restriction screen could be resolved, so the UI
  /// only offers the shortcut when it leads somewhere.
  final bool hasVendorSettings;

  /// Null until the worker has run at least once.
  final DateTime? lastRunAtUtc;

  /// `ok`, `blocked` (a permission is missing) or `failed`.
  final String? lastRunStatus;

  /// Why the run was scheduled: `call-ended`, `periodic`, `boot`, ...
  final String? lastRunReason;

  final int runCount;
  final int capturedCalls;

  /// True when the capture store hit its cap and dropped its oldest batches —
  /// the app has been closed for a very long time.
  final bool overflowed;

  bool get hasRun => lastRunAtUtc != null;
  bool get isHealthy => lastRunStatus == 'ok' || !hasRun;

  factory BackgroundStatus.fromPlatform(Map<Object?, Object?> m) {
    final at = (m['lastRunAtMillis'] as num?)?.toInt() ?? 0;
    return BackgroundStatus(
      ignoringBatteryOptimizations:
          m['ignoringBatteryOptimizations'] as bool? ?? false,
      manufacturer: m['manufacturer'] as String? ?? '',
      hasVendorSettings: m['hasVendorSettings'] as bool? ?? false,
      lastRunAtUtc: at == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(at).toUtc(),
      lastRunStatus: m['lastRunStatus'] as String?,
      lastRunReason: m['lastRunReason'] as String?,
      runCount: (m['runCount'] as num?)?.toInt() ?? 0,
      capturedCalls: (m['capturedCalls'] as num?)?.toInt() ?? 0,
      overflowed: m['overflowed'] as bool? ?? false,
    );
  }
}

/// One background capture: the call rows seen, plus the recordings that existed
/// at that moment. The pairing is what makes this worth running in the
/// background — a recording listing is perishable, a call log row is not.
class IngestBatch {
  const IngestBatch({
    required this.capturedAtUtc,
    required this.calls,
    required this.recordings,
  });

  final DateTime capturedAtUtc;
  final List<CallLogRow> calls;
  final List<RecordingCandidate> recordings;

  factory IngestBatch.fromPlatform(Map<Object?, Object?> m) => IngestBatch(
    capturedAtUtc: DateTime.fromMillisecondsSinceEpoch(
      (m['capturedAtMillis'] as num?)?.toInt() ?? 0,
    ).toUtc(),
    calls: (m['calls'] as List<Object?>? ?? const <Object?>[])
        .cast<Map<Object?, Object?>>()
        .map(CallLogRow.fromPlatform)
        .toList(growable: false),
    recordings: (m['recordings'] as List<Object?>? ?? const <Object?>[])
        .cast<Map<Object?, Object?>>()
        .map(_candidateFromPlatform)
        .toList(growable: false),
  );
}

class SyncedCallRecord {
  const SyncedCallRecord({
    required this.idempotencyKey,
    required this.serverCallId,
    required this.syncedAtMillis,
  });

  final String idempotencyKey;
  final String serverCallId;
  final int syncedAtMillis;

  factory SyncedCallRecord.fromPlatform(Map<Object?, Object?> m) => SyncedCallRecord(
    idempotencyKey: m['idempotencyKey'] as String? ?? '',
    serverCallId: m['serverCallId'] as String? ?? '',
    syncedAtMillis: (m['syncedAtMillis'] as num?)?.toInt() ?? 0,
  );
}

class IngestSnapshot {
  const IngestSnapshot({
    required this.batches,
    this.syncedCalls = const [],
    required this.overflowed,
  });

  final List<IngestBatch> batches;
  final List<SyncedCallRecord> syncedCalls;
  final bool overflowed;

  bool get isEmpty => batches.isEmpty && syncedCalls.isEmpty;

  /// Every recording seen across all batches, newest capture last. Feeding the
  /// matcher the union rather than per-batch lists means a call captured in one
  /// run can still match a recording indexed in the next.
  List<RecordingCandidate> get allRecordings => [
    for (final b in batches) ...b.recordings,
  ];

  factory IngestSnapshot.fromPlatform(Map<Object?, Object?> m) => IngestSnapshot(
    batches: (m['batches'] as List<Object?>? ?? const <Object?>[])
        .cast<Map<Object?, Object?>>()
        .map(IngestBatch.fromPlatform)
        .toList(growable: false),
    syncedCalls: (m['syncedCalls'] as List<Object?>? ?? const <Object?>[])
        .cast<Map<Object?, Object?>>()
        .map(SyncedCallRecord.fromPlatform)
        .toList(growable: false),
    overflowed: m['overflowed'] as bool? ?? false,
  );
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
