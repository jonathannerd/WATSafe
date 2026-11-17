import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/incident_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/core/vision/camera_motion_analyzer.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

import 'alarm_controller_test.dart';
import 'camera_motion_detection_test.dart'
    show overlayPassingPerson, renderSyntheticRoomScene;

/// Overlays a person leaning toward the stationary webcam (radial expansion
/// around `(centerX, centerY)` while room wall corners remain stationary).
Float32List _overlayApproachingPerson(
  Float32List background, {
  int width = 64,
  int height = 48,
  required double scale,
}) {
  final out = Float32List.fromList(background);
  const cx = 31.5;
  const cy = 28.0;
  final rx = 10.0 * scale;
  final ry = 13.0 * scale;

  for (var y = 10; y < height; y++) {
    for (var x = 8; x < width - 8; x++) {
      final nx = (x - cx) / rx;
      final ny = (y - cy) / ry;
      final r2 = (nx * nx) + (ny * ny);
      if (r2 <= 1.0) {
        // Textured sweater expanding radially with scale
        final u = (x - cx) / scale;
        final v = (y - cy) / scale;
        final pattern =
            54.0 + 18.0 * math.sin(u * 0.85) + 14.0 * math.cos(v * 0.75);
        out[y * width + x] = pattern.clamp(0.0, 255.0);
      }
    }
  }
  return out;
}

/// Overlays a hand briefly sweeping in front of the lens.
Float32List _overlayPassingHand(
  Float32List background, {
  int width = 64,
  int height = 48,
  required double centerX,
  double halfWidth = 18.0,
}) {
  final out = Float32List.fromList(background);
  for (var y = 8; y < height - 4; y++) {
    for (var x = 0; x < width; x++) {
      if ((x - centerX).abs() <= halfWidth) {
        // Smooth skin-tone palm (low internal spatial texture)
        final palm = 166.0 + 1.4 * math.sin((x - centerX) * 0.2);
        out[y * width + x] = palm.clamp(0.0, 255.0);
      }
    }
  }
  return out;
}

/// Overlays a stationary seated owner in front of the laptop with slight
/// natural breathing/posture sway (`swayX`, `swayY`) while upper room walls
/// stay completely fixed.
Float32List _overlaySeatedUser(
  Float32List background, {
  int width = 64,
  int height = 48,
  double swayX = 0.0,
  double swayY = 0.0,
}) {
  final out = Float32List.fromList(background);
  final cx = 32.0 + swayX;
  final headCy = 22.0 + swayY;
  for (var y = 14; y < height; y++) {
    final isShoulders = y >= 29;
    final halfW = isShoulders ? 14.5 : 7.5;
    for (var x = 0; x < width; x++) {
      final inHead =
          !isShoulders &&
          (((x - cx) * (x - cx)) / 56.0 +
                  ((y - headCy) * (y - headCy)) / 64.0) <=
              1.0;
      final inTorso = isShoulders && (x - cx).abs() <= halfW;
      if (inHead || inTorso) {
        final tone =
            62.0 +
            10.0 * math.sin((x - cx) * 0.55) +
            8.0 * math.cos((y - headCy) * 0.45);
        out[y * width + x] = tone.clamp(0.0, 255.0);
      }
    }
  }
  return out;
}

CameraMotionAnalyzer _createCalibratedAnalyzer({
  required Float32List baseline,
  required DateTime startTime,
  MotionSensitivityPreset preset = MotionSensitivityPreset.balanced,
}) {
  final config = MonitorConfig(
    sessionId: 'scenario_eval',
    sensitivity: preset.sensitivityValue,
  );
  final analyzer = CameraMotionAnalyzer(
    calibrationDuration: const Duration(milliseconds: 1200),
    persistenceFramesRequired: 3,
    motionThreshold: config.motionScoreThreshold,
  );
  var t = startTime;
  for (var i = 0; i < 6; i++) {
    analyzer.processFrame(baseline, timestamp: t);
    t = t.add(const Duration(milliseconds: 300));
  }
  return analyzer;
}

class _SpyNotificationAdapter extends UnconfiguredRemoteNotificationService {
  int sentRealAlerts = 0;

  @override
  Future<NotificationDispatchResult> sendIncidentAlert(
    IncidentRecord incident,
  ) async {
    sentRealAlerts += 1;
    return super.sendIncidentAlert(incident);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Priority 2: 10 Realistic Theft vs. Everyday False-Alarm Scenarios (Synthetic Grayscale Video Fixtures)', () {
    test('Scenario 1: Person walking behind the user produces 0 false alarms across all presets', () {
      final t0 = DateTime.utc(2026, 11, 17, 16, 0, 0);
      final room = renderSyntheticRoomScene();

      for (final preset in MotionSensitivityPreset.values) {
        final analyzer = _createCalibratedAnalyzer(
          baseline: room,
          startTime: t0,
          preset: preset,
        );
        var t = t0.add(const Duration(seconds: 2));
        var falseAlarmCount = 0;

        for (var step = 0; step < 24; step++) {
          t = t.add(const Duration(milliseconds: 125));
          final personX = -12.0 + (step * 3.8);
          final frame = overlayPassingPerson(room, personCenterX: personX);
          final eval = analyzer.processFrame(frame, timestamp: t);
          if (eval.triggered) {
            falseAlarmCount += 1;
          }
        }

        expect(
          falseAlarmCount,
          0,
          reason:
              'Scenario 1 (${preset.title}): passerby walking across room must produce 0 false alarms',
        );
      }
    });

    test('Scenario 2: Person approaching or leaning near the camera without moving the device produces 0 false alarms', () {
      final t0 = DateTime.utc(2026, 11, 17, 16, 5, 0);
      final room = renderSyntheticRoomScene();
      final analyzer = _createCalibratedAnalyzer(
        baseline: _overlayApproachingPerson(room, scale: 0.85),
        startTime: t0,
      );

      var t = t0.add(const Duration(seconds: 2));
      var falseAlarmCount = 0;
      for (var step = 1; step <= 14; step++) {
        t = t.add(const Duration(milliseconds: 125));
        final scale = 0.85 + (step * 0.05);
        final frame = _overlayApproachingPerson(room, scale: scale);
        final eval = analyzer.processFrame(frame, timestamp: t);
        if (eval.triggered) {
          falseAlarmCount += 1;
        }
      }

      expect(
        falseAlarmCount,
        0,
        reason: 'Scenario 2: radial looming / leaning toward a stationary webcam must produce 0 false alarms',
      );
    });

    test('Scenario 3: Hand passing briefly in front of the camera produces 0 false alarms', () {
      final t0 = DateTime.utc(2026, 11, 17, 16, 10, 0);
      final room = renderSyntheticRoomScene();
      final analyzer = _createCalibratedAnalyzer(baseline: room, startTime: t0);

      var t = t0.add(const Duration(seconds: 2));
      var falseAlarmCount = 0;
      final handPositions = <double?>[18.0, 38.0, null, null, null];
      for (final pos in handPositions) {
        t = t.add(const Duration(milliseconds: 125));
        final frame = pos == null
            ? room
            : _overlayPassingHand(room, centerX: pos);
        final eval = analyzer.processFrame(frame, timestamp: t);
        if (eval.triggered) {
          falseAlarmCount += 1;
        }
      }

      expect(
        falseAlarmCount,
        0,
        reason: 'Scenario 3: brief 2-frame hand pass across lens must produce 0 false alarms',
      );
    });

    test('Scenario 4: Abrupt & gradual room lighting, auto-exposure contrast, and moving shadow shifts produce 0 false alarms', () {
      final t0 = DateTime.utc(2026, 11, 17, 16, 15, 0);
      final room = renderSyntheticRoomScene();
      final analyzer = _createCalibratedAnalyzer(baseline: room, startTime: t0);

      var t = t0.add(const Duration(seconds: 2));
      var falseAlarmCount = 0;

      // Abrupt light switch (+48 luma, 1.3x contrast) held for 6 frames, then gradual dimming
      for (var step = 0; step < 16; step++) {
        t = t.add(const Duration(milliseconds: 125));
        final offset = step < 6 ? 48.0 : (48.0 - (step - 5) * 8.5);
        final scale = step < 6 ? 1.30 : 0.82;
        final lit = renderSyntheticRoomScene(
          illuminationOffset: offset,
          contrastScale: scale,
        );
        // Add soft diagonal window shadow gradient
        for (var y = 0; y < 48; y++) {
          for (var x = 0; x < 64; x++) {
            if (x + y < (step * 6)) {
              lit[y * 64 + x] = (lit[y * 64 + x] * 0.88).clamp(0.0, 255.0);
            }
          }
        }
        final eval = analyzer.processFrame(lit, timestamp: t);
        if (eval.triggered) {
          falseAlarmCount += 1;
        }
      }

      expect(
        falseAlarmCount,
        0,
        reason: 'Scenario 4: lighting/brightness/shadow shifts without camera movement must produce 0 false alarms',
      );
    });

    test('Scenario 5: Camera covered or dark room produces 0 false alarms and honestly reports degraded input', () {
      final t0 = DateTime.utc(2026, 11, 17, 16, 20, 0);
      final room = renderSyntheticRoomScene();
      final analyzer = _createCalibratedAnalyzer(baseline: room, startTime: t0);

      var t = t0.add(const Duration(seconds: 2));
      var falseAlarmCount = 0;
      var reportedDegradedInput = false;

      final coveredLens = Float32List(64 * 48)..fillRange(0, 64 * 48, 3.0);
      for (var step = 0; step < 12; step++) {
        t = t.add(const Duration(milliseconds: 125));
        final eval = analyzer.processFrame(coveredLens, timestamp: t);
        if (eval.isPoorInput) {
          reportedDegradedInput = true;
        }
        if (eval.triggered) {
          falseAlarmCount += 1;
        }
      }

      expect(falseAlarmCount, 0);
      expect(
        reportedDegradedInput,
        isTrue,
        reason: 'Scenario 5: covered camera or pitch-dark room must warn of degraded input without false-triggering',
      );
    });

    test('Scenario 6: Stationary user sitting in front of the laptop with subtle posture micro-sway produces 0 false alarms', () {
      final t0 = DateTime.utc(2026, 11, 17, 16, 25, 0);
      final room = renderSyntheticRoomScene();
      final initialSeated = _overlaySeatedUser(room);
      final analyzer = _createCalibratedAnalyzer(
        baseline: initialSeated,
        startTime: t0,
      );

      var t = t0.add(const Duration(seconds: 2));
      var falseAlarmCount = 0;
      for (var step = 0; step < 30; step++) {
        t = t.add(const Duration(milliseconds: 125));
        final swayX = 0.75 * math.sin(step * 0.35);
        final swayY = 0.45 * math.cos(step * 0.28);
        final frame = _overlaySeatedUser(room, swayX: swayX, swayY: swayY);
        final eval = analyzer.processFrame(frame, timestamp: t);
        if (eval.triggered) {
          falseAlarmCount += 1;
        }
      }

      expect(
        falseAlarmCount,
        0,
        reason: 'Scenario 6: stationary seated user in front of anchored room walls must produce 0 false alarms',
      );
    });

    test('Scenario 7: Gentle lift or tilt of the laptop triggers alarm reliably with bounded frame latency', () {
      final t0 = DateTime.utc(2026, 11, 17, 16, 30, 0);
      final room = renderSyntheticRoomScene();
      final analyzer = _createCalibratedAnalyzer(baseline: room, startTime: t0);

      final liftStart = t0.add(const Duration(seconds: 2));
      var t = liftStart;
      int? triggerFrame;
      Duration? triggerLatency;
      CameraMotionFrameEvaluation? triggerEval;

      for (var step = 1; step <= 8; step++) {
        t = t.add(const Duration(milliseconds: 125));
        final tilted = renderSyntheticRoomScene(
          panY: step * 1.35,
          rollRadians: step * 0.032,
        );
        final eval = analyzer.processFrame(tilted, timestamp: t);
        if (eval.triggered) {
          triggerFrame = step;
          triggerLatency = t.difference(liftStart);
          triggerEval = eval;
          break;
        }
      }

      expect(
        triggerFrame,
        isNotNull,
        reason: 'Scenario 7: gentle lift/tilt must trigger alarm',
      );
      expect(triggerFrame, lessThanOrEqualTo(5));
      expect(triggerLatency!.inMilliseconds, lessThanOrEqualTo(625));
      expect(triggerEval!.coherentTranslatedBlocks, greaterThanOrEqualTo(5));
      expect(triggerEval.rigidCoherence, greaterThanOrEqualTo(0.56));
    });

    test('Scenario 8: Picking up and carrying the laptop away triggers within 3 frames (375ms) and skips confirmation delay', () {
      final t0 = DateTime.utc(2026, 11, 17, 16, 35, 0);
      final room = renderSyntheticRoomScene();
      final analyzer = _createCalibratedAnalyzer(baseline: room, startTime: t0);

      final pickupStart = t0.add(const Duration(seconds: 2));
      var t = pickupStart;
      int? triggerFrame;
      CameraMotionFrameEvaluation? triggerEval;

      for (var step = 1; step <= 6; step++) {
        t = t.add(const Duration(milliseconds: 125));
        final carried = renderSyntheticRoomScene(
          panX: step * 2.3,
          panY: step * 1.7,
          rollRadians: step * 0.055,
        );
        final eval = analyzer.processFrame(carried, timestamp: t);
        if (eval.triggered) {
          triggerFrame = step;
          triggerEval = eval;
          break;
        }
      }

      expect(triggerFrame, equals(3));
      expect(
        t.difference(pickupStart),
        equals(const Duration(milliseconds: 375)),
      );
      expect(triggerEval!.coherentTranslatedBlocks, greaterThanOrEqualTo(7));
    });

    test('Scenario 9: Slow slide across a table triggers via rolling 4-frame drift consensus', () {
      final t0 = DateTime.utc(2026, 11, 17, 16, 40, 0);
      final room = renderSyntheticRoomScene();
      final analyzer = _createCalibratedAnalyzer(baseline: room, startTime: t0);

      var t = t0.add(const Duration(seconds: 2));
      var triggered = false;
      var peakSlowDrift = 0.0;

      // 0.72 px per frame is sub-pixel step-to-step, accumulating ~2.9 px across 4 frames
      for (var step = 1; step <= 12; step++) {
        t = t.add(const Duration(milliseconds: 125));
        final slid = renderSyntheticRoomScene(panX: step * 0.72);
        final eval = analyzer.processFrame(slid, timestamp: t);
        peakSlowDrift = math.max(peakSlowDrift, eval.slowDriftScore);
        if (eval.triggered) {
          triggered = true;
          break;
        }
      }

      expect(
        triggered,
        isTrue,
        reason: 'Scenario 9: slow horizontal slide across desk must be caught by 4-frame drift window',
      );
      expect(peakSlowDrift, greaterThan(0.05));
    });

    test('Scenario 10 + Sensitivity Presets + AC-Unplug Corroboration + Silent Guided Protection Test', () async {
      // Verify preset ordering & plain-language titles
      expect(
        MotionSensitivityPreset.fewerFalseAlarms.title,
        'Fewer false alarms',
      );
      expect(MotionSensitivityPreset.balanced.title, 'Balanced');
      expect(
        MotionSensitivityPreset.higherSensitivity.title,
        'Higher sensitivity',
      );

      final lowSensThreshold = MonitorConfig(
        sessionId: 's1',
        sensitivity: MotionSensitivityPreset.fewerFalseAlarms.sensitivityValue,
      ).motionScoreThreshold;
      final balancedThreshold = MonitorConfig(
        sessionId: 's2',
        sensitivity: MotionSensitivityPreset.balanced.sensitivityValue,
      ).motionScoreThreshold;
      final highSensThreshold = MonitorConfig(
        sessionId: 's3',
        sensitivity: MotionSensitivityPreset.higherSensitivity.sensitivityValue,
      ).motionScoreThreshold;
      expect(highSensThreshold, lessThan(balancedThreshold));
      expect(balancedThreshold, lessThan(lowSensThreshold));

      var now = DateTime.utc(2026, 11, 17, 17, 0, 0);
      final detector = FakeMotionDetector(
        type: DetectorType.macosCameraSceneMotion,
      );
      final audio = FakeAudioAlarmAdapter();
      final spyNotifs = _SpyNotificationAdapter();
      final pinService = PinSecurityService(
        storage: InMemorySecurePinStorage(),
        pbkdf2Iterations: 500,
      );
      await pinService.setupInitialPin(pin: '654321', confirmPin: '654321');

      final controller = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.macosCameraSceneMotion: detector,
        },
        audioAdapter: audio,
        pinService: pinService,
        incidentStorage: InMemoryIncidentStorage(),
        settingsStorage: InMemorySettingsStorage(
          const ProtectionSettings(
            selectedDetector: DetectorType.macosCameraSceneMotion,
            armingCountdownSeconds: 1,
            onboardingCompleted: true,
          ),
        ),
        notificationAdapter: spyNotifs,
        clock: () => now,
        ambiguousMotionConfirmationWindow: const Duration(seconds: 3),
      );
      addTearDown(() async {
        controller.dispose();
        await detector.dispose();
      });

      await controller.initialize();

      // --- A. Safe Silent Guided Protection Test (passerby -> gentle lift -> 0 sirens, 0 remote alerts) ---
      final guidedStarted = await controller.startGuidedProtectionTest();
      expect(guidedStarted, isTrue);
      expect(controller.isGuidedTestRunning, isTrue);
      expect(controller.guidedTestPhase, 'passerby_check');
      final guidedSid = detector.lastStartedSessionId!;

      // Emit calm telemetry during passerby step -> 0 false triggers
      detector.emit(
        DetectorEvent(
          eventId: 'gt_tel_1',
          sessionId: guidedSid,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.telemetryFrame,
          timestamp: now,
          summary: 'Background anchored while person walked past',
          motionScore: 0.022,
          threshold: balancedThreshold,
          coherentBlocks: 0,
          anchoredBlocks: 10,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.guidedTestFalseTriggers, 0);
      expect(audio.isPlaying, isFalse);

      // Advance to lift check and emit pickup trigger 380ms later
      controller.advanceGuidedTestToLiftStep();
      expect(controller.guidedTestPhase, 'lift_check');
      now = now.add(const Duration(milliseconds: 380));
      detector.emit(
        DetectorEvent(
          eventId: 'gt_lift_1',
          sessionId: guidedSid,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: now,
          summary: 'Gentle device lift detected',
          motionScore: 0.24,
          threshold: balancedThreshold,
          consecutiveAboveThresholdFrames: 3,
          coherentBlocks: 8,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.guidedTestPickupDetected, isTrue);
      expect(
        controller.guidedTestPickupLatency,
        equals(const Duration(milliseconds: 380)),
      );
      expect(controller.guidedTestPhase, 'completed');
      expect(
        audio.isPlaying,
        isFalse,
        reason: 'Guided Protection Test must never sound the siren',
      );
      expect(
        spyNotifs.sentRealAlerts,
        0,
        reason: 'Guided Protection Test must never send panic notifications',
      );

      // --- B. AC power unplug alone NEVER triggers an alarm ---
      await controller.startArming();
      var sid = controller.activeSessionId!;
      await controller.handleCountdownTickForSession(sid);
      expect(controller.state, ProtectionState.armed);

      detector.emit(
        DetectorEvent(
          eventId: 'ac_unplug_only',
          sessionId: sid,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.telemetryFrame,
          timestamp: now,
          summary: 'AC power cable unplugged while stationary',
          motionScore: 0.012,
          threshold: balancedThreshold,
          acPowerUnplugged: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.state,
        ProtectionState.armed,
        reason: 'Unplugging power cable alone must never trigger an alarm',
      );

      // --- C1. Ambiguous borderline camera trigger enters "Movement detected — checking…" and settles cleanly if room calms down ---
      detector.emit(
        DetectorEvent(
          eventId: 'ambig_settle_1',
          sessionId: sid,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: now,
          summary: 'Borderline camera motion',
          motionScore: balancedThreshold * 1.12,
          threshold: balancedThreshold,
          consecutiveAboveThresholdFrames: 3,
          coherentBlocks: 4,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, ProtectionState.armed);
      expect(controller.isConfirmingMovement, isTrue);
      expect(controller.confirmationMessage, 'Movement detected — checking…');
      expect(audio.isPlaying, isFalse);

      now = now.add(const Duration(milliseconds: 600));
      detector.emit(
        DetectorEvent(
          eventId: 'ambig_settled_telemetry',
          sessionId: sid,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.telemetryFrame,
          timestamp: now,
          summary: 'Scene settled',
          motionScore: balancedThreshold * 0.25,
          threshold: balancedThreshold,
          coherentBlocks: 0,
          anchoredBlocks: 12,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.isConfirmingMovement, isFalse);
      expect(controller.state, ProtectionState.armed);
      expect(audio.isPlaying, isFalse);

      // --- C2. Enter confirmation stage again, then disarm with correct PIN DURING confirmation ---
      detector.emit(
        DetectorEvent(
          eventId: 'ambig_1',
          sessionId: sid,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: now,
          summary: 'Borderline camera motion',
          motionScore: balancedThreshold * 1.12,
          threshold: balancedThreshold,
          consecutiveAboveThresholdFrames: 3,
          coherentBlocks: 4,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, ProtectionState.armed);
      expect(controller.isConfirmingMovement, isTrue);
      expect(audio.isPlaying, isFalse);

      // Disarming with correct PIN DURING confirmation stage cancels immediately!
      final disarmDuringCheck = await controller.verifyAndDisarm('654321');
      expect(disarmDuringCheck.verified, isTrue);
      expect(controller.state, ProtectionState.disarmed);
      expect(controller.isConfirmingMovement, isFalse);
      expect(audio.isPlaying, isFalse);

      // --- D. Re-arm: AC unplug corroborates borderline camera ego-motion immediately ---
      await controller.startArming();
      sid = controller.activeSessionId!;
      await controller.handleCountdownTickForSession(sid);
      expect(controller.state, ProtectionState.armed);

      detector.emit(
        DetectorEvent(
          eventId: 'corroborated_ac_pickup',
          sessionId: sid,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: now,
          summary: 'Camera motion corroborated by recent AC power unplug',
          motionScore: balancedThreshold * 1.12,
          threshold: balancedThreshold,
          consecutiveAboveThresholdFrames: 3,
          coherentBlocks: 4,
          acPowerUnplugged: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        controller.state,
        ProtectionState.alarming,
        reason:
            'Concurrent AC unplug + camera ego-motion skips confirmation delay',
      );
      expect(audio.isPlaying, isTrue);

      // Disarming with correct PIN during active alarm stops siren immediately!
      final disarmDuringAlarm = await controller.verifyAndDisarm('654321');
      expect(disarmDuringAlarm.verified, isTrue);
      expect(controller.state, ProtectionState.disarmed);
      expect(audio.isPlaying, isFalse);
    });
  });
}
