// On-device proof that the Flutter <-> Android native bridge can actually read
// the data this product needs. Run against a real handset:
//
//   adb shell pm grant in.mynt.zebu_call_tracker android.permission.READ_CALL_LOG
//   adb shell pm grant in.mynt.zebu_call_tracker android.permission.READ_PHONE_STATE
//   adb shell pm grant in.mynt.zebu_call_tracker android.permission.READ_CONTACTS
//   flutter test integration_test/native_access_probe_test.dart -d <device>
//
// PRIVACY: this file must never print a raw phone number or contact name. Both
// are masked before they reach stdout, because CI logs are not a safe place for
// call data (brief §26).

// Reporting to stdout IS the deliverable of this probe, so print is correct here.
// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zebu_call_tracker/core/platform/native_call_bridge.dart';

/// `+919876543210` -> `+9198*****210`. Enough to eyeball that parsing worked,
/// not enough to identify anyone.
String maskNumber(String? number) {
  if (number == null) return '<withheld>';
  if (number.length <= 6) return '*' * number.length;
  return '${number.substring(0, 4)}${'*' * (number.length - 7)}'
      '${number.substring(number.length - 3)}';
}

String maskName(String? name) {
  if (name == null || name.isEmpty) return '<none>';
  return '${name[0]}${'*' * (name.length - 1)}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final bridge = MethodChannelNativeCallBridge();
  late Map<String, bool> permissions;

  setUpAll(() async {
    permissions = await bridge.getPermissionStatus();
  });

  test('bridge is reachable and reports device info', () async {
    final info = await bridge.getDeviceInfo();
    print('--- DEVICE ---');
    print('  manufacturer : ${info['manufacturer']}');
    print('  model        : ${info['model']}');
    print('  android      : ${info['osVersion']} (API ${info['sdkInt']})');

    expect(info['sdkInt'], isA<int>());
    expect(info['model'], isNotNull);
  });

  test('permission snapshot round-trips from native', () async {
    print('--- PERMISSIONS ---');
    permissions.forEach((k, v) => print('  ${v ? "GRANTED" : "denied "}  $k'));

    expect(permissions.keys, containsAll(<String>['readCallLog', 'readPhoneState']));
  });

  test('call log is readable and incremental', () async {
    if (permissions['readCallLog'] != true) {
      print('--- CALL LOG --- skipped: READ_CALL_LOG not granted');
      return;
    }

    final total = await bridge.getCallLogCount();
    final recent = await bridge.readCallLog(sinceMillis: 0, limit: 10);

    print('--- CALL LOG ---');
    print('  rows on device : $total');
    print('  fetched        : ${recent.length}');
    for (final r in recent.take(5)) {
      print(
        '  ${r.direction.name.padRight(9)} '
        '${maskNumber(r.number).padRight(16)} '
        '${(r.durationSeconds ?? 0).toString().padLeft(5)}s  '
        'sim=${r.phoneAccountId ?? "-"}  '
        'pres=${r.presentation.name}  '
        '${r.startedAtUtc?.toIso8601String() ?? "-"}',
      );
    }

    expect(recent.length, lessThanOrEqualTo(10));
    if (recent.isNotEmpty) {
      // Every field the CallRecord model depends on must actually arrive.
      final first = recent.first;
      expect(first.dateMillis, isNotNull, reason: 'call start timestamp');
      expect(first.durationSeconds, isNotNull, reason: 'call duration');
      expect(first.direction, isNot(CallDirection.unknown), reason: 'direction');
      expect(first.startedAtUtc!.isUtc, isTrue, reason: 'timestamps are UTC');
    }

    // The incremental contract: asking for rows newer than the newest row we
    // already have must return nothing. This is what stops the sync engine
    // re-uploading the whole history on every run.
    if (recent.isNotEmpty) {
      final newest = recent.first.dateMillis!;
      final after = await bridge.readCallLog(sinceMillis: newest, limit: 10);
      print('  rows newer than newest : ${after.length} (expected 0)');
      expect(after, isEmpty);
    }
  });

  test('call log rows are ordered newest-first', () async {
    if (permissions['readCallLog'] != true) return;
    final rows = await bridge.readCallLog(sinceMillis: 0, limit: 50);
    if (rows.length < 2) return;

    for (var i = 1; i < rows.length; i++) {
      expect(
        rows[i].dateMillis!,
        lessThanOrEqualTo(rows[i - 1].dateMillis!),
        reason: 'cursor logic depends on DESC ordering',
      );
    }
    print('--- ORDERING --- ${rows.length} rows verified newest-first');
  });

  test('SIM / subscription info', () async {
    final sim = await bridge.getSimInfo();
    print('--- SIM ---');
    print('  active modems : ${sim.simCount}');
    for (final s in sim.subscriptions) {
      print(
        '  slot ${s.simSlotIndex}  subId=${s.subscriptionId}  '
        'carrier=${s.carrierName}  country=${s.countryIso}',
      );
    }
    // Dual-SIM data is DEVICE DEPENDENT by design: absence is not a failure.
    expect(sim.simCount, greaterThanOrEqualTo(0));
  });

  test('contact resolution degrades gracefully', () async {
    if (permissions['readCallLog'] != true) return;
    final rows = await bridge.readCallLog(sinceMillis: 0, limit: 20);
    final withNumber = rows.where((r) => r.number != null).take(5);

    print('--- CONTACTS ---');
    if (permissions['readContacts'] != true) {
      print('  READ_CONTACTS denied -> names must be null, calls still valid');
    }
    for (final r in withNumber) {
      final name = await bridge.resolveContact(r.number!);
      print('  ${maskNumber(r.number)} -> ${maskName(name)}');
    }

    // A number that cannot match anything must return null, never throw.
    expect(await bridge.resolveContact('+10000000000'), isNull);
  });

  test('recording capability is reported honestly', () async {
    final cap = await bridge.probeRecordingCapability();
    print('--- RECORDING ---');
    print('  verdict : ${cap.verdict.name}');
    print('  reason  : ${cap.reason}');
    for (final d in cap.oemRecordingDirs) {
      print(
        '  oem dir ${d['path']}: exists=${d['exists']} '
        'readable=${d['readable']} files=${d['fileCount']}',
      );
    }

    // The contract that matters: on API 29+ the probe must NOT claim support,
    // because claiming it would mean shipping silent files as recordings.
    if (cap.sdkInt >= 29) {
      expect(
        cap.verdict,
        isNot(RecordingVerdict.supported),
        reason: 'API ${cap.sdkInt} cannot capture call audio in a normal app',
      );
    }
  });

  test('background call-state journal is readable', () async {
    final journal = await bridge.readCallStateJournal();
    print('--- CALL STATE JOURNAL (background receiver) ---');
    print('  entries          : ${journal.entries.length}');
    print('  reconcilePending : ${journal.reconcilePending}');
    print('  overflowed       : ${journal.overflowed}');
    for (final e in journal.entries.take(10)) {
      print(
        '  ${e.state.padRight(8)} '
        '${DateTime.fromMillisecondsSinceEpoch(e.atMillis).toUtc().toIso8601String()}',
      );
    }
    expect(journal.entries, isNotNull);
  });
}
