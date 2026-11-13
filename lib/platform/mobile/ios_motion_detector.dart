import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';

/// Real iOS Core Motion foreground monitoring adapter backed by native Swift
/// `CMMotionManager` (`dev.watsafe/ios_motion` and
/// `dev.watsafe/ios_motion_events`).
///
/// Lifecycle policy:
/// iOS does not allow indefinite background accelerometer monitoring for general
/// apps. Live monitoring operates while WATSafe is in the foreground and
/// transitions to `ProtectionState.paused` via `DetectorEventType.lifecyclePaused`
/// when suspended or screen-locked, resuming automatically when foregrounded.
class IosCoreMotionDetectorAdapter implements MotionDetectorAdapter {
  IosCoreMotionDetectorAdapter({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool? isIOSOverride,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel('dev.watsafe/ios_motion'),
       _eventChannel =
           eventChannel ?? const EventChannel('dev.watsafe/ios_motion_events'),
       _isIOS = isIOSOverride ?? (!kIsWeb && Platform.isIOS) {
    if (_isIOS) {
      _ensureEventSubscription();
    }
  }

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final bool _isIOS;

  final StreamController<DetectorEvent> _eventsController =
      StreamController<DetectorEvent>.broadcast();
  StreamSubscription<dynamic>? _nativeEventSub;
  int _eventCounter = 0;

  @override
  DetectorType get detectorType => DetectorType.iosCoreMotionForeground;

  @override
  Stream<DetectorEvent> get events => _eventsController.stream;

  void _ensureEventSubscription() {
    if (_nativeEventSub != null) {
      return;
    }
    try {
      _nativeEventSub = _eventChannel.receiveBroadcastStream().listen(
        _onNativeEvent,
        onError: (Object error) {
          _nativeEventSub = null;
          _eventsController.add(
            DetectorEvent(
              eventId: 'ios_motion_err_${++_eventCounter}',
              sessionId: 'unknown',
              detectorType: detectorType,
              eventType: DetectorEventType.detectorFailed,
              timestamp: DateTime.now(),
              summary: 'iOS Core Motion event stream error: $error',
              errorCode: 'STREAM_ERROR',
            ),
          );
        },
      );
    } catch (_) {
      // Event channel will be subscribed when native side is ready
    }
  }

  @override
  Future<DetectorCapability> checkCapability() async {
    if (!_isIOS) {
      return const DetectorCapability(
        type: DetectorType.iosCoreMotionForeground,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary: 'iOS Core Motion is only applicable on iOS devices.',
        guidance:
            'Select a detector supported by your current operating system.',
      );
    }

    try {
      final response = await _methodChannel.invokeMapMethod<String, Object?>(
        'checkCapability',
      );
      if (response == null) {
        return const DetectorCapability(
          type: DetectorType.iosCoreMotionForeground,
          status: CapabilityStatus.unsupported,
          permissionStatus: PermissionStatus.notApplicable,
          summary:
              'iOS Core Motion bridge returned an empty capability response.',
        );
      }

      final hasHardware = response['hasMotionHardware'] as bool? ?? false;
      final deviceName = response['deviceName'] as String?;
      final permRaw = response['permissionStatus'] as String? ?? 'granted';
      final permissionStatus = _parsePermissionStatus(permRaw);
      final detail = response['detail'] as String?;

      if (!hasHardware) {
        return DetectorCapability(
          type: DetectorType.iosCoreMotionForeground,
          status: CapabilityStatus.unsupported,
          permissionStatus: PermissionStatus.notApplicable,
          summary: 'No Core Motion accelerometer/gyroscope hardware detected.',
          statusDetail:
              detail ??
              'CMMotionManager reported isDeviceMotionAvailable and isAccelerometerAvailable as false.',
          guidance:
              'Run WATSafe on a physical iPhone or iPad with Core Motion hardware.',
        );
      }

      if (permissionStatus == PermissionStatus.denied ||
          permissionStatus == PermissionStatus.restricted) {
        return DetectorCapability(
          type: DetectorType.iosCoreMotionForeground,
          status: CapabilityStatus.permissionRequired,
          permissionStatus: permissionStatus,
          hardwareDeviceName: deviceName ?? 'Apple Core Motion IMU',
          summary: 'iOS Motion & Fitness permission is disabled for WATSafe.',
          statusDetail: detail,
          guidance:
              'Open iOS Settings → Privacy & Security → Motion & Fitness, enable WATSafe, then tap Refresh Readiness.',
        );
      }

      return DetectorCapability(
        type: DetectorType.iosCoreMotionForeground,
        status: CapabilityStatus.ready,
        permissionStatus: PermissionStatus.granted,
        hardwareDeviceName: deviceName ?? 'Apple Core Motion IMU',
        summary:
            'Ready — ${deviceName ?? "iOS Core Motion"} available (foreground active monitoring).',
        statusDetail:
            detail ??
            'CMMotionManager active in foreground; pauses automatically on app suspension or screen lock.',
      );
    } on MissingPluginException {
      return const DetectorCapability(
        type: DetectorType.iosCoreMotionForeground,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary:
            'Native iOS Core Motion bridge is not registered in this runner.',
        guidance:
            'Build and run the iOS target (`flutter run -d ios`) so the native CMMotionManager bridge is active.',
      );
    } on PlatformException catch (error) {
      return DetectorCapability(
        type: DetectorType.iosCoreMotionForeground,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary:
            'iOS Core Motion capability check failed: ${error.message ?? error.code}',
        statusDetail: error.code,
      );
    }
  }

  @override
  Future<PermissionStatus> requestPermission() async {
    if (!_isIOS) {
      return PermissionStatus.notApplicable;
    }
    try {
      final raw = await _methodChannel.invokeMethod<String>(
        'requestPermission',
      );
      return _parsePermissionStatus(raw ?? 'granted');
    } on MissingPluginException {
      return PermissionStatus.notApplicable;
    } on PlatformException {
      return PermissionStatus.denied;
    }
  }

  @override
  Future<DetectorStartResult> startMonitoring(MonitorConfig config) async {
    if (!_isIOS) {
      return const DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: 'iOS Core Motion monitoring is only available on iOS.',
        errorCode: 'UNSUPPORTED_OS',
      );
    }

    await _nativeEventSub?.cancel();
    _nativeEventSub = null;
    _ensureEventSubscription();
    try {
      final response = await _methodChannel.invokeMapMethod<String, Object?>(
        'startMonitoring',
        config.toMap(),
      );
      if (response == null) {
        return const DetectorStartResult(
          started: false,
          status: CapabilityStatus.unsupported,
          message: 'Native iOS Core Motion bridge returned no response.',
          errorCode: 'EMPTY_RESPONSE',
        );
      }

      final started = response['started'] as bool? ?? false;
      final message =
          response['message'] as String? ??
          (started
              ? 'iOS Core Motion foreground monitoring started.'
              : 'Failed to start iOS Core Motion monitoring.');
      final errorCode = response['errorCode'] as String?;

      return DetectorStartResult(
        started: started,
        status: started ? CapabilityStatus.ready : CapabilityStatus.unsupported,
        message: message,
        errorCode: errorCode,
      );
    } on MissingPluginException {
      return const DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: 'Native iOS Core Motion bridge is unavailable.',
        errorCode: 'MISSING_PLUGIN',
      );
    } on PlatformException catch (error) {
      return DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: error.message ?? 'Native iOS Core Motion failed to start.',
        errorCode: error.code,
      );
    }
  }

  @override
  Future<void> updateSensitivity(double sensitivity) async {
    if (!_isIOS) {
      return;
    }
    final threshold = MonitorConfig(
      sessionId: 'update',
      sensitivity: sensitivity,
    ).motionScoreThreshold;
    try {
      await _methodChannel.invokeMethod<void>(
        'updateSensitivity',
        <String, Object?>{
          'sensitivity': sensitivity,
          'motionScoreThreshold': threshold,
        },
      );
    } on MissingPluginException {
      // Ignore
    } on PlatformException {
      // Ignore
    }
  }

  @override
  Future<void> stopMonitoring({String? sessionId}) async {
    if (!_isIOS) {
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>(
        'stopMonitoring',
        <String, Object?>{'sessionId': sessionId},
      );
    } on MissingPluginException {
      // Ignore
    } on PlatformException {
      // Ignore
    }
  }

  void _onNativeEvent(dynamic raw) {
    if (raw is! Map) {
      return;
    }
    final map = Map<String, Object?>.from(raw);
    final sessionId = map['sessionId'] as String? ?? '';
    final typeRaw = map['eventType'] as String? ?? 'telemetryFrame';
    final eventType = _parseEventType(typeRaw);
    final summary =
        map['summary'] as String? ?? 'iOS Core Motion detector update';
    final motionScore = (map['motionScore'] as num?)?.toDouble();
    final threshold = (map['threshold'] as num?)?.toDouble();
    final consecutive = (map['consecutiveFrames'] as num?)?.toInt();
    final errorCode = map['errorCode'] as String?;
    final timestampMs = (map['timestampMs'] as num?)?.toInt();

    _eventsController.add(
      DetectorEvent(
        eventId: 'ios_motion_${++_eventCounter}',
        sessionId: sessionId,
        detectorType: detectorType,
        eventType: eventType,
        timestamp: timestampMs != null
            ? DateTime.fromMillisecondsSinceEpoch(timestampMs)
            : DateTime.now(),
        summary: summary,
        motionScore: motionScore,
        threshold: threshold,
        consecutiveAboveThresholdFrames: consecutive,
        errorCode: errorCode,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _nativeEventSub?.cancel();
    _nativeEventSub = null;
    await _eventsController.close();
  }
}

PermissionStatus _parsePermissionStatus(String raw) {
  switch (raw) {
    case 'granted':
      return PermissionStatus.granted;
    case 'denied':
      return PermissionStatus.denied;
    case 'restricted':
      return PermissionStatus.restricted;
    case 'notApplicable':
      return PermissionStatus.notApplicable;
    case 'notDetermined':
    default:
      return PermissionStatus.notDetermined;
  }
}

DetectorEventType _parseEventType(String raw) {
  for (final value in DetectorEventType.values) {
    if (value.name == raw) {
      return value;
    }
  }
  return DetectorEventType.telemetryFrame;
}
