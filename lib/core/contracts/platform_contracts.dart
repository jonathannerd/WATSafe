import 'package:flutter/foundation.dart';

import '../models/detector_models.dart';
import '../models/incident_models.dart';
import '../models/settings_models.dart';

/// Result of attempting to start a detector monitoring session.
@immutable
class DetectorStartResult {
  const DetectorStartResult({
    required this.started,
    required this.status,
    required this.message,
    this.errorCode,
  });

  final bool started;
  final CapabilityStatus status;
  final String message;
  final String? errorCode;
}

/// Contract for platform-specific motion or tamper detectors.
abstract class MotionDetectorAdapter {
  DetectorType get detectorType;
  bool get supportsBackgroundMonitoring;
  Stream<DetectorEvent> get events;
  Future<DetectorCapability> checkCapability();
  Future<PermissionStatus> requestPermission();
  Future<DetectorStartResult> startMonitoring(MonitorConfig config);
  Future<void> updateSensitivity(double sensitivity);
  Future<void> stopMonitoring({String? sessionId});
  Future<void> dispose();
}

/// Contract for local alarm audio playback.
abstract class AudioAlarmAdapter {
  Future<void> prepareForAlarm();
  Future<void> startLoopingAlarm({required double volume});
  Future<void> startTestAlarm({
    required double volume,
    required Duration maxDuration,
  });
  Future<void> stopAlarm();
  Future<void> setVolume(double volume);
  Future<void> configureAlarmSound({
    required String soundId,
    CustomAlarmSound? customSound,
  }) async {}
  Future<String?> pickCustomAudioFilePath() async => null;
  bool get isPlaying;
  String get audioLimitationsNote;
}

/// Salted PBKDF2 hash record stored via [SecurePinStorageAdapter].
///
/// Lockout fields were added as optional JSON members so records created by
/// earlier WATSafe versions remain readable without requiring a PIN reset.
@immutable
class StoredPinRecord {
  const StoredPinRecord({
    required this.algorithm,
    required this.iterations,
    required this.saltBase64,
    required this.hashBase64,
    required this.updatedAtUtcIso,
    this.failedAttempts = 0,
    this.lockedUntilUtcIso,
  });

  final String algorithm;
  final int iterations;
  final String saltBase64;
  final String hashBase64;
  final String updatedAtUtcIso;
  final int failedAttempts;
  final String? lockedUntilUtcIso;

  StoredPinRecord withSecurityState({
    required int failedAttempts,
    required DateTime? lockedUntil,
    required String updatedAtUtcIso,
  }) {
    return StoredPinRecord(
      algorithm: algorithm,
      iterations: iterations,
      saltBase64: saltBase64,
      hashBase64: hashBase64,
      updatedAtUtcIso: updatedAtUtcIso,
      failedAttempts: failedAttempts,
      lockedUntilUtcIso: lockedUntil?.toUtc().toIso8601String(),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'algorithm': algorithm,
      'iterations': iterations,
      'saltBase64': saltBase64,
      'hashBase64': hashBase64,
      'updatedAtUtcIso': updatedAtUtcIso,
      'failedAttempts': failedAttempts,
      'lockedUntilUtcIso': lockedUntilUtcIso,
    };
  }

  factory StoredPinRecord.fromJson(Map<String, Object?> json) {
    final rawFailedAttempts = json['failedAttempts'];
    final failedAttempts = rawFailedAttempts is num
        ? rawFailedAttempts.toInt().clamp(0, 1000000)
        : 0;
    return StoredPinRecord(
      algorithm: json['algorithm'] as String? ?? 'PBKDF2-HMAC-SHA256',
      iterations: (json['iterations'] as num?)?.toInt() ?? 20000,
      saltBase64: json['saltBase64'] as String? ?? '',
      hashBase64: json['hashBase64'] as String? ?? '',
      updatedAtUtcIso: json['updatedAtUtcIso'] as String? ?? '',
      failedAttempts: failedAttempts,
      lockedUntilUtcIso: json['lockedUntilUtcIso'] as String?,
    );
  }
}

/// Contract for storing derived PIN credentials in platform secure storage.
abstract class SecurePinStorageAdapter {
  Future<StoredPinRecord?> readPinRecord();
  Future<void> writePinRecord(StoredPinRecord record);
  Future<void> deletePinRecord();
  String get storageBackendDescription;
}

