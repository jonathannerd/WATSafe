import 'package:flutter/foundation.dart';

import 'detector_models.dart';

/// User-configurable protection settings persisted locally.
@immutable
class ProtectionSettings {
  const ProtectionSettings({
    this.selectedDetector = DetectorType.macosCameraSceneMotion,
    this.motionSensitivity = 0.60,
    this.armingCountdownSeconds = 10,
    this.alarmVolume = 0.85,
    this.onboardingCompleted = false,
  });

  final DetectorType selectedDetector;

  /// Motion sensitivity in `[0.20, 0.90]`.
  final double motionSensitivity;

  /// Arming countdown in seconds (`3`..`30`).
  final int armingCountdownSeconds;

  /// Alarm output volume in `[0.10, 1.00]`.
  final double alarmVolume;

  /// Whether first-run onboarding and PIN creation have been completed.
  final bool onboardingCompleted;

  ProtectionSettings copyWith({
    DetectorType? selectedDetector,
    double? motionSensitivity,
    int? armingCountdownSeconds,
    double? alarmVolume,
    bool? onboardingCompleted,
  }) {
    return ProtectionSettings(
      selectedDetector: selectedDetector ?? this.selectedDetector,
      motionSensitivity: (motionSensitivity ?? this.motionSensitivity).clamp(
        0.20,
        0.90,
      ),
      armingCountdownSeconds:
          (armingCountdownSeconds ?? this.armingCountdownSeconds).clamp(3, 30),
      alarmVolume: (alarmVolume ?? this.alarmVolume).clamp(0.10, 1.00),
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'selectedDetector': selectedDetector.id,
      'motionSensitivity': motionSensitivity,
      'armingCountdownSeconds': armingCountdownSeconds,
      'alarmVolume': alarmVolume,
      'onboardingCompleted': onboardingCompleted,
    };
  }

  factory ProtectionSettings.fromJson(Map<String, Object?> json) {
    final detectorId = json['selectedDetector'] as String?;
    return ProtectionSettings(
      selectedDetector: detectorId != null
          ? DetectorType.fromId(detectorId)
          : DetectorType.macosCameraSceneMotion,
      motionSensitivity:
          ((json['motionSensitivity'] as num?)?.toDouble() ?? 0.60).clamp(
            0.20,
            0.90,
          ),
      armingCountdownSeconds:
          ((json['armingCountdownSeconds'] as num?)?.toInt() ?? 10).clamp(
            3,
            30,
          ),
      alarmVolume: ((json['alarmVolume'] as num?)?.toDouble() ?? 0.85).clamp(
        0.10,
        1.00,
      ),
      onboardingCompleted: json['onboardingCompleted'] as bool? ?? false,
    );
  }
}
