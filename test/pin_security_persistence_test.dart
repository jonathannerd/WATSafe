import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

void main() {
  group('Persistent PIN lockout and verifier migration', () {
    late DateTime now;

    setUp(() {
      now = DateTime.utc(2026, 11, 20, 12);
    });

    PinSecurityService createService(
      SecurePinStorageAdapter storage, {
      int iterations = 1000,
    }) {
      return PinSecurityService(
        storage: storage,
        clock: () => now,
        pbkdf2Iterations: iterations,
      );
    }

    test('legacy PIN JSON without lockout fields remains readable', () {
      final legacy = StoredPinRecord.fromJson(<String, Object?>{
        'algorithm': 'PBKDF2-HMAC-SHA256',
        'iterations': 20000,
        'saltBase64': 'c2FsdA==',
        'hashBase64': 'aGFzaA==',
        'updatedAtUtcIso': '2026-11-20T12:00:00.000Z',
      });

      expect(legacy.iterations, 20000);
      expect(legacy.failedAttempts, 0);
      expect(legacy.lockedUntilUtcIso, isNull);
      expect(StoredPinRecord.fromJson(legacy.toJson()).failedAttempts, 0);
    });

    test('failed attempts and lockout survive service recreation and clear on correct PIN', () async {
      final storage = InMemorySecurePinStorage();
      final firstService = createService(storage);
      await firstService.setupInitialPin(
        pin: '246810',
        confirmPin: '246810',
      );

      final firstFailure = await firstService.verifyPin('000000');
      expect(firstFailure.verified, isFalse);
      expect(firstFailure.failedAttempts, 1);
      expect(firstFailure.securityStatePersisted, isTrue);

      final recordAfterFirstFailure = await storage.readPinRecord();
      expect(recordAfterFirstFailure?.failedAttempts, 1);
      expect(recordAfterFirstFailure?.lockedUntilUtcIso, isNull);

      // A new service instance simulates a full app process restart.
      final secondService = createService(storage);
      final secondFailure = await secondService.verifyPin('111111');
      expect(secondFailure.verified, isFalse);
      expect(secondFailure.failedAttempts, 2);
      expect(secondFailure.isLockedOut, isTrue);
      expect(secondFailure.remainingLockout, const Duration(seconds: 2));

      final persistedLockout = await storage.readPinRecord();
      expect(persistedLockout?.failedAttempts, 2);
      expect(persistedLockout?.lockedUntilUtcIso, isNotNull);

      // A further service recreation cannot bypass the stored lockout.
      final thirdService = createService(storage);
      final blockedCorrectPin = await thirdService.verifyPin('246810');
      expect(blockedCorrectPin.verified, isFalse);
      expect(blockedCorrectPin.isLockedOut, isTrue);

      now = now.add(const Duration(seconds: 3));
      final successful = await thirdService.verifyPin('246810');
      expect(successful.verified, isTrue);
      expect(successful.failedAttempts, 0);
      expect(successful.securityStatePersisted, isTrue);

      final cleared = await storage.readPinRecord();
      expect(cleared?.failedAttempts, 0);
      expect(cleared?.lockedUntilUtcIso, isNull);

      final restartedAfterSuccess = createService(storage);
      expect(await restartedAfterSuccess.hasConfiguredPin(), isTrue);
      final stillValid = await restartedAfterSuccess.verifyPin('246810');
      expect(stillValid.verified, isTrue);
    });

    test('expired lockout keeps the attempt count and applies the next backoff step', () async {
      final storage = InMemorySecurePinStorage();
      final service = createService(storage);
      await service.setupInitialPin(pin: '123456', confirmPin: '123456');

      await service.verifyPin('000000');
      final second = await service.verifyPin('111111');
      expect(second.isLockedOut, isTrue);
      expect(second.remainingLockout, const Duration(seconds: 2));

      now = now.add(const Duration(seconds: 3));
      final restarted = createService(storage);
      final third = await restarted.verifyPin('222222');
      expect(third.failedAttempts, 3);
      expect(third.isLockedOut, isTrue);
      expect(third.remainingLockout, const Duration(seconds: 5));
    });

    test('correct PIN transparently upgrades old PBKDF2 records and preserves PIN validity', () async {
      final storage = InMemorySecurePinStorage();
      final legacyService = createService(storage, iterations: 500);
      await legacyService.setupInitialPin(
        pin: '654321',
        confirmPin: '654321',
      );
      expect((await storage.readPinRecord())?.iterations, 500);

      final upgradedService = createService(storage, iterations: 1500);
      final result = await upgradedService.verifyPin('654321');

      expect(result.verified, isTrue);
      expect(result.verifierUpgraded, isTrue);
      expect(result.securityStatePersisted, isTrue);
      expect((await storage.readPinRecord())?.iterations, 1500);

      final afterRestart = createService(storage, iterations: 1500);
      expect((await afterRestart.verifyPin('654321')).verified, isTrue);
    });

    test('concurrent failures are serialized and cannot overwrite each other', () async {
      final storage = InMemorySecurePinStorage();
      final service = createService(storage);
      await service.setupInitialPin(pin: '135790', confirmPin: '135790');

      final results = await Future.wait(<Future<PinVerificationResult>>[
        service.verifyPin('000000'),
        service.verifyPin('111111'),
      ]);

      expect(results.map((result) => result.failedAttempts), <int>[1, 2]);
      expect(results.last.isLockedOut, isTrue);
      expect((await storage.readPinRecord())?.failedAttempts, 2);
    });

    test('write failures fail closed and retry persistence before another PIN check', () async {
      final storage = _ControlledPinStorage();
      final service = createService(storage);
      await service.setupInitialPin(pin: '987654', confirmPin: '987654');

      storage.failWrites = true;
      final failed = await service.verifyPin('000000');
      expect(failed.verified, isFalse);
      expect(failed.securityStatePersisted, isFalse);
      expect(failed.failedAttempts, 1);

      // Correct PIN is not evaluated while the new failed-attempt state cannot
      // be committed to the secure record.
      final blocked = await service.verifyPin('987654');
      expect(blocked.verified, isFalse);
      expect(blocked.securityStatePersisted, isFalse);
      expect(blocked.message, contains('temporarily blocked'));

      storage.failWrites = false;
      final recovered = await service.verifyPin('987654');
      expect(recovered.verified, isTrue);
      expect(recovered.securityStatePersisted, isTrue);
      expect(storage.record?.failedAttempts, 0);
    });

    test('PIN change and installation reset clear persisted lockout metadata', () async {
      final storage = InMemorySecurePinStorage();
      final service = createService(storage);
      await service.setupInitialPin(pin: '111222', confirmPin: '111222');
      await service.verifyPin('000000');

      final changed = await service.changePin(
        currentPin: '111222',
        newPin: '333444',
        confirmNewPin: '333444',
      );
      expect(changed.isValid, isTrue);
      expect((await storage.readPinRecord())?.failedAttempts, 0);
      expect((await storage.readPinRecord())?.lockedUntilUtcIso, isNull);

      await service.verifyPin('000000');
      await service.clearPinForInstallationReset();
      expect(await storage.readPinRecord(), isNull);
    });
  });
}

class _ControlledPinStorage implements SecurePinStorageAdapter {
  StoredPinRecord? record;
  bool failWrites = false;

  @override
  String get storageBackendDescription => 'Controlled test secure storage';

  @override
  Future<StoredPinRecord?> readPinRecord() async => record;

  @override
  Future<void> writePinRecord(StoredPinRecord record) async {
    if (failWrites) {
      throw StateError('Simulated secure-storage write failure');
    }
    this.record = record;
  }

  @override
  Future<void> deletePinRecord() async {
    record = null;
  }
}
