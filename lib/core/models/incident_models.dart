import 'package:flutter/foundation.dart';

import 'detector_models.dart';

/// Distinguishes real detector incidents from manual test alarms and hardware failures.
enum IncidentKind {
  realDetectorTrigger,
  manualTestAlarm,
  detectorFailureDuringMonitoring,
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
    this.detectorType,
    this.resolvedAt,
    this.peakMotionScore,
    this.remoteNotificationAttempted = false,
    this.remoteNotificationStatus = 'Not configured (local-only milestone)',
  });

  final String id;
  final String sessionId;
  final IncidentKind kind;
  final DetectorType? detectorType;
  final DateTime triggeredAt;
  final DateTime? resolvedAt;
  final String triggerSummary;
  final double? peakMotionScore;
  final String resolutionSummary;
  final bool remoteNotificationAttempted;
  final String remoteNotificationStatus;

  bool get isTest => kind == IncidentKind.manualTestAlarm;

  IncidentRecord copyWith({
    String? id,
    String? sessionId,
    IncidentKind? kind,
    DetectorType? detectorType,
    DateTime? triggeredAt,
    DateTime? resolvedAt,
    String? triggerSummary,
    double? peakMotionScore,
    String? resolutionSummary,
    bool? remoteNotificationAttempted,
    String? remoteNotificationStatus,
  }) {
    return IncidentRecord(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      kind: kind ?? this.kind,
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
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'sessionId': sessionId,
      'kind': kind.name,
      'detectorType': detectorType?.id,
      'triggeredAt': triggeredAt.toUtc().toIso8601String(),
      'resolvedAt': resolvedAt?.toUtc().toIso8601String(),
      'triggerSummary': triggerSummary,
      'peakMotionScore': peakMotionScore,
      'resolutionSummary': resolutionSummary,
      'remoteNotificationAttempted': remoteNotificationAttempted,
      'remoteNotificationStatus': remoteNotificationStatus,
    };
  }

  factory IncidentRecord.fromJson(Map<String, Object?> json) {
    final kindName = json['kind'] as String? ?? '';
    final kind = IncidentKind.values.firstWhere(
      (value) => value.name == kindName,
      orElse: () => IncidentKind.realDetectorTrigger,
    );
    final detectorId = json['detectorType'] as String?;
    return IncidentRecord(
      id: json['id'] as String? ?? 'unknown_incident',
      sessionId: json['sessionId'] as String? ?? 'unknown_session',
      kind: kind,
      detectorType: detectorId != null ? DetectorType.fromId(detectorId) : null,
      triggeredAt:
          DateTime.tryParse(json['triggeredAt'] as String? ?? '')?.toLocal() ??
          DateTime.now(),
      resolvedAt: json['resolvedAt'] != null
          ? DateTime.tryParse(json['resolvedAt'] as String)?.toLocal()
          : null,
      triggerSummary: json['triggerSummary'] as String? ?? 'Motion incident',
      peakMotionScore: (json['peakMotionScore'] as num?)?.toDouble(),
      resolutionSummary:
          json['resolutionSummary'] as String? ?? 'Active / unresolved',
      remoteNotificationAttempted:
          json['remoteNotificationAttempted'] as bool? ?? false,
      remoteNotificationStatus:
          json['remoteNotificationStatus'] as String? ??
          'Not configured (local-only milestone)',
    );
  }
}
