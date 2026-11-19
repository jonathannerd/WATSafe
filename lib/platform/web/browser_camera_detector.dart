import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';
import '../../core/vision/camera_motion_analyzer.dart';

/// Samples downsampled grayscale webcam frames while the browser tab is visible
/// and evaluates coherent camera movement via [CameraMotionAnalyzer].
class BrowserCameraDetector implements MotionDetectorAdapter {
  final _events = StreamController<DetectorEvent>.broadcast();
  PermissionStatus _permission = PermissionStatus.notDetermined;
  CapabilityStatus _lastFailureStatus = CapabilityStatus.permissionRequired;
  String? _cameraError;
  String? _cameraErrorCode;
  MonitorConfig? _config;
  String? _pausedSessionId;
  web.MediaStream? _stream;
  web.HTMLVideoElement? _video;
  Timer? _frameTimer;
  Completer<DetectorStartResult>? _calibration;
  DateTime? _lastFrameAt;
  CameraMotionAnalyzer? _analyzer;
  int _eventNumber = 0;

  late final JSFunction _visibilityChanged = ((web.Event _) {
    if (web.document.hidden) {
      if (_config != null) {
        _pausedSessionId = _config!.sessionId;
        _stopWithEvent(
          DetectorEventType.lifecyclePaused,
          'The WATSafe browser tab was hidden; webcam capture paused.',
          keepVisibilityListener: true,
        );
      }
    } else if (_pausedSessionId != null) {
      final sessionId = _pausedSessionId!;
      _pausedSessionId = null;
      _events.add(
        DetectorEvent(
          eventId: 'web_camera_${++_eventNumber}',
          sessionId: sessionId,
          detectorType: detectorType,
          eventType: DetectorEventType.lifecycleResumed,
          timestamp: DateTime.now(),
          summary: 'The WATSafe browser tab became visible again.',
        ),
      );
    }
  }).toJS;

  @override
  DetectorType get detectorType => DetectorType.browserCameraSceneMotion;

  @override
  bool get supportsBackgroundMonitoring => false;

  @override
  Stream<DetectorEvent> get events => _events.stream;

  bool get _hasCameraApi =>
      web.window.isSecureContext && web.window.navigator.has('mediaDevices');

  @override
  Future<DetectorCapability> checkCapability() async {
    if (!_hasCameraApi) {
      return DetectorCapability(
        type: detectorType,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary: 'Camera access is unavailable on this page.',
        guidance:
            'Open WATSafe in Chrome or Edge at localhost or an HTTPS URL.',
      );
    }
    if (_cameraError != null && _permission != PermissionStatus.denied) {
      return DetectorCapability(
        type: detectorType,
        status: _lastFailureStatus,
        permissionStatus: _permission,
        summary: _cameraError!,
        statusDetail: _cameraErrorCode,
        guidance: _cameraError!,
      );
    }
    final ready = _permission == PermissionStatus.granted;
    return DetectorCapability(
      type: detectorType,
      status: ready
          ? CapabilityStatus.ready
          : CapabilityStatus.permissionRequired,
      permissionStatus: _permission,
      summary: ready ? 'Webcam ready' : 'Allow camera access to arm WATSafe.',
      statusDetail: _cameraError,
      guidance: _cameraError ?? 'Keep this tab visible and the device awake.',
    );
  }

  Future<web.MediaStream> _openCamera() => web.window.navigator.mediaDevices
      .getUserMedia(web.MediaStreamConstraints(video: true.toJS))
      .toDart;

  @override
  Future<PermissionStatus> requestPermission() async {
    if (!_hasCameraApi) {
      return PermissionStatus.restricted;
    }
    if (_config != null) {
      return _permission;
    }
    try {
      final stream = await _openCamera();
      _stopTracks(stream);
      _permission = PermissionStatus.granted;
      _cameraError = null;
      _cameraErrorCode = null;
    } catch (error) {
      _describeCameraError(error);
    }
    return _permission;
  }

  void _describeCameraError(Object error) {
    final details = error.toString();
    if (details.contains('NotAllowedError') ||
        details.contains('Permission denied') ||
        details.contains('SecurityError')) {
      _permission = PermissionStatus.denied;
      _lastFailureStatus = CapabilityStatus.permissionRequired;
      _cameraErrorCode = 'PERMISSION_DENIED';
      _cameraError = 'Camera permission denied. Allow camera access in browser site settings and retry.';
    } else if (details.contains('NotFoundError') ||
        details.contains('DevicesNotFoundError')) {
      _permission = PermissionStatus.notDetermined;
      _lastFailureStatus = CapabilityStatus.unsupported;
      _cameraErrorCode = 'NO_CAMERA_HARDWARE';
      _cameraError = 'No webcam found. Connect a webcam and retry.';
    } else if (details.contains('NotReadableError') ||
        details.contains('TrackStartError')) {
      _lastFailureStatus = CapabilityStatus.unsupported;
      _cameraErrorCode = 'CAMERA_BUSY';
      _cameraError = 'Webcam is busy or in use by another app/tab. Close other camera apps and retry.';
    } else {
      _lastFailureStatus = CapabilityStatus.unsupported;
      _cameraErrorCode = 'CAMERA_INIT_FAILED';
      _cameraError =
          'Could not initialize webcam. Check camera connection and retry.';
    }
  }

  @override
  Future<DetectorStartResult> startMonitoring(MonitorConfig config) async {
    if (!_hasCameraApi) {
      return const DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: 'Camera API is unavailable on this page (HTTPS/localhost required).',
        errorCode: 'INSECURE_CONTEXT',
      );
    }
    if (web.document.hidden) {
      return const DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: 'Open and focus the WATSafe browser tab before arming.',
        errorCode: 'TAB_HIDDEN',
      );
    }

    _releaseCapture();
    _pausedSessionId = null;
    _config = config;
    _analyzer = CameraMotionAnalyzer(
      gridWidth: config.downsampleWidth,
      gridHeight: config.downsampleHeight,
      calibrationDuration: config.calibrationDuration,
      persistenceFramesRequired: config.persistenceFramesRequired,
      motionThreshold: config.motionScoreThreshold,
    );
    web.document.addEventListener('visibilitychange', _visibilityChanged);

    try {
      final stream = await _openCamera();
      if (_config?.sessionId != config.sessionId) {
        _stopTracks(stream);
        return _notStarted('Monitoring was cancelled.', code: 'CANCELLED');
      }
      _stream = stream;
      _permission = PermissionStatus.granted;
      _cameraError = null;
      _cameraErrorCode = null;
      for (final track in stream.getVideoTracks().toDart) {
        track.onended = ((web.Event _) {
          if (_config?.sessionId == config.sessionId) {
            _stopWithEvent(
              DetectorEventType.detectorFailed,
              'Webcam access ended unexpectedly.',
            );
          }
        }).toJS;
      }

      final video = web.HTMLVideoElement()
        ..muted = true
        ..playsInline = true
        ..srcObject = stream;
      _video = video;
      await video.play().toDart.timeout(const Duration(seconds: 5));
      if (_config?.sessionId != config.sessionId) {
        return _notStarted('Monitoring was cancelled.', code: 'CANCELLED');
      }

      final canvas = web.HTMLCanvasElement()
        ..width = config.downsampleWidth
        ..height = config.downsampleHeight;
      final context = canvas.getContext(
        '2d',
        web.CanvasRenderingContext2DSettings(willReadFrequently: true),
      ) as web.CanvasRenderingContext2D?;
      if (context == null) {
        throw StateError('Canvas is unavailable.');
      }
      final calibration = Completer<DetectorStartResult>();
      _calibration = calibration;
      _lastFrameAt = DateTime.now();
      _emit(DetectorEventType.calibrationStarted, 'Calibrating the webcam.');
      _frameTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _sampleFrame(config, video, context),
      );
      return await calibration.future;
    } catch (error) {
      if (_config?.sessionId != config.sessionId) {
        return _notStarted('Monitoring was cancelled.', code: 'CANCELLED');
      }
      _describeCameraError(error);
      _releaseCapture();
      return _notStarted(_cameraError!, code: _cameraErrorCode);
    }
  }

  void _sampleFrame(
    MonitorConfig config,
    web.HTMLVideoElement video,
    web.CanvasRenderingContext2D context,
  ) {
    if (web.document.hidden) {
      _pausedSessionId = config.sessionId;
      _stopWithEvent(
        DetectorEventType.lifecyclePaused,
        'The WATSafe browser tab was hidden; webcam capture paused.',
        keepVisibilityListener: true,
      );
      return;
    }
    final now = DateTime.now();
    if (video.readyState < 2 ||
        video.videoWidth == 0 ||
        _stream!.getVideoTracks().toDart.any((track) => track.muted)) {
      if (now.difference(_lastFrameAt!) > const Duration(seconds: 4)) {
        _cameraError = 'Webcam stopped delivering frames.';
        _cameraErrorCode = 'FRAME_TIMEOUT';
        _stopWithEvent(
          DetectorEventType.detectorFailed,
          'Webcam stopped delivering frames.',
        );
      }
      return;
    }
    _lastFrameAt = now;
    try {
      final width = config.downsampleWidth;
      final height = config.downsampleHeight;
      context.drawImage(video, 0, 0, width, height);
      final rgba = context.getImageData(0, 0, width, height).data.toDart;
      final sampled = CameraFrameSampler.sampleToGrayscaleGrid(
        rawBytes: rgba,
        format: CameraPixelFormat.rgba32,
        srcWidth: width,
        srcHeight: height,
        reportedStride: width * 4,
        gridWidth: width,
        gridHeight: height,
      );
      if (sampled == null) {
        return;
      }
      _processSampledFrame(sampled, now);
    } catch (_) {
      _stopWithEvent(
        DetectorEventType.detectorFailed,
        'Could not read the webcam image.',
      );
    }
  }

  void _processSampledFrame(SampledGrayscaleFrame sampled, DateTime now) {
    final analyzer = _analyzer;
    final calibration = _calibration;
    if (analyzer == null || calibration == null) {
      return;
    }

    final eval = analyzer.processFrame(sampled.grid, timestamp: now);
    if (!calibration.isCompleted) {
      if (eval.calibrationJustCompleted) {
        _emit(
          DetectorEventType.calibrationCompleted,
          eval.isObstructedAtCalibration
              ? 'Camera appears covered or too dark. Uncover the webcam for visual motion detection — lid and connection alerts remain active.'
              : 'Webcam baseline calibrated. Coherent camera-motion monitoring active.',
          score: 0.0,
          luminance: eval.normalizedLuminance,
          consecutive: 0,
          obstructionKind: eval.obstructionKind,
        );
        if (eval.isObstructedAtCalibration) {
          _emit(
            DetectorEventType.poorInputWarning,
            'Camera appears covered or too dark. Uncover the webcam for visual motion detection — lid and connection alerts remain active.',
            luminance: eval.normalizedLuminance,
            obstructionKind: eval.obstructionKind,
          );
        }
        calibration.complete(
          DetectorStartResult(
            started: true,
            status: eval.isObstructedAtCalibration
                ? CapabilityStatus.degraded
                : CapabilityStatus.ready,
            message: eval.isObstructedAtCalibration
                ? 'Camera appears covered or too dark. Uncover the webcam for visual motion detection.'
                : 'Webcam is actively delivering frames and monitoring.',
          ),
        );
      }
      return;
    }

    if (eval.obstructionJustTriggered) {
      _emit(
        DetectorEventType.cameraObstructed,
        'Camera blocked — webcam view obstructed while armed.',
        score: eval.motionScore,
        luminance: eval.normalizedLuminance,
        consecutive: eval.consecutiveObstructedFrames,
        obstructionKind: eval.obstructionKind,
      );
      return;
    }

    if (eval.poorInputJustChanged) {
      _emit(
        eval.isPoorInput
            ? DetectorEventType.poorInputWarning
            : DetectorEventType.inputRecovered,
        eval.isPoorInput
            ? (eval.isObstructedAtCalibration
                  ? 'Camera appears covered or too dark. Uncover the webcam for visual motion detection — lid and connection alerts remain active.'
                  : 'Low light or covered webcam lens detected.')
            : 'Webcam lighting and scene contrast restored.',
        luminance: eval.normalizedLuminance,
        obstructionKind: eval.obstructionKind,
      );
    }

    _emit(
      eval.triggered
          ? DetectorEventType.motionTriggered
          : DetectorEventType.telemetryFrame,
      eval.triggered
          ? 'Coherent camera movement detected in webcam view'
          : 'Monitoring webcam for laptop movement',
      score: eval.motionScore,
      luminance: eval.normalizedLuminance,
      consecutive: eval.consecutiveAboveThreshold,
      coherentBlocks: eval.coherentTranslatedBlocks,
      anchoredBlocks: eval.anchoredTexturedBlocks,
      slowDriftScore: eval.slowDriftScore,
      loomingRejected: eval.loomingRejected,
      obstructionKind: eval.obstructionKind,
    );
  }

  void _emit(
    DetectorEventType type,
    String summary, {
    double? score,
    double? luminance,
    int? consecutive,
    int? coherentBlocks,
    int? anchoredBlocks,
    double? slowDriftScore,
    bool? loomingRejected,
    String? obstructionKind,
  }) {
    final config = _config;
    if (config == null) {
      return;
    }
    _events.add(
      DetectorEvent(
        eventId: 'web_camera_${++_eventNumber}',
        sessionId: config.sessionId,
        detectorType: detectorType,
        eventType: type,
        timestamp: DateTime.now(),
        summary: summary,
        motionScore: score,
        threshold: _analyzer?.motionThreshold ?? config.motionScoreThreshold,
        averageLuminance: luminance,
        consecutiveAboveThresholdFrames: consecutive,
        coherentBlocks: coherentBlocks,
        anchoredBlocks: anchoredBlocks,
        slowDriftScore: slowDriftScore,
        loomingRejected: loomingRejected,
        obstructionKind: obstructionKind,
      ),
    );
  }

  void _stopWithEvent(
    DetectorEventType type,
    String message, {
    bool keepVisibilityListener = false,
  }) {
    _emit(type, message);
    _releaseCapture(message, keepVisibilityListener);
  }

  DetectorStartResult _notStarted(String message, {String? code}) =>
      DetectorStartResult(
        started: false,
        status: _permission == PermissionStatus.denied
            ? CapabilityStatus.permissionRequired
            : CapabilityStatus.unsupported,
        message: message,
        errorCode: code,
      );

  @override
  Future<void> updateSensitivity(double sensitivity) async {
    final config = _config;
    if (config != null) {
      final newThreshold = MonitorConfig(
        sessionId: config.sessionId,
        sensitivity: sensitivity,
      ).motionScoreThreshold;
      _analyzer?.updateThreshold(newThreshold);
    }
  }

  @override
  Future<void> stopMonitoring({String? sessionId}) async {
    if (sessionId == null ||
        sessionId == _config?.sessionId ||
        sessionId == _pausedSessionId) {
      _pausedSessionId = null;
      _releaseCapture();
    }
  }

  void _releaseCapture([
    String reason = 'Monitoring was cancelled.',
    bool keepVisibilityListener = false,
  ]) {
    _config = null;
    _frameTimer?.cancel();
    _frameTimer = null;
    if (!keepVisibilityListener) {
      web.document.removeEventListener('visibilitychange', _visibilityChanged);
    }
    _video?.pause();
    _video?.srcObject = null;
    _video = null;
    final stream = _stream;
    _stream = null;
    if (stream != null) {
      _stopTracks(stream);
    }
    final calibration = _calibration;
    _calibration = null;
    if (calibration != null && !calibration.isCompleted) {
      calibration.complete(_notStarted(reason, code: _cameraErrorCode));
    }
    _lastFrameAt = null;
    _analyzer?.reset();
    _analyzer = null;
  }

  void _stopTracks(web.MediaStream stream) {
    for (final track in stream.getTracks().toDart) {
      track.onended = null;
      track.stop();
    }
  }

  @override
  Future<void> dispose() async {
    _pausedSessionId = null;
    _releaseCapture();
    await _events.close();
  }
}
