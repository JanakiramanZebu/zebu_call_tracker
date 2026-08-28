// End-to-end recording INGESTION on a real handset: discover the audio the
// device's own dialer already wrote, then match it against the real call log.
// The app records nothing.
//
//   flutter build apk --debug
//   adb install -r -g build/app/outputs/flutter-apk/app-debug.apk
//   flutter test integration_test/recording_ingestion_test.dart -d <device>
//
// PRIVACY: no raw phone number, contact name or recording filename reaches
// stdout — recording filenames embed contact names, so they are masked too.

// Reporting to stdout IS the deliverable of this probe, so print is correct here.
// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zebu_call_tracker/core/platform/native_call_bridge.dart';
import 'package:zebu_call_tracker/features/recording/domain/recording_matcher.dart';

String maskFile(String? name) {
  if (name == null) return '<none>';
  // "Call Amit Zebu_260825_115236.m4a" -> "Call ***_260825_115236.m4a";
  // the timestamp is kept because it is evidence, the identity is not.
  return name.replaceAllMapped(
    RegExp(r'^(Call recording |Call )(.+?)(_\d{6}_\d{6}\.\w+)$'),
    (m) => '${m[1]}***${m[3]}',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final bridge = MethodChannelNativeCallBridge();
  const engine = RecordingMatcher();

  test('recording access is available without all-files access', () async {
    final access = await bridge.getRecordingAccess();
    print('--- RECORDING ACCESS ---');
    print('  permission : ${access.permission}');
    print('  granted    : ${access.granted}');

    // The point of the MediaStore approach: a normal media permission, never
    // MANAGE_EXTERNAL_STORAGE.
    expect(access.permission, isNot(contains('MANAGE_EXTERNAL_STORAGE')));
  });

  test('existing recordings are discoverable', () async {
    final access = await bridge.getRecordingAccess();
    if (!access.granted) {
      print('--- SCAN --- skipped: ${access.permission} not granted');
      return;
    }

    final found = await bridge.scanRecordings(sinceEpochSeconds: 0, limit: 20);
    print('--- SCAN ---');
    print('  discovered : ${found.length} (capped at 20)');
    for (final r in found.take(6)) {
      print(
        '  ${maskFile(r.displayName).padRight(34)} '
        '${r.durationSeconds.toStringAsFixed(1).padLeft(7)}s '
        '${(r.sizeBytes / 1024).round().toString().padLeft(6)}KB  '
        'added=${r.dateAddedEpochSeconds}  ${r.source}',
      );
    }

    if (found.isNotEmpty) {
      final first = found.first;
      expect(first.durationMillis, greaterThan(0), reason: 'duration signal');
      expect(first.dateAddedEpochSeconds, greaterThan(0), reason: 'time signal');
      expect(first.sizeBytes, greaterThan(0));
      // Newest-first, mirroring the call-log cursor.
      for (var i = 1; i < found.length; i++) {
        expect(
          found[i].dateAddedEpochSeconds,
          lessThanOrEqualTo(found[i - 1].dateAddedEpochSeconds),
        );
      }
    }
  });

  test('discovered recordings match real call-log rows', () async {
    final access = await bridge.getRecordingAccess();
    final perms = await bridge.getPermissionStatus();
    if (!access.granted || perms['readCallLog'] != true) {
      print('--- MATCH --- skipped: permissions not granted');
      return;
    }

    final calls = await bridge.readCallLog(sinceMillis: 0, limit: 60);
    final candidates =
        await bridge.scanRecordings(sinceEpochSeconds: 0, limit: 200);

    print('--- MATCH ---');
    print('  calls examined     : ${calls.length}');
    print('  recordings in pool : ${candidates.length}');

    var matched = 0, ambiguous = 0, unmatched = 0, notFound = 0;
    var connected = 0;
    final samples = <String>[];

    for (final c in calls) {
      if (c.dateMillis == null) continue;
      final duration = c.durationSeconds ?? 0;
      if (duration > 0) connected++;

      final result = engine.match(
        CallForMatching(
          startedAtEpochMillis: c.dateMillis!,
          durationSeconds: duration,
          normalizedNumber: c.number,
          contactName: c.cachedName,
        ),
        candidates,
      );

      switch (result.status) {
        case RecordingMatchStatus.matched:
          matched++;
          if (samples.length < 6) {
            samples.add(
              '  ${c.direction.name.padRight(8)} '
              'call=${duration.toString().padLeft(4)}s  '
              'rec=${result.candidate!.durationSeconds.toStringAsFixed(1).padLeft(7)}s  '
              'delta=${result.signals!.durationDeltaSeconds.toStringAsFixed(2)}s  '
              'ring=${result.signals!.ringGapSeconds.toString().padLeft(3)}s  '
              'conf=${result.confidence.toStringAsFixed(3)}',
            );
          }
        case RecordingMatchStatus.ambiguous:
          ambiguous++;
        case RecordingMatchStatus.unmatched:
          unmatched++;
        case RecordingMatchStatus.notFound:
          notFound++;
      }
    }

    print('  connected calls    : $connected');
    print('');
    print('  MATCHED   : $matched');
    print('  AMBIGUOUS : $ambiguous');
    print('  UNMATCHED : $unmatched');
    print('  NOT_FOUND : $notFound');
    if (samples.isNotEmpty) {
      print('');
      print('  sample associations:');
      samples.forEach(print);
    }

    // The real assertion: against a pool of hundreds of recordings, the matcher
    // must land associations rather than drowning in ambiguity. If this fails,
    // the confidence model is wrong and no amount of UI hides it.
    if (connected > 0 && candidates.isNotEmpty) {
      expect(
        matched,
        greaterThan(0),
        reason: 'no call could be associated with any of '
            '${candidates.length} recordings',
      );
      expect(
        ambiguous,
        lessThan(matched),
        reason: 'ambiguity should be the exception, not the rule',
      );
    }
  });

  test('checksum is computed natively over a real file', () async {
    final access = await bridge.getRecordingAccess();
    if (!access.granted) return;

    final found = await bridge.scanRecordings(sinceEpochSeconds: 0, limit: 1);
    if (found.isEmpty) {
      print('--- CHECKSUM --- skipped: no recordings on device');
      return;
    }

    final r = found.first;
    final hash = await bridge.hashRecording(r.mediaStoreId);
    print('--- CHECKSUM ---');
    print('  file      : ${maskFile(r.displayName)}');
    print('  sha256    : ${hash?.checksum.substring(0, 16)}...');
    print('  bytesRead : ${hash?.bytesRead}  (MediaStore size ${r.sizeBytes})');

    expect(hash, isNotNull);
    expect(hash!.checksum, hasLength(64));
    // Reading fewer bytes than MediaStore reports means a truncated or
    // still-being-written file — worth catching before spending upload
    // bandwidth on it.
    expect(hash.bytesRead, r.sizeBytes);

    // Deterministic: the same file must hash identically, or server-side
    // duplicate detection is meaningless.
    final again = await bridge.hashRecording(r.mediaStoreId);
    expect(again!.checksum, hash.checksum);
  });

  test('a deleted recording returns null rather than throwing', () async {
    final access = await bridge.getRecordingAccess();
    if (!access.granted) return;
    // An id that cannot exist. The user may delete a recording between scan and
    // upload; that is normal and must not crash the sync engine.
    expect(await bridge.hashRecording(999999999), isNull);
  });
}
