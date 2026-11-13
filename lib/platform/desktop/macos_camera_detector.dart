import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';

/// Real macOS webcam scene-motion detector backed by native Swift/AVFoundation
/// (`dev.watsafe/macos_camera` and `dev.watsafe/macos_camera_events`).
///
/// Algorithm notes:
/// - Captures video frames via `AVCaptureSession` on a background dispatch queue.
/// - Downsamples each frame to a compact grayscale grid (default 64x48) off the UI thread.
/// - Computes normalized mean absolute pixel luminance delta (`motionScore` in `0.0..1.0`)
///   against an exponentially updated background reference frame.
/// - Enforces a startup calibration interval and consecutive-frame persistence filter
///   before emitting `DetectorEventType.motionTriggered`.
/// - Reports low-light or covered-lens conditions as `DetectorEventType.poorInputWarning`.
/// - Never retains or uploads images or video frames.
class MacOSCameraSceneMotionDetector implements MotionDetectorAdapter {
  MacOSCameraSceneMotionDetector({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool? isMacOSOverride,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel('dev.watsafe/macos_camera'),
       _eventChannel =
           eventChannel ??
           const EventChannel('dev.watsafe/macos_camera_events'),
       _isMacOS = isMacOSOverride ?? (!kIsWeb && Platform.isMacOS) {
    if (_isMacOS) {
      _ensureEventSubscription();
    }
  }

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final bool _isMacOS;

  final StreamController<DetectorEvent> _eventsController =
      StreamController<DetectorEvent>.broadcast();
  StreamSubscription<dynamic>? _nativeEventSub;
  int _eventCounter = 0;

  @override
  DetectorType get detectorType => DetectorType.macosCameraSceneMotion;

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
              eventId: 'macos_cam_err_${++_eventCounter}',
              sessionId: 'unknown',
              detectorType: detectorType,
              eventType: DetectorEventType.detectorFailed,
              timestamp: DateTime.now(),
              summary: 'macOS camera event stream error: $error',
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
    if (!_isMacOS) {
      return const DetectorCapability(
        type: DetectorType.macosCameraSceneMotion,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary: 'macOS Webcam Scene-Motion is only supported on macOS.',
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
          type: DetectorType.macosCameraSceneMotion,
          status: CapabilityStatus.unsupported,
          permissionStatus: PermissionStatus.notDetermined,
          summary: 'macOS camera bridge returned an empty capability response.',
        );
      }

      final hasHardware = response['hasCameraHardware'] as bool? ?? false;
      final deviceName = response['deviceName'] as String?;
      final permRaw =
          response['permissionStatus'] as String? ?? 'notDetermined';
      final permissionStatus = _parsePermissionStatus(permRaw);

      if (!hasHardware) {
        return DetectorCapability(
          type: DetectorType.macosCameraSceneMotion,
          status: CapabilityStatus.unsupported,
          permissionStatus: permissionStatus,
          summary: 'No camera hardware detected on this Mac.',
          statusDetail:
              response['detail'] as String? ??
              'AVCaptureDevice.DiscoverySession returned 0 video devices.',
          guidance:
              'Connect a UVC-compatible webcam or use the manual Test Alarm to verify local siren operation.',
        );
      }

      switch (permissionStatus) {
        case PermissionStatus.granted:
          return DetectorCapability(
            type: DetectorType.macosCameraSceneMotion,
            status: CapabilityStatus.ready,
            permissionStatus: PermissionStatus.granted,
            hardwareDeviceName: deviceName ?? 'Built-in macOS Camera',
            summary:
                'Ready — ${deviceName ?? "macOS Camera"} available with camera permission granted.',
            statusDetail:
                'Local 64x48 grayscale scene-motion pipeline ready (no frames saved or uploaded).',
          );

        case PermissionStatus.notDetermined:
          return DetectorCapability(
            type: DetectorType.macosCameraSceneMotion,
            status: CapabilityStatus.permissionRequired,
            permissionStatus: PermissionStatus.notDetermined,
            hardwareDeviceName: deviceName ?? 'Built-in macOS Camera',
            summary:
                'Camera permission required to enable macOS scene-motion monitoring.',
            statusDetail: 'Hardware detected: ${deviceName ?? "macOS Camera"}.',
            guidance:
                'Click "Grant Camera Permission" below to prompt macOS for local camera access.',
          );

        case PermissionStatus.denied:
          return DetectorCapability(
            type: DetectorType.macosCameraSceneMotion,
            status: CapabilityStatus.permissionRequired,
            permissionStatus: PermissionStatus.denied,
            hardwareDeviceName: deviceName ?? 'Built-in macOS Camera',
            summary: 'Camera access was denied for WATSafe.',
            statusDetail:
                'macOS blocked AVCaptureDevice access for this application.',
            guidance:
                'Open macOS System Settings → Privacy & Security → Camera, enable WATSafe, then click Refresh Status.',
          );

        case PermissionStatus.restricted:
          return DetectorCapability(
            type: DetectorType.macosCameraSceneMotion,
            status: CapabilityStatus.permissionRequired,
            permissionStatus: PermissionStatus.restricted,
            hardwareDeviceName: deviceName,
            summary:
                'Camera access is restricted by a macOS Screen Time or MDM profile.',
            guidance:
                'Check macOS System Settings → Screen Time → Content & Privacy Restrictions.',
          );

        case PermissionStatus.notApplicable:
          return const DetectorCapability(
            type: DetectorType.macosCameraSceneMotion,
            status: CapabilityStatus.unsupported,
            permissionStatus: PermissionStatus.notApplicable,
            summary: 'Camera permission is not applicable on this host.',
          );
      }
    } on MissingPluginException {
      return const DetectorCapability(
        type: DetectorType.macosCameraSceneMotion,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notDetermined,
        summary: 'Native macOS camera bridge is not registered in this runner.',
        guidance:
            'Run the full macOS desktop build (`flutter run -d macos`) so the native AVFoundation bridge is active.',
      );
    } on PlatformException catch (error) {
      return DetectorCapability(
        type: DetectorType.macosCameraSceneMotion,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notDetermined,
        summary:
            'macOS camera capability check failed: ${error.message ?? error.code}',
        statusDetail: error.code,
      );
    }
  }

  @override
  Future<PermissionStatus> requestPermission() async {
    if (!_isMacOS) {
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
    if (!_isMacOS) {
      return const DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: 'macOS camera monitoring is only available on macOS.',
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
          message: 'Native camera bridge returned no start response.',
          errorCode: 'EMPTY_RESPONSE',
        );
      }
      final started = response['started'] as bool? ?? false;
      final message =
          response['message'] as String? ??
          (started
              ? 'macOS camera scene-motion monitoring started.'
              : 'Failed to start macOS camera monitoring.');
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
        message: 'Native macOS camera bridge is unavailable.',
        errorCode: 'MISSING_PLUGIN',
      );
    } on PlatformException catch (error) {
      return DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: error.message ?? 'Native camera capture failed to start.',
        errorCode: error.code,
      );
    }
  }

  @override
  Future<void> updateSensitivity(double sensitivity) async {
    if (!_isMacOS) {
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
    if (!_isMacOS) {
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
    final summary = map['summary'] as String? ?? 'macOS camera detector update';
    final motionScore = (map['motionScore'] as num?)?.toDouble();
    final threshold = (map['threshold'] as num?)?.toDouble();
    final averageLuminance = (map['averageLuminance'] as num?)?.toDouble();
    final consecutive = (map['consecutiveFrames'] as num?)?.toInt();
    final errorCode = map['errorCode'] as String?;
    final timestampMs = (map['timestampMs'] as num?)?.toInt();

    _eventsController.add(
      DetectorEvent(
        eventId: 'macos_cam_${++_eventCounter}',
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

  @override
  Future<void> dispose() async {
    await _nativeEventSub?.cancel();
    _nativeEventSub = null;
    await _eventsController.close();
  }
}
