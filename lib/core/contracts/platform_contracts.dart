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

/// Summary of a paired remote device (for cloud/push or companion relay integration).
@immutable
class PairedDeviceSummary {
  const PairedDeviceSummary({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.pairedAt,
    required this.pushChannelReady,
    this.remoteStateLabel = 'Connected • Standby',
    this.remoteSensorForwardingEnabled = true,
    this.isRingingRemotely = false,
    this.lastActionSummary,
    this.lastSeenAt,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final DateTime pairedAt;
  final bool pushChannelReady;
  final String remoteStateLabel;
  final bool remoteSensorForwardingEnabled;
  final bool isRingingRemotely;
  final String? lastActionSummary;
  final DateTime? lastSeenAt;

  bool get isAndroidDevice => platform.toLowerCase().contains('android');
  bool get isIosDevice => platform.toLowerCase().contains('ios');

  PairedDeviceSummary copyWith({
    String? deviceId,
    String? displayName,
    String? platform,
    DateTime? pairedAt,
    bool? pushChannelReady,
    String? remoteStateLabel,
    bool? remoteSensorForwardingEnabled,
    bool? isRingingRemotely,
    String? lastActionSummary,
    DateTime? lastSeenAt,
  }) {
    return PairedDeviceSummary(
      deviceId: deviceId ?? this.deviceId,
      displayName: displayName ?? this.displayName,
      platform: platform ?? this.platform,
      pairedAt: pairedAt ?? this.pairedAt,
      pushChannelReady: pushChannelReady ?? this.pushChannelReady,
      remoteStateLabel: remoteStateLabel ?? this.remoteStateLabel,
      remoteSensorForwardingEnabled:
          remoteSensorForwardingEnabled ?? this.remoteSensorForwardingEnabled,
      isRingingRemotely: isRingingRemotely ?? this.isRingingRemotely,
      lastActionSummary: lastActionSummary ?? this.lastActionSummary,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'deviceId': deviceId,
      'displayName': displayName,
      'platform': platform,
      'pairedAtUtcIso': pairedAt.toUtc().toIso8601String(),
      'pushChannelReady': pushChannelReady,
      'remoteStateLabel': remoteStateLabel,
      'remoteSensorForwardingEnabled': remoteSensorForwardingEnabled,
      'isRingingRemotely': isRingingRemotely,
      'lastActionSummary': lastActionSummary,
      'lastSeenAtUtcIso': lastSeenAt?.toUtc().toIso8601String(),
    };
  }

  factory PairedDeviceSummary.fromJson(Map<String, Object?> json) {
    final pairedAtRaw = json['pairedAtUtcIso'] as String? ?? '';
    final lastSeenRaw = json['lastSeenAtUtcIso'] as String?;
    return PairedDeviceSummary(
      deviceId: json['deviceId'] as String? ?? 'dev_unknown',
      displayName: json['displayName'] as String? ?? 'Companion Device',
      platform: json['platform'] as String? ?? 'Android',
      pairedAt:
          DateTime.tryParse(pairedAtRaw)?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      pushChannelReady: json['pushChannelReady'] as bool? ?? true,
      remoteStateLabel:
          json['remoteStateLabel'] as String? ?? 'Connected • Standby',
      remoteSensorForwardingEnabled:
          json['remoteSensorForwardingEnabled'] as bool? ?? true,
      isRingingRemotely: json['isRingingRemotely'] as bool? ?? false,
      lastActionSummary: json['lastActionSummary'] as String?,
      lastSeenAt: lastSeenRaw != null
          ? DateTime.tryParse(lastSeenRaw)?.toLocal()
          : null,
    );
  }
}

/// Interactive commands and actions that can be executed on a paired device.
enum PairedDeviceCommandType {
  sendTestPush(id: 'send_test_push', displayName: 'Send Test Alert'),
  toggleRemoteRing(id: 'toggle_remote_ring', displayName: 'Ring / Locate'),
  syncProtectionState(
    id: 'sync_protection_state',
    displayName: 'Sync Protection State',
  ),
  toggleRemoteSensorForwarding(
    id: 'toggle_remote_sensor',
    displayName: 'Toggle Sensor Link',
  ),
  simulateCompanionMotionTrigger(
    id: 'simulate_companion_motion',
    displayName: 'Trigger Companion Motion',
  );

  const PairedDeviceCommandType({required this.id, required this.displayName});

  final String id;
  final String displayName;

  static PairedDeviceCommandType fromId(String raw) {
    for (final value in PairedDeviceCommandType.values) {
      if (value.id == raw || value.name == raw) {
        return value;
      }
    }
    return PairedDeviceCommandType.sendTestPush;
  }
}

/// Audit log entry for an interactive command or alert sent to / received from
/// a paired companion device.
@immutable
class PairedDeviceActionRecord {
  const PairedDeviceActionRecord({
    required this.actionId,
    required this.deviceId,
    required this.deviceName,
    required this.commandType,
    required this.timestamp,
    required this.delivered,
    required this.summary,
  });

  final String actionId;
  final String deviceId;
  final String deviceName;
  final PairedDeviceCommandType commandType;
  final DateTime timestamp;
  final bool delivered;
  final String summary;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'actionId': actionId,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'commandType': commandType.id,
      'timestampUtcIso': timestamp.toUtc().toIso8601String(),
      'delivered': delivered,
      'summary': summary,
    };
  }

  factory PairedDeviceActionRecord.fromJson(Map<String, Object?> json) {
    final tsRaw = json['timestampUtcIso'] as String? ?? '';
    return PairedDeviceActionRecord(
      actionId: json['actionId'] as String? ?? 'act_unknown',
      deviceId: json['deviceId'] as String? ?? 'dev_unknown',
      deviceName: json['deviceName'] as String? ?? 'Companion Device',
      commandType: PairedDeviceCommandType.fromId(
        json['commandType'] as String? ?? 'send_test_push',
      ),
      timestamp:
          DateTime.tryParse(tsRaw)?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      delivered: json['delivered'] as bool? ?? true,
      summary: json['summary'] as String? ?? 'Action executed',
    );
  }
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

/// Extended contract for notification adapters that support interactive device
/// pairing, unpairing, remote companion commands, and sensor telemetry bridging.
abstract class MutableRemoteNotificationAdapter
    extends RemoteNotificationAdapter {
  String? get relayEndpointUrl;

  List<PairedDeviceActionRecord> get actionHistory;

  Stream<Map<String, Object?>> get companionSensorEvents;

  Future<void> configureRelayEndpoint(String? endpointUrl);

  Future<PairedDeviceSummary> pairDevice({
    required String displayName,
    required String platform,
    String? pairingCode,
  });

  Future<void> unpairDevice(String deviceId);

  Future<PairedDeviceActionRecord> sendDeviceCommand({
    required String deviceId,
    required PairedDeviceCommandType command,
    Map<String, Object?>? payload,
  });
}
