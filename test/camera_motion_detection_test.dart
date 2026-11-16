import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/core/vision/camera_motion_analyzer.dart';
import 'package:watsafe/platform/desktop/macos_camera_detector.dart';
import 'package:watsafe/platform/desktop/windows_detectors.dart';
import 'package:watsafe/platform/mobile/android_motion_detector.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

import 'alarm_controller_test.dart';

/// Synthesizes a structured indoor study/library background with bookshelves,
/// monitor bezel edges, and wall texture at continuous sub-pixel coordinates.
Float32List renderSyntheticRoomScene({
  int width = 64,
  int height = 48,
  double panX = 0.0,
  double panY = 0.0,
  double rollRadians = 0.0,
  double illuminationOffset = 0.0,
  double contrastScale = 1.0,
  bool minimalistWalls = false,
}) {
  final grid = Float32List(width * height);
  final cx = (width - 1) / 2.0;
  final cy = (height - 1) / 2.0;
  final cosR = math.cos(rollRadians);
  final sinR = math.sin(rollRadians);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final dx = x - cx;
      final dy = y - cy;
      final wx = (dx * cosR - dy * sinR) + cx + panX;
      final wy = (dx * sinR + dy * cosR) + cy + panY;

      double base;
      if (minimalistWalls) {
        // Mostly smooth wall with a textured doorframe/poster only in top-left.
        base = 138.0 + (wy * 0.25);
        if (wx < 26.0 && wy < 22.0) {
          base +=
              26.0 * math.sin(wx * 0.65) +
              22.0 * math.cos(wy * 0.72) +
              14.0 * math.sin((wx + wy) * 0.45);
        }
      } else {
        // Multi-quadrant room texture: shelves, vertical dividers, desk edge.
        final shelf = 24.0 * math.sin(wy * 0.55);
        final books = 22.0 * math.sin(wx * 0.78 + 0.4 * math.cos(wy * 0.35));
        final framing = 16.0 * math.cos((wx - wy) * 0.42);
        base = 122.0 + shelf + books + framing;
      }

      final adjusted =
          ((base - 128.0) * contrastScale) + 128.0 + illuminationOffset;
      grid[y * width + x] = adjusted.clamp(0.0, 255.0);
    }
  }
  return grid;
}

/// Overlays a moving person (head + torso silhouette with clothing texture)
/// passing in front of a stationary webcam at horizontal center [personCenterX].
Float32List overlayPassingPerson(
  Float32List background, {
  int width = 64,
  int height = 48,
  required double personCenterX,
  double halfWidth = 11.5,
}) {
  final out = Float32List.fromList(background);
  for (var y = 6; y < height; y++) {
    final isHead = y < 18;
    final rowHalfWidth = isHead ? halfWidth * 0.58 : halfWidth;
    for (var x = 0; x < width; x++) {
      if ((x - personCenterX).abs() <= rowHalfWidth) {
        final jacketShade =
            42.0 + 9.0 * math.sin((x - personCenterX) * 0.5 + y * 0.2);
        out[y * width + x] = jacketShade.clamp(0.0, 255.0);
      }
    }
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Windows Media Foundation Frame Format & Row Stride Sampling (#8)', () {
    test('NV12 contiguous buffer with padded MF_MT_DEFAULT_STRIDE=768 resolves to 640 and avoids UV chroma skew', () {
      const srcW = 640;
      const srcH = 480;
      final nv12Bytes = Uint8List(
        CameraFrameSampler.contiguousFrameByteLength(
          CameraPixelFormat.nv12,
          srcW,
          srcH,
        ),
      );
      // Fill Y plane with clean gradient 40..160, and fill UV plane with 255
      // so any stride overshoot into UV is immediately caught.
      for (var y = 0; y < srcH; y++) {
        final luma = 40 + ((y * 120) ~/ srcH);
        nv12Bytes.fillRange(y * srcW, (y + 1) * srcW, luma);
      }
      nv12Bytes.fillRange(srcW * srcH, nv12Bytes.length, 255);

      final sampled = CameraFrameSampler.sampleToGrayscaleGrid(
        rawBytes: nv12Bytes,
        format: CameraPixelFormat.nv12,
        srcWidth: srcW,
        srcHeight: srcH,
        reportedStride: 768,
        isContiguousBuffer: true,
      );

      expect(sampled, isNotNull);
      expect(sampled!.effectiveRowStride, 640);
      // Top row should be ~40 and bottom row should be ~158 (never 255 from UV!).
      expect(sampled.grid.first, closeTo(40.0, 2.0));
      expect(sampled.grid.last, closeTo(157.0, 4.0));
    });

    test(
      'NV12 GPU-padded 2D buffer (pitch 768) preserves padded row alignment',
      () {
        const srcW = 640;
        const srcH = 480;
        const pitch = 768;
        final paddedBytes = Uint8List(pitch * (srcH + (srcH ~/ 2)));
        // Put 250 in the 128-byte row padding region so wrong stride is caught.
        paddedBytes.fillRange(0, paddedBytes.length, 250);
        for (var y = 0; y < srcH; y++) {
          final rowStart = y * pitch;
          paddedBytes.fillRange(rowStart, rowStart + srcW, 85);
        }

        final sampled = CameraFrameSampler.sampleToGrayscaleGrid(
          rawBytes: paddedBytes,
          format: CameraPixelFormat.nv12,
          srcWidth: srcW,
          srcHeight: srcH,
          reportedStride: pitch,
          isContiguousBuffer: false,
        );

        expect(sampled, isNotNull);
        expect(sampled!.effectiveRowStride, pitch);
        expect(sampled.meanLuminance255, closeTo(85.0, 0.5));
      },
    );

    test('YUY2 and UYVY contiguous buffers with padded MF_MT_DEFAULT_STRIDE=1408 are accepted instead of dropped', () {
      const srcW = 640;
      const srcH = 480;
      final yuy2Bytes = Uint8List(srcW * srcH * 2);
      final uyvyBytes = Uint8List(srcW * srcH * 2);
      for (var i = 0; i < srcW * srcH; i++) {
        yuy2Bytes[i * 2] = 112; // Y
        yuy2Bytes[i * 2 + 1] = 200; // U/V
        uyvyBytes[i * 2] = 200; // U/V
        uyvyBytes[i * 2 + 1] = 134; // Y
      }

      final sampledYuy2 = CameraFrameSampler.sampleToGrayscaleGrid(
        rawBytes: yuy2Bytes,
        format: CameraPixelFormat.yuy2,
        srcWidth: srcW,
        srcHeight: srcH,
        reportedStride: 1408, // Padded GPU stride > 1280!
      );
      final sampledUyvy = CameraFrameSampler.sampleToGrayscaleGrid(
        rawBytes: uyvyBytes,
        format: CameraPixelFormat.uyvy,
        srcWidth: srcW,
        srcHeight: srcH,
        reportedStride: 1408,
      );

      expect(sampledYuy2, isNotNull);
      expect(sampledYuy2!.effectiveRowStride, 1280);
      expect(sampledYuy2.meanLuminance255, closeTo(112.0, 0.1));

      expect(sampledUyvy, isNotNull);
      expect(sampledUyvy!.effectiveRowStride, 1280);
      expect(sampledUyvy.meanLuminance255, closeTo(134.0, 0.1));
    });

    test('Negative bottom-up RGB32 and RGB24 DIB strides orient top and bottom rows accurately', () {
      const srcW = 64;
      const srcH = 48;
      final rgb32 = Uint8List(srcW * srcH * 4);
      final rgb24 = Uint8List(srcW * srcH * 3);

      // In a bottom-up DIB, row 0 in memory is the visual bottom row (dark=30)
      // and row srcH-1 in memory is the visual top row (bright=210).
      for (var memRow = 0; memRow < srcH; memRow++) {
        final val = memRow < (srcH ~/ 2) ? 30 : 210;
        for (var x = 0; x < srcW; x++) {
          final p32 = (memRow * srcW + x) * 4;
          rgb32[p32] = val;
          rgb32[p32 + 1] = val;
          rgb32[p32 + 2] = val;
          rgb32[p32 + 3] = 255;

          final p24 = (memRow * srcW + x) * 3;
          rgb24[p24] = val;
          rgb24[p24 + 1] = val;
          rgb24[p24 + 2] = val;
        }
      }

      final sampled32 = CameraFrameSampler.sampleToGrayscaleGrid(
        rawBytes: rgb32,
        format: CameraPixelFormat.bgra32,
        srcWidth: srcW,
        srcHeight: srcH,
        reportedStride: -(srcW * 4),
      );
      final sampled24 = CameraFrameSampler.sampleToGrayscaleGrid(
        rawBytes: rgb24,
        format: CameraPixelFormat.bgr24,
        srcWidth: srcW,
        srcHeight: srcH,
        reportedStride: -(srcW * 3),
      );

      expect(sampled32, isNotNull);
      expect(sampled32!.grid.first, closeTo(210.0, 2.0));
      expect(sampled32.grid.last, closeTo(30.0, 2.0));

      expect(sampled24, isNotNull);
      expect(sampled24!.grid.first, closeTo(210.0, 2.0));
      expect(sampled24.grid.last, closeTo(30.0, 2.0));
    });
  });

  group('Camera Ego-Motion vs. Passersby & Lighting Regression (#2)', () {
    CameraMotionAnalyzer buildCalibratedAnalyzer({
      required Float32List baselineScene,
      required DateTime startTime,
    }) {
      final analyzer = CameraMotionAnalyzer(
        calibrationDuration: const Duration(milliseconds: 1200),
        persistenceFramesRequired: 3,
        motionThreshold: 0.095,
      );
      for (var i = 0; i < 6; i++) {
        analyzer.processFrame(
          baselineScene,
          timestamp: startTime.add(Duration(milliseconds: i * 300)),
        );
      }
      expect(analyzer.isCalibrationDone, isTrue);
      return analyzer;
    }

    test('Stationary laptop does NOT trigger false alarm when a person walks across the webcam view', () {
      final t0 = DateTime.utc(2026, 11, 13, 12);
      final background = renderSyntheticRoomScene();
      final analyzer = buildCalibratedAnalyzer(
        baselineScene: background,
        startTime: t0,
      );

      // Simulate a person walking continuously from left (x=8) to right (x=56)
      // across 13 frames while background shelves/walls remain anchored.
      var time = t0.add(const Duration(seconds: 2));
      for (var step = 0; step < 13; step++) {
        time = time.add(const Duration(milliseconds: 125));
        final frame = overlayPassingPerson(
          background,
          personCenterX: 8.0 + (step * 4.0),
          halfWidth: 11.5,
        );
        final eval = analyzer.processFrame(frame, timestamp: time);
        expect(
          eval.anchoredTexturedBlocks,
          greaterThanOrEqualTo(4),
          reason:
              'Unoccluded background blocks should remain anchored on step $step',
        );
        expect(
          eval.triggered,
          isFalse,
          reason:
              'Passing person in front of stationary laptop must not trigger alarm (step $step, score=${eval.motionScore})',
        );
      }
    });

    test('Brief lighting switch and gradual ambient brightness drift do NOT trigger false alarm', () {
      final t0 = DateTime.utc(2026, 11, 13, 12);
      final background = renderSyntheticRoomScene();
      final analyzer = buildCalibratedAnalyzer(
        baselineScene: background,
        startTime: t0,
      );

      var time = t0.add(const Duration(seconds: 2));
      // Abrupt overhead room light switch (+38 brightness, 1.15x contrast).
      final brightFlash = renderSyntheticRoomScene(
        illuminationOffset: 38.0,
        contrastScale: 1.15,
      );
      for (var i = 0; i < 5; i++) {
        time = time.add(const Duration(milliseconds: 125));
        final eval = analyzer.processFrame(brightFlash, timestamp: time);
        expect(eval.triggered, isFalse);
      }

      // Gradual sunlight drift.
      for (var i = 1; i <= 8; i++) {
        time = time.add(const Duration(milliseconds: 125));
        final drifted = renderSyntheticRoomScene(
          illuminationOffset: 38.0 - (i * 4.0),
        );
        final eval = analyzer.processFrame(drifted, timestamp: time);
        expect(eval.triggered, isFalse);
      }
    });

    test('Picking up or panning the laptop produces coherent multi-quadrant optical flow and DOES trigger alarm', () {
      final t0 = DateTime.utc(2026, 11, 13, 12);
      final background = renderSyntheticRoomScene();
      final analyzer = buildCalibratedAnalyzer(
        baselineScene: background,
        startTime: t0,
      );

      var time = t0.add(const Duration(seconds: 2));
      var triggeredAny = false;
      for (var step = 1; step <= 5; step++) {
        time = time.add(const Duration(milliseconds: 125));
        final movedFrame = renderSyntheticRoomScene(
          panX: step * 1.8,
          panY: step * 0.9,
        );
        final eval = analyzer.processFrame(movedFrame, timestamp: time);
        if (eval.triggered) {
          triggeredAny = true;
          expect(eval.activeQuadrants, greaterThanOrEqualTo(3));
          expect(eval.coherentTranslatedBlocks, greaterThanOrEqualTo(5));
          break;
        }
      }
      expect(
        triggeredAny,
        isTrue,
        reason: 'Sustained laptop pickup/panning must trigger alarm',
      );
    });

    test('Rotating the laptop (including in a minimalist plain-wall room) triggers alarm', () {
      final t0 = DateTime.utc(2026, 11, 13, 12);
      final minimalistBase = renderSyntheticRoomScene(minimalistWalls: true);
      final analyzer = buildCalibratedAnalyzer(
        baselineScene: minimalistBase,
        startTime: t0,
      );

      var time = t0.add(const Duration(seconds: 2));
      var triggeredAny = false;
      for (var step = 1; step <= 6; step++) {
        time = time.add(const Duration(milliseconds: 125));
        final rotated = renderSyntheticRoomScene(
          minimalistWalls: true,
          rollRadians: step * 0.085,
          panX: step * 1.6,
        );
        final eval = analyzer.processFrame(rotated, timestamp: time);
        if (eval.triggered) {
          triggeredAny = true;
          break;
        }
      }
      expect(
        triggeredAny,
        isTrue,
        reason: 'Rotating/lifting laptop in a minimalist room must still trigger alarm',
      );
    });
  });

  group(
    'Camera Initialization Failures, Retry & Auxiliary Sensors (#6, #9)',
    () {
      const macMethod = MethodChannel('dev.watsafe/test_mac_cam_init');
      const macEvents = EventChannel('dev.watsafe/test_mac_cam_init_events');

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(macMethod, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(macEvents, null);
      });

      test('Handles PERMISSION_DENIED, NO_CAMERA_HARDWARE, CAMERA_BUSY, and FRAME_TIMEOUT without entering armed, cleans up, and recovers on retry', () async {
        final failureModes = <Map<String, Object?>>[
          <String, Object?>{
            'started': false,
            'errorCode': 'PERMISSION_DENIED',
            'message': 'Camera permission denied by OS.',
          },
          <String, Object?>{
            'started': false,
            'errorCode': 'NO_CAMERA_HARDWARE',
            'message': 'No webcam hardware detected.',
          },
          <String, Object?>{
            'started': false,
            'errorCode': 'CAMERA_BUSY',
            'message': 'Built-in Camera is in use by another application.',
          },
          <String, Object?>{
            'started': false,
            'errorCode': 'FRAME_TIMEOUT',
            'message': 'Camera opened, but no video frames arrived within 4s.',
          },
        ];

        var attemptIndex = 0;
        var stopCalls = 0;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(macMethod, (MethodCall call) async {
              switch (call.method) {
                case 'checkCapability':
                  return <String, Object?>{
                    'hasCameraHardware': true,
                    'deviceName': 'FaceTime HD Camera',
                    'permissionStatus': 'granted',
                  };
                case 'startMonitoring':
                  if (attemptIndex < failureModes.length) {
                    return failureModes[attemptIndex++];
                  }
                  return <String, Object?>{
                    'started': true,
                    'message': 'Monitoring active on FaceTime HD Camera (frames arriving).',
                  };
                case 'stopMonitoring':
                  stopCalls += 1;
                  return null;
              }
              return null;
            });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
              macEvents,
              MockStreamHandler.inline(onListen: (_, _) {}),
            );

        final macDetector = MacOSCameraSceneMotionDetector(
          methodChannel: macMethod,
          eventChannel: macEvents,
          isMacOSOverride: true,
        );
        final pinService = PinSecurityService(
          storage: InMemorySecurePinStorage(),
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '246810', confirmPin: '246810');

        final controller = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.macosCameraSceneMotion: macDetector,
          },
          audioAdapter: FakeAudioAlarmAdapter(),
          pinService: pinService,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: InMemorySettingsStorage(
            const ProtectionSettings(
              selectedDetector: DetectorType.macosCameraSceneMotion,
              armingCountdownSeconds: 3,
              onboardingCompleted: true,
            ),
          ),
          notificationAdapter: const UnconfiguredRemoteNotificationService(),
        );
        await controller.initialize();

        for (var i = 0; i < failureModes.length; i++) {
          final expectedCode = failureModes[i]['errorCode'] as String;
          final armedStarted = await controller.startArming();
          expect(armedStarted, isTrue);
          final sid = controller.activeSessionId!;
          await controller.handleCountdownTickForSession(sid);
          await controller.handleCountdownTickForSession(sid);
          await controller.handleCountdownTickForSession(sid);

          // Must NEVER enter armed when camera init fails or times out!
          expect(controller.state, ProtectionState.unavailable);
          expect(controller.warningMessage, isNotNull);
          expect(controller.selectedCapability?.statusDetail, expectedCode);
          expect(stopCalls, greaterThanOrEqualTo(i + 1));

          // User clicks "Retry Detector Check" once issue is resolved.
          final recovered = await controller.retrySelectedDetectorSetup();
          expect(recovered, isTrue);
          expect(controller.state, ProtectionState.disarmed);
        }

        // Final attempt succeeds once frames arrive!
        expect(await controller.startArming(), isTrue);
        final sid = controller.activeSessionId!;
        await controller.handleCountdownTickForSession(sid);
        await controller.handleCountdownTickForSession(sid);
        await controller.handleCountdownTickForSession(sid);
        expect(controller.state, ProtectionState.armed);

        controller.dispose();
        await macDetector.dispose();
      });

      test('Arms auxiliary Windows Accelerometer alongside Windows Webcam as a corroborating physical motion input', () async {
        final winCam = FakeMotionDetector(
          type: DetectorType.windowsCameraSceneMotion,
          initialCapability: const DetectorCapability(
            type: DetectorType.windowsCameraSceneMotion,
            status: CapabilityStatus.ready,
            permissionStatus: PermissionStatus.granted,
            summary: 'Ready — Windows Camera',
          ),
        );
        final winAccel = FakeMotionDetector(
          type: DetectorType.windowsAccelerometer,
          initialCapability: const DetectorCapability(
            type: DetectorType.windowsAccelerometer,
            status: CapabilityStatus.ready,
            permissionStatus: PermissionStatus.granted,
            summary: 'Ready — Windows 3D Accelerometer',
          ),
        );
        final audio = FakeAudioAlarmAdapter();
        final pinService = PinSecurityService(
          storage: InMemorySecurePinStorage(),
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '246810', confirmPin: '246810');

        final controller = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.windowsCameraSceneMotion: winCam,
            DetectorType.windowsAccelerometer: winAccel,
          },
          audioAdapter: audio,
          pinService: pinService,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: InMemorySettingsStorage(
            const ProtectionSettings(
              selectedDetector: DetectorType.windowsCameraSceneMotion,
              armingCountdownSeconds: 3,
              onboardingCompleted: true,
            ),
          ),
          notificationAdapter: const UnconfiguredRemoteNotificationService(),
        );
        await controller.initialize();

        expect(await controller.startArming(), isTrue);
        final sid = controller.activeSessionId!;
        await controller.handleCountdownTickForSession(sid);
        await controller.handleCountdownTickForSession(sid);
        await controller.handleCountdownTickForSession(sid);

        expect(controller.state, ProtectionState.armed);
        expect(winCam.startCount, 1);
        expect(winAccel.startCount, 1);

        // Physical pickup detected by the auxiliary accelerometer triggers the alarm!
        winAccel.emit(
          DetectorEvent(
            eventId: 'aux_1',
            sessionId: sid,
            detectorType: DetectorType.windowsAccelerometer,
            eventType: DetectorEventType.motionTriggered,
            timestamp: DateTime.utc(2026, 11, 13, 12, 1),
            summary: 'Auxiliary accelerometer detected 0.42g pickup',
            motionScore: 0.49,
            threshold: 0.095,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(controller.state, ProtectionState.alarming);
        expect(audio.isPlaying, isTrue);

        controller.dispose();
        await winCam.dispose();
        await winAccel.dispose();
      });

      test('Android background monitoring stays armed across app pause and exits armed if foreground service stops (#9)', () async {
        const androidMethod = MethodChannel('dev.watsafe/test_android_bg');
        const androidEvents = EventChannel(
          'dev.watsafe/test_android_bg_events',
        );
        MockStreamHandlerEventSink? sink;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(androidMethod, (MethodCall call) async {
              switch (call.method) {
                case 'checkCapability':
                  return <String, Object?>{
                    'hasMotionHardware': true,
                    'deviceName': 'BMI260 Linear Acceleration',
                    'permissionStatus': 'granted',
                  };
                case 'startMonitoring':
                  return <String, Object?>{
                    'started': true,
                    'message':
                        'Background monitoring active via foreground service.',
                  };
                case 'stopMonitoring':
                  return null;
              }
              return null;
            });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
              androidEvents,
              MockStreamHandler.inline(
                onListen: (_, MockStreamHandlerEventSink events) {
                  sink = events;
                },
              ),
            );

        final androidDetector = AndroidMotionDetectorAdapter(
          methodChannel: androidMethod,
          eventChannel: androidEvents,
          isAndroidOverride: true,
        );
        expect(androidDetector.supportsBackgroundMonitoring, isTrue);

        final pinService = PinSecurityService(
          storage: InMemorySecurePinStorage(),
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '246810', confirmPin: '246810');

        final controller = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.androidMotionSensors: androidDetector,
          },
          audioAdapter: FakeAudioAlarmAdapter(),
          pinService: pinService,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: InMemorySettingsStorage(
            const ProtectionSettings(
              selectedDetector: DetectorType.androidMotionSensors,
              armingCountdownSeconds: 3,
              onboardingCompleted: true,
            ),
          ),
          notificationAdapter: const UnconfiguredRemoteNotificationService(),
        );
        await controller.initialize();

        expect(await controller.startArming(), isTrue);
        final sid = controller.activeSessionId!;
        await controller.handleCountdownTickForSession(sid);
        await controller.handleCountdownTickForSession(sid);
        await controller.handleCountdownTickForSession(sid);
        expect(controller.state, ProtectionState.armed);

        // Screen turns off / Activity pauses -> Android FGS keeps monitoring armed!
        await controller.handleAppLifecycleState(AppLifecycleState.paused);
        expect(controller.state, ProtectionState.armed);

        // User stops foreground service from notification -> exits armed immediately!
        sink?.success(<String, Object?>{
          'sessionId': sid,
          'eventType': 'detectorFailed',
          'summary': 'Android foreground monitoring stopped from persistent notification.',
          'errorCode': 'FOREGROUND_SERVICE_STOPPED',
          'timestampMs': 1730000010000,
        });
        await Future<void>.delayed(Duration.zero);

        expect(controller.state, ProtectionState.unavailable);
        expect(controller.warningMessage, contains('NOT protected'));

        controller.dispose();
        await androidDetector.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(androidMethod, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(androidEvents, null);
      });

      test('WindowsCameraSceneMotionDetectorAdapter maps PERMISSION_DENIED to permissionRequired', () async {
        const winMethod = MethodChannel('dev.watsafe/test_win_cam_err');
        const winEvents = EventChannel('dev.watsafe/test_win_cam_err_events');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(winMethod, (MethodCall call) async {
              if (call.method == 'startMonitoring') {
                return <String, Object?>{
                  'started': false,
                  'errorCode': 'PERMISSION_DENIED',
                  'message': 'Windows blocked camera access.',
                };
              }
              return null;
            });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
              winEvents,
              MockStreamHandler.inline(onListen: (_, _) {}),
            );

        final winDetector = WindowsCameraSceneMotionDetectorAdapter(
          methodChannel: winMethod,
          eventChannel: winEvents,
          isWindowsOverride: true,
        );
        final res = await winDetector.startMonitoring(
          const MonitorConfig(sessionId: 'win_err_1', sensitivity: 0.6),
        );
        expect(res.started, isFalse);
        expect(res.status, CapabilityStatus.permissionRequired);
        expect(res.errorCode, 'PERMISSION_DENIED');

        await winDetector.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(winMethod, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(winEvents, null);
      });
    },
  );
}
