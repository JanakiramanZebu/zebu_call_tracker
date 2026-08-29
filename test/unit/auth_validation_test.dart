import 'package:flutter_test/flutter_test.dart';
import 'package:zebu_call_tracker/features/auth/data/auth_repository.dart';
import 'package:zebu_call_tracker/features/auth/domain/session.dart';

void main() {
  group('LocalAuthRepository Client ID & Mobile Number Validation', () {
    final repo = LocalAuthRepository(InMemorySessionStore());

    test('valid Client ID starting with Z succeeds', () async {
      final session = await repo.signIn(
        clientId: 'Z12345',
        mobileNumber: '9876543210',
        deviceId: 'device-uuid-123',
        device: {},
      );
      expect(session.employeeId, 'Z12345');
      expect(session.phone, '9876543210');
    });

    test('valid Client ID starting with lowercase z is converted to uppercase and succeeds', () async {
      final session = await repo.signIn(
        clientId: 'z98765',
        mobileNumber: '9876543210',
        deviceId: 'device-uuid-123',
        device: {},
      );
      expect(session.employeeId, 'Z98765');
    });

    test('valid Client ID starting with J succeeds', () async {
      final session = await repo.signIn(
        clientId: 'J54321',
        mobileNumber: '9876543210',
        deviceId: 'device-uuid-123',
        device: {},
      );
      expect(session.employeeId, 'J54321');
    });

    test('invalid prefix throws AuthFailure', () async {
      expect(
        () => repo.signIn(
          clientId: 'X12345',
          mobileNumber: '9876543210',
          deviceId: 'device-uuid-123',
          device: {},
        ),
        throwsA(isA<AuthFailure>()),
      );
    });

    test('invalid mobile length throws AuthFailure', () async {
      expect(
        () => repo.signIn(
          clientId: 'Z12345',
          mobileNumber: '12345',
          deviceId: 'device-uuid-123',
          device: {},
        ),
        throwsA(isA<AuthFailure>()),
      );
    });
  });
}
