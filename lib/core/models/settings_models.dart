import 'package:flutter/foundation.dart';

import 'detector_models.dart';

/// Simple user-facing sensitivity presets explaining the practical trade-off
/// in plain language without exposing raw optical-flow thresholds.
enum MotionSensitivityPreset {
  fewerFalseAlarms(
    id: 'fewer_false_alarms',
    sensitivityValue: 0.38,
    title: 'Fewer false alarms',
    description: 'Fewer alerts from people walking or leaning nearby. Best for busy libraries, offices, and cafés.',
  ),
  balanced(
    id: 'balanced',
    sensitivityValue: 0.60,
    title: 'Balanced',
    description: 'Recommended. Detects lifting and carrying promptly while ignoring passersby and room lighting changes.',
  ),
  higherSensitivity(
    id: 'higher_sensitivity',
    sensitivityValue: 0.78,
    title: 'Higher sensitivity',
    description: 'Reacts faster to gentle or slow movement of your device. Best for quiet rooms.',
  );

  const MotionSensitivityPreset({
    required this.id,
    required this.sensitivityValue,
    required this.title,
    required this.description,
  });

  final String id;
  final double sensitivityValue;
  final String title;
  final String description;

  static MotionSensitivityPreset fromSensitivity(double sensitivity) {
    if (sensitivity < 0.49) {
      return MotionSensitivityPreset.fewerFalseAlarms;
    }
    if (sensitivity > 0.69) {
      return MotionSensitivityPreset.higherSensitivity;
    }
    return MotionSensitivityPreset.balanced;
  }
}

/// User-configurable protection settings persisted locally.
@immutable
class ProtectionSettings {
  const ProtectionSettings({
    this.selectedDetector = DetectorType.macosCameraSceneMotion,
    this.motionSensitivity = 0.60,
    this.armingCountdownSeconds = 10,
    this.alarmVolume = 0.85,
    this.onboardingCompleted = false,
    this.deviceDisplayName = '',
    this.shareLocationOnAlarm = true,
    this.shareCompanionPhoneLocation = false,
    this.alertOnInputInteraction = false,
    this.permanentRelayEndpointUrl = '',
  });

  final DetectorType selectedDetector;

  /// Motion sensitivity in `[0.20, 0.90]`.
  final double motionSensitivity;

  /// Closest simple sensitivity preset for normal user flows.
  MotionSensitivityPreset get sensitivityPreset =>
      MotionSensitivityPreset.fromSensitivity(motionSensitivity);

  /// Arming countdown in seconds (`3`..`30`).
  final int armingCountdownSeconds;

  /// Alarm output volume in `[0.10, 1.00]`.
  final double alarmVolume;

  /// Whether first-run onboarding and PIN creation have been completed.
  final bool onboardingCompleted;

  /// User-facing name for this device (e.g., "Jonathan’s MacBook").
  final String deviceDisplayName;

  /// Whether to share this device's location with the paired phone when an alarm triggers.
  final bool shareLocationOnAlarm;

  /// Whether this companion phone explicitly opted in to sharing its own
  /// active foreground location on the paired Devices map.
  final bool shareCompanionPhoneLocation;

  /// Optional desktop tamper check: alert when keyboard, trackpad, or mouse
  /// activity is detected while armed (with a brief PIN-entry grace window).
  final bool alertOnInputInteraction;

  /// User-configured permanent HTTPS relay/companion origin persisted across
  /// normal desktop launches.
  final String permanentRelayEndpointUrl;

  ProtectionSettings copyWith({
    DetectorType? selectedDetector,
    double? motionSensitivity,
    int? armingCountdownSeconds,
    double? alarmVolume,
    bool? onboardingCompleted,
    String? deviceDisplayName,
    bool? shareLocationOnAlarm,
    bool? shareCompanionPhoneLocation,
    bool? alertOnInputInteraction,
    String? permanentRelayEndpointUrl,
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
      deviceDisplayName: deviceDisplayName ?? this.deviceDisplayName,
      shareLocationOnAlarm: shareLocationOnAlarm ?? this.shareLocationOnAlarm,
      shareCompanionPhoneLocation:
          shareCompanionPhoneLocation ?? this.shareCompanionPhoneLocation,
      alertOnInputInteraction:
          alertOnInputInteraction ?? this.alertOnInputInteraction,
      permanentRelayEndpointUrl:
          permanentRelayEndpointUrl ?? this.permanentRelayEndpointUrl,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'selectedDetector': selectedDetector.id,
      'motionSensitivity': motionSensitivity,
      'armingCountdownSeconds': armingCountdownSeconds,
      'alarmVolume': alarmVolume,
      'onboardingCompleted': onboardingCompleted,
      'deviceDisplayName': deviceDisplayName,
      'shareLocationOnAlarm': shareLocationOnAlarm,
      'shareCompanionPhoneLocation': shareCompanionPhoneLocation,
      'alertOnInputInteraction': alertOnInputInteraction,
      if (permanentRelayEndpointUrl.trim().isNotEmpty)
        'permanentRelayEndpointUrl': permanentRelayEndpointUrl.trim(),
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
      deviceDisplayName: json['deviceDisplayName'] as String? ?? '',
      shareLocationOnAlarm: json['shareLocationOnAlarm'] as bool? ?? true,
      shareCompanionPhoneLocation:
          json['shareCompanionPhoneLocation'] as bool? ?? false,
      alertOnInputInteraction:
          json['alertOnInputInteraction'] as bool? ?? false,
      permanentRelayEndpointUrl:
          (json['permanentRelayEndpointUrl'] as String? ?? '').trim(),
    );
  }
}
