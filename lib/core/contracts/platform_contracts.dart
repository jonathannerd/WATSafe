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

  /// Stream of calibration, telemetry, trigger, warning, and failure events.
  Stream<DetectorEvent> get events;

  /// Inspects hardware availability, permission state, and readiness.
  Future<DetectorCapability> checkCapability();

  /// Requests OS permission for the underlying sensor/camera when applicable.
  Future<PermissionStatus> requestPermission();

  /// Starts active monitoring for the given [config] session.
  Future<DetectorStartResult> startMonitoring(MonitorConfig config);

  /// Updates sensitivity for an active monitoring session.
  Future<void> updateSensitivity(double sensitivity);

  /// Stops active monitoring and releases hardware resources.
  Future<void> stopMonitoring({String? sessionId});

  /// Releases stream controllers and native listeners.
  Future<void> dispose();
}

/// Contract for local alarm audio playback.
abstract class AudioAlarmAdapter {
  /// Prepares audio during the user's Arm action, before the countdown.
  Future<void> prepareForAlarm();

  /// Starts the continuous looping siren immediately at [volume] (`0.0`..`1.0`).
  Future<void> startLoopingAlarm({required double volume});

  /// Starts a short test alarm that automatically stops by [maxDuration].
  Future<void> startTestAlarm({
    required double volume,
    required Duration maxDuration,
  });

  /// Stops any active looping or test alarm immediately.
  Future<void> stopAlarm();

  /// Adjusts the volume (`0.0`..`1.0`) of the alarm output.
  Future<void> setVolume(double volume);

  bool get isPlaying;

  /// Honest explanation of host audio routing and OS mute limitations.
  String get audioLimitationsNote;
}

/// Salted PBKDF2 hash record stored via [SecurePinStorageAdapter].
@immutable
class StoredPinRecord {
  const StoredPinRecord({
    required this.algorithm,
    required this.iterations,
    required this.saltBase64,
    required this.hashBase64,
    required this.updatedAtUtcIso,
  });

  final String algorithm;
  final int iterations;
  final String saltBase64;
  final String hashBase64;
  final String updatedAtUtcIso;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'algorithm': algorithm,
      'iterations': iterations,
      'saltBase64': saltBase64,
      'hashBase64': hashBase64,
      'updatedAtUtcIso': updatedAtUtcIso,
    };
  }

  factory StoredPinRecord.fromJson(Map<String, Object?> json) {
    return StoredPinRecord(
      algorithm: json['algorithm'] as String? ?? 'PBKDF2-HMAC-SHA256',
      iterations: (json['iterations'] as num?)?.toInt() ?? 20000,
      saltBase64: json['saltBase64'] as String? ?? '',
      hashBase64: json['hashBase64'] as String? ?? '',
      updatedAtUtcIso: json['updatedAtUtcIso'] as String? ?? '',
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

/// Contract for persisting local incident history (never contains frames or PINs).
abstract class IncidentStorageAdapter {
  Future<List<IncidentRecord>> loadIncidents();
  Future<void> saveIncident(IncidentRecord incident);
  Future<void> updateIncident(IncidentRecord incident);
  Future<void> clearIncidents();
}

/// Contract for persisting user protection settings.
abstract class SettingsStorageAdapter {
  Future<ProtectionSettings> loadSettings();
  Future<void> saveSettings(ProtectionSettings settings);
}

/// Summary of a paired remote device (for future cloud/push integration).
@immutable
class PairedDeviceSummary {
  const PairedDeviceSummary({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.pairedAt,
    required this.pushChannelReady,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final DateTime pairedAt;
  final bool pushChannelReady;
}

/// Status of the remote pairing & push notification subsystem.
@immutable
class NotificationServiceStatus {
  const NotificationServiceStatus({
    required this.capabilityStatus,
    required this.summary,
    required this.detail,
  });

  final CapabilityStatus capabilityStatus;
  final String summary;
  final String detail;
}

/// Result of attempting to dispatch a remote incident notification.
@immutable
class NotificationDispatchResult {
  const NotificationDispatchResult({
    required this.delivered,
    required this.capabilityStatus,
    required this.message,
  });

  final bool delivered;
  final CapabilityStatus capabilityStatus;
  final String message;
}

/// Contract for remote device pairing and push alert delivery (APNs/FCM via backend).
abstract class RemoteNotificationAdapter {
  Future<NotificationServiceStatus> getStatus();
  Future<List<PairedDeviceSummary>> listPairedDevices();
  Future<NotificationDispatchResult> sendIncidentAlert(IncidentRecord incident);
}
