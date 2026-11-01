import 'package:flutter/foundation.dart';

/// Supported and planned motion/tamper detector modalities across platforms.
enum DetectorType {
  macosCameraSceneMotion(
    id: 'macos_camera_scene_motion',
    displayName: 'macOS Webcam Scene-Motion',
    platformLabel: 'macOS',
    modalityLabel: 'Optical Scene Motion (AVFoundation)',
    limitationNote:
        'Analyzes downsampled grayscale camera frames locally for visual scene motion. '
        'Reacts to people, lighting changes, or laptop movement—not verified physical theft detection. '
        'Optical-flow camera movement estimation is planned as a future improvement.',
  ),
  windowsAccelerometer(
    id: 'windows_accelerometer',
    displayName: 'Windows Hardware Accelerometer',
    platformLabel: 'Windows',
    modalityLabel: 'WinRT Sensors Accelerometer',
    limitationNote:
        'Requires integrated 3-axis accelerometer hardware (primarily 2-in-1 convertibles and tablets). '
        'Many standard clamshell Windows laptops omit an accessible WinRT accelerometer.',
  ),
  windowsCameraSceneMotion(
    id: 'windows_camera_scene_motion',
    displayName: 'Windows Webcam Scene-Motion',
    platformLabel: 'Windows',
    modalityLabel: 'MediaFoundation Scene Motion',
    limitationNote:
        'Planned fallback for Windows laptops without an integrated accelerometer. '
        'Processes local webcam frames for scene-motion changes.',
  ),
  androidMotionSensors(
    id: 'android_motion_sensors',
    displayName: 'Android Motion Sensors & Foreground Service',
    platformLabel: 'Android',
    modalityLabel: 'SensorManager + Foreground Service',
    limitationNote:
        'Requires user-initiated foreground monitoring with a persistent notification and '
        'explicit Android 14+ foreground service declarations.',
  ),
  iosCoreMotionForeground(
    id: 'ios_core_motion_foreground',
    displayName: 'iOS Core Motion (Foreground Only)',
    platformLabel: 'iOS',
    modalityLabel: 'CMMotionManager Foreground Monitoring',
    limitationNote:
        'iOS restricts continuous background sensor capture. Live motion monitoring operates '
        'only while WATSafe remains in the foreground; suspended or locked devices rely on paired-device push alerts.',
  );

  const DetectorType({
    required this.id,
    required this.displayName,
    required this.platformLabel,
    required this.modalityLabel,
    required this.limitationNote,
  });

  final String id;
  final String displayName;
  final String platformLabel;
  final String modalityLabel;
  final String limitationNote;

  static DetectorType fromId(String id) {
    for (final value in DetectorType.values) {
      if (value.id == id) {
        return value;
      }
    }
    return DetectorType.macosCameraSceneMotion;
  }
}

/// Distinct capability and readiness states for platform detectors and services.
enum CapabilityStatus {
  /// Hardware and permission are verified; ready to arm immediately.
  ready,

  /// Hardware is supported and available, but requires permission or setup before arming.
  supported,

  /// Hardware is supported, but OS permission is required or has been denied.
  permissionRequired,

  /// Detector is available or running, but input quality is degraded (e.g., dark/covered lens).
  degraded,

  /// Required hardware is missing or unsupported on this device or host OS.
  unsupported,

  /// Planned integration contract exists, but native implementation is deferred to a later task.
  notImplemented,

  /// Requires external service or pairing configuration that is not set up.
  notConfigured,
}

/// Explicit OS permission states for hardware sensors/camera.
enum PermissionStatus {
  notDetermined,
  granted,
  denied,
  restricted,
  notApplicable,
}

/// Snapshot of a detector's capability, permission state, and hardware readiness.
@immutable
class DetectorCapability {
  const DetectorCapability({
    required this.type,
    required this.status,
    required this.permissionStatus,
    required this.summary,
    this.hardwareDeviceName,
    this.statusDetail,
    this.guidance,
  });

  final DetectorType type;
  final CapabilityStatus status;
  final PermissionStatus permissionStatus;
  final String summary;
  final String? hardwareDeviceName;
  final String? statusDetail;
  final String? guidance;

  /// True only when the detector is genuinely ready (or degraded with warning)
  /// and holds the required OS permissions.
  bool get canArm =>
      (status == CapabilityStatus.ready ||
          status == CapabilityStatus.degraded) &&
      (permissionStatus == PermissionStatus.granted ||
          permissionStatus == PermissionStatus.notApplicable);

  bool get needsPermissionRequest =>
      status == CapabilityStatus.permissionRequired ||
      permissionStatus == PermissionStatus.notDetermined ||
      permissionStatus == PermissionStatus.denied;

  DetectorCapability copyWith({
    DetectorType? type,
    CapabilityStatus? status,
    PermissionStatus? permissionStatus,
    String? summary,
    String? hardwareDeviceName,
    String? statusDetail,
    String? guidance,
  }) {
    return DetectorCapability(
      type: type ?? this.type,
      status: status ?? this.status,
      permissionStatus: permissionStatus ?? this.permissionStatus,
      summary: summary ?? this.summary,
      hardwareDeviceName: hardwareDeviceName ?? this.hardwareDeviceName,
      statusDetail: statusDetail ?? this.statusDetail,
      guidance: guidance ?? this.guidance,
    );
  }
}

/// Configuration passed to a detector when starting an active monitoring session.
@immutable
class MonitorConfig {
  const MonitorConfig({
    required this.sessionId,
    required this.sensitivity,
    this.calibrationDuration = const Duration(milliseconds: 1500),
    this.persistenceFramesRequired = 3,
    this.downsampleWidth = 64,
    this.downsampleHeight = 48,
  });

  final String sessionId;

  /// User sensitivity in `[0.10, 0.90]`. Higher sensitivity maps to a lower
  /// normalized frame-difference trigger threshold.
  final double sensitivity;
  final Duration calibrationDuration;
  final int persistenceFramesRequired;
  final int downsampleWidth;
  final int downsampleHeight;

  /// Converts user sensitivity (`0.10`..`0.90`) into a normalized scene-motion
  /// score threshold (`0.03`..`0.24`).
  double get motionScoreThreshold {
    final clamped = sensitivity.clamp(0.10, 0.90);
    // At sensitivity 0.90 -> threshold ~0.035; at 0.60 -> ~0.095; at 0.20 -> ~0.175
    return double.parse((0.215 - (clamped * 0.20)).toStringAsFixed(4));
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'sessionId': sessionId,
      'sensitivity': sensitivity,
      'motionScoreThreshold': motionScoreThreshold,
      'calibrationDurationMs': calibrationDuration.inMilliseconds,
      'persistenceFramesRequired': persistenceFramesRequired,
      'downsampleWidth': downsampleWidth,
      'downsampleHeight': downsampleHeight,
    };
  }
}

/// Types of events emitted by a [MotionDetectorAdapter].
enum DetectorEventType {
  calibrationStarted,
  calibrationCompleted,
  telemetryFrame,
  motionTriggered,
  poorInputWarning,
  inputRecovered,
  detectorFailed,
  lifecyclePaused,
  lifecycleResumed,
}

/// Strongly typed detector event delivered to the central alarm controller.
@immutable
class DetectorEvent {
  const DetectorEvent({
    required this.eventId,
    required this.sessionId,
    required this.detectorType,
    required this.eventType,
    required this.timestamp,
    required this.summary,
    this.motionScore,
    this.threshold,
    this.averageLuminance,
    this.consecutiveAboveThresholdFrames,
    this.errorCode,
    this.isSimulatedTest = false,
  });

  final String eventId;
  final String sessionId;
  final DetectorType detectorType;
  final DetectorEventType eventType;
  final DateTime timestamp;
  final String summary;

  /// Normalized scene-motion or sensor score in `[0.0, 1.0]`.
  final double? motionScore;

  /// Active motion threshold in `[0.0, 1.0]` at the time of the event.
  final double? threshold;

  /// Normalized average frame luminance in `[0.0, 1.0]` (camera detectors).
  final double? averageLuminance;

  /// Number of consecutive frames exceeding [threshold].
  final int? consecutiveAboveThresholdFrames;

  /// Optional platform or capture error code.
  final String? errorCode;

  /// Whether this event originated from a simulated test rather than real hardware.
  final bool isSimulatedTest;
}
