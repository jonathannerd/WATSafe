import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';

/// Real Windows hardware accelerometer detector backed by native C++/WinRT and
/// Windows Sensor API (`dev.watsafe/windows_accelerometer` and
/// `dev.watsafe/windows_accelerometer_events`).
///
/// Algorithm notes:
/// - Queries `Windows.Devices.Sensors.Accelerometer.GetDefault()` (and fallback
///   `ISensorManager` `SENSOR_TYPE_ACCELEROMETER_3D`).
/// - Reports `CapabilityStatus.unsupported` when no integrated 3-axis
///   accelerometer hardware is present (common on standard clamshell laptops)
///   and guides the user to `Windows Webcam Scene-Motion`.
/// - Calibrates the 1g resting vector and magnitude baseline during the startup
///   calibration interval, then computes 3D acceleration vector and magnitude
///   deltas (`motionScore`) with a consecutive-sample persistence filter.
class WindowsAccelerometerDetectorAdapter implements MotionDetectorAdapter {
  WindowsAccelerometerDetectorAdapter({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool? isWindowsOverride,
  }) : _methodChannel =
           methodChannel ??
           const MethodChannel('dev.watsafe/windows_accelerometer'),
       _eventChannel =
           eventChannel ??
           const EventChannel('dev.watsafe/windows_accelerometer_events'),
       _isWindows = isWindowsOverride ?? (!kIsWeb && Platform.isWindows) {
    if (_isWindows) {
      _ensureEventSubscription();
    }
  }

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final bool _isWindows;

  final StreamController<DetectorEvent> _eventsController =
      StreamController<DetectorEvent>.broadcast();
  StreamSubscription<dynamic>? _nativeEventSub;
  int _eventCounter = 0;

  @override
  DetectorType get detectorType => DetectorType.windowsAccelerometer;

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
              eventId: 'win_accel_err_${++_eventCounter}',
              sessionId: 'unknown',
              detectorType: detectorType,
              eventType: DetectorEventType.detectorFailed,
              timestamp: DateTime.now(),
              summary: 'Windows accelerometer event stream error: $error',
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
    if (!_isWindows) {
      return const DetectorCapability(
        type: DetectorType.windowsAccelerometer,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary:
            'Windows Hardware Accelerometer is only applicable on Windows.',
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
          type: DetectorType.windowsAccelerometer,
          status: CapabilityStatus.unsupported,
          permissionStatus: PermissionStatus.notApplicable,
          summary:
              'Windows accelerometer bridge returned an empty capability response.',
        );
      }

      final hasHardware =
          response['hasAccelerometerHardware'] as bool? ?? false;
      final deviceName = response['deviceName'] as String?;
      final permRaw =
          response['permissionStatus'] as String? ?? 'notApplicable';
      final permissionStatus = _parsePermissionStatus(permRaw);
      final detail = response['detail'] as String?;

      if (!hasHardware) {
        return DetectorCapability(
          type: DetectorType.windowsAccelerometer,
          status: CapabilityStatus.unsupported,
          permissionStatus: PermissionStatus.notApplicable,
          summary:
              'No integrated 3-axis accelerometer hardware detected on this Windows PC.',
          statusDetail:
              detail ??
              'Windows.Devices.Sensors.Accelerometer.GetDefault() returned null.',
          guidance:
              'Standard clamshell Windows laptops often omit a WinRT accelerometer. '
              'Select "Windows Webcam Scene-Motion" below for live optical monitoring.',
        );
      }

      if (permissionStatus == PermissionStatus.denied ||
          permissionStatus == PermissionStatus.restricted) {
        return DetectorCapability(
          type: DetectorType.windowsAccelerometer,
          status: CapabilityStatus.permissionRequired,
          permissionStatus: permissionStatus,
          hardwareDeviceName:
              deviceName ?? 'Windows Integrated 3-Axis Accelerometer',
          summary:
              'Motion sensor access is disabled in Windows Privacy Settings.',
          statusDetail: detail,
          guidance:
              'Open Windows Settings → Privacy & security → Motion (or Sensors), '
              'enable access, then click Refresh Readiness.',
        );
      }

      return DetectorCapability(
        type: DetectorType.windowsAccelerometer,
        status: CapabilityStatus.ready,
        permissionStatus: PermissionStatus.granted,
        hardwareDeviceName:
            deviceName ?? 'Windows Integrated 3-Axis Accelerometer',
        summary:
            'Ready — ${deviceName ?? "Windows Hardware Accelerometer"} available.',
        statusDetail:
            detail ??
            '3-axis WinRT accelerometer ready for 1g baseline calibration.',
      );
    } on MissingPluginException {
      return const DetectorCapability(
        type: DetectorType.windowsAccelerometer,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary:
            'Native Windows accelerometer bridge is not registered in this runner.',
        guidance:
            'Rebuild and run the Windows desktop target (`flutter run -d windows`) '
            'so the native WinRT sensor bridge is active.',
      );
    } on PlatformException catch (error) {
      return DetectorCapability(
        type: DetectorType.windowsAccelerometer,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary:
            'Windows accelerometer capability check failed: ${error.message ?? error.code}',
        statusDetail: error.code,
      );
    }
  }

  @override
  Future<PermissionStatus> requestPermission() async {
    if (!_isWindows) {
      return PermissionStatus.notApplicable;
    }
    try {
      final raw = await _methodChannel.invokeMethod<String>(
        'requestPermission',
      );
      return _parsePermissionStatus(raw ?? 'notApplicable');
    } on MissingPluginException {
      return PermissionStatus.notApplicable;
    } on PlatformException {
      return PermissionStatus.denied;
    }
  }

  @override
  Future<DetectorStartResult> startMonitoring(MonitorConfig config) async {
    if (!_isWindows) {
      return const DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message:
            'Windows accelerometer monitoring is only available on Windows.',
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
          message: 'Native Windows accelerometer bridge returned no response.',
          errorCode: 'EMPTY_RESPONSE',
        );
      }

      final started = response['started'] as bool? ?? false;
      final message =
          response['message'] as String? ??
          (started
              ? 'Windows hardware accelerometer monitoring started.'
              : 'Failed to start Windows accelerometer monitoring.');
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
        message: 'Native Windows accelerometer bridge is unavailable.',
        errorCode: 'MISSING_PLUGIN',
      );
    } on PlatformException catch (error) {
      return DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message:
            error.message ?? 'Native Windows accelerometer failed to start.',
        errorCode: error.code,
      );
    }
  }

  @override
  Future<void> updateSensitivity(double sensitivity) async {
    if (!_isWindows) {
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
    if (!_isWindows) {
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
        map['summary'] as String? ?? 'Windows accelerometer detector update';
    final motionScore = (map['motionScore'] as num?)?.toDouble();
    final threshold = (map['threshold'] as num?)?.toDouble();
    final consecutive = (map['consecutiveFrames'] as num?)?.toInt();
    final errorCode = map['errorCode'] as String?;
    final timestampMs = (map['timestampMs'] as num?)?.toInt();

    _eventsController.add(
      DetectorEvent(
        eventId: 'win_accel_${++_eventCounter}',
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

/// Real Windows webcam scene-motion detector backed by native C++ / Windows
/// Media Foundation (`dev.watsafe/windows_camera` and
/// `dev.watsafe/windows_camera_events`).
///
/// Algorithm notes:
/// - Enumerates video capture hardware via `MFEnumDeviceSources` and reads
///   frames off the UI thread via `IMFSourceReader`.
/// - Downsamples each frame to a compact `64x48` grayscale grid (`NV12`, `YUY2`,
///   `RGB32`, `RGB24`).
/// - Calibrates an adaptive reference baseline and computes normalized mean
///   absolute pixel luminance delta (`motionScore` in `0.0..1.0`).
/// - Enforces a consecutive-frame persistence filter before emitting
///   `DetectorEventType.motionTriggered` and warns on dark/covered lenses via
///   `DetectorEventType.poorInputWarning`.
/// - Never saves or uploads images or video frames.
class WindowsCameraSceneMotionDetectorAdapter implements MotionDetectorAdapter {
  WindowsCameraSceneMotionDetectorAdapter({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool? isWindowsOverride,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel('dev.watsafe/windows_camera'),
       _eventChannel =
           eventChannel ??
           const EventChannel('dev.watsafe/windows_camera_events'),
       _isWindows = isWindowsOverride ?? (!kIsWeb && Platform.isWindows) {
    if (_isWindows) {
      _ensureEventSubscription();
    }
  }

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final bool _isWindows;

  final StreamController<DetectorEvent> _eventsController =
      StreamController<DetectorEvent>.broadcast();
  StreamSubscription<dynamic>? _nativeEventSub;
  int _eventCounter = 0;

  @override
  DetectorType get detectorType => DetectorType.windowsCameraSceneMotion;

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
              eventId: 'win_cam_err_${++_eventCounter}',
              sessionId: 'unknown',
              detectorType: detectorType,
              eventType: DetectorEventType.detectorFailed,
              timestamp: DateTime.now(),
              summary: 'Windows camera event stream error: $error',
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
    if (!_isWindows) {
      return const DetectorCapability(
        type: DetectorType.windowsCameraSceneMotion,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary: 'Windows Webcam Scene-Motion is only applicable on Windows.',
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
          type: DetectorType.windowsCameraSceneMotion,
          status: CapabilityStatus.unsupported,
          permissionStatus: PermissionStatus.notDetermined,
          summary:
              'Windows camera bridge returned an empty capability response.',
        );
      }

      final hasHardware = response['hasCameraHardware'] as bool? ?? false;
      final deviceName = response['deviceName'] as String?;
      final permRaw = response['permissionStatus'] as String? ?? 'granted';
      final permissionStatus = _parsePermissionStatus(permRaw);

      if (!hasHardware) {
        return DetectorCapability(
          type: DetectorType.windowsCameraSceneMotion,
          status: CapabilityStatus.unsupported,
          permissionStatus: permissionStatus,
          summary: 'No camera hardware detected on this Windows PC.',
          statusDetail:
              response['detail'] as String? ??
              'Media Foundation MFEnumDeviceSources returned 0 video devices.',
          guidance:
              'Connect a USB/UVC webcam or use the manual Test Alarm to verify local siren operation.',
        );
      }

      switch (permissionStatus) {
        case PermissionStatus.granted:
          return DetectorCapability(
            type: DetectorType.windowsCameraSceneMotion,
            status: CapabilityStatus.ready,
            permissionStatus: PermissionStatus.granted,
            hardwareDeviceName: deviceName ?? 'Built-in Windows Camera',
            summary:
                'Ready — ${deviceName ?? "Windows Camera"} available with camera access enabled.',
            statusDetail:
                'Local 64x48 grayscale scene-motion pipeline ready via Media Foundation (no frames saved or uploaded).',
          );

        case PermissionStatus.notDetermined:
          return DetectorCapability(
            type: DetectorType.windowsCameraSceneMotion,
            status: CapabilityStatus.permissionRequired,
            permissionStatus: PermissionStatus.notDetermined,
            hardwareDeviceName: deviceName ?? 'Built-in Windows Camera',
            summary:
                'Camera permission required to enable Windows scene-motion monitoring.',
            statusDetail:
                'Hardware detected: ${deviceName ?? "Windows Camera"}.',
            guidance:
                'Click "Grant Camera Permission" below to check or open Windows Camera Privacy Settings.',
          );

        case PermissionStatus.denied:
        case PermissionStatus.restricted:
          return DetectorCapability(
            type: DetectorType.windowsCameraSceneMotion,
            status: CapabilityStatus.permissionRequired,
            permissionStatus: permissionStatus,
            hardwareDeviceName: deviceName ?? 'Built-in Windows Camera',
            summary: 'Camera access is disabled in Windows Privacy Settings.',
            statusDetail:
                'Windows ConsentStore blocked webcam access for desktop applications.',
            guidance:
                'Open Windows Settings → Privacy & security → Camera, enable "Camera access" and "Let desktop apps access your camera", then click Refresh Readiness.',
          );

        case PermissionStatus.notApplicable:
          return const DetectorCapability(
            type: DetectorType.windowsCameraSceneMotion,
            status: CapabilityStatus.unsupported,
            permissionStatus: PermissionStatus.notApplicable,
            summary: 'Camera permission is not applicable on this host.',
          );
      }
    } on MissingPluginException {
      return const DetectorCapability(
        type: DetectorType.windowsCameraSceneMotion,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notDetermined,
        summary:
            'Native Windows camera bridge is not registered in this runner.',
        guidance:
            'Rebuild and run the Windows desktop target (`flutter run -d windows`) '
            'so the native Media Foundation bridge is active.',
      );
    } on PlatformException catch (error) {
      return DetectorCapability(
        type: DetectorType.windowsCameraSceneMotion,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notDetermined,
        summary:
            'Windows camera capability check failed: ${error.message ?? error.code}',
        statusDetail: error.code,
      );
    }
  }

  @override
  Future<PermissionStatus> requestPermission() async {
    if (!_isWindows) {
      return PermissionStatus.notApplicable;
    }
    try {
      final raw = await _methodChannel.invokeMethod<String>(
        'requestPermission',
      );
      return _parsePermissionStatus(raw ?? 'denied');
    } on MissingPluginException {
      return PermissionStatus.denied;
    } on PlatformException {
      return PermissionStatus.denied;
    }
  }

  @override
  Future<DetectorStartResult> startMonitoring(MonitorConfig config) async {
    if (!_isWindows) {
      return const DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: 'Windows camera monitoring is only available on Windows.',
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
          message: 'Native Windows camera bridge returned no start response.',
          errorCode: 'EMPTY_RESPONSE',
        );
      }
      final started = response['started'] as bool? ?? false;
      final message =
          response['message'] as String? ??
          (started
              ? 'Windows camera scene-motion monitoring started.'
              : 'Failed to start Windows camera monitoring.');
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
        message: 'Native Windows camera bridge is unavailable.',
        errorCode: 'MISSING_PLUGIN',
      );
    } on PlatformException catch (error) {
      return DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message:
            error.message ?? 'Native Windows camera capture failed to start.',
        errorCode: error.code,
      );
    }
  }

  @override
  Future<void> updateSensitivity(double sensitivity) async {
    if (!_isWindows) {
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
    if (!_isWindows) {
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
        map['summary'] as String? ?? 'Windows camera detector update';
    final motionScore = (map['motionScore'] as num?)?.toDouble();
    final threshold = (map['threshold'] as num?)?.toDouble();
    final averageLuminance = (map['averageLuminance'] as num?)?.toDouble();
    final consecutive = (map['consecutiveFrames'] as num?)?.toInt();
    final errorCode = map['errorCode'] as String?;
    final timestampMs = (map['timestampMs'] as num?)?.toInt();

    _eventsController.add(
      DetectorEvent(
        eventId: 'win_cam_${++_eventCounter}',
        sessionId: sessionId,
        detectorType: detectorType,
        eventType: eventType,
        timestamp: timestampMs != null
            ? DateTime.fromMillisecondsSinceEpoch(timestampMs)
            : DateTime.now(),
        summary: summary,
        motionScore: motionScore,
        threshold: threshold,
        averageLuminance: averageLuminance,
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
