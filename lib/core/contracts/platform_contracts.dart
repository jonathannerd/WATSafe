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

  /// Whether this detector continues operating reliably when the application
  /// window/activity enters the background (e.g., an active Android Foreground
  /// Service). When false, minimizing or backgrounding pauses monitoring.
  bool get supportsBackgroundMonitoring;

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
  /// Preloads local audio buffers or unlocks browser audio on user interaction.
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

/// Summary of a paired remote device (for cloud/push or companion relay integration).
@immutable
class PairedDeviceSummary {
  const PairedDeviceSummary({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.pairedAt,
    required this.pushChannelReady,
    this.connected = true,
    this.pairingSessionId,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final DateTime pairedAt;
  final bool pushChannelReady;
  final bool connected;
  final String? pairingSessionId;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'deviceId': deviceId,
      'displayName': displayName,
      'platform': platform,
      'pairedAtUtcIso': pairedAt.toUtc().toIso8601String(),
      'pushChannelReady': pushChannelReady,
      'connected': connected,
      if (pairingSessionId != null) 'pairingSessionId': pairingSessionId,
    };
  }

  factory PairedDeviceSummary.fromJson(Map<String, Object?> json) {
    final pairedAtRaw = json['pairedAtUtcIso'] as String? ?? '';
    return PairedDeviceSummary(
      deviceId: json['deviceId'] as String? ?? 'dev_unknown',
      displayName: json['displayName'] as String? ?? 'Companion Device',
      platform: json['platform'] as String? ?? 'Android',
      pairedAt:
          DateTime.tryParse(pairedAtRaw)?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      pushChannelReady: json['pushChannelReady'] as bool? ?? true,
      connected: json['connected'] as bool? ?? true,
      pairingSessionId: json['pairingSessionId'] as String?,
    );
  }
}

/// Short-lived single-use pairing code and QR payload generated by a laptop host.
@immutable
class PairingCodeInvitation {
  const PairingCodeInvitation({
    required this.pairingSessionId,
    required this.pairingCode,
    required this.expiresAt,
    required this.qrPayload,
    required this.relayEndpointUrl,
  });

  final String pairingSessionId;
  final String pairingCode;
  final DateTime expiresAt;
  final String qrPayload;
  final String relayEndpointUrl;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  int remainingSecondsAt(DateTime now) {
    final diff = expiresAt.difference(now).inSeconds;
    return diff > 0 ? diff : 0;
  }
}

/// Connection state when this device is paired as a companion phone receiving
/// alerts from a protected laptop session.
@immutable
class CompanionSessionState {
  const CompanionSessionState({
    required this.isConnected,
    this.pairingSessionId,
    this.hostDisplayName,
    this.deviceId,
    this.phoneDisplayName,
    this.relayEndpointUrl,
    this.deliveryMode = 'foreground_poll',
    this.statusMessage,
  });

  static const CompanionSessionState disconnected = CompanionSessionState(
    isConnected: false,
  );

  final bool isConnected;
  final String? pairingSessionId;
  final String? hostDisplayName;
  final String? deviceId;
  final String? phoneDisplayName;
  final String? relayEndpointUrl;
  final String deliveryMode;
  final String? statusMessage;
}

/// Sanitized metadata-only alert delivered to a paired companion phone.
@immutable
class CompanionAlertEvent {
  const CompanionAlertEvent({
    required this.alertSeq,
    required this.pairingSessionId,
    required this.incidentId,
    required this.sessionId,
    required this.kind,
    required this.detectorType,
    required this.triggeredAt,
    required this.triggerSummary,
    this.peakMotionScore,
    this.hostDisplayName,
    this.isTest = false,
  });

  final int alertSeq;
  final String pairingSessionId;
  final String incidentId;
  final String sessionId;
  final String kind;
  final String detectorType;
  final DateTime triggeredAt;
  final String triggerSummary;
  final double? peakMotionScore;
  final String? hostDisplayName;
  final bool isTest;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'alertSeq': alertSeq,
      'pairingSessionId': pairingSessionId,
      'incidentId': incidentId,
      'sessionId': sessionId,
      'kind': kind,
      'detectorType': detectorType,
      'triggeredAtUtc': triggeredAt.toUtc().toIso8601String(),
      'triggerSummary': triggerSummary,
      if (peakMotionScore != null) 'peakMotionScore': peakMotionScore,
      if (hostDisplayName != null) 'hostDisplayName': hostDisplayName,
      'isTest': isTest,
    };
  }

  factory CompanionAlertEvent.fromJson(Map<String, Object?> json) {
    final triggeredRaw = json['triggeredAtUtc'] as String? ?? '';
    return CompanionAlertEvent(
      alertSeq: (json['alertSeq'] as num?)?.toInt() ?? 0,
      pairingSessionId: json['pairingSessionId'] as String? ?? '',
      incidentId: json['incidentId'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      kind: json['kind'] as String? ?? 'realDetectorTrigger',
      detectorType: json['detectorType'] as String? ?? 'unknown',
      triggeredAt: DateTime.tryParse(triggeredRaw)?.toLocal() ?? DateTime.now(),
      triggerSummary:
          json['triggerSummary'] as String? ?? 'Laptop alarm triggered',
      peakMotionScore: (json['peakMotionScore'] as num?)?.toDouble(),
      hostDisplayName: json['hostDisplayName'] as String?,
      isTest: json['isTest'] as bool? ?? false,
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
/// pairing, short-lived code/QR initiation, companion alert reception,
/// unpairing, and backend relay endpoint configuration.
abstract class MutableRemoteNotificationAdapter
    extends RemoteNotificationAdapter {
  String? get relayEndpointUrl;

  PairingCodeInvitation? get activePairingInvitation;

  CompanionSessionState get companionSession;

  List<CompanionAlertEvent> get receivedCompanionAlerts;

  Stream<CompanionAlertEvent> get incomingCompanionAlerts;

  set onStateChanged(VoidCallback? callback);

  Future<void> configureRelayEndpoint(String? endpointUrl);

  Future<PairingCodeInvitation> initiateHostPairing({String? hostDisplayName});

  Future<List<PairedDeviceSummary>> syncPairedDevicesFromRelay();

  Future<PairedDeviceSummary> pairDevice({
    required String displayName,
    required String platform,
    String? pairingCode,
  });

  Future<void> unpairDevice(String deviceId);

  Future<CompanionSessionState> pairAsCompanionPhone({
    required String pairingCodeOrPayload,
    required String displayName,
    required String platform,
    String? endpointUrlOverride,
  });

  Future<List<CompanionAlertEvent>> pollCompanionAlertsOnce();

  Future<void> disconnectCompanionSession();

  void setForegroundActive(bool active);

  void dispose();
}
