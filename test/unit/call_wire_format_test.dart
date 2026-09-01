import 'package:flutter_test/flutter_test.dart';
import 'package:zebu_call_tracker/core/network/call_wire_format.dart';

void main() {
  group('Wire vocabulary matches the Mobile API Guide', () {
    test('every status the mapper emits is a member of the server enum', () {
      // The defect this guards: the client sent status "completed", which is
      // absent from the enum in §4.4. The server answered 422 VALIDATION_ERROR
      // with retryable:false, so every answered call was permanently dropped.
      const directions = ['incoming', 'outgoing', 'missed', 'rejected',
                          'blocked', 'voicemail', 'unknown', ''];

      for (final d in directions) {
        for (final duration in [0, 1, 120]) {
          final outcome =
              callWireOutcome(rawDirection: d, durationSeconds: duration);

          expect(
            CallWireStatus.all,
            contains(outcome.status),
            reason: '"$d"/${duration}s produced status "${outcome.status}", '
                'which the server does not accept',
          );
          expect(
            const [
              CallWireDirection.incoming,
              CallWireDirection.outgoing,
              CallWireDirection.unknown,
            ],
            contains(outcome.direction),
          );
        }
      }
    });

    test('"completed" is never emitted', () {
      const directions = ['incoming', 'outgoing', 'missed', 'rejected', 'unknown'];
      for (final d in directions) {
        for (final duration in [0, 60]) {
          expect(
            callWireOutcome(rawDirection: d, durationSeconds: duration).status,
            isNot('completed'),
          );
        }
      }
    });

    test('an answered call is ended, not completed', () {
      expect(
        callWireOutcome(rawDirection: 'incoming', durationSeconds: 120),
        (direction: CallWireDirection.incoming, status: CallWireStatus.ended),
      );
      expect(
        callWireOutcome(rawDirection: 'outgoing', durationSeconds: 120),
        (direction: CallWireDirection.outgoing, status: CallWireStatus.ended),
      );
    });

    test('outgoing is never missed or rejected', () {
      // §4.4: "an outgoing call cannot be missed or rejected" — 422 otherwise.
      // An unanswered outgoing call is cancelled: the caller rang off.
      final unanswered =
          callWireOutcome(rawDirection: 'outgoing', durationSeconds: 0);

      expect(unanswered.direction, CallWireDirection.outgoing);
      expect(unanswered.status, CallWireStatus.cancelled);
      expect(unanswered.status, isNot(CallWireStatus.missed));
      expect(unanswered.status, isNot(CallWireStatus.rejected));
    });

    test('missed and rejected are forced to incoming', () {
      for (final d in ['missed', 'rejected', 'blocked']) {
        expect(
          callWireOutcome(rawDirection: d, durationSeconds: 0).direction,
          CallWireDirection.incoming,
          reason: 'only an incoming call can be $d',
        );
      }
    });

    test('an unanswered incoming call is missed', () {
      expect(
        callWireOutcome(rawDirection: 'incoming', durationSeconds: 0).status,
        CallWireStatus.missed,
      );
    });

    test('legacy stored values normalise onto the enum', () {
      expect(CallWireStatus.normalize('completed'), CallWireStatus.ended);
      expect(CallWireStatus.normalize('ENDED'), CallWireStatus.ended);
      expect(CallWireStatus.normalize('nonsense'), CallWireStatus.unknown);

      final statements = CallWireStatus.normalizationStatements;
      expect(statements, hasLength(1));
      expect(
        statements.single,
        "UPDATE local_calls SET status = 'ended' WHERE status = 'completed';",
      );
    });
  });
}
