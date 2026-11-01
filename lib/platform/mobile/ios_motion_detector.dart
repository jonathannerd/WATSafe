import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';

/// iOS Core Motion foreground monitoring adapter contract.
///
/// Explicitly returns `CapabilityStatus.notImplemented` on iOS (and
/// `CapabilityStatus.unsupported` on non-iOS hosts) until the Mobile Native
/// teammate connects `CMMotionManager` in `ios/Runner/`.
///
/// Lifecycle policy:
/// iOS does not allow indefinite background accelerometer monitoring for general
/// apps. Live monitoring operates only while WATSafe is in the foreground and
/// transitions to `ProtectionState.paused` when suspended or screen-locked.
class IosCoreMotionDetectorAdapter implements MotionDetectorAdapter {
  IosCoreMotionDetectorAdapter({bool? isIOSOverride})
    : _isIOS = isIOSOverride ?? (!kIsWeb && Platform.isIOS);

  final bool _isIOS;
  final StreamController<DetectorEvent> _eventsController =
      StreamController<DetectorEvent>.broadcast();

  @override
  DetectorType get detectorType => DetectorType.iosCoreMotionForeground;

  @override
  Stream<DetectorEvent> get events => _eventsController.stream;

  @override
  Future<DetectorCapability> checkCapability() async {
    if (!_isIOS) {
      return const DetectorCapability(
        type: DetectorType.iosCoreMotionForeground,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary: 'iOS Core Motion is only applicable on iOS devices.',
      );
    }

    return const DetectorCapability(
      type: DetectorType.iosCoreMotionForeground,
      status: CapabilityStatus.notImplemented,
      permissionStatus: PermissionStatus.notDetermined,
      summary:
          'Not implemented — iOS Core Motion foreground adapter is a scheduled team task.',
      statusDetail:
          'Uses CMMotionManager while in the foreground; pauses automatically on app suspension or screen lock.',
      guidance:
          'See docs/roadmap.md (Area 3: Mobile Native) for iOS Core Motion and lifecycle handling details.',
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
      message: 'iOS Core Motion foreground monitoring is not yet implemented.',
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
