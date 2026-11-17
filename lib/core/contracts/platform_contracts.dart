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

/// Contract for non-blocking device location lookup when protection is active
/// or an alarm triggers.
abstract class LocationServiceAdapter {
  bool get isSupported;

  Future<PermissionStatus> checkPermission();

  Future<PermissionStatus> requestPermission();

  Future<({DeviceLocationSnapshot? location, IncidentLocationStatus status})>
  captureCurrentLocation({
    Duration timeout = const Duration(seconds: 6),
    bool highAccuracy = false,
  });
}

/// Contract for OS / Browser notification permissions, local notification
/// display, push token inspection, and tap-to-open-event routing.
abstract class LocalNotificationAdapter {
  bool get isSupported;

  /// Label describing the underlying notification channel ('os', 'browser', 'none').
  String get channelKind;

  Future<PermissionStatus> checkPermission();

  Future<PermissionStatus> requestPermission();

  /// Displays a lock-screen-safe notification (device name + message ONLY,
  /// never coordinates), deduplicated by [incidentId].
  Future<bool> showAlertNotification({
    required String incidentId,
    required String deviceName,
    required String message,
    bool isTest = false,
  });

  /// Emits `incidentId` whenever the user taps a delivered notification.
  Stream<String> get notificationTaps;

  /// Returns and clears any `incidentId` from a cold-launch notification tap.
  String? consumeInitialTappedIncidentId();

  /// Returns an APNs/FCM/WebPush registration token if available on this client.
  Future<String?> getPushRegistrationToken();

  /// Opens external URLs (such as Open in Maps or OS settings) safely.
  Future<bool> openExternalUrl(String url);

  void dispose();
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
    this.notificationsEnabled = true,
    this.notificationChannel = 'push',
    this.pairingSessionId,
    this.remoteStateLabel = 'Connected',
    this.remoteSensorForwardingEnabled = true,
    this.isRingingRemotely = false,
    this.lastActionSummary,
    this.lastSeenAt,
    this.pushSubscriptionNeedsRenewal = false,
    this.lastPushErrorCode,
    this.lastReceiptIncidentId,
    this.lastReceiptAt,
    this.lastReceiptSource,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final DateTime pairedAt;
  final bool pushChannelReady;
  final bool connected;
  final bool notificationsEnabled;
  final String notificationChannel;
  final String? pairingSessionId;
  final String remoteStateLabel;
  final bool remoteSensorForwardingEnabled;
  final bool isRingingRemotely;
  final String? lastActionSummary;
  final DateTime? lastSeenAt;
  final bool pushSubscriptionNeedsRenewal;
  final String? lastPushErrorCode;
  final String? lastReceiptIncidentId;
  final DateTime? lastReceiptAt;
  final String? lastReceiptSource;

  bool get isAndroidDevice => platform.toLowerCase().contains('android');
  bool get isIosDevice => platform.toLowerCase().contains('ios');

  PairedDeviceSummary copyWith({
    String? deviceId,
    String? displayName,
    String? platform,
    DateTime? pairedAt,
    bool? pushChannelReady,
    bool? connected,
    bool? notificationsEnabled,
    String? notificationChannel,
    String? pairingSessionId,
    String? remoteStateLabel,
    bool? remoteSensorForwardingEnabled,
    bool? isRingingRemotely,
    String? lastActionSummary,
    DateTime? lastSeenAt,
    bool? pushSubscriptionNeedsRenewal,
    String? lastPushErrorCode,
    String? lastReceiptIncidentId,
    DateTime? lastReceiptAt,
    String? lastReceiptSource,
  }) {
    return PairedDeviceSummary(
      deviceId: deviceId ?? this.deviceId,
      displayName: displayName ?? this.displayName,
      platform: platform ?? this.platform,
      pairedAt: pairedAt ?? this.pairedAt,
      pushChannelReady: pushChannelReady ?? this.pushChannelReady,
      connected: connected ?? this.connected,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      notificationChannel: notificationChannel ?? this.notificationChannel,
      pairingSessionId: pairingSessionId ?? this.pairingSessionId,
      remoteStateLabel: remoteStateLabel ?? this.remoteStateLabel,
      remoteSensorForwardingEnabled:
          remoteSensorForwardingEnabled ?? this.remoteSensorForwardingEnabled,
      isRingingRemotely: isRingingRemotely ?? this.isRingingRemotely,
      lastActionSummary: lastActionSummary ?? this.lastActionSummary,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      pushSubscriptionNeedsRenewal:
          pushSubscriptionNeedsRenewal ?? this.pushSubscriptionNeedsRenewal,
      lastPushErrorCode: lastPushErrorCode ?? this.lastPushErrorCode,
      lastReceiptIncidentId:
          lastReceiptIncidentId ?? this.lastReceiptIncidentId,
      lastReceiptAt: lastReceiptAt ?? this.lastReceiptAt,
      lastReceiptSource: lastReceiptSource ?? this.lastReceiptSource,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'deviceId': deviceId,
      'displayName': displayName,
      'platform': platform,
      'pairedAtUtcIso': pairedAt.toUtc().toIso8601String(),
      'pushChannelReady': pushChannelReady,
      'connected': connected,
      'notificationsEnabled': notificationsEnabled,
      'notificationChannel': notificationChannel,
      'pairingSessionId': ?pairingSessionId,
      'remoteStateLabel': remoteStateLabel,
      'remoteSensorForwardingEnabled': remoteSensorForwardingEnabled,
      'isRingingRemotely': isRingingRemotely,
      'lastActionSummary': lastActionSummary,
      'lastSeenAtUtcIso': lastSeenAt?.toUtc().toIso8601String(),
      'pushSubscriptionNeedsRenewal': pushSubscriptionNeedsRenewal,
      'lastPushErrorCode': ?lastPushErrorCode,
      'lastReceiptIncidentId': ?lastReceiptIncidentId,
      'lastReceiptAtUtcIso': ?lastReceiptAt?.toUtc().toIso8601String(),
      'lastReceiptSource': ?lastReceiptSource,
    };
  }

  factory PairedDeviceSummary.fromJson(Map<String, Object?> json) {
    final pairedAtRaw = json['pairedAtUtcIso'] as String? ?? '';
    final lastSeenRaw = json['lastSeenAtUtcIso'] as String?;
    final lastReceiptRaw = json['lastReceiptAtUtcIso'] as String?;
    final pushReady = json['pushChannelReady'] as bool? ?? true;
    return PairedDeviceSummary(
      deviceId: json['deviceId'] as String? ?? 'dev_unknown',
      displayName: json['displayName'] as String? ?? 'Phone',
      platform: json['platform'] as String? ?? 'Phone',
      pairedAt:
          DateTime.tryParse(pairedAtRaw)?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      pushChannelReady: pushReady,
      connected: json['connected'] as bool? ?? true,
      notificationsEnabled: json['notificationsEnabled'] as bool? ?? pushReady,
      notificationChannel: json['notificationChannel'] as String? ?? 'push',
      pairingSessionId: json['pairingSessionId'] as String?,
      remoteStateLabel: json['remoteStateLabel'] as String? ?? 'Connected',
      remoteSensorForwardingEnabled:
          json['remoteSensorForwardingEnabled'] as bool? ?? true,
      isRingingRemotely: json['isRingingRemotely'] as bool? ?? false,
      lastActionSummary: json['lastActionSummary'] as String?,
      lastSeenAt: lastSeenRaw != null
          ? DateTime.tryParse(lastSeenRaw)?.toLocal()
          : null,
      pushSubscriptionNeedsRenewal:
          json['pushSubscriptionNeedsRenewal'] as bool? ?? false,
      lastPushErrorCode: json['lastPushErrorCode'] as String?,
      lastReceiptIncidentId: json['lastReceiptIncidentId'] as String?,
      lastReceiptAt: lastReceiptRaw != null
          ? DateTime.tryParse(lastReceiptRaw)?.toLocal()
          : null,
      lastReceiptSource: json['lastReceiptSource'] as String?,
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
    this.pairingUrl,
    this.hostDisplayName,
  });

  final String pairingSessionId;
  final String pairingCode;
  final DateTime expiresAt;
  final String qrPayload;
  final String relayEndpointUrl;
  final String? pairingUrl;
  final String? hostDisplayName;

  String get effectiveScanUrl => pairingUrl ?? qrPayload;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  int remainingSecondsAt(DateTime now) {
    final diff = expiresAt.difference(now).inSeconds;
    return diff > 0 ? diff : 0;
  }
}

/// Non-consuming preview of a pairing code so the phone can prompt
/// `"Connect to <Host Name>?"` with one Connect button.
@immutable
class PairingLookupPreview {
  const PairingLookupPreview({
    required this.pairingSessionId,
    required this.hostDisplayName,
    required this.pairingCode,
    required this.relayEndpointUrl,
    required this.expiresAt,
  });

  final String pairingSessionId;
  final String hostDisplayName;
  final String pairingCode;
  final String relayEndpointUrl;
  final DateTime expiresAt;
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
    this.pushServerConfigured = false,
    this.notificationsEnabled = false,
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
  final bool pushServerConfigured;
  final bool notificationsEnabled;
  final String? statusMessage;

  CompanionSessionState copyWith({
    bool? isConnected,
    String? pairingSessionId,
    String? hostDisplayName,
    String? deviceId,
    String? phoneDisplayName,
    String? relayEndpointUrl,
    String? deliveryMode,
    bool? pushServerConfigured,
    bool? notificationsEnabled,
    String? statusMessage,
  }) {
    return CompanionSessionState(
      isConnected: isConnected ?? this.isConnected,
      pairingSessionId: pairingSessionId ?? this.pairingSessionId,
      hostDisplayName: hostDisplayName ?? this.hostDisplayName,
      deviceId: deviceId ?? this.deviceId,
      phoneDisplayName: phoneDisplayName ?? this.phoneDisplayName,
      relayEndpointUrl: relayEndpointUrl ?? this.relayEndpointUrl,
      deliveryMode: deliveryMode ?? this.deliveryMode,
      pushServerConfigured: pushServerConfigured ?? this.pushServerConfigured,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      statusMessage: statusMessage ?? this.statusMessage,
    );
  }
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
    this.updatedSeq,
    this.peakMotionScore,
    this.hostDisplayName,
    this.isTest = false,
    this.location,
    this.alarmTimeLocation,
    this.locationTrail = const <DeviceLocationSnapshot>[],
    this.locationStatus = IncidentLocationStatus.notRequested,
    this.locationTrackingState = 'last_known',
  });

  final int alertSeq;
  final int? updatedSeq;
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
  final DeviceLocationSnapshot? location;
  final DeviceLocationSnapshot? alarmTimeLocation;
  final List<DeviceLocationSnapshot> locationTrail;
  final IncidentLocationStatus locationStatus;
  final String locationTrackingState;

  int get effectiveCursorSeq =>
      updatedSeq != null && updatedSeq! > alertSeq ? updatedSeq! : alertSeq;

  DeviceLocationSnapshot? get effectiveAlarmLocation =>
      alarmTimeLocation ??
      (locationTrail.isNotEmpty ? locationTrail.first : location);

  bool get hasDistinctLatestLocation =>
      location != null &&
      effectiveAlarmLocation != null &&
      location!.differsMeaningfullyFrom(effectiveAlarmLocation!);

  bool get hasReliableTrail => locationTrail.length >= 2;

  CompanionAlertEvent copyWith({
    int? alertSeq,
    int? updatedSeq,
    String? pairingSessionId,
    String? incidentId,
    String? sessionId,
    String? kind,
    String? detectorType,
    DateTime? triggeredAt,
    String? triggerSummary,
    double? peakMotionScore,
    String? hostDisplayName,
    bool? isTest,
    DeviceLocationSnapshot? location,
    DeviceLocationSnapshot? alarmTimeLocation,
    List<DeviceLocationSnapshot>? locationTrail,
    IncidentLocationStatus? locationStatus,
    String? locationTrackingState,
  }) {
    return CompanionAlertEvent(
      alertSeq: alertSeq ?? this.alertSeq,
      updatedSeq: updatedSeq ?? this.updatedSeq,
      pairingSessionId: pairingSessionId ?? this.pairingSessionId,
      incidentId: incidentId ?? this.incidentId,
      sessionId: sessionId ?? this.sessionId,
      kind: kind ?? this.kind,
      detectorType: detectorType ?? this.detectorType,
      triggeredAt: triggeredAt ?? this.triggeredAt,
      triggerSummary: triggerSummary ?? this.triggerSummary,
      peakMotionScore: peakMotionScore ?? this.peakMotionScore,
      hostDisplayName: hostDisplayName ?? this.hostDisplayName,
      isTest: isTest ?? this.isTest,
      location: location ?? this.location,
      alarmTimeLocation: alarmTimeLocation ?? this.alarmTimeLocation,
      locationTrail: locationTrail ?? this.locationTrail,
      locationStatus: locationStatus ?? this.locationStatus,
      locationTrackingState:
          locationTrackingState ?? this.locationTrackingState,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'alertSeq': alertSeq,
      'updatedSeq': ?updatedSeq,
      'pairingSessionId': pairingSessionId,
      'incidentId': incidentId,
      'sessionId': sessionId,
      'kind': kind,
      'detectorType': detectorType,
      'triggeredAtUtc': triggeredAt.toUtc().toIso8601String(),
      'triggerSummary': triggerSummary,
      'peakMotionScore': ?peakMotionScore,
      'hostDisplayName': ?hostDisplayName,
      'isTest': isTest,
      if (location != null && location!.isValid) 'location': location!.toJson(),
      if (alarmTimeLocation != null && alarmTimeLocation!.isValid)
        'alarmLocation': alarmTimeLocation!.toJson(),
      if (locationTrail.isNotEmpty)
        'locationTrail': locationTrail
            .where((point) => point.isValid)
            .map((point) => point.toJson())
            .toList(growable: false),
      'locationStatus': locationStatus.name,
      'locationTrackingState': locationTrackingState,
    };
  }

  factory CompanionAlertEvent.fromJson(Map<String, Object?> json) {
    final triggeredRaw = json['triggeredAtUtc'] as String? ?? '';
    final rawLocation = json['location'];
    final parsedLocation = rawLocation is Map
        ? DeviceLocationSnapshot.tryFromJson(
            Map<String, Object?>.from(rawLocation),
          )
        : null;
    final rawAlarmLocation = json['alarmLocation'];
    final parsedAlarmLocation = rawAlarmLocation is Map
        ? DeviceLocationSnapshot.tryFromJson(
            Map<String, Object?>.from(rawAlarmLocation),
          )
        : null;
    final rawTrail = json['locationTrail'];
    final parsedTrail = <DeviceLocationSnapshot>[];
    if (rawTrail is List) {
      for (final item in rawTrail) {
        if (item is Map) {
          final point = DeviceLocationSnapshot.tryFromJson(
            Map<String, Object?>.from(item),
          );
          if (point != null) {
            parsedTrail.add(point);
          }
        }
      }
    }
    final parsedLocStatus = IncidentLocationStatus.fromName(
      json['locationStatus'] as String?,
    );
    return CompanionAlertEvent(
      alertSeq: (json['alertSeq'] as num?)?.toInt() ?? 0,
      updatedSeq: (json['updatedSeq'] as num?)?.toInt(),
      pairingSessionId: json['pairingSessionId'] as String? ?? '',
      incidentId: json['incidentId'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      kind: json['kind'] as String? ?? 'realDetectorTrigger',
      detectorType: json['detectorType'] as String? ?? 'unknown',
      triggeredAt: DateTime.tryParse(triggeredRaw)?.toLocal() ?? DateTime.now(),
      triggerSummary: json['triggerSummary'] as String? ?? 'Alarm triggered',
      peakMotionScore: (json['peakMotionScore'] as num?)?.toDouble(),
      hostDisplayName: json['hostDisplayName'] as String?,
      isTest: json['isTest'] as bool? ?? false,
      location: parsedLocation,
      alarmTimeLocation: parsedAlarmLocation ?? parsedLocation,
      locationTrail: parsedTrail.isNotEmpty
          ? List<DeviceLocationSnapshot>.unmodifiable(parsedTrail)
          : (parsedLocation != null
                ? List<DeviceLocationSnapshot>.unmodifiable(
                    <DeviceLocationSnapshot>[
                      parsedAlarmLocation ?? parsedLocation,
                    ],
                  )
                : const <DeviceLocationSnapshot>[]),
      locationStatus:
          parsedLocation != null &&
              parsedLocStatus == IncidentLocationStatus.notRequested
          ? IncidentLocationStatus.attached
          : parsedLocStatus,
      locationTrackingState:
          json['locationTrackingState'] as String? ?? 'last_known',
    );
  }
}

/// Authorized device entry returned for the Devices map view.
///
/// Only devices belonging to the caller's authenticated pairing session are
/// ever included. Companion phones are never mislabeled as the protected laptop.
@immutable
class AuthorizedDeviceLocationSummary {
  const AuthorizedDeviceLocationSummary({
    required this.deviceId,
    required this.displayName,
    required this.role,
    required this.platform,
    required this.online,
    required this.protectionStatusLabel,
    this.isAlarming = false,
    this.trackingState = 'unavailable',
    this.latestLocation,
    this.alarmTimeLocation,
    this.locationTrail = const <DeviceLocationSnapshot>[],
    this.locationStatus = IncidentLocationStatus.notRequested,
    this.statusExplanation,
    this.activeIncidentId,
    this.lastSeenAt,
  });

  final String deviceId;
  final String displayName;

  /// `'protected_device'` or `'companion_phone'`.
  final String role;
  final String platform;
  final bool online;
  final String protectionStatusLabel;
  final bool isAlarming;

  /// `'live'`, `'reconnecting'`, `'last_known'`, or `'unavailable'`.
  final String trackingState;
  final DeviceLocationSnapshot? latestLocation;
  final DeviceLocationSnapshot? alarmTimeLocation;
  final List<DeviceLocationSnapshot> locationTrail;
  final IncidentLocationStatus locationStatus;
  final String? statusExplanation;
  final String? activeIncidentId;
  final DateTime? lastSeenAt;

  bool get isProtectedDevice => role == 'protected_device';

  bool get hasUsableLocation =>
      latestLocation != null && latestLocation!.isValid;

  factory AuthorizedDeviceLocationSummary.fromJson(Map<String, Object?> json) {
    final rawLatest = json['latestLocation'];
    final parsedLatest = rawLatest is Map
        ? DeviceLocationSnapshot.tryFromJson(
            Map<String, Object?>.from(rawLatest),
          )
        : null;
    final rawAlarm = json['alarmLocation'];
    final parsedAlarm = rawAlarm is Map
        ? DeviceLocationSnapshot.tryFromJson(
            Map<String, Object?>.from(rawAlarm),
          )
        : null;
    final rawTrail = json['locationTrail'];
    final parsedTrail = <DeviceLocationSnapshot>[];
    if (rawTrail is List) {
      for (final item in rawTrail) {
        if (item is Map) {
          final point = DeviceLocationSnapshot.tryFromJson(
            Map<String, Object?>.from(item),
          );
          if (point != null) {
            parsedTrail.add(point);
          }
        }
      }
    }
    final lastSeenRaw = json['lastSeenAtUtc'] as String?;
    return AuthorizedDeviceLocationSummary(
      deviceId: json['deviceId'] as String? ?? 'device_unknown',
      displayName: json['displayName'] as String? ?? 'Device',
      role: json['role'] as String? ?? 'protected_device',
      platform: json['platform'] as String? ?? 'Device',
      online: json['online'] as bool? ?? false,
      protectionStatusLabel: json['protectionStatusLabel'] as String? ?? 'Off',
      isAlarming: json['isAlarming'] as bool? ?? false,
      trackingState: json['trackingState'] as String? ?? 'unavailable',
      latestLocation: parsedLatest,
      alarmTimeLocation: parsedAlarm,
      locationTrail: List<DeviceLocationSnapshot>.unmodifiable(parsedTrail),
      locationStatus: IncidentLocationStatus.fromName(
        json['locationStatus'] as String?,
      ),
      statusExplanation: json['statusExplanation'] as String?,
      activeIncidentId: json['activeIncidentId'] as String?,
      lastSeenAt: lastSeenRaw != null
          ? DateTime.tryParse(lastSeenRaw)?.toLocal()
          : null,
    );
  }
}

/// Interactive commands and actions that can be executed on a paired device.
enum PairedDeviceCommandType {
  sendTestPush(id: 'send_test_push', displayName: 'Send test alert'),
  toggleRemoteRing(id: 'toggle_remote_ring', displayName: 'Ring / Locate'),
  syncProtectionState(
    id: 'sync_protection_state',
    displayName: 'Sync protection state',
  ),
  toggleRemoteSensorForwarding(
    id: 'toggle_remote_sensor',
    displayName: 'Toggle sensor link',
  ),
  simulateCompanionMotionTrigger(
    id: 'simulate_companion_motion',
    displayName: 'Trigger companion motion',
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
      deviceName: json['deviceName'] as String? ?? 'Phone',
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
///
/// Explicitly distinguishes whether the relay recorded the Activity event
/// ([relayRecorded]), whether an upstream push provider accepted the push
/// ([pushAccepted]), and whether the phone itself confirmed receipt
/// ([receiptConfirmed]).
@immutable
class NotificationDispatchResult {
  const NotificationDispatchResult({
    required this.delivered,
    required this.capabilityStatus,
    required this.message,
    this.relayRecorded = false,
    this.pushAccepted = false,
    this.receiptConfirmed = false,
    this.deliveryStage = 'unknown',
  });

  final bool delivered;
  final CapabilityStatus capabilityStatus;
  final String message;
  final bool relayRecorded;
  final bool pushAccepted;
  final bool receiptConfirmed;
  final String deliveryStage;
}

/// Contract for remote device pairing and push alert delivery (APNs/FCM via backend).
abstract class RemoteNotificationAdapter {
  Future<NotificationServiceStatus> getStatus();
  Future<List<PairedDeviceSummary>> listPairedDevices();
  Future<NotificationDispatchResult> sendIncidentAlert(IncidentRecord incident);
}

/// Extended contract for notification adapters that support interactive device
/// pairing, short-lived code/QR initiation, companion alert reception, remote
/// companion commands, location updates, unpairing, and backend relay
/// endpoint configuration.
abstract class MutableRemoteNotificationAdapter
    extends RemoteNotificationAdapter {
  String? get relayEndpointUrl;

  PairingCodeInvitation? get activePairingInvitation;

  CompanionSessionState get companionSession;

  List<CompanionAlertEvent> get receivedCompanionAlerts;

  Stream<CompanionAlertEvent> get incomingCompanionAlerts;

  List<PairedDeviceActionRecord> get actionHistory;

  Stream<Map<String, Object?>> get companionSensorEvents;

  set onStateChanged(VoidCallback? callback);

  Future<void> configureRelayEndpoint(String? endpointUrl);

  Future<PairingCodeInvitation> initiateHostPairing({String? hostDisplayName});

  Future<PairingLookupPreview> lookupPairingInvitation(
    String pairingCodeOrPayload, {
    String? endpointUrlOverride,
  });

  Future<List<PairedDeviceSummary>> syncPairedDevicesFromRelay();

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

  Future<CompanionSessionState> pairAsCompanionPhone({
    required String pairingCodeOrPayload,
    required String displayName,
    required String platform,
    String? endpointUrlOverride,
    bool notificationsEnabled = false,
    String notificationChannel = 'foreground_only',
    String? pushToken,
  });

  Future<void> updateCompanionNotificationStatus({
    required bool notificationsEnabled,
    required String deliveryChannel,
    String? pushToken,
  });

  Future<bool> updateIncidentLocation({
    required String incidentId,
    DeviceLocationSnapshot? location,
    required IncidentLocationStatus locationStatus,
    String? locationTrackingState,
  });

  Future<bool> reportHostLocation({
    DeviceLocationSnapshot? location,
    required IncidentLocationStatus locationStatus,
    required String protectionState,
    String? activeIncidentId,
    bool isBoundedAlarmTracking = false,
  });

  Future<List<AuthorizedDeviceLocationSummary>>
  fetchAuthorizedDevicesLocations();

  Future<bool> deleteRelayLocationHistory();

  Future<List<CompanionAlertEvent>> pollCompanionAlertsOnce();

  Future<void> disconnectCompanionSession();

  /// Revokes this installation's host pairing session, paired bonds, push
  /// registrations, and companion session on the relay, then clears local
  /// pairing state and restores [defaultRelayUrl].
  Future<void> resetInstallationPairingAndPush({String? defaultRelayUrl});

  void setForegroundActive(bool active);

  void dispose();
}
