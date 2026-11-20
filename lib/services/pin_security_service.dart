import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../core/contracts/platform_contracts.dart';

@immutable
class PinValidationResult {
  const PinValidationResult({required this.isValid, this.errorMessage});

  final bool isValid;
  final String? errorMessage;
}

@immutable
class PinVerificationResult {
  const PinVerificationResult({
    required this.verified,
    required this.failedAttempts,
    this.isLockedOut = false,
    this.remainingLockout = Duration.zero,
    this.message,
    this.securityStatePersisted = true,
    this.verifierUpgraded = false,
  });

  final bool verified;
  final int failedAttempts;
  final bool isLockedOut;
  final Duration remainingLockout;
  final String? message;

  /// False means the result is known, but updated lockout metadata could not be
  /// committed. Callers must not imply that the new state survived a restart.
  final bool securityStatePersisted;
  final bool verifierUpgraded;
}

/// Manages salted PBKDF2-HMAC-SHA256 PIN records, persisted stepped backoff,
/// constant-time comparison, and transparent upgrades of older verifier records.
class PinSecurityService {
  PinSecurityService({
    required this._storage,
    DateTime Function()? clock,
    this._pbkdf2Iterations = productionPbkdf2Iterations,
  }) : _clock = clock ?? DateTime.now {
    if (_pbkdf2Iterations < 1 ||
        _pbkdf2Iterations > maximumSupportedPbkdf2Iterations) {
      throw ArgumentError.value(
        _pbkdf2Iterations,
        'pbkdf2Iterations',
        'Must be between 1 and $maximumSupportedPbkdf2Iterations.',
      );
    }
  }

  /// PBKDF2-HMAC-SHA256 work factor listed by OWASP for PBKDF2 use.
  /// OWASP prefers Argon2id for new general-purpose password storage where
  /// available. Benchmark this portable PBKDF2 fallback on each target device
  /// before release; target derivation time should remain below one second.
  static const int productionPbkdf2Iterations = 600000;
  static const int maximumSupportedPbkdf2Iterations = 2000000;

  final SecurePinStorageAdapter _storage;
  final DateTime Function() _clock;
  final int _pbkdf2Iterations;

  static final RegExp _digitsOnly = RegExp(r'^\d+$');
  static const int minPinDigits = 6;
  static const int maxPinDigits = 12;

  int _failedAttempts = 0;
  DateTime? _lockedUntil;
  bool _lockoutPersistencePending = false;
  Future<void> _verificationTail = Future<void>.value();

  int get failedAttempts => _failedAttempts;

  Duration get remainingLockout {
    final until = _lockedUntil;
    if (until == null) {
      return Duration.zero;
    }
    final now = _clock();
    if (!now.isBefore(until)) {
      return Duration.zero;
    }
    return until.difference(now);
  }

  bool get isLockedOut => remainingLockout > Duration.zero;

  String get storageBackendDescription => _storage.storageBackendDescription;

  /// Reads the PIN record and restores persistent backoff into memory.
  Future<bool> hasConfiguredPin() async {
    final record = await _storage.readPinRecord();
    if (record == null ||
        record.saltBase64.isEmpty ||
        record.hashBase64.isEmpty) {
      _resetBackoff();
      return false;
    }
    if (!_lockoutPersistencePending) {
      _restoreBackoff(record);
    }
    return true;
  }

  PinValidationResult validateNewPin({
    required String pin,
    required String confirmPin,
  }) {
    if (pin.length < minPinDigits) {
      return const PinValidationResult(
        isValid: false,
        errorMessage: 'PIN must be at least 6 digits.',
      );
    }
    if (pin.length > maxPinDigits) {
      return const PinValidationResult(
        isValid: false,
        errorMessage: 'PIN must be 12 digits or fewer.',
      );
    }
    if (!_digitsOnly.hasMatch(pin)) {
      return const PinValidationResult(
        isValid: false,
        errorMessage: 'PIN must contain digits (0–9) only.',
      );
    }
    if (pin != confirmPin) {
      return const PinValidationResult(
        isValid: false,
        errorMessage: 'PIN confirmation does not match.',
      );
    }
    return const PinValidationResult(isValid: true);
  }

  Future<PinValidationResult> setupInitialPin({
    required String pin,
    required String confirmPin,
  }) async {
    if (await hasConfiguredPin()) {
      return const PinValidationResult(
        isValid: false,
        errorMessage:
            'A PIN is already configured. Use Change PIN with your current PIN.',
      );
    }
    final validation = validateNewPin(pin: pin, confirmPin: confirmPin);
    if (!validation.isValid) {
      return validation;
    }
    final record = await _derivePinRecord(pin);
    await _storage.writePinRecord(record);
    _resetBackoff();
    return const PinValidationResult(isValid: true);
  }

  /// Serializes verification so simultaneous submissions cannot overwrite
  /// each other's persisted attempt counters or race a successful reset.
  Future<PinVerificationResult> verifyPin(String candidatePin) {
    final completer = Completer<PinVerificationResult>();
    final previous = _verificationTail;
    final gate = Completer<void>();
    _verificationTail = gate.future;

    () async {
      try {
        await previous;
        completer.complete(await _verifyPinInternal(candidatePin));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        gate.complete();
      }
    }();

    return completer.future;
  }

  /// Restores and enforces persisted lockout metadata before doing KDF work.
  Future<PinVerificationResult> _verifyPinInternal(
    String candidatePin,
  ) async {
    final record = await _storage.readPinRecord();
    if (record == null) {
      _resetBackoff();
      return PinVerificationResult(
        verified: false,
        failedAttempts: _failedAttempts,
        message: 'No PIN is configured on this device.',
      );
    }

    // Keep the in-memory backoff authoritative after a failed storage write.
    // Never restore stale on-disk metadata over a more recent in-memory count.
    if (!_lockoutPersistencePending) {
      _restoreBackoff(record);
    }

    final lockout = remainingLockout;
    if (lockout > Duration.zero) {
      return _lockedOutResult(lockout);
    }

    if (!_digitsOnly.hasMatch(candidatePin) ||
        candidatePin.length < minPinDigits ||
        candidatePin.length > maxPinDigits) {
      return _recordFailedAttempt(record);
    }

    if (record.algorithm != 'PBKDF2-HMAC-SHA256' ||
        record.iterations < 1 ||
        record.iterations > maximumSupportedPbkdf2Iterations) {
      return PinVerificationResult(
        verified: false,
        failedAttempts: _failedAttempts,
        message:
            'The stored PIN verifier is invalid or unsupported. Secure PIN storage must be repaired before disarming.',
      );
    }

    late final List<int> saltBytes;
    late final List<int> expectedHashBytes;
    try {
      saltBytes = base64Decode(record.saltBase64);
      expectedHashBytes = base64Decode(record.hashBase64);
    } on FormatException {
      return PinVerificationResult(
        verified: false,
        failedAttempts: _failedAttempts,
        message:
            'The stored PIN verifier is damaged. Secure PIN storage must be repaired before disarming.',
      );
    }

    final derivedBytes = await _pbkdf2Sha256(
      pin: candidatePin,
      salt: saltBytes,
      iterations: record.iterations,
    );

    if (_constantTimeEquals(derivedBytes, expectedHashBytes)) {
      final targetIterations = record.iterations > _pbkdf2Iterations
          ? record.iterations
          : _pbkdf2Iterations;
      final needsUpgrade = targetIterations > record.iterations;
      final verifiedRecord = needsUpgrade
          ? await _derivePinRecord(candidatePin, iterations: targetIterations)
          : record;
      final clearedRecord = verifiedRecord.withSecurityState(
        failedAttempts: 0,
        lockedUntil: null,
        updatedAtUtcIso: _clock().toUtc().toIso8601String(),
      );

      var persisted = true;
      try {
        await _storage.writePinRecord(clearedRecord);
      } catch (_) {
        persisted = false;
        _lockoutPersistencePending = true;
      }
      _failedAttempts = 0;
      _lockedUntil = null;

      return PinVerificationResult(
        verified: true,
        failedAttempts: 0,
        message: persisted
            ? 'PIN verified.'
            : 'PIN verified, but the lockout reset and verifier upgrade could not be saved. Check secure storage before the next protected session.',
        securityStatePersisted: persisted,
        verifierUpgraded: persisted && needsUpgrade,
      );
    }

    return _recordFailedAttempt(record);
  }

  Future<PinValidationResult> changePin({
    required String currentPin,
    required String newPin,
    required String confirmNewPin,
  }) async {
    final currentVerification = await verifyPin(currentPin);
    if (!currentVerification.verified) {
      return PinValidationResult(
        isValid: false,
        errorMessage:
            currentVerification.message ?? 'Current PIN is incorrect.',
      );
    }

    final validation = validateNewPin(pin: newPin, confirmPin: confirmNewPin);
    if (!validation.isValid) {
      return validation;
    }

    final record = await _derivePinRecord(newPin);
    await _storage.writePinRecord(record);
    _resetBackoff();
    return const PinValidationResult(isValid: true);
  }

  Future<void> clearPinForInstallationReset() async {
    await _storage.deletePinRecord();
    _resetBackoff();
  }

  Future<PinVerificationResult> _recordFailedAttempt(
    StoredPinRecord record,
  ) async {
    _failedAttempts += 1;
    final delay = _delayForFailedAttempt(_failedAttempts);
    _lockedUntil = delay > Duration.zero ? _clock().add(delay) : null;
    final persisted = await _persistBackoff(record);
    final delaySeconds = delay.inSeconds;
    final suffix = delaySeconds > 0
        ? ' Please wait $delaySeconds second'
            '${delaySeconds == 1 ? '' : 's'} before retrying.'
        : '';
    final persistenceWarning = persisted
        ? ''
        : ' Security state could not be saved. This attempt is enforced only for this running session; restore secure storage to preserve it across restart.';
    return PinVerificationResult(
      verified: false,
      failedAttempts: _failedAttempts,
      isLockedOut: delay > Duration.zero,
      remainingLockout: delay,
      message:
          'Incorrect PIN (attempt $_failedAttempts).$suffix$persistenceWarning',
      securityStatePersisted: persisted,
    );
  }

  Future<bool> _persistBackoff(StoredPinRecord record) async {
    final updated = record.withSecurityState(
      failedAttempts: _failedAttempts,
      lockedUntil: _lockedUntil,
      updatedAtUtcIso: _clock().toUtc().toIso8601String(),
    );
    try {
      await _storage.writePinRecord(updated);
      _lockoutPersistencePending = false;
      return true;
    } catch (_) {
      _lockoutPersistencePending = true;
      return false;
    }
  }

  PinVerificationResult _lockedOutResult(Duration lockout) {
    final seconds = (lockout.inMilliseconds / 1000).ceil();
    return PinVerificationResult(
      verified: false,
      failedAttempts: _failedAttempts,
      isLockedOut: true,
      remainingLockout: lockout,
      message:
          'Too many incorrect attempts. Try again in $seconds second'
          '${seconds == 1 ? '' : 's'}.',
    );
  }

  void _restoreBackoff(StoredPinRecord record) {
    _failedAttempts = record.failedAttempts.clamp(0, 1000000).toInt();
    final rawLockedUntil = record.lockedUntilUtcIso;
    final parsed = rawLockedUntil == null
        ? null
        : DateTime.tryParse(rawLockedUntil);
    final nowUtc = _clock().toUtc();
    if (parsed == null || !nowUtc.isBefore(parsed)) {
      _lockedUntil = null;
      return;
    }

    // A malformed or edited timestamp must not lock the owner out forever.
    // WATSafe's longest intentional backoff step is 30 seconds.
    final maximumDeadline = nowUtc.add(const Duration(seconds: 30));
    _lockedUntil = parsed.toUtc().isAfter(maximumDeadline)
        ? maximumDeadline
        : parsed.toUtc();
  }

  Duration _delayForFailedAttempt(int attemptCount) {
    if (attemptCount <= 1) {
      return Duration.zero;
    }
    if (attemptCount == 2) {
      return const Duration(seconds: 2);
    }
    if (attemptCount == 3) {
      return const Duration(seconds: 5);
    }
    if (attemptCount == 4) {
      return const Duration(seconds: 10);
    }
    return const Duration(seconds: 30);
  }

  void _resetBackoff() {
    _failedAttempts = 0;
    _lockedUntil = null;
    _lockoutPersistencePending = false;
  }

  Future<StoredPinRecord> _derivePinRecord(
    String pin, {
    int? iterations,
  }) async {
    final effectiveIterations = iterations ?? _pbkdf2Iterations;
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    final hash = await _pbkdf2Sha256(
      pin: pin,
      salt: salt,
      iterations: effectiveIterations,
    );
    return StoredPinRecord(
      algorithm: 'PBKDF2-HMAC-SHA256',
      iterations: effectiveIterations,
      saltBase64: base64Encode(salt),
      hashBase64: base64Encode(hash),
      updatedAtUtcIso: _clock().toUtc().toIso8601String(),
      failedAttempts: 0,
      lockedUntilUtcIso: null,
    );
  }

  /// Measures WATSafe's exact PBKDF2 implementation with a dummy PIN and a
  /// deterministic non-secret salt. These timings are for target-device
  /// benchmarking, not for CI performance assertions.
  static Future<List<Duration>> benchmarkPbkdf2({
    int iterations = productionPbkdf2Iterations,
    int samples = 3,
  }) async {
    if (iterations < 1 || iterations > maximumSupportedPbkdf2Iterations) {
      throw ArgumentError.value(iterations, 'iterations');
    }
    if (samples < 1 || samples > 10) {
      throw ArgumentError.value(samples, 'samples');
    }
    const benchmarkPin = 'WATSafe-PIN-KDF-Benchmark';
    final salt = List<int>.generate(16, (index) => index);
    final durations = <Duration>[];
    for (var sample = 0; sample < samples; sample++) {
      final stopwatch = Stopwatch()..start();
      await _pbkdf2Sha256(
        pin: benchmarkPin,
        salt: salt,
        iterations: iterations,
      );
      stopwatch.stop();
      durations.add(stopwatch.elapsed);
    }
    return List<Duration>.unmodifiable(durations);
  }

  static Future<List<int>> _pbkdf2Sha256({
    required String pin,
    required List<int> salt,
    required int iterations,
  }) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return secretKey.extractBytes();
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
