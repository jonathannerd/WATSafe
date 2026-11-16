import 'package:flutter/foundation.dart';

import 'detector_models.dart';

/// Distinguishes real detector incidents from manual test alarms and hardware failures.
enum IncidentKind {
  realDetectorTrigger,
  manualTestAlarm,
  detectorFailureDuringMonitoring,
}

/// Lifecycle state of location capture for an alarm event.
enum IncidentLocationStatus {
  notRequested,
  pending,
  attached,
  permissionDenied,
  unavailable;

  static IncidentLocationStatus fromName(String? raw) {
    if (raw == null || raw.isEmpty) {
      return IncidentLocationStatus.notRequested;
    }
    for (final value in IncidentLocationStatus.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return IncidentLocationStatus.notRequested;
  }
}

/// Authenticated device location fix captured asynchronously when an alarm triggers.
///
/// Privacy & Security Invariant:
/// Coordinates are stored only in local incident history and authenticated
/// session-scoped event records — never in lock-screen push notification text.
@immutable
class DeviceLocationSnapshot {
  const DeviceLocationSnapshot({
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
    this.accuracyMeters,
    this.isApproximate = false,
    this.isLastKnown = false,
  });

  final double latitude;
  final double longitude;
  final DateTime capturedAt;
  final double? accuracyMeters;
  final bool isApproximate;
  final bool isLastKnown;

  bool get isEffectivelyApproximate =>
      isApproximate || (accuracyMeters != null && accuracyMeters! > 100);

  String get precisionLabel {
    if (isLastKnown) {
      return 'Last known location';
    }
    if (isEffectivelyApproximate) {
      return 'Approximate location';
    }
    return 'Precise location';
  }

  String get formattedCoordinates =>
      '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';

  String get mapsUrl =>
      'https://www.google.com/maps/search/?api=1&query=${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';

  String get appleMapsUrl =>
      'https://maps.apple.com/?ll=${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}&q=Protected%20Device';

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'latitude': latitude,
      'longitude': longitude,
      'capturedAtUtc': capturedAt.toUtc().toIso8601String(),
      'accuracyMeters': ?accuracyMeters,
      'isApproximate': isApproximate,
      'isLastKnown': isLastKnown,
    };
  }

  factory DeviceLocationSnapshot.fromJson(Map<String, Object?> json) {
    final capturedRaw =
        (json['capturedAtUtc'] ?? json['capturedAt']) as String? ?? '';
    return DeviceLocationSnapshot(
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      capturedAt:
          DateTime.tryParse(capturedRaw)?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      accuracyMeters: (json['accuracyMeters'] as num?)?.toDouble(),
      isApproximate: json['isApproximate'] as bool? ?? false,
      isLastKnown: json['isLastKnown'] as bool? ?? false,
    );
  }
}

/// Persistent local incident record.
///
/// Privacy & Security Invariant:
/// Incident records NEVER store camera frames/images or PIN material.
@immutable
class IncidentRecord {
  const IncidentRecord({
    required this.id,
    required this.sessionId,
    required this.kind,
    required this.triggeredAt,
    required this.triggerSummary,
    required this.resolutionSummary,
    this.deviceName,
    this.detectorType,
    this.resolvedAt,
    this.peakMotionScore,
    this.remoteNotificationAttempted = false,
    this.remoteNotificationStatus = 'Not sent',
    this.location,
    this.locationStatus = IncidentLocationStatus.notRequested,
  });

  final String id;
  final String sessionId;
  final IncidentKind kind;
  final String? deviceName;
  final DetectorType? detectorType;
  final DateTime triggeredAt;
  final DateTime? resolvedAt;
  final String triggerSummary;
  final double? peakMotionScore;
  final String resolutionSummary;
  final bool remoteNotificationAttempted;
  final String remoteNotificationStatus;
  final DeviceLocationSnapshot? location;
  final IncidentLocationStatus locationStatus;

  bool get isTest => kind == IncidentKind.manualTestAlarm;

  IncidentRecord copyWith({
    String? id,
    String? sessionId,
    IncidentKind? kind,
    String? deviceName,
    DetectorType? detectorType,
    DateTime? triggeredAt,
    DateTime? resolvedAt,
    String? triggerSummary,
    double? peakMotionScore,
    String? resolutionSummary,
    bool? remoteNotificationAttempted,
    String? remoteNotificationStatus,
    DeviceLocationSnapshot? location,
    IncidentLocationStatus? locationStatus,
  }) {
    return IncidentRecord(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      kind: kind ?? this.kind,
      deviceName: deviceName ?? this.deviceName,
      detectorType: detectorType ?? this.detectorType,
      triggeredAt: triggeredAt ?? this.triggeredAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      triggerSummary: triggerSummary ?? this.triggerSummary,
      peakMotionScore: peakMotionScore ?? this.peakMotionScore,
      resolutionSummary: resolutionSummary ?? this.resolutionSummary,
      remoteNotificationAttempted:
          remoteNotificationAttempted ?? this.remoteNotificationAttempted,
      remoteNotificationStatus:
          remoteNotificationStatus ?? this.remoteNotificationStatus,
      location: location ?? this.location,
      locationStatus: locationStatus ?? this.locationStatus,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'sessionId': sessionId,
      'kind': kind.name,
      'deviceName': ?deviceName,
      'detectorType': detectorType?.id,
      'triggeredAt': triggeredAt.toUtc().toIso8601String(),
      'resolvedAt': resolvedAt?.toUtc().toIso8601String(),
      'triggerSummary': triggerSummary,
      'peakMotionScore': peakMotionScore,
      'resolutionSummary': resolutionSummary,
      'remoteNotificationAttempted': remoteNotificationAttempted,
      'remoteNotificationStatus': remoteNotificationStatus,
      if (location != null) 'location': location!.toJson(),
      'locationStatus': locationStatus.name,
    };
  }

  factory IncidentRecord.fromJson(Map<String, Object?> json) {
    final kindName = json['kind'] as String? ?? '';
    final kind = IncidentKind.values.firstWhere(
      (value) => value.name == kindName,
      orElse: () => IncidentKind.realDetectorTrigger,
    );
    final detectorId = json['detectorType'] as String?;
    final rawLocation = json['location'];
    final parsedLocation = rawLocation is Map
        ? DeviceLocationSnapshot.fromJson(
            Map<String, Object?>.from(rawLocation),
          )
        : null;
    final parsedStatus = IncidentLocationStatus.fromName(
      json['locationStatus'] as String?,
    );
    return IncidentRecord(
      id: json['id'] as String? ?? 'unknown_incident',
      sessionId: json['sessionId'] as String? ?? 'unknown_session',
      kind: kind,
      deviceName: json['deviceName'] as String?,
      detectorType: detectorId != null ? DetectorType.fromId(detectorId) : null,
      triggeredAt:
          DateTime.tryParse(json['triggeredAt'] as String? ?? '')?.toLocal() ??
          DateTime.now(),
      resolvedAt: json['resolvedAt'] != null
          ? DateTime.tryParse(json['resolvedAt'] as String)?.toLocal()
          : null,
      triggerSummary: json['triggerSummary'] as String? ?? 'Motion detected',
      peakMotionScore: (json['peakMotionScore'] as num?)?.toDouble(),
      resolutionSummary:
          json['resolutionSummary'] as String? ?? 'Active / unresolved',
      remoteNotificationAttempted:
          json['remoteNotificationAttempted'] as bool? ?? false,
      remoteNotificationStatus:
          json['remoteNotificationStatus'] as String? ?? 'Not sent',
      location: parsedLocation,
      locationStatus:
          parsedLocation != null &&
              parsedStatus == IncidentLocationStatus.notRequested
          ? IncidentLocationStatus.attached
          : parsedStatus,
    );
  }
}
