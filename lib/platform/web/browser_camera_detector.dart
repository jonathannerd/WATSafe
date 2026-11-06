import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';

/// Samples a small grayscale webcam image while the browser tab is visible.
class BrowserCameraDetector implements MotionDetectorAdapter {
  final _events = StreamController<DetectorEvent>.broadcast();
  PermissionStatus _permission = PermissionStatus.notDetermined;
  String? _cameraError;
  MonitorConfig? _config;
  web.MediaStream? _stream;
  web.HTMLVideoElement? _video;
  Timer? _frameTimer;
  Completer<DetectorStartResult>? _calibration;
  DateTime? _calibrationStartedAt;
  DateTime? _lastFrameAt;
  Float32List? _reference;
  double _threshold = 0;
  int _aboveThreshold = 0;
  int _darkFrames = 0;
  int _eventNumber = 0;

  late final JSFunction _visibilityChanged = ((web.Event _) {
    if (web.document.hidden) {
      _stopWithEvent(
        DetectorEventType.lifecyclePaused,
        'The WATSafe tab was hidden. Return to it and disarm before restarting.',
      );
    }
  }).toJS;

  @override
  DetectorType get detectorType => DetectorType.browserCameraSceneMotion;

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
    } catch (error) {
      _describeCameraError(error);
    }
    return _permission;
  }

  void _describeCameraError(Object error) {
    final details = error.toString();
    if (details.contains('NotAllowedError') ||
        details.contains('Permission denied')) {
      _permission = PermissionStatus.denied;
      _cameraError =
          'Allow camera access in this site’s browser settings and retry.';
    } else if (details.contains('NotFoundError')) {
      _permission = PermissionStatus.notDetermined;
      _cameraError = 'Connect a webcam and try granting access again.';
    } else {
      _permission = PermissionStatus.notDetermined;
      _cameraError =
          'Check that a webcam is connected and available to this browser.';
    }
  }

  @override
  Future<DetectorStartResult> startMonitoring(MonitorConfig config) async {
    if (!_hasCameraApi || web.document.hidden) {
      return _notStarted('Open the WATSafe tab before arming.');
    }

    _releaseCapture();
    _config = config;
    _threshold = config.motionScoreThreshold;
    web.document.addEventListener('visibilitychange', _visibilityChanged);

    try {
      final stream = await _openCamera();
      if (_config?.sessionId != config.sessionId) {
        _stopTracks(stream);
        return _notStarted('Monitoring was cancelled.');
      }
      _stream = stream;
      _permission = PermissionStatus.granted;
      _cameraError = null;
      for (final track in stream.getVideoTracks().toDart) {
        track.onended = ((web.Event _) {
          if (_config?.sessionId == config.sessionId) {
            _stopWithEvent(
              DetectorEventType.detectorFailed,
              'Webcam access ended.',
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
        return _notStarted('Monitoring was cancelled.');
      }

      final canvas = web.HTMLCanvasElement()
        ..width = config.downsampleWidth
        ..height = config.downsampleHeight;
      final context =
          canvas.getContext(
                '2d',
                web.CanvasRenderingContext2DSettings(willReadFrequently: true),
              )
              as web.CanvasRenderingContext2D?;
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
        return _notStarted('Monitoring was cancelled.');
      }
      _describeCameraError(error);
      _releaseCapture();
      return _notStarted(_cameraError!);
    }
  }

  void _sampleFrame(
    MonitorConfig config,
    web.HTMLVideoElement video,
    web.CanvasRenderingContext2D context,
  ) {
    if (web.document.hidden) {
      _stopWithEvent(
        DetectorEventType.lifecyclePaused,
        'The WATSafe tab was hidden.',
      );
      return;
    }
    final now = DateTime.now();
    if (video.readyState < 2 ||
        _stream!.getVideoTracks().toDart.any((track) => track.muted)) {
      if (now.difference(_lastFrameAt!) > const Duration(seconds: 4)) {
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
      final luminance = Uint8List(width * height);
      var total = 0;
      for (var i = 0; i < luminance.length; i++) {
        final pixel = i * 4;
        final gray =
            (77 * rgba[pixel] + 150 * rgba[pixel + 1] + 29 * rgba[pixel + 2]) >>
            8;
        luminance[i] = gray;
        total += gray;
      }
      final mean = total / (255 * luminance.length);
      if (mean < 0.04) {
        _aboveThreshold = 0;
        if (++_darkFrames >= 10) {
          _stopWithEvent(
            DetectorEventType.detectorFailed,
            'Webcam image is too dark. Add light and arm again.',
          );
        }
        return;
      }
      _darkFrames = 0;
      _processFrame(config, luminance, mean, now);
    } catch (_) {
      _stopWithEvent(
        DetectorEventType.detectorFailed,
        'Could not read the webcam image.',
      );
    }
  }

  void _processFrame(
    MonitorConfig config,
    Uint8List luminance,
    double mean,
    DateTime now,
  ) {
    final reference = _reference ??= Float32List.fromList(
      luminance.map((pixel) => pixel.toDouble()).toList(),
    );
    final calibration = _calibration!;
    if (!calibration.isCompleted) {
      final started = _calibrationStartedAt ??= now;
      _adaptReference(reference, luminance);
      if (now.difference(started) >= config.calibrationDuration) {
        _emit(
          DetectorEventType.calibrationCompleted,
          'Webcam calibration finished.',
        );
        calibration.complete(
          const DetectorStartResult(
            started: true,
            status: CapabilityStatus.ready,
            message: 'Webcam is monitoring.',
          ),
        );
      }
      return;
    }

    var difference = 0.0;
    for (var i = 0; i < reference.length; i++) {
      difference += (luminance[i] - reference[i]).abs();
    }
    final score = difference / (255 * reference.length);
    if (score >= _threshold) {
      _aboveThreshold++;
    } else {
      _aboveThreshold = 0;
      _adaptReference(reference, luminance);
    }
    final triggered = _aboveThreshold == config.persistenceFramesRequired;
    _emit(
      triggered
          ? DetectorEventType.motionTriggered
          : DetectorEventType.telemetryFrame,
      triggered
          ? 'Movement in the webcam view'
          : 'Watching for changes in the webcam view',
      score: score,
      luminance: mean,
    );
  }

  void _adaptReference(Float32List reference, Uint8List luminance) {
    for (var i = 0; i < reference.length; i++) {
      reference[i] += 0.08 * (luminance[i] - reference[i]);
    }
  }

  void _emit(
    DetectorEventType type,
    String summary, {
    double? score,
    double? luminance,
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
        threshold: _threshold,
        averageLuminance: luminance,
        consecutiveAboveThresholdFrames: _aboveThreshold,
      ),
    );
  }

  void _stopWithEvent(DetectorEventType type, String message) {
    _emit(type, message);
    _releaseCapture(message);
  }

  DetectorStartResult _notStarted(String message) => DetectorStartResult(
    started: false,
    status: _permission == PermissionStatus.granted
        ? CapabilityStatus.unsupported
        : CapabilityStatus.permissionRequired,
    message: message,
  );

  @override
  Future<void> updateSensitivity(double sensitivity) async {
    final config = _config;
    if (config != null) {
      _threshold = MonitorConfig(
        sessionId: config.sessionId,
        sensitivity: sensitivity,
      ).motionScoreThreshold;
      _aboveThreshold = 0;
    }
  }

  @override
  Future<void> stopMonitoring({String? sessionId}) async {
    if (sessionId == null || sessionId == _config?.sessionId) {
      _releaseCapture();
    }
  }

  void _releaseCapture([String reason = 'Monitoring was cancelled.']) {
    _config = null;
    _frameTimer?.cancel();
    _frameTimer = null;
    web.document.removeEventListener('visibilitychange', _visibilityChanged);
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
      calibration.complete(_notStarted(reason));
    }
    _calibrationStartedAt = null;
    _lastFrameAt = null;
    _reference = null;
    _aboveThreshold = 0;
    _darkFrames = 0;
  }

  void _stopTracks(web.MediaStream stream) {
    for (final track in stream.getTracks().toDart) {
      track.onended = null;
      track.stop();
    }
  }

  @override
  Future<void> dispose() async {
    _releaseCapture();
    await _events.close();
  }
}
