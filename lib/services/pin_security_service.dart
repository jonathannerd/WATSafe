import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../core/contracts/platform_contracts.dart';

/// Result of validating a candidate PIN for creation or change.
@immutable
class PinValidationResult {
  const PinValidationResult({required this.isValid, this.errorMessage});

  final bool isValid;
  final String? errorMessage;
}

/// Result of verifying a PIN against the stored salted PBKDF2 hash.
@immutable
class PinVerificationResult {
  const PinVerificationResult({
    required this.verified,
    required this.failedAttempts,
    this.isLockedOut = false,
    this.remainingLockout = Duration.zero,
    this.message,
  });

  final bool verified;
  final int failedAttempts;
  final bool isLockedOut;
  final Duration remainingLockout;
  final String? message;
}

/// Manages PIN validation, PBKDF2-HMAC-SHA256 salted hashing, constant-time
/// verification, and stepped backoff delays on repeated incorrect attempts.
///
/// Security invariant: Never logs or exposes plaintext PINs or raw hash material.
class PinSecurityService {
  PinSecurityService({
    required SecurePinStorageAdapter storage,
    DateTime Function()? clock,
    int pbkdf2Iterations = 20000,
  }) : _storage = storage,
       _clock = clock ?? DateTime.now,
       _pbkdf2Iterations = pbkdf2Iterations;

  final SecurePinStorageAdapter _storage;
  final DateTime Function() _clock;
  final int _pbkdf2Iterations;

  static final RegExp _digitsOnly = RegExp(r'^\d+$');
  static const int minPinDigits = 6;
  static const int maxPinDigits = 12;

  int _failedAttempts = 0;
  DateTime? _lockedUntil;

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

  /// Checks whether a PIN record exists in secure storage.
  Future<bool> hasConfiguredPin() async {
    final record = await _storage.readPinRecord();
    return record != null &&
        record.saltBase64.isNotEmpty &&
        record.hashBase64.isNotEmpty;
  }

  /// Validates a new PIN and its confirmation.
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

  /// Creates the initial PIN during first-run setup.
  /// Fails if a PIN is already configured (use [changePin] instead).
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

  /// Verifies [candidatePin] against the stored PBKDF2-HMAC-SHA256 hash,
  /// applying stepped delays on repeated failures.
  Future<PinVerificationResult> verifyPin(String candidatePin) async {
    final lockout = remainingLockout;
    if (lockout > Duration.zero) {
      final seconds = (lockout.inMilliseconds / 1000).ceil();
      return PinVerificationResult(
        verified: false,
        failedAttempts: _failedAttempts,
        isLockedOut: true,
        remainingLockout: lockout,
        message:
            'Too many incorrect attempts. Try again in $seconds second${seconds == 1 ? '' : 's'}.',
      );
    }

    final record = await _storage.readPinRecord();
    if (record == null) {
      return PinVerificationResult(
        verified: false,
        failedAttempts: _failedAttempts,
        message: 'No PIN is configured on this device.',
      );
    }

    if (!_digitsOnly.hasMatch(candidatePin) ||
        candidatePin.length < minPinDigits ||
        candidatePin.length > maxPinDigits) {
      return _recordFailedAttempt();
    }

    final saltBytes = base64Decode(record.saltBase64);
    final expectedHashBytes = base64Decode(record.hashBase64);
    final derivedBytes = await _pbkdf2Sha256(
      pin: candidatePin,
      salt: saltBytes,
      iterations: record.iterations,
    );

    if (_constantTimeEquals(derivedBytes, expectedHashBytes)) {
      _resetBackoff();
      return const PinVerificationResult(
        verified: true,
        failedAttempts: 0,
        message: 'PIN verified.',
      );
    }

    return _recordFailedAttempt();
  }

  /// Changes the stored PIN after verifying [currentPin].
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

  PinVerificationResult _recordFailedAttempt() {
    _failedAttempts += 1;
    final delay = _delayForFailedAttempt(_failedAttempts);
    if (delay > Duration.zero) {
      _lockedUntil = _clock().add(delay);
    }
    final delaySeconds = delay.inSeconds;
    final suffix = delaySeconds > 0
        ? ' Please wait $delaySeconds second${delaySeconds == 1 ? '' : 's'} before retrying.'
        : '';
    return PinVerificationResult(
      verified: false,
      failedAttempts: _failedAttempts,
      isLockedOut: delay > Duration.zero,
      remainingLockout: delay,
      message: 'Incorrect PIN (attempt $_failedAttempts).$suffix',
    );
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
  }

  Future<StoredPinRecord> _derivePinRecord(String pin) async {
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    final hash = await _pbkdf2Sha256(
      pin: pin,
      salt: salt,
      iterations: _pbkdf2Iterations,
    );
    return StoredPinRecord(
      algorithm: 'PBKDF2-HMAC-SHA256',
      iterations: _pbkdf2Iterations,
      saltBase64: base64Encode(salt),
      hashBase64: base64Encode(hash),
      updatedAtUtcIso: _clock().toUtc().toIso8601String(),
    );
  }

  Future<List<int>> _pbkdf2Sha256({
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
