import 'dart:math' as math;

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

/// Authenticated device location fix captured asynchronously from the protected device.
///
/// Privacy & Security Invariant:
/// Coordinates are stored only in local incident history and authenticated
/// session-scoped event records — never in lock-screen push notification text,
/// URLs, analytics, or routine logs. Missing or invalid fixes are NEVER mapped
/// to `(0, 0)`.
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

  /// Validates that [latitude] and [longitude] represent a genuine geographic
  /// fix rather than `NaN`, out-of-range numbers, negative `CoreLocation`
  /// invalid-accuracy markers, or uninitialized `(0, 0)` fallback coordinates.
  static bool isValidCoordinates(
    double? latitude,
    double? longitude, {
    double? accuracyMeters,
  }) {
    if (latitude == null || longitude == null) {
      return false;
    }
    if (!latitude.isFinite || !longitude.isFinite) {
      return false;
    }
    if (latitude < -90.0 ||
        latitude > 90.0 ||
        longitude < -180.0 ||
        longitude > 180.0) {
      return false;
    }
    if (accuracyMeters != null &&
        (!accuracyMeters.isFinite || accuracyMeters < 0.0)) {
      return false;
    }
    if (latitude.abs() < 1e-6 && longitude.abs() < 1e-6) {
      return false;
    }
    return true;
  }

  bool get isValid =>
      isValidCoordinates(latitude, longitude, accuracyMeters: accuracyMeters);

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

  String get accuracyDescription {
    final acc = accuracyMeters;
    if (acc != null && acc.isFinite && acc > 0) {
      final rounded = acc.round();
      if (isEffectivelyApproximate) {
        return 'Approximate location (±$rounded m)';
      }
      return 'Within ±$rounded m';
    }
    if (isEffectivelyApproximate) {
      return 'Approximate location';
    }
    return 'Precise location';
  }

  String relativeAgeLabel(DateTime now) {
    final diff = now.difference(capturedAt);
    final seconds = diff.inSeconds < 0 ? 0 : diff.inSeconds;
    if (seconds < 45) {
      return 'Updated just now';
    }
    final minutes = diff.inMinutes < 1 ? 1 : diff.inMinutes;
    if (minutes < 60) {
      return 'Updated $minutes minute${minutes == 1 ? '' : 's'} ago';
    }
    final hours = diff.inHours;
    if (hours < 24) {
      return 'Updated $hours hour${hours == 1 ? '' : 's'} ago';
    }
    final days = diff.inDays;
    return 'Updated $days day${days == 1 ? '' : 's'} ago';
  }

  /// Great-circle distance in meters using the Haversine formula.
  double distanceMetersTo(DeviceLocationSnapshot other) {
    const earthRadiusMeters = 6371000.0;
    final dLat = _degToRad(other.latitude - latitude);
    final dLon = _degToRad(other.longitude - longitude);
    final lat1 = _degToRad(latitude);
    final lat2 = _degToRad(other.latitude);
    final sinLat = math.sin(dLat / 2.0);
    final sinLon = math.sin(dLon / 2.0);
    final a =
        (sinLat * sinLat) + (math.cos(lat1) * math.cos(lat2) * sinLon * sinLon);
    final c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1.0 - a)));
    return earthRadiusMeters * c;
  }

  /// Returns `true` when [other] represents a meaningful geographic displacement
  /// beyond expected Wi-Fi / cellular measurement noise.
  bool differsMeaningfullyFrom(DeviceLocationSnapshot other) {
    if (!isValid || !other.isValid) {
      return false;
    }
    final dist = distanceMetersTo(other);
    final combinedAcc =
        (accuracyMeters ?? 35.0) + (other.accuracyMeters ?? 35.0);
    final minSeparation = math.max(25.0, combinedAcc * 0.65);
    return dist >= minSeparation;
  }

  /// Appends [candidate] to [existingTrail] only when it is valid, not an
  /// implausible teleport jump, and displaced beyond measurement-accuracy noise
  /// so noisy Wi-Fi fixes never draw a misleading travel route.
  static List<DeviceLocationSnapshot> appendFilteredTrailPoint(
    List<DeviceLocationSnapshot> existingTrail,
    DeviceLocationSnapshot candidate, {
    int maxPoints = 40,
  }) {
    if (!candidate.isValid) {
      return existingTrail;
    }
    if (existingTrail.isEmpty) {
      return <DeviceLocationSnapshot>[candidate];
    }
    final last = existingTrail.last;
    final dtSec =
        candidate.capturedAt.difference(last.capturedAt).inMilliseconds /
        1000.0;
    if (dtSec < -2.0) {
      return existingTrail;
    }
    final dist = last.distanceMetersTo(candidate);
    final combinedAcc =
        (last.accuracyMeters ?? 40.0) + (candidate.accuracyMeters ?? 40.0);

    // Reject physically implausible jumps (> ~235 km/h over short intervals)
    // beyond measurement uncertainty.
    if (dtSec >= 0.0 && dtSec <= 300.0) {
      final maxPlausibleMeters =
          (65.0 * math.max(dtSec, 1.0)) + combinedAcc + 120.0;
      if (dist > maxPlausibleMeters) {
        return existingTrail;
      }
    }

    // Do not extend the trail for minor jitter inside the accuracy circle.
    final minDisplacement = math.max(22.0, combinedAcc * 0.75);
    if (dist < minDisplacement) {
      return existingTrail;
    }

    final updated = <DeviceLocationSnapshot>[...existingTrail, candidate];
    if (updated.length <= maxPoints) {
      return updated;
    }
    // Preserve the initial alarm-time point at index 0 plus the latest tail.
    return <DeviceLocationSnapshot>[
      updated.first,
      ...updated.sublist(updated.length - (maxPoints - 1)),
    ];
  }

  static double _degToRad(double degrees) => degrees * (math.pi / 180.0);

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

  static DeviceLocationSnapshot? tryFromJson(Map<String, Object?>? json) {
    if (json == null) {
      return null;
    }
    final lat = (json['latitude'] as num?)?.toDouble();
    final lon = (json['longitude'] as num?)?.toDouble();
    final rawAccuracy = (json['accuracyMeters'] as num?)?.toDouble();
    if (!isValidCoordinates(lat, lon, accuracyMeters: rawAccuracy)) {
      return null;
    }
    final capturedRaw =
        (json['capturedAtUtc'] ?? json['capturedAt']) as String? ?? '';
    final parsedTime = DateTime.tryParse(capturedRaw)?.toLocal();
    return DeviceLocationSnapshot(
      latitude: lat!,
      longitude: lon!,
      capturedAt: parsedTime ?? DateTime.fromMillisecondsSinceEpoch(0),
      accuracyMeters: rawAccuracy,
      isApproximate: json['isApproximate'] as bool? ?? false,
      isLastKnown: json['isLastKnown'] as bool? ?? false,
    );
  }

  factory DeviceLocationSnapshot.fromJson(Map<String, Object?> json) {
    final parsed = tryFromJson(json);
    if (parsed == null) {
      throw const FormatException(
        'Invalid DeviceLocationSnapshot coordinates.',
      );
    }
    return parsed;
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
    this.alarmTimeLocation,
    this.locationTrail = const <DeviceLocationSnapshot>[],
    this.locationStatus = IncidentLocationStatus.notRequested,
    this.locationTrackingState = 'last_known',
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

  /// Latest known location recorded for this incident.
  final DeviceLocationSnapshot? location;

  /// First valid location captured when the alarm triggered.
  final DeviceLocationSnapshot? alarmTimeLocation;

  /// Filtered reliable post-alarm positions for this incident.
  final List<DeviceLocationSnapshot> locationTrail;

  final IncidentLocationStatus locationStatus;

  /// `'live'`, `'reconnecting'`, `'last_known'`, or `'stopped'`.
  final String locationTrackingState;

  bool get isTest => kind == IncidentKind.manualTestAlarm;

  DeviceLocationSnapshot? get effectiveAlarmLocation =>
      alarmTimeLocation ??
      (locationTrail.isNotEmpty ? locationTrail.first : location);

  bool get hasDistinctLatestLocation =>
      location != null &&
      effectiveAlarmLocation != null &&
      location!.differsMeaningfullyFrom(effectiveAlarmLocation!);

  bool get hasReliableTrail => locationTrail.length >= 2;

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
    DeviceLocationSnapshot? alarmTimeLocation,
    List<DeviceLocationSnapshot>? locationTrail,
    IncidentLocationStatus? locationStatus,
    String? locationTrackingState,
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
      alarmTimeLocation: alarmTimeLocation ?? this.alarmTimeLocation,
      locationTrail: locationTrail ?? this.locationTrail,
      locationStatus: locationStatus ?? this.locationStatus,
      locationTrackingState:
          locationTrackingState ?? this.locationTrackingState,
    );
  }

  /// Scrubs stored location history from this incident while preserving
  /// incident audit metadata.
  IncidentRecord withoutLocationHistory() {
    return IncidentRecord(
      id: id,
      sessionId: sessionId,
      kind: kind,
      deviceName: deviceName,
      detectorType: detectorType,
      triggeredAt: triggeredAt,
      resolvedAt: resolvedAt,
      triggerSummary: triggerSummary,
      peakMotionScore: peakMotionScore,
      resolutionSummary: resolutionSummary,
      remoteNotificationAttempted: remoteNotificationAttempted,
      remoteNotificationStatus: remoteNotificationStatus,
      location: null,
      alarmTimeLocation: null,
      locationTrail: const <DeviceLocationSnapshot>[],
      locationStatus: IncidentLocationStatus.notRequested,
      locationTrackingState: 'stopped',
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

  factory IncidentRecord.fromJson(Map<String, Object?> json) {
    final kindName = json['kind'] as String? ?? '';
    final kind = IncidentKind.values.firstWhere(
      (value) => value.name == kindName,
      orElse: () => IncidentKind.realDetectorTrigger,
    );
    final detectorId = json['detectorType'] as String?;
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
              parsedStatus == IncidentLocationStatus.notRequested
          ? IncidentLocationStatus.attached
          : parsedStatus,
      locationTrackingState:
          json['locationTrackingState'] as String? ?? 'last_known',
    );
  }
}
