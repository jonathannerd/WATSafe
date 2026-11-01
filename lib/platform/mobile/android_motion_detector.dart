import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';

/// Android motion sensor and foreground monitoring adapter contract.
///
/// Explicitly returns `CapabilityStatus.notImplemented` on Android (and
/// `CapabilityStatus.unsupported` on non-Android hosts) until the Mobile Native
/// teammate connects `SensorManager` and the Android 14+ foreground service.
class AndroidMotionDetectorAdapter implements MotionDetectorAdapter {
  AndroidMotionDetectorAdapter({bool? isAndroidOverride})
    : _isAndroid = isAndroidOverride ?? (!kIsWeb && Platform.isAndroid);

  final bool _isAndroid;
  final StreamController<DetectorEvent> _eventsController =
      StreamController<DetectorEvent>.broadcast();

  @override
  DetectorType get detectorType => DetectorType.androidMotionSensors;

  @override
  Stream<DetectorEvent> get events => _eventsController.stream;

  @override
  Future<DetectorCapability> checkCapability() async {
    if (!_isAndroid) {
      return const DetectorCapability(
        type: DetectorType.androidMotionSensors,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary:
            'Android Motion Sensors are only applicable on Android devices.',
      );
    }

    return const DetectorCapability(
      type: DetectorType.androidMotionSensors,
      status: CapabilityStatus.notImplemented,
      permissionStatus: PermissionStatus.notDetermined,
      summary:
          'Not implemented — Android SensorManager & Foreground Service is a scheduled team task.',
      statusDetail:
          'Requires SensorManager linear acceleration listener and user-initiated foreground service declaration.',
      guidance:
          'See docs/roadmap.md (Area 3: Mobile Native) for Android sensor & foreground service specifications.',
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
      message: 'Android motion sensor monitoring is not yet implemented.',
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
