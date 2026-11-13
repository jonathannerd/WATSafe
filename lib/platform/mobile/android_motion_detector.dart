import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';

/// Real Android motion sensor and foreground monitoring adapter backed by
/// native Kotlin `SensorManager` (`dev.watsafe/android_motion` and
/// `dev.watsafe/android_motion_events`).
///
/// Algorithm notes:
/// - Queries `SensorManager` for `Sensor.TYPE_LINEAR_ACCELERATION` (or fallback
///   `Sensor.TYPE_ACCELEROMETER`).
/// - Calibrates the resting baseline vector and magnitude during the startup
///   calibration window, then computes 3D acceleration vector and magnitude
///   deltas (`motionScore`) with a consecutive-sample persistence filter.
class AndroidMotionDetectorAdapter implements MotionDetectorAdapter {
  AndroidMotionDetectorAdapter({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool? isAndroidOverride,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel('dev.watsafe/android_motion'),
       _eventChannel =
           eventChannel ??
           const EventChannel('dev.watsafe/android_motion_events'),
       _isAndroid = isAndroidOverride ?? (!kIsWeb && Platform.isAndroid) {
    if (_isAndroid) {
      _ensureEventSubscription();
    }
  }

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final bool _isAndroid;

  final StreamController<DetectorEvent> _eventsController =
      StreamController<DetectorEvent>.broadcast();
  StreamSubscription<dynamic>? _nativeEventSub;
  int _eventCounter = 0;

  @override
  DetectorType get detectorType => DetectorType.androidMotionSensors;

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
              eventId: 'android_motion_err_${++_eventCounter}',
              sessionId: 'unknown',
              detectorType: detectorType,
              eventType: DetectorEventType.detectorFailed,
              timestamp: DateTime.now(),
              summary: 'Android motion sensor event stream error: $error',
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
    if (!_isAndroid) {
      return const DetectorCapability(
        type: DetectorType.androidMotionSensors,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary:
            'Android Motion Sensors are only applicable on Android devices.',
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
          type: DetectorType.androidMotionSensors,
          status: CapabilityStatus.unsupported,
          permissionStatus: PermissionStatus.notApplicable,
          summary:
              'Android motion sensor bridge returned an empty capability response.',
        );
      }

      final hasHardware = response['hasMotionHardware'] as bool? ?? false;
      final deviceName = response['deviceName'] as String?;
      final permRaw = response['permissionStatus'] as String? ?? 'granted';
      final permissionStatus = _parsePermissionStatus(permRaw);
      final detail = response['detail'] as String?;

      if (!hasHardware) {
        return DetectorCapability(
          type: DetectorType.androidMotionSensors,
          status: CapabilityStatus.unsupported,
          permissionStatus: PermissionStatus.notApplicable,
          summary: 'No accelerometer or linear acceleration sensor detected.',
          statusDetail:
              detail ?? 'Android SensorManager returned no motion sensors.',
          guidance:
              'Run WATSafe on an Android device with hardware accelerometer sensors.',
        );
      }

      if (permissionStatus == PermissionStatus.denied ||
          permissionStatus == PermissionStatus.restricted) {
        return DetectorCapability(
          type: DetectorType.androidMotionSensors,
          status: CapabilityStatus.permissionRequired,
          permissionStatus: permissionStatus,
          hardwareDeviceName: deviceName ?? 'Android Motion Sensor',
          summary: 'Android sensor or notification permission is required.',
          statusDetail: detail,
          guidance:
              'Grant sensor permission in Android Settings, then tap Refresh Readiness.',
        );
      }

      return DetectorCapability(
        type: DetectorType.androidMotionSensors,
        status: CapabilityStatus.ready,
        permissionStatus: PermissionStatus.granted,
        hardwareDeviceName: deviceName ?? 'Android Linear Accelerometer',
        summary: 'Ready — ${deviceName ?? "Android Motion Sensor"} available.',
        statusDetail:
            detail ??
            'Android SensorManager 3-axis motion pipeline ready for baseline calibration.',
      );
    } on MissingPluginException {
      return const DetectorCapability(
        type: DetectorType.androidMotionSensors,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary:
            'Native Android motion sensor bridge is not registered in this runner.',
        guidance:
            'Build and run the Android target (`flutter run -d android`) so the native SensorManager bridge is active.',
      );
    } on PlatformException catch (error) {
      return DetectorCapability(
        type: DetectorType.androidMotionSensors,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary:
            'Android motion capability check failed: ${error.message ?? error.code}',
        statusDetail: error.code,
      );
    }
  }

  @override
  Future<PermissionStatus> requestPermission() async {
    if (!_isAndroid) {
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
    if (!_isAndroid) {
      return const DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message:
            'Android motion sensor monitoring is only available on Android.',
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
          message: 'Native Android motion bridge returned no response.',
          errorCode: 'EMPTY_RESPONSE',
        );
      }

      final started = response['started'] as bool? ?? false;
      final message =
          response['message'] as String? ??
          (started
              ? 'Android motion sensor monitoring started.'
              : 'Failed to start Android motion sensor monitoring.');
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
        message: 'Native Android motion bridge is unavailable.',
        errorCode: 'MISSING_PLUGIN',
      );
    } on PlatformException catch (error) {
      return DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message:
            error.message ?? 'Native Android motion sensor failed to start.',
        errorCode: error.code,
      );
    }
  }

  @override
  Future<void> updateSensitivity(double sensitivity) async {
    if (!_isAndroid) {
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
    if (!_isAndroid) {
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
        map['summary'] as String? ?? 'Android motion detector update';
    final motionScore = (map['motionScore'] as num?)?.toDouble();
    final threshold = (map['threshold'] as num?)?.toDouble();
    final consecutive = (map['consecutiveFrames'] as num?)?.toInt();
    final errorCode = map['errorCode'] as String?;
    final timestampMs = (map['timestampMs'] as num?)?.toInt();

    _eventsController.add(
      DetectorEvent(
        eventId: 'android_motion_${++_eventCounter}',
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
