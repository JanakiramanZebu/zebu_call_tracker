// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $LocalCallsTable extends LocalCalls
    with TableInfo<$LocalCallsTable, LocalCall> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalCallsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _localIdMeta = const VerificationMeta(
    'localId',
  );
  @override
  late final GeneratedColumn<int> localId = GeneratedColumn<int>(
    'local_id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _idempotencyKeyMeta = const VerificationMeta(
    'idempotencyKey',
  );
  @override
  late final GeneratedColumn<String> idempotencyKey = GeneratedColumn<String>(
    'idempotency_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _externalCallIdMeta = const VerificationMeta(
    'externalCallId',
  );
  @override
  late final GeneratedColumn<String> externalCallId = GeneratedColumn<String>(
    'external_call_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverCallIdMeta = const VerificationMeta(
    'serverCallId',
  );
  @override
  late final GeneratedColumn<String> serverCallId = GeneratedColumn<String>(
    'server_call_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _revisionMeta = const VerificationMeta(
    'revision',
  );
  @override
  late final GeneratedColumn<int> revision = GeneratedColumn<int>(
    'revision',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _phoneNumberMeta = const VerificationMeta(
    'phoneNumber',
  );
  @override
  late final GeneratedColumn<String> phoneNumber = GeneratedColumn<String>(
    'phone_number',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _normalizedPhoneNumberMeta =
      const VerificationMeta('normalizedPhoneNumber');
  @override
  late final GeneratedColumn<String> normalizedPhoneNumber =
      GeneratedColumn<String>(
        'normalized_phone_number',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _contactNameMeta = const VerificationMeta(
    'contactName',
  );
  @override
  late final GeneratedColumn<String> contactName = GeneratedColumn<String>(
    'contact_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _directionMeta = const VerificationMeta(
    'direction',
  );
  @override
  late final GeneratedColumn<String> direction = GeneratedColumn<String>(
    'direction',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<DateTime> startedAt = GeneratedColumn<DateTime>(
    'started_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _answeredAtMeta = const VerificationMeta(
    'answeredAt',
  );
  @override
  late final GeneratedColumn<DateTime> answeredAt = GeneratedColumn<DateTime>(
    'answered_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _endedAtMeta = const VerificationMeta(
    'endedAt',
  );
  @override
  late final GeneratedColumn<DateTime> endedAt = GeneratedColumn<DateTime>(
    'ended_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationSecondsMeta = const VerificationMeta(
    'durationSeconds',
  );
  @override
  late final GeneratedColumn<int> durationSeconds = GeneratedColumn<int>(
    'duration_seconds',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _hasRecordingMeta = const VerificationMeta(
    'hasRecording',
  );
  @override
  late final GeneratedColumn<bool> hasRecording = GeneratedColumn<bool>(
    'has_recording',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_recording" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _recordingPathMeta = const VerificationMeta(
    'recordingPath',
  );
  @override
  late final GeneratedColumn<String> recordingPath = GeneratedColumn<String>(
    'recording_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _recordingMediaStoreIdMeta =
      const VerificationMeta('recordingMediaStoreId');
  @override
  late final GeneratedColumn<int> recordingMediaStoreId = GeneratedColumn<int>(
    'recording_media_store_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _recordingChecksumMeta = const VerificationMeta(
    'recordingChecksum',
  );
  @override
  late final GeneratedColumn<String> recordingChecksum =
      GeneratedColumn<String>(
        'recording_checksum',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _recordingUploadStatusMeta =
      const VerificationMeta('recordingUploadStatus');
  @override
  late final GeneratedColumn<String> recordingUploadStatus =
      GeneratedColumn<String>(
        'recording_upload_status',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('pending'),
      );
  static const VerificationMeta _simSlotMeta = const VerificationMeta(
    'simSlot',
  );
  @override
  late final GeneratedColumn<int> simSlot = GeneratedColumn<int>(
    'sim_slot',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _clientCreatedAtMeta = const VerificationMeta(
    'clientCreatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> clientCreatedAt =
      GeneratedColumn<DateTime>(
        'client_created_at',
        aliasedName,
        false,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _syncStateMeta = const VerificationMeta(
    'syncState',
  );
  @override
  late final GeneratedColumn<String> syncState = GeneratedColumn<String>(
    'sync_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _attemptCountMeta = const VerificationMeta(
    'attemptCount',
  );
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
    'attempt_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _nextAttemptAtMeta = const VerificationMeta(
    'nextAttemptAt',
  );
  @override
  late final GeneratedColumn<DateTime> nextAttemptAt =
      GeneratedColumn<DateTime>(
        'next_attempt_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _lastErrorCodeMeta = const VerificationMeta(
    'lastErrorCode',
  );
  @override
  late final GeneratedColumn<String> lastErrorCode = GeneratedColumn<String>(
    'last_error_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    localId,
    idempotencyKey,
    externalCallId,
    serverCallId,
    revision,
    phoneNumber,
    normalizedPhoneNumber,
    contactName,
    direction,
    status,
    startedAt,
    answeredAt,
    endedAt,
    durationSeconds,
    hasRecording,
    recordingPath,
    recordingMediaStoreId,
    recordingChecksum,
    recordingUploadStatus,
    simSlot,
    clientCreatedAt,
    syncState,
    attemptCount,
    nextAttemptAt,
    lastErrorCode,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_calls';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalCall> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('local_id')) {
      context.handle(
        _localIdMeta,
        localId.isAcceptableOrUnknown(data['local_id']!, _localIdMeta),
      );
    }
    if (data.containsKey('idempotency_key')) {
      context.handle(
        _idempotencyKeyMeta,
        idempotencyKey.isAcceptableOrUnknown(
          data['idempotency_key']!,
          _idempotencyKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_idempotencyKeyMeta);
    }
    if (data.containsKey('external_call_id')) {
      context.handle(
        _externalCallIdMeta,
        externalCallId.isAcceptableOrUnknown(
          data['external_call_id']!,
          _externalCallIdMeta,
        ),
      );
    }
    if (data.containsKey('server_call_id')) {
      context.handle(
        _serverCallIdMeta,
        serverCallId.isAcceptableOrUnknown(
          data['server_call_id']!,
          _serverCallIdMeta,
        ),
      );
    }
    if (data.containsKey('revision')) {
      context.handle(
        _revisionMeta,
        revision.isAcceptableOrUnknown(data['revision']!, _revisionMeta),
      );
    }
    if (data.containsKey('phone_number')) {
      context.handle(
        _phoneNumberMeta,
        phoneNumber.isAcceptableOrUnknown(
          data['phone_number']!,
          _phoneNumberMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_phoneNumberMeta);
    }
    if (data.containsKey('normalized_phone_number')) {
      context.handle(
        _normalizedPhoneNumberMeta,
        normalizedPhoneNumber.isAcceptableOrUnknown(
          data['normalized_phone_number']!,
          _normalizedPhoneNumberMeta,
        ),
      );
    }
    if (data.containsKey('contact_name')) {
      context.handle(
        _contactNameMeta,
        contactName.isAcceptableOrUnknown(
          data['contact_name']!,
          _contactNameMeta,
        ),
      );
    }
    if (data.containsKey('direction')) {
      context.handle(
        _directionMeta,
        direction.isAcceptableOrUnknown(data['direction']!, _directionMeta),
      );
    } else if (isInserting) {
      context.missing(_directionMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('answered_at')) {
      context.handle(
        _answeredAtMeta,
        answeredAt.isAcceptableOrUnknown(data['answered_at']!, _answeredAtMeta),
      );
    }
    if (data.containsKey('ended_at')) {
      context.handle(
        _endedAtMeta,
        endedAt.isAcceptableOrUnknown(data['ended_at']!, _endedAtMeta),
      );
    }
    if (data.containsKey('duration_seconds')) {
      context.handle(
        _durationSecondsMeta,
        durationSeconds.isAcceptableOrUnknown(
          data['duration_seconds']!,
          _durationSecondsMeta,
        ),
      );
    }
    if (data.containsKey('has_recording')) {
      context.handle(
        _hasRecordingMeta,
        hasRecording.isAcceptableOrUnknown(
          data['has_recording']!,
          _hasRecordingMeta,
        ),
      );
    }
    if (data.containsKey('recording_path')) {
      context.handle(
        _recordingPathMeta,
        recordingPath.isAcceptableOrUnknown(
          data['recording_path']!,
          _recordingPathMeta,
        ),
      );
    }
    if (data.containsKey('recording_media_store_id')) {
      context.handle(
        _recordingMediaStoreIdMeta,
        recordingMediaStoreId.isAcceptableOrUnknown(
          data['recording_media_store_id']!,
          _recordingMediaStoreIdMeta,
        ),
      );
    }
    if (data.containsKey('recording_checksum')) {
      context.handle(
        _recordingChecksumMeta,
        recordingChecksum.isAcceptableOrUnknown(
          data['recording_checksum']!,
          _recordingChecksumMeta,
        ),
      );
    }
    if (data.containsKey('recording_upload_status')) {
      context.handle(
        _recordingUploadStatusMeta,
        recordingUploadStatus.isAcceptableOrUnknown(
          data['recording_upload_status']!,
          _recordingUploadStatusMeta,
        ),
      );
    }
    if (data.containsKey('sim_slot')) {
      context.handle(
        _simSlotMeta,
        simSlot.isAcceptableOrUnknown(data['sim_slot']!, _simSlotMeta),
      );
    }
    if (data.containsKey('client_created_at')) {
      context.handle(
        _clientCreatedAtMeta,
        clientCreatedAt.isAcceptableOrUnknown(
          data['client_created_at']!,
          _clientCreatedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_clientCreatedAtMeta);
    }
    if (data.containsKey('sync_state')) {
      context.handle(
        _syncStateMeta,
        syncState.isAcceptableOrUnknown(data['sync_state']!, _syncStateMeta),
      );
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
        _attemptCountMeta,
        attemptCount.isAcceptableOrUnknown(
          data['attempt_count']!,
          _attemptCountMeta,
        ),
      );
    }
    if (data.containsKey('next_attempt_at')) {
      context.handle(
        _nextAttemptAtMeta,
        nextAttemptAt.isAcceptableOrUnknown(
          data['next_attempt_at']!,
          _nextAttemptAtMeta,
        ),
      );
    }
    if (data.containsKey('last_error_code')) {
      context.handle(
        _lastErrorCodeMeta,
        lastErrorCode.isAcceptableOrUnknown(
          data['last_error_code']!,
          _lastErrorCodeMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {localId};
  @override
  LocalCall map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalCall(
      localId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}local_id'],
      )!,
      idempotencyKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}idempotency_key'],
      )!,
      externalCallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}external_call_id'],
      ),
      serverCallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_call_id'],
      ),
      revision: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}revision'],
      )!,
      phoneNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}phone_number'],
      )!,
      normalizedPhoneNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}normalized_phone_number'],
      ),
      contactName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}contact_name'],
      ),
      direction: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}direction'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}started_at'],
      )!,
      answeredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}answered_at'],
      ),
      endedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}ended_at'],
      ),
      durationSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_seconds'],
      )!,
      hasRecording: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_recording'],
      )!,
      recordingPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}recording_path'],
      ),
      recordingMediaStoreId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}recording_media_store_id'],
      ),
      recordingChecksum: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}recording_checksum'],
      ),
      recordingUploadStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}recording_upload_status'],
      )!,
      simSlot: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sim_slot'],
      ),
      clientCreatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}client_created_at'],
      )!,
      syncState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sync_state'],
      )!,
      attemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempt_count'],
      )!,
      nextAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}next_attempt_at'],
      ),
      lastErrorCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error_code'],
      ),
    );
  }

  @override
  $LocalCallsTable createAlias(String alias) {
    return $LocalCallsTable(attachedDatabase, alias);
  }
}

class LocalCall extends DataClass implements Insertable<LocalCall> {
  final int localId;
  final String idempotencyKey;
  final String? externalCallId;
  final String? serverCallId;
  final int revision;
  final String phoneNumber;
  final String? normalizedPhoneNumber;
  final String? contactName;
  final String direction;
  final String status;
  final DateTime startedAt;
  final DateTime? answeredAt;
  final DateTime? endedAt;
  final int durationSeconds;
  final bool hasRecording;
  final String? recordingPath;
  final int? recordingMediaStoreId;
  final String? recordingChecksum;
  final String recordingUploadStatus;
  final int? simSlot;
  final DateTime clientCreatedAt;
  final String syncState;
  final int attemptCount;
  final DateTime? nextAttemptAt;
  final String? lastErrorCode;
  const LocalCall({
    required this.localId,
    required this.idempotencyKey,
    this.externalCallId,
    this.serverCallId,
    required this.revision,
    required this.phoneNumber,
    this.normalizedPhoneNumber,
    this.contactName,
    required this.direction,
    required this.status,
    required this.startedAt,
    this.answeredAt,
    this.endedAt,
    required this.durationSeconds,
    required this.hasRecording,
    this.recordingPath,
    this.recordingMediaStoreId,
    this.recordingChecksum,
    required this.recordingUploadStatus,
    this.simSlot,
    required this.clientCreatedAt,
    required this.syncState,
    required this.attemptCount,
    this.nextAttemptAt,
    this.lastErrorCode,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['local_id'] = Variable<int>(localId);
    map['idempotency_key'] = Variable<String>(idempotencyKey);
    if (!nullToAbsent || externalCallId != null) {
      map['external_call_id'] = Variable<String>(externalCallId);
    }
    if (!nullToAbsent || serverCallId != null) {
      map['server_call_id'] = Variable<String>(serverCallId);
    }
    map['revision'] = Variable<int>(revision);
    map['phone_number'] = Variable<String>(phoneNumber);
    if (!nullToAbsent || normalizedPhoneNumber != null) {
      map['normalized_phone_number'] = Variable<String>(normalizedPhoneNumber);
    }
    if (!nullToAbsent || contactName != null) {
      map['contact_name'] = Variable<String>(contactName);
    }
    map['direction'] = Variable<String>(direction);
    map['status'] = Variable<String>(status);
    map['started_at'] = Variable<DateTime>(startedAt);
    if (!nullToAbsent || answeredAt != null) {
      map['answered_at'] = Variable<DateTime>(answeredAt);
    }
    if (!nullToAbsent || endedAt != null) {
      map['ended_at'] = Variable<DateTime>(endedAt);
    }
    map['duration_seconds'] = Variable<int>(durationSeconds);
    map['has_recording'] = Variable<bool>(hasRecording);
    if (!nullToAbsent || recordingPath != null) {
      map['recording_path'] = Variable<String>(recordingPath);
    }
    if (!nullToAbsent || recordingMediaStoreId != null) {
      map['recording_media_store_id'] = Variable<int>(recordingMediaStoreId);
    }
    if (!nullToAbsent || recordingChecksum != null) {
      map['recording_checksum'] = Variable<String>(recordingChecksum);
    }
    map['recording_upload_status'] = Variable<String>(recordingUploadStatus);
    if (!nullToAbsent || simSlot != null) {
      map['sim_slot'] = Variable<int>(simSlot);
    }
    map['client_created_at'] = Variable<DateTime>(clientCreatedAt);
    map['sync_state'] = Variable<String>(syncState);
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || nextAttemptAt != null) {
      map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt);
    }
    if (!nullToAbsent || lastErrorCode != null) {
      map['last_error_code'] = Variable<String>(lastErrorCode);
    }
    return map;
  }

  LocalCallsCompanion toCompanion(bool nullToAbsent) {
    return LocalCallsCompanion(
      localId: Value(localId),
      idempotencyKey: Value(idempotencyKey),
      externalCallId: externalCallId == null && nullToAbsent
          ? const Value.absent()
          : Value(externalCallId),
      serverCallId: serverCallId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverCallId),
      revision: Value(revision),
      phoneNumber: Value(phoneNumber),
      normalizedPhoneNumber: normalizedPhoneNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(normalizedPhoneNumber),
      contactName: contactName == null && nullToAbsent
          ? const Value.absent()
          : Value(contactName),
      direction: Value(direction),
      status: Value(status),
      startedAt: Value(startedAt),
      answeredAt: answeredAt == null && nullToAbsent
          ? const Value.absent()
          : Value(answeredAt),
      endedAt: endedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(endedAt),
      durationSeconds: Value(durationSeconds),
      hasRecording: Value(hasRecording),
      recordingPath: recordingPath == null && nullToAbsent
          ? const Value.absent()
          : Value(recordingPath),
      recordingMediaStoreId: recordingMediaStoreId == null && nullToAbsent
          ? const Value.absent()
          : Value(recordingMediaStoreId),
      recordingChecksum: recordingChecksum == null && nullToAbsent
          ? const Value.absent()
          : Value(recordingChecksum),
      recordingUploadStatus: Value(recordingUploadStatus),
      simSlot: simSlot == null && nullToAbsent
          ? const Value.absent()
          : Value(simSlot),
      clientCreatedAt: Value(clientCreatedAt),
      syncState: Value(syncState),
      attemptCount: Value(attemptCount),
      nextAttemptAt: nextAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextAttemptAt),
      lastErrorCode: lastErrorCode == null && nullToAbsent
          ? const Value.absent()
          : Value(lastErrorCode),
    );
  }

  factory LocalCall.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalCall(
      localId: serializer.fromJson<int>(json['localId']),
      idempotencyKey: serializer.fromJson<String>(json['idempotencyKey']),
      externalCallId: serializer.fromJson<String?>(json['externalCallId']),
      serverCallId: serializer.fromJson<String?>(json['serverCallId']),
      revision: serializer.fromJson<int>(json['revision']),
      phoneNumber: serializer.fromJson<String>(json['phoneNumber']),
      normalizedPhoneNumber: serializer.fromJson<String?>(
        json['normalizedPhoneNumber'],
      ),
      contactName: serializer.fromJson<String?>(json['contactName']),
      direction: serializer.fromJson<String>(json['direction']),
      status: serializer.fromJson<String>(json['status']),
      startedAt: serializer.fromJson<DateTime>(json['startedAt']),
      answeredAt: serializer.fromJson<DateTime?>(json['answeredAt']),
      endedAt: serializer.fromJson<DateTime?>(json['endedAt']),
      durationSeconds: serializer.fromJson<int>(json['durationSeconds']),
      hasRecording: serializer.fromJson<bool>(json['hasRecording']),
      recordingPath: serializer.fromJson<String?>(json['recordingPath']),
      recordingMediaStoreId: serializer.fromJson<int?>(
        json['recordingMediaStoreId'],
      ),
      recordingChecksum: serializer.fromJson<String?>(
        json['recordingChecksum'],
      ),
      recordingUploadStatus: serializer.fromJson<String>(
        json['recordingUploadStatus'],
      ),
      simSlot: serializer.fromJson<int?>(json['simSlot']),
      clientCreatedAt: serializer.fromJson<DateTime>(json['clientCreatedAt']),
      syncState: serializer.fromJson<String>(json['syncState']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      nextAttemptAt: serializer.fromJson<DateTime?>(json['nextAttemptAt']),
      lastErrorCode: serializer.fromJson<String?>(json['lastErrorCode']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'localId': serializer.toJson<int>(localId),
      'idempotencyKey': serializer.toJson<String>(idempotencyKey),
      'externalCallId': serializer.toJson<String?>(externalCallId),
      'serverCallId': serializer.toJson<String?>(serverCallId),
      'revision': serializer.toJson<int>(revision),
      'phoneNumber': serializer.toJson<String>(phoneNumber),
      'normalizedPhoneNumber': serializer.toJson<String?>(
        normalizedPhoneNumber,
      ),
      'contactName': serializer.toJson<String?>(contactName),
      'direction': serializer.toJson<String>(direction),
      'status': serializer.toJson<String>(status),
      'startedAt': serializer.toJson<DateTime>(startedAt),
      'answeredAt': serializer.toJson<DateTime?>(answeredAt),
      'endedAt': serializer.toJson<DateTime?>(endedAt),
      'durationSeconds': serializer.toJson<int>(durationSeconds),
      'hasRecording': serializer.toJson<bool>(hasRecording),
      'recordingPath': serializer.toJson<String?>(recordingPath),
      'recordingMediaStoreId': serializer.toJson<int?>(recordingMediaStoreId),
      'recordingChecksum': serializer.toJson<String?>(recordingChecksum),
      'recordingUploadStatus': serializer.toJson<String>(recordingUploadStatus),
      'simSlot': serializer.toJson<int?>(simSlot),
      'clientCreatedAt': serializer.toJson<DateTime>(clientCreatedAt),
      'syncState': serializer.toJson<String>(syncState),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'nextAttemptAt': serializer.toJson<DateTime?>(nextAttemptAt),
      'lastErrorCode': serializer.toJson<String?>(lastErrorCode),
    };
  }

  LocalCall copyWith({
    int? localId,
    String? idempotencyKey,
    Value<String?> externalCallId = const Value.absent(),
    Value<String?> serverCallId = const Value.absent(),
    int? revision,
    String? phoneNumber,
    Value<String?> normalizedPhoneNumber = const Value.absent(),
    Value<String?> contactName = const Value.absent(),
    String? direction,
    String? status,
    DateTime? startedAt,
    Value<DateTime?> answeredAt = const Value.absent(),
    Value<DateTime?> endedAt = const Value.absent(),
    int? durationSeconds,
    bool? hasRecording,
    Value<String?> recordingPath = const Value.absent(),
    Value<int?> recordingMediaStoreId = const Value.absent(),
    Value<String?> recordingChecksum = const Value.absent(),
    String? recordingUploadStatus,
    Value<int?> simSlot = const Value.absent(),
    DateTime? clientCreatedAt,
    String? syncState,
    int? attemptCount,
    Value<DateTime?> nextAttemptAt = const Value.absent(),
    Value<String?> lastErrorCode = const Value.absent(),
  }) => LocalCall(
    localId: localId ?? this.localId,
    idempotencyKey: idempotencyKey ?? this.idempotencyKey,
    externalCallId: externalCallId.present
        ? externalCallId.value
        : this.externalCallId,
    serverCallId: serverCallId.present ? serverCallId.value : this.serverCallId,
    revision: revision ?? this.revision,
    phoneNumber: phoneNumber ?? this.phoneNumber,
    normalizedPhoneNumber: normalizedPhoneNumber.present
        ? normalizedPhoneNumber.value
        : this.normalizedPhoneNumber,
    contactName: contactName.present ? contactName.value : this.contactName,
    direction: direction ?? this.direction,
    status: status ?? this.status,
    startedAt: startedAt ?? this.startedAt,
    answeredAt: answeredAt.present ? answeredAt.value : this.answeredAt,
    endedAt: endedAt.present ? endedAt.value : this.endedAt,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    hasRecording: hasRecording ?? this.hasRecording,
    recordingPath: recordingPath.present
        ? recordingPath.value
        : this.recordingPath,
    recordingMediaStoreId: recordingMediaStoreId.present
        ? recordingMediaStoreId.value
        : this.recordingMediaStoreId,
    recordingChecksum: recordingChecksum.present
        ? recordingChecksum.value
        : this.recordingChecksum,
    recordingUploadStatus: recordingUploadStatus ?? this.recordingUploadStatus,
    simSlot: simSlot.present ? simSlot.value : this.simSlot,
    clientCreatedAt: clientCreatedAt ?? this.clientCreatedAt,
    syncState: syncState ?? this.syncState,
    attemptCount: attemptCount ?? this.attemptCount,
    nextAttemptAt: nextAttemptAt.present
        ? nextAttemptAt.value
        : this.nextAttemptAt,
    lastErrorCode: lastErrorCode.present
        ? lastErrorCode.value
        : this.lastErrorCode,
  );
  LocalCall copyWithCompanion(LocalCallsCompanion data) {
    return LocalCall(
      localId: data.localId.present ? data.localId.value : this.localId,
      idempotencyKey: data.idempotencyKey.present
          ? data.idempotencyKey.value
          : this.idempotencyKey,
      externalCallId: data.externalCallId.present
          ? data.externalCallId.value
          : this.externalCallId,
      serverCallId: data.serverCallId.present
          ? data.serverCallId.value
          : this.serverCallId,
      revision: data.revision.present ? data.revision.value : this.revision,
      phoneNumber: data.phoneNumber.present
          ? data.phoneNumber.value
          : this.phoneNumber,
      normalizedPhoneNumber: data.normalizedPhoneNumber.present
          ? data.normalizedPhoneNumber.value
          : this.normalizedPhoneNumber,
      contactName: data.contactName.present
          ? data.contactName.value
          : this.contactName,
      direction: data.direction.present ? data.direction.value : this.direction,
      status: data.status.present ? data.status.value : this.status,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      answeredAt: data.answeredAt.present
          ? data.answeredAt.value
          : this.answeredAt,
      endedAt: data.endedAt.present ? data.endedAt.value : this.endedAt,
      durationSeconds: data.durationSeconds.present
          ? data.durationSeconds.value
          : this.durationSeconds,
      hasRecording: data.hasRecording.present
          ? data.hasRecording.value
          : this.hasRecording,
      recordingPath: data.recordingPath.present
          ? data.recordingPath.value
          : this.recordingPath,
      recordingMediaStoreId: data.recordingMediaStoreId.present
          ? data.recordingMediaStoreId.value
          : this.recordingMediaStoreId,
      recordingChecksum: data.recordingChecksum.present
          ? data.recordingChecksum.value
          : this.recordingChecksum,
      recordingUploadStatus: data.recordingUploadStatus.present
          ? data.recordingUploadStatus.value
          : this.recordingUploadStatus,
      simSlot: data.simSlot.present ? data.simSlot.value : this.simSlot,
      clientCreatedAt: data.clientCreatedAt.present
          ? data.clientCreatedAt.value
          : this.clientCreatedAt,
      syncState: data.syncState.present ? data.syncState.value : this.syncState,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      nextAttemptAt: data.nextAttemptAt.present
          ? data.nextAttemptAt.value
          : this.nextAttemptAt,
      lastErrorCode: data.lastErrorCode.present
          ? data.lastErrorCode.value
          : this.lastErrorCode,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalCall(')
          ..write('localId: $localId, ')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('externalCallId: $externalCallId, ')
          ..write('serverCallId: $serverCallId, ')
          ..write('revision: $revision, ')
          ..write('phoneNumber: $phoneNumber, ')
          ..write('normalizedPhoneNumber: $normalizedPhoneNumber, ')
          ..write('contactName: $contactName, ')
          ..write('direction: $direction, ')
          ..write('status: $status, ')
          ..write('startedAt: $startedAt, ')
          ..write('answeredAt: $answeredAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('hasRecording: $hasRecording, ')
          ..write('recordingPath: $recordingPath, ')
          ..write('recordingMediaStoreId: $recordingMediaStoreId, ')
          ..write('recordingChecksum: $recordingChecksum, ')
          ..write('recordingUploadStatus: $recordingUploadStatus, ')
          ..write('simSlot: $simSlot, ')
          ..write('clientCreatedAt: $clientCreatedAt, ')
          ..write('syncState: $syncState, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastErrorCode: $lastErrorCode')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    localId,
    idempotencyKey,
    externalCallId,
    serverCallId,
    revision,
    phoneNumber,
    normalizedPhoneNumber,
    contactName,
    direction,
    status,
    startedAt,
    answeredAt,
    endedAt,
    durationSeconds,
    hasRecording,
    recordingPath,
    recordingMediaStoreId,
    recordingChecksum,
    recordingUploadStatus,
    simSlot,
    clientCreatedAt,
    syncState,
    attemptCount,
    nextAttemptAt,
    lastErrorCode,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalCall &&
          other.localId == this.localId &&
          other.idempotencyKey == this.idempotencyKey &&
          other.externalCallId == this.externalCallId &&
          other.serverCallId == this.serverCallId &&
          other.revision == this.revision &&
          other.phoneNumber == this.phoneNumber &&
          other.normalizedPhoneNumber == this.normalizedPhoneNumber &&
          other.contactName == this.contactName &&
          other.direction == this.direction &&
          other.status == this.status &&
          other.startedAt == this.startedAt &&
          other.answeredAt == this.answeredAt &&
          other.endedAt == this.endedAt &&
          other.durationSeconds == this.durationSeconds &&
          other.hasRecording == this.hasRecording &&
          other.recordingPath == this.recordingPath &&
          other.recordingMediaStoreId == this.recordingMediaStoreId &&
          other.recordingChecksum == this.recordingChecksum &&
          other.recordingUploadStatus == this.recordingUploadStatus &&
          other.simSlot == this.simSlot &&
          other.clientCreatedAt == this.clientCreatedAt &&
          other.syncState == this.syncState &&
          other.attemptCount == this.attemptCount &&
          other.nextAttemptAt == this.nextAttemptAt &&
          other.lastErrorCode == this.lastErrorCode);
}

class LocalCallsCompanion extends UpdateCompanion<LocalCall> {
  final Value<int> localId;
  final Value<String> idempotencyKey;
  final Value<String?> externalCallId;
  final Value<String?> serverCallId;
  final Value<int> revision;
  final Value<String> phoneNumber;
  final Value<String?> normalizedPhoneNumber;
  final Value<String?> contactName;
  final Value<String> direction;
  final Value<String> status;
  final Value<DateTime> startedAt;
  final Value<DateTime?> answeredAt;
  final Value<DateTime?> endedAt;
  final Value<int> durationSeconds;
  final Value<bool> hasRecording;
  final Value<String?> recordingPath;
  final Value<int?> recordingMediaStoreId;
  final Value<String?> recordingChecksum;
  final Value<String> recordingUploadStatus;
  final Value<int?> simSlot;
  final Value<DateTime> clientCreatedAt;
  final Value<String> syncState;
  final Value<int> attemptCount;
  final Value<DateTime?> nextAttemptAt;
  final Value<String?> lastErrorCode;
  const LocalCallsCompanion({
    this.localId = const Value.absent(),
    this.idempotencyKey = const Value.absent(),
    this.externalCallId = const Value.absent(),
    this.serverCallId = const Value.absent(),
    this.revision = const Value.absent(),
    this.phoneNumber = const Value.absent(),
    this.normalizedPhoneNumber = const Value.absent(),
    this.contactName = const Value.absent(),
    this.direction = const Value.absent(),
    this.status = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.answeredAt = const Value.absent(),
    this.endedAt = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.hasRecording = const Value.absent(),
    this.recordingPath = const Value.absent(),
    this.recordingMediaStoreId = const Value.absent(),
    this.recordingChecksum = const Value.absent(),
    this.recordingUploadStatus = const Value.absent(),
    this.simSlot = const Value.absent(),
    this.clientCreatedAt = const Value.absent(),
    this.syncState = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.lastErrorCode = const Value.absent(),
  });
  LocalCallsCompanion.insert({
    this.localId = const Value.absent(),
    required String idempotencyKey,
    this.externalCallId = const Value.absent(),
    this.serverCallId = const Value.absent(),
    this.revision = const Value.absent(),
    required String phoneNumber,
    this.normalizedPhoneNumber = const Value.absent(),
    this.contactName = const Value.absent(),
    required String direction,
    required String status,
    required DateTime startedAt,
    this.answeredAt = const Value.absent(),
    this.endedAt = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.hasRecording = const Value.absent(),
    this.recordingPath = const Value.absent(),
    this.recordingMediaStoreId = const Value.absent(),
    this.recordingChecksum = const Value.absent(),
    this.recordingUploadStatus = const Value.absent(),
    this.simSlot = const Value.absent(),
    required DateTime clientCreatedAt,
    this.syncState = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.nextAttemptAt = const Value.absent(),
    this.lastErrorCode = const Value.absent(),
  }) : idempotencyKey = Value(idempotencyKey),
       phoneNumber = Value(phoneNumber),
       direction = Value(direction),
       status = Value(status),
       startedAt = Value(startedAt),
       clientCreatedAt = Value(clientCreatedAt);
  static Insertable<LocalCall> custom({
    Expression<int>? localId,
    Expression<String>? idempotencyKey,
    Expression<String>? externalCallId,
    Expression<String>? serverCallId,
    Expression<int>? revision,
    Expression<String>? phoneNumber,
    Expression<String>? normalizedPhoneNumber,
    Expression<String>? contactName,
    Expression<String>? direction,
    Expression<String>? status,
    Expression<DateTime>? startedAt,
    Expression<DateTime>? answeredAt,
    Expression<DateTime>? endedAt,
    Expression<int>? durationSeconds,
    Expression<bool>? hasRecording,
    Expression<String>? recordingPath,
    Expression<int>? recordingMediaStoreId,
    Expression<String>? recordingChecksum,
    Expression<String>? recordingUploadStatus,
    Expression<int>? simSlot,
    Expression<DateTime>? clientCreatedAt,
    Expression<String>? syncState,
    Expression<int>? attemptCount,
    Expression<DateTime>? nextAttemptAt,
    Expression<String>? lastErrorCode,
  }) {
    return RawValuesInsertable({
      if (localId != null) 'local_id': localId,
      if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
      if (externalCallId != null) 'external_call_id': externalCallId,
      if (serverCallId != null) 'server_call_id': serverCallId,
      if (revision != null) 'revision': revision,
      if (phoneNumber != null) 'phone_number': phoneNumber,
      if (normalizedPhoneNumber != null)
        'normalized_phone_number': normalizedPhoneNumber,
      if (contactName != null) 'contact_name': contactName,
      if (direction != null) 'direction': direction,
      if (status != null) 'status': status,
      if (startedAt != null) 'started_at': startedAt,
      if (answeredAt != null) 'answered_at': answeredAt,
      if (endedAt != null) 'ended_at': endedAt,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
      if (hasRecording != null) 'has_recording': hasRecording,
      if (recordingPath != null) 'recording_path': recordingPath,
      if (recordingMediaStoreId != null)
        'recording_media_store_id': recordingMediaStoreId,
      if (recordingChecksum != null) 'recording_checksum': recordingChecksum,
      if (recordingUploadStatus != null)
        'recording_upload_status': recordingUploadStatus,
      if (simSlot != null) 'sim_slot': simSlot,
      if (clientCreatedAt != null) 'client_created_at': clientCreatedAt,
      if (syncState != null) 'sync_state': syncState,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
      if (lastErrorCode != null) 'last_error_code': lastErrorCode,
    });
  }

  LocalCallsCompanion copyWith({
    Value<int>? localId,
    Value<String>? idempotencyKey,
    Value<String?>? externalCallId,
    Value<String?>? serverCallId,
    Value<int>? revision,
    Value<String>? phoneNumber,
    Value<String?>? normalizedPhoneNumber,
    Value<String?>? contactName,
    Value<String>? direction,
    Value<String>? status,
    Value<DateTime>? startedAt,
    Value<DateTime?>? answeredAt,
    Value<DateTime?>? endedAt,
    Value<int>? durationSeconds,
    Value<bool>? hasRecording,
    Value<String?>? recordingPath,
    Value<int?>? recordingMediaStoreId,
    Value<String?>? recordingChecksum,
    Value<String>? recordingUploadStatus,
    Value<int?>? simSlot,
    Value<DateTime>? clientCreatedAt,
    Value<String>? syncState,
    Value<int>? attemptCount,
    Value<DateTime?>? nextAttemptAt,
    Value<String?>? lastErrorCode,
  }) {
    return LocalCallsCompanion(
      localId: localId ?? this.localId,
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      externalCallId: externalCallId ?? this.externalCallId,
      serverCallId: serverCallId ?? this.serverCallId,
      revision: revision ?? this.revision,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      normalizedPhoneNumber:
          normalizedPhoneNumber ?? this.normalizedPhoneNumber,
      contactName: contactName ?? this.contactName,
      direction: direction ?? this.direction,
      status: status ?? this.status,
      startedAt: startedAt ?? this.startedAt,
      answeredAt: answeredAt ?? this.answeredAt,
      endedAt: endedAt ?? this.endedAt,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      hasRecording: hasRecording ?? this.hasRecording,
      recordingPath: recordingPath ?? this.recordingPath,
      recordingMediaStoreId:
          recordingMediaStoreId ?? this.recordingMediaStoreId,
      recordingChecksum: recordingChecksum ?? this.recordingChecksum,
      recordingUploadStatus:
          recordingUploadStatus ?? this.recordingUploadStatus,
      simSlot: simSlot ?? this.simSlot,
      clientCreatedAt: clientCreatedAt ?? this.clientCreatedAt,
      syncState: syncState ?? this.syncState,
      attemptCount: attemptCount ?? this.attemptCount,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      lastErrorCode: lastErrorCode ?? this.lastErrorCode,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (localId.present) {
      map['local_id'] = Variable<int>(localId.value);
    }
    if (idempotencyKey.present) {
      map['idempotency_key'] = Variable<String>(idempotencyKey.value);
    }
    if (externalCallId.present) {
      map['external_call_id'] = Variable<String>(externalCallId.value);
    }
    if (serverCallId.present) {
      map['server_call_id'] = Variable<String>(serverCallId.value);
    }
    if (revision.present) {
      map['revision'] = Variable<int>(revision.value);
    }
    if (phoneNumber.present) {
      map['phone_number'] = Variable<String>(phoneNumber.value);
    }
    if (normalizedPhoneNumber.present) {
      map['normalized_phone_number'] = Variable<String>(
        normalizedPhoneNumber.value,
      );
    }
    if (contactName.present) {
      map['contact_name'] = Variable<String>(contactName.value);
    }
    if (direction.present) {
      map['direction'] = Variable<String>(direction.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<DateTime>(startedAt.value);
    }
    if (answeredAt.present) {
      map['answered_at'] = Variable<DateTime>(answeredAt.value);
    }
    if (endedAt.present) {
      map['ended_at'] = Variable<DateTime>(endedAt.value);
    }
    if (durationSeconds.present) {
      map['duration_seconds'] = Variable<int>(durationSeconds.value);
    }
    if (hasRecording.present) {
      map['has_recording'] = Variable<bool>(hasRecording.value);
    }
    if (recordingPath.present) {
      map['recording_path'] = Variable<String>(recordingPath.value);
    }
    if (recordingMediaStoreId.present) {
      map['recording_media_store_id'] = Variable<int>(
        recordingMediaStoreId.value,
      );
    }
    if (recordingChecksum.present) {
      map['recording_checksum'] = Variable<String>(recordingChecksum.value);
    }
    if (recordingUploadStatus.present) {
      map['recording_upload_status'] = Variable<String>(
        recordingUploadStatus.value,
      );
    }
    if (simSlot.present) {
      map['sim_slot'] = Variable<int>(simSlot.value);
    }
    if (clientCreatedAt.present) {
      map['client_created_at'] = Variable<DateTime>(clientCreatedAt.value);
    }
    if (syncState.present) {
      map['sync_state'] = Variable<String>(syncState.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (nextAttemptAt.present) {
      map['next_attempt_at'] = Variable<DateTime>(nextAttemptAt.value);
    }
    if (lastErrorCode.present) {
      map['last_error_code'] = Variable<String>(lastErrorCode.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalCallsCompanion(')
          ..write('localId: $localId, ')
          ..write('idempotencyKey: $idempotencyKey, ')
          ..write('externalCallId: $externalCallId, ')
          ..write('serverCallId: $serverCallId, ')
          ..write('revision: $revision, ')
          ..write('phoneNumber: $phoneNumber, ')
          ..write('normalizedPhoneNumber: $normalizedPhoneNumber, ')
          ..write('contactName: $contactName, ')
          ..write('direction: $direction, ')
          ..write('status: $status, ')
          ..write('startedAt: $startedAt, ')
          ..write('answeredAt: $answeredAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('hasRecording: $hasRecording, ')
          ..write('recordingPath: $recordingPath, ')
          ..write('recordingMediaStoreId: $recordingMediaStoreId, ')
          ..write('recordingChecksum: $recordingChecksum, ')
          ..write('recordingUploadStatus: $recordingUploadStatus, ')
          ..write('simSlot: $simSlot, ')
          ..write('clientCreatedAt: $clientCreatedAt, ')
          ..write('syncState: $syncState, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('nextAttemptAt: $nextAttemptAt, ')
          ..write('lastErrorCode: $lastErrorCode')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $LocalCallsTable localCalls = $LocalCallsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [localCalls];
}

typedef $$LocalCallsTableCreateCompanionBuilder =
    LocalCallsCompanion Function({
      Value<int> localId,
      required String idempotencyKey,
      Value<String?> externalCallId,
      Value<String?> serverCallId,
      Value<int> revision,
      required String phoneNumber,
      Value<String?> normalizedPhoneNumber,
      Value<String?> contactName,
      required String direction,
      required String status,
      required DateTime startedAt,
      Value<DateTime?> answeredAt,
      Value<DateTime?> endedAt,
      Value<int> durationSeconds,
      Value<bool> hasRecording,
      Value<String?> recordingPath,
      Value<int?> recordingMediaStoreId,
      Value<String?> recordingChecksum,
      Value<String> recordingUploadStatus,
      Value<int?> simSlot,
      required DateTime clientCreatedAt,
      Value<String> syncState,
      Value<int> attemptCount,
      Value<DateTime?> nextAttemptAt,
      Value<String?> lastErrorCode,
    });
typedef $$LocalCallsTableUpdateCompanionBuilder =
    LocalCallsCompanion Function({
      Value<int> localId,
      Value<String> idempotencyKey,
      Value<String?> externalCallId,
      Value<String?> serverCallId,
      Value<int> revision,
      Value<String> phoneNumber,
      Value<String?> normalizedPhoneNumber,
      Value<String?> contactName,
      Value<String> direction,
      Value<String> status,
      Value<DateTime> startedAt,
      Value<DateTime?> answeredAt,
      Value<DateTime?> endedAt,
      Value<int> durationSeconds,
      Value<bool> hasRecording,
      Value<String?> recordingPath,
      Value<int?> recordingMediaStoreId,
      Value<String?> recordingChecksum,
      Value<String> recordingUploadStatus,
      Value<int?> simSlot,
      Value<DateTime> clientCreatedAt,
      Value<String> syncState,
      Value<int> attemptCount,
      Value<DateTime?> nextAttemptAt,
      Value<String?> lastErrorCode,
    });

class $$LocalCallsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalCallsTable> {
  $$LocalCallsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get externalCallId => $composableBuilder(
    column: $table.externalCallId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverCallId => $composableBuilder(
    column: $table.serverCallId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get phoneNumber => $composableBuilder(
    column: $table.phoneNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get normalizedPhoneNumber => $composableBuilder(
    column: $table.normalizedPhoneNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contactName => $composableBuilder(
    column: $table.contactName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get answeredAt => $composableBuilder(
    column: $table.answeredAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get endedAt => $composableBuilder(
    column: $table.endedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasRecording => $composableBuilder(
    column: $table.hasRecording,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordingPath => $composableBuilder(
    column: $table.recordingPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get recordingMediaStoreId => $composableBuilder(
    column: $table.recordingMediaStoreId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordingChecksum => $composableBuilder(
    column: $table.recordingChecksum,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordingUploadStatus => $composableBuilder(
    column: $table.recordingUploadStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get simSlot => $composableBuilder(
    column: $table.simSlot,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get clientCreatedAt => $composableBuilder(
    column: $table.clientCreatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get syncState => $composableBuilder(
    column: $table.syncState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalCallsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalCallsTable> {
  $$LocalCallsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get externalCallId => $composableBuilder(
    column: $table.externalCallId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverCallId => $composableBuilder(
    column: $table.serverCallId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get phoneNumber => $composableBuilder(
    column: $table.phoneNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get normalizedPhoneNumber => $composableBuilder(
    column: $table.normalizedPhoneNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contactName => $composableBuilder(
    column: $table.contactName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get answeredAt => $composableBuilder(
    column: $table.answeredAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get endedAt => $composableBuilder(
    column: $table.endedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasRecording => $composableBuilder(
    column: $table.hasRecording,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordingPath => $composableBuilder(
    column: $table.recordingPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get recordingMediaStoreId => $composableBuilder(
    column: $table.recordingMediaStoreId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordingChecksum => $composableBuilder(
    column: $table.recordingChecksum,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordingUploadStatus => $composableBuilder(
    column: $table.recordingUploadStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get simSlot => $composableBuilder(
    column: $table.simSlot,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get clientCreatedAt => $composableBuilder(
    column: $table.clientCreatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get syncState => $composableBuilder(
    column: $table.syncState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalCallsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalCallsTable> {
  $$LocalCallsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get localId =>
      $composableBuilder(column: $table.localId, builder: (column) => column);

  GeneratedColumn<String> get idempotencyKey => $composableBuilder(
    column: $table.idempotencyKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get externalCallId => $composableBuilder(
    column: $table.externalCallId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverCallId => $composableBuilder(
    column: $table.serverCallId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get revision =>
      $composableBuilder(column: $table.revision, builder: (column) => column);

  GeneratedColumn<String> get phoneNumber => $composableBuilder(
    column: $table.phoneNumber,
    builder: (column) => column,
  );

  GeneratedColumn<String> get normalizedPhoneNumber => $composableBuilder(
    column: $table.normalizedPhoneNumber,
    builder: (column) => column,
  );

  GeneratedColumn<String> get contactName => $composableBuilder(
    column: $table.contactName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get direction =>
      $composableBuilder(column: $table.direction, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<DateTime> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get answeredAt => $composableBuilder(
    column: $table.answeredAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get endedAt =>
      $composableBuilder(column: $table.endedAt, builder: (column) => column);

  GeneratedColumn<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get hasRecording => $composableBuilder(
    column: $table.hasRecording,
    builder: (column) => column,
  );

  GeneratedColumn<String> get recordingPath => $composableBuilder(
    column: $table.recordingPath,
    builder: (column) => column,
  );

  GeneratedColumn<int> get recordingMediaStoreId => $composableBuilder(
    column: $table.recordingMediaStoreId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get recordingChecksum => $composableBuilder(
    column: $table.recordingChecksum,
    builder: (column) => column,
  );

  GeneratedColumn<String> get recordingUploadStatus => $composableBuilder(
    column: $table.recordingUploadStatus,
    builder: (column) => column,
  );

  GeneratedColumn<int> get simSlot =>
      $composableBuilder(column: $table.simSlot, builder: (column) => column);

  GeneratedColumn<DateTime> get clientCreatedAt => $composableBuilder(
    column: $table.clientCreatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get syncState =>
      $composableBuilder(column: $table.syncState, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get nextAttemptAt => $composableBuilder(
    column: $table.nextAttemptAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => column,
  );
}

class $$LocalCallsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalCallsTable,
          LocalCall,
          $$LocalCallsTableFilterComposer,
          $$LocalCallsTableOrderingComposer,
          $$LocalCallsTableAnnotationComposer,
          $$LocalCallsTableCreateCompanionBuilder,
          $$LocalCallsTableUpdateCompanionBuilder,
          (
            LocalCall,
            BaseReferences<_$AppDatabase, $LocalCallsTable, LocalCall>,
          ),
          LocalCall,
          PrefetchHooks Function()
        > {
  $$LocalCallsTableTableManager(_$AppDatabase db, $LocalCallsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalCallsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalCallsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalCallsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> localId = const Value.absent(),
                Value<String> idempotencyKey = const Value.absent(),
                Value<String?> externalCallId = const Value.absent(),
                Value<String?> serverCallId = const Value.absent(),
                Value<int> revision = const Value.absent(),
                Value<String> phoneNumber = const Value.absent(),
                Value<String?> normalizedPhoneNumber = const Value.absent(),
                Value<String?> contactName = const Value.absent(),
                Value<String> direction = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<DateTime> startedAt = const Value.absent(),
                Value<DateTime?> answeredAt = const Value.absent(),
                Value<DateTime?> endedAt = const Value.absent(),
                Value<int> durationSeconds = const Value.absent(),
                Value<bool> hasRecording = const Value.absent(),
                Value<String?> recordingPath = const Value.absent(),
                Value<int?> recordingMediaStoreId = const Value.absent(),
                Value<String?> recordingChecksum = const Value.absent(),
                Value<String> recordingUploadStatus = const Value.absent(),
                Value<int?> simSlot = const Value.absent(),
                Value<DateTime> clientCreatedAt = const Value.absent(),
                Value<String> syncState = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<DateTime?> nextAttemptAt = const Value.absent(),
                Value<String?> lastErrorCode = const Value.absent(),
              }) => LocalCallsCompanion(
                localId: localId,
                idempotencyKey: idempotencyKey,
                externalCallId: externalCallId,
                serverCallId: serverCallId,
                revision: revision,
                phoneNumber: phoneNumber,
                normalizedPhoneNumber: normalizedPhoneNumber,
                contactName: contactName,
                direction: direction,
                status: status,
                startedAt: startedAt,
                answeredAt: answeredAt,
                endedAt: endedAt,
                durationSeconds: durationSeconds,
                hasRecording: hasRecording,
                recordingPath: recordingPath,
                recordingMediaStoreId: recordingMediaStoreId,
                recordingChecksum: recordingChecksum,
                recordingUploadStatus: recordingUploadStatus,
                simSlot: simSlot,
                clientCreatedAt: clientCreatedAt,
                syncState: syncState,
                attemptCount: attemptCount,
                nextAttemptAt: nextAttemptAt,
                lastErrorCode: lastErrorCode,
              ),
          createCompanionCallback:
              ({
                Value<int> localId = const Value.absent(),
                required String idempotencyKey,
                Value<String?> externalCallId = const Value.absent(),
                Value<String?> serverCallId = const Value.absent(),
                Value<int> revision = const Value.absent(),
                required String phoneNumber,
                Value<String?> normalizedPhoneNumber = const Value.absent(),
                Value<String?> contactName = const Value.absent(),
                required String direction,
                required String status,
                required DateTime startedAt,
                Value<DateTime?> answeredAt = const Value.absent(),
                Value<DateTime?> endedAt = const Value.absent(),
                Value<int> durationSeconds = const Value.absent(),
                Value<bool> hasRecording = const Value.absent(),
                Value<String?> recordingPath = const Value.absent(),
                Value<int?> recordingMediaStoreId = const Value.absent(),
                Value<String?> recordingChecksum = const Value.absent(),
                Value<String> recordingUploadStatus = const Value.absent(),
                Value<int?> simSlot = const Value.absent(),
                required DateTime clientCreatedAt,
                Value<String> syncState = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<DateTime?> nextAttemptAt = const Value.absent(),
                Value<String?> lastErrorCode = const Value.absent(),
              }) => LocalCallsCompanion.insert(
                localId: localId,
                idempotencyKey: idempotencyKey,
                externalCallId: externalCallId,
                serverCallId: serverCallId,
                revision: revision,
                phoneNumber: phoneNumber,
                normalizedPhoneNumber: normalizedPhoneNumber,
                contactName: contactName,
                direction: direction,
                status: status,
                startedAt: startedAt,
                answeredAt: answeredAt,
                endedAt: endedAt,
                durationSeconds: durationSeconds,
                hasRecording: hasRecording,
                recordingPath: recordingPath,
                recordingMediaStoreId: recordingMediaStoreId,
                recordingChecksum: recordingChecksum,
                recordingUploadStatus: recordingUploadStatus,
                simSlot: simSlot,
                clientCreatedAt: clientCreatedAt,
                syncState: syncState,
                attemptCount: attemptCount,
                nextAttemptAt: nextAttemptAt,
                lastErrorCode: lastErrorCode,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalCallsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalCallsTable,
      LocalCall,
      $$LocalCallsTableFilterComposer,
      $$LocalCallsTableOrderingComposer,
      $$LocalCallsTableAnnotationComposer,
      $$LocalCallsTableCreateCompanionBuilder,
      $$LocalCallsTableUpdateCompanionBuilder,
      (LocalCall, BaseReferences<_$AppDatabase, $LocalCallsTable, LocalCall>),
      LocalCall,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$LocalCallsTableTableManager get localCalls =>
      $$LocalCallsTableTableManager(_db, _db.localCalls);
}
