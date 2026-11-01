import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';

/// Windows hardware accelerometer adapter contract (`Windows.Devices.Sensors.Accelerometer`).
///
/// Explicitly returns `CapabilityStatus.notImplemented` on Windows hosts (and
/// `CapabilityStatus.unsupported` on non-Windows hosts) until the Desktop Native
/// teammate connects the WinRT C++ bridge in `windows/runner/`.
class WindowsAccelerometerDetectorAdapter implements MotionDetectorAdapter {
  WindowsAccelerometerDetectorAdapter({bool? isWindowsOverride})
    : _isWindows = isWindowsOverride ?? (!kIsWeb && Platform.isWindows);

  final bool _isWindows;
  final StreamController<DetectorEvent> _eventsController =
      StreamController<DetectorEvent>.broadcast();

  @override
  DetectorType get detectorType => DetectorType.windowsAccelerometer;

  @override
  Stream<DetectorEvent> get events => _eventsController.stream;

  @override
  Future<DetectorCapability> checkCapability() async {
    if (!_isWindows) {
      return const DetectorCapability(
        type: DetectorType.windowsAccelerometer,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary:
            'Windows Hardware Accelerometer is only applicable on Windows.',
        guidance:
            'On macOS, select "macOS Webcam Scene-Motion" for live hardware monitoring.',
      );
    }

    return const DetectorCapability(
      type: DetectorType.windowsAccelerometer,
      status: CapabilityStatus.notImplemented,
      permissionStatus: PermissionStatus.notApplicable,
      summary:
          'Not implemented — Windows WinRT Accelerometer native C++ bridge is a scheduled team task.',
      statusDetail:
          'Planned API: Windows.Devices.Sensors.Accelerometer.GetDefault() with hardware availability check.',
      guidance:
          'See docs/roadmap.md (Area 2: Desktop Native) for the Windows sensor implementation specification.',
    );
  }

  @override
  Future<PermissionStatus> requestPermission() async =>
      PermissionStatus.notApplicable;

  @override
  Future<DetectorStartResult> startMonitoring(MonitorConfig config) async {
    return const DetectorStartResult(
      started: false,
      status: CapabilityStatus.notImplemented,
      message:
          'Windows Hardware Accelerometer monitoring is not yet implemented.',
      errorCode: 'NOT_IMPLEMENTED',
    );
  }

  @override
  Future<void> updateSensitivity(double sensitivity) async {}

  @override
  Future<void> stopMonitoring({String? sessionId}) async {}

  @override
  Future<void> dispose() async {
    await _eventsController.close();
  }
}

/// Windows webcam scene-motion fallback adapter contract (`MediaFoundation`).
class WindowsCameraSceneMotionDetectorAdapter implements MotionDetectorAdapter {
  WindowsCameraSceneMotionDetectorAdapter({bool? isWindowsOverride})
    : _isWindows = isWindowsOverride ?? (!kIsWeb && Platform.isWindows);

  final bool _isWindows;
  final StreamController<DetectorEvent> _eventsController =
      StreamController<DetectorEvent>.broadcast();

  @override
  DetectorType get detectorType => DetectorType.windowsCameraSceneMotion;

  @override
  Stream<DetectorEvent> get events => _eventsController.stream;

  @override
  Future<DetectorCapability> checkCapability() async {
    if (!_isWindows) {
      return const DetectorCapability(
        type: DetectorType.windowsCameraSceneMotion,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary: 'Windows Webcam Scene-Motion is only applicable on Windows.',
      );
    }

    return const DetectorCapability(
      type: DetectorType.windowsCameraSceneMotion,
      status: CapabilityStatus.notImplemented,
      permissionStatus: PermissionStatus.notDetermined,
      summary:
          'Not implemented — Windows webcam scene-motion bridge is a scheduled team task.',
      statusDetail:
          'Planned fallback for clamshell Windows laptops that lack an integrated WinRT accelerometer.',
      guidance:
          'See docs/roadmap.md (Area 2: Desktop Native) for the Windows camera integration task.',
    );
  }

  @override
  Future<PermissionStatus> requestPermission() async =>
      PermissionStatus.notDetermined;

  @override
  Future<DetectorStartResult> startMonitoring(MonitorConfig config) async {
    return const DetectorStartResult(
      started: false,
      status: CapabilityStatus.notImplemented,
      message: 'Windows Webcam Scene-Motion monitoring is not yet implemented.',
      errorCode: 'NOT_IMPLEMENTED',
    );
  }

  @override
  Future<void> updateSensitivity(double sensitivity) async {}

  @override
  Future<void> stopMonitoring({String? sessionId}) async {}

  @override
  Future<void> dispose() async {
    await _eventsController.close();
  }
}
