import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/contracts/platform_contracts.dart';
import '../core/models/detector_models.dart';
import 'desktop/macos_camera_detector.dart';
import 'desktop/windows_detectors.dart';
import 'mobile/android_motion_detector.dart';
import 'mobile/ios_motion_detector.dart';

/// Builds the registry of all platform detector adapters and selects the
/// appropriate default detector for the current host OS.
class PlatformDetectorRegistry {
  static Map<DetectorType, MotionDetectorAdapter> createDefaultDetectors({
    RemoteNotificationAdapter? notificationAdapter,
  }) {
    return <DetectorType, MotionDetectorAdapter>{
      DetectorType.macosCameraSceneMotion: MacOSCameraSceneMotionDetector(),
      DetectorType.windowsAccelerometer: WindowsAccelerometerDetectorAdapter(),
      DetectorType.windowsCameraSceneMotion:
          WindowsCameraSceneMotionDetectorAdapter(),
      DetectorType.androidMotionSensors: AndroidMotionDetectorAdapter(
        notificationAdapter: notificationAdapter,
      ),
      DetectorType.iosCoreMotionForeground: IosCoreMotionDetectorAdapter(),
    };
  }

  static DetectorType defaultDetectorForCurrentPlatform() {
    if (!kIsWeb) {
      if (Platform.isMacOS) {
        return DetectorType.macosCameraSceneMotion;
      }
      if (Platform.isWindows) {
        return DetectorType.windowsAccelerometer;
      }
      if (Platform.isAndroid) {
        return DetectorType.androidMotionSensors;
      }
      if (Platform.isIOS) {
        return DetectorType.iosCoreMotionForeground;
      }
    }
    return DetectorType.macosCameraSceneMotion;
  }
}
