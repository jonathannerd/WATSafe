import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/incident_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

/// Controllable fake detector for deterministic state machine testing.
class FakeMotionDetector implements MotionDetectorAdapter {
  FakeMotionDetector({
    this.type = DetectorType.macosCameraSceneMotion,
    DetectorCapability? initialCapability,
  }) : capability =
           initialCapability ??
           DetectorCapability(
             type: type,
             status: CapabilityStatus.ready,
             permissionStatus: PermissionStatus.granted,
             summary: 'Ready for testing',
             hardwareDeviceName: 'Fake Test Camera',
           );

  final DetectorType type;
  DetectorCapability capability;
  DetectorStartResult nextStartResult = const DetectorStartResult(
    started: true,
    status: CapabilityStatus.ready,
    message: 'Monitoring started',
  );
  PermissionStatus nextPermissionResult = PermissionStatus.granted;

  final StreamController<DetectorEvent> _events =
      StreamController<DetectorEvent>.broadcast();

  String? lastStartedSessionId;
  String? lastStoppedSessionId;
  int startCount = 0;
  int stopCount = 0;

  @override
  DetectorType get detectorType => type;

  @override
  Stream<DetectorEvent> get events => _events.stream;

  void emit(DetectorEvent event) {
    _events.add(event);
  }

  @override
  Future<DetectorCapability> checkCapability() async => capability;

  @override
  Future<PermissionStatus> requestPermission() async => nextPermissionResult;

  @override
  Future<DetectorStartResult> startMonitoring(MonitorConfig config) async {
    startCount += 1;
    lastStartedSessionId = config.sessionId;
    return nextStartResult;
  }

  @override
  Future<void> updateSensitivity(double sensitivity) async {}

  @override
  Future<void> stopMonitoring({String? sessionId}) async {
    stopCount += 1;
    lastStoppedSessionId = sessionId;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

class FailingNotificationAdapter implements RemoteNotificationAdapter {
  bool shouldThrow = false;

  @override
  Future<NotificationServiceStatus> getStatus() async {
    return const NotificationServiceStatus(
      capabilityStatus: CapabilityStatus.notConfigured,
      summary: 'Not configured',
      detail: 'Test notification adapter',
    );
  }

  @override
  Future<List<PairedDeviceSummary>> listPairedDevices() async =>
      const <PairedDeviceSummary>[];

  @override
  Future<NotificationDispatchResult> sendIncidentAlert(
    IncidentRecord incident,
  ) async {
    if (shouldThrow) {
      throw StateError('Simulated remote notification network failure');
    }
    return const NotificationDispatchResult(
      delivered: false,
      capabilityStatus: CapabilityStatus.notConfigured,
      message: 'Not configured',
    );
  }
}

void main() {
  late FakeMotionDetector fakeDetector;
  late FakeAudioAlarmAdapter fakeAudio;
  late InMemorySecurePinStorage pinStorage;
  late PinSecurityService pinService;
  late InMemoryIncidentStorage incidentStorage;
  late InMemorySettingsStorage settingsStorage;
  late FailingNotificationAdapter notificationAdapter;
  late DateTime currentTime;
  late AlarmController controller;

  setUp(() async {
    currentTime = DateTime.utc(2026, 10, 30, 12, 0, 0);
    fakeDetector = FakeMotionDetector();
    fakeAudio = FakeAudioAlarmAdapter();
    pinStorage = InMemorySecurePinStorage();
    pinService = PinSecurityService(
      storage: pinStorage,
      clock: () => currentTime,
      pbkdf2Iterations: 1000, // Fast iterations for unit tests
    );
    incidentStorage = InMemoryIncidentStorage();
    settingsStorage = InMemorySettingsStorage(
      const ProtectionSettings(
        selectedDetector: DetectorType.macosCameraSceneMotion,
        motionSensitivity: 0.60,
        armingCountdownSeconds: 3,
        alarmVolume: 0.80,
        onboardingCompleted: true,
      ),
    );
    notificationAdapter = FailingNotificationAdapter();

    controller = AlarmController(
      detectors: <DetectorType, MotionDetectorAdapter>{
        DetectorType.macosCameraSceneMotion: fakeDetector,
      },
      audioAdapter: fakeAudio,
      pinService: pinService,
      incidentStorage: incidentStorage,
      settingsStorage: settingsStorage,
      notificationAdapter: notificationAdapter,
      clock: () => currentTime,
    );

    await controller.initialize();
    await controller.setupInitialPin(pin: '246810', confirmPin: '246810');
  });

  tearDown(() async {
    controller.dispose();
    await fakeDetector.dispose();
  });

  Future<void> armControllerToArmedState() async {
    final started = await controller.startArming();
    expect(started, isTrue);
    expect(controller.state, ProtectionState.arming);
    final sessionId = controller.activeSessionId!;

    for (var i = 0; i < 3; i++) {
      await controller.handleCountdownTickForSession(sessionId);
    }
    expect(controller.state, ProtectionState.armed);
  }

  test(
    '1. Arming and cancellation, including ignoring a stale countdown callback',
    () async {
      final started = await controller.startArming();
      expect(started, isTrue);
      expect(controller.state, ProtectionState.arming);
      expect(controller.remainingCountdownSeconds, 3);

      final cancelledSessionId = controller.activeSessionId!;
      await controller.handleCountdownTickForSession(cancelledSessionId);
      expect(controller.remainingCountdownSeconds, 2);

      // Cancel arming before countdown finishes
      await controller.cancelArming();
      expect(controller.state, ProtectionState.disarmed);
      expect(controller.activeSessionId, isNull);

      // Fire stale countdown callbacks from the cancelled session
      await controller.handleCountdownTickForSession(cancelledSessionId);
      await controller.handleCountdownTickForSession(cancelledSessionId);
      await controller.handleCountdownTickForSession(cancelledSessionId);

      // Controller must remain disarmed and never start monitoring for the stale session
      expect(controller.state, ProtectionState.disarmed);
      expect(fakeDetector.startCount, 0);
    },
  );

  test(
    '2. Calibration and readiness failure prevents arming and never shows Protected',
    () async {
      // Case A: Pre-arming readiness check fails (permission required)
      fakeDetector.capability = const DetectorCapability(
        type: DetectorType.macosCameraSceneMotion,
        status: CapabilityStatus.permissionRequired,
        permissionStatus: PermissionStatus.denied,
        summary: 'Camera permission denied.',
      );

      final canStart = await controller.startArming();
      expect(canStart, isFalse);
      expect(controller.state, ProtectionState.unavailable);
      expect(controller.state.isProtected, isFalse);

      // Case B: Readiness passes, countdown completes, but native calibration/startup fails
      fakeDetector.capability = const DetectorCapability(
        type: DetectorType.macosCameraSceneMotion,
        status: CapabilityStatus.ready,
        permissionStatus: PermissionStatus.granted,
        summary: 'Camera ready.',
      );
      fakeDetector.nextStartResult = const DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: 'AVCaptureSession failed during startup calibration.',
        errorCode: 'CALIBRATION_FAILED',
      );

      final started = await controller.startArming();
      expect(started, isTrue);
      final sessionId = controller.activeSessionId!;

      for (var i = 0; i < 3; i++) {
        await controller.handleCountdownTickForSession(sessionId);
      }

      // Must transition to unavailable, NOT armed
      expect(controller.state, ProtectionState.unavailable);
      expect(controller.state.isProtected, isFalse);
      expect(controller.activeSessionId, isNull);
      expect(controller.statusMessage, contains('AVCaptureSession failed'));
    },
  );

  test(
    '3. Duplicate detector events produce only one active incident and one siren start',
    () async {
      await armControllerToArmedState();
      final sessionId = controller.activeSessionId!;

      fakeDetector.emit(
        DetectorEvent(
          eventId: 'evt_1',
          sessionId: sessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: currentTime,
          summary: 'Sustained scene motion #1',
          motionScore: 0.14,
          threshold: 0.095,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, ProtectionState.alarming);
      expect(controller.incidents.length, 1);
      expect(fakeAudio.loopingStartCount, 1);
      expect(controller.activeIncident?.peakMotionScore, 0.14);

      // Emit two more trigger events in the same armed session
      fakeDetector.emit(
        DetectorEvent(
          eventId: 'evt_2',
          sessionId: sessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: currentTime.add(const Duration(seconds: 1)),
          summary: 'Sustained scene motion #2',
          motionScore: 0.29,
          threshold: 0.095,
        ),
      );
      fakeDetector.emit(
        DetectorEvent(
          eventId: 'evt_3',
          sessionId: sessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: currentTime.add(const Duration(seconds: 2)),
          summary: 'Sustained scene motion #3',
          motionScore: 0.19,
          threshold: 0.095,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // Still only ONE incident and ONE audio siren start; peak score updated to 0.29
      expect(controller.incidents.length, 1);
      expect(fakeAudio.loopingStartCount, 1);
      expect(controller.activeIncident?.peakMotionScore, 0.29);
    },
  );

  test(
    '4. Correct and incorrect PIN behavior, backoff lockout, and PIN change validation',
    () async {
      await armControllerToArmedState();
      final sessionId = controller.activeSessionId!;

      // Trigger alarm
      fakeDetector.emit(
        DetectorEvent(
          eventId: 'evt_alarm',
          sessionId: sessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: currentTime,
          summary: 'Motion trigger',
          motionScore: 0.18,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, ProtectionState.alarming);
      expect(fakeAudio.isPlaying, isTrue);

      // 1st wrong PIN -> leaves alarm and siren active
      final wrong1 = await controller.verifyAndDisarm('000000');
      expect(wrong1.verified, isFalse);
      expect(controller.state, ProtectionState.alarming);
      expect(fakeAudio.isPlaying, isTrue);

      // 2nd wrong PIN -> triggers 2-second backoff delay
      final wrong2 = await controller.verifyAndDisarm('111111');
      expect(wrong2.verified, isFalse);
      expect(wrong2.isLockedOut, isTrue);
      expect(wrong2.remainingLockout, const Duration(seconds: 2));
      expect(controller.state, ProtectionState.alarming);
      expect(fakeAudio.isPlaying, isTrue);

      // Immediate attempt with correct PIN while locked out is rejected
      final duringLockout = await controller.verifyAndDisarm('246810');
      expect(duringLockout.verified, isFalse);
      expect(duringLockout.isLockedOut, isTrue);
      expect(controller.state, ProtectionState.alarming);

      // Advance clock past 2-second lockout and verify with correct PIN
      currentTime = currentTime.add(const Duration(seconds: 3));
      final right = await controller.verifyAndDisarm('246810');
      expect(right.verified, isTrue);
      expect(controller.state, ProtectionState.disarmed);
      expect(fakeAudio.isPlaying, isFalse);
      expect(controller.activeIncident, isNull);
      expect(controller.incidents.first.resolvedAt, isNotNull);

      // PIN change requires valid current PIN and >= 6 digits
      final badCurrent = await controller.changePin(
        currentPin: '999999',
        newPin: '654321',
        confirmNewPin: '654321',
      );
      expect(badCurrent.isValid, isFalse);

      final tooShort = await controller.changePin(
        currentPin: '246810',
        newPin: '12345',
        confirmNewPin: '12345',
      );
      expect(tooShort.isValid, isFalse);

      final validChange = await controller.changePin(
        currentPin: '246810',
        newPin: '654321',
        confirmNewPin: '654321',
      );
      expect(validChange.isValid, isTrue);
    },
  );

  test(
    '5. Late detector events from a previous session are strictly ignored',
    () async {
      await armControllerToArmedState();
      final firstSessionId = controller.activeSessionId!;

      // Disarm first session
      final disarmed = await controller.verifyAndDisarm('246810');
      expect(disarmed.verified, isTrue);
      expect(controller.state, ProtectionState.disarmed);

      // Emit a late motionTriggered event carrying the old sessionId while disarmed
      fakeDetector.emit(
        DetectorEvent(
          eventId: 'late_evt_1',
          sessionId: firstSessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: currentTime,
          summary: 'Late event from ended session',
          motionScore: 0.45,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, ProtectionState.disarmed);
      expect(controller.incidents, isEmpty);
      expect(fakeAudio.loopingStartCount, 0);

      // Start a second armed session and emit a late event with the first session's ID
      await armControllerToArmedState();
      final secondSessionId = controller.activeSessionId!;
      expect(secondSessionId, isNot(equals(firstSessionId)));

      fakeDetector.emit(
        DetectorEvent(
          eventId: 'late_evt_2',
          sessionId: firstSessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: currentTime,
          summary: 'Stale session trigger during new session',
          motionScore: 0.50,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // Must remain armed and NOT trigger alarm for the stale session event
      expect(controller.state, ProtectionState.armed);
      expect(controller.incidents, isEmpty);
      expect(fakeAudio.loopingStartCount, 0);
    },
  );

  test(
    '6. Detector failure and lifecycle changes update status accurately and never show Protected when failed or paused',
    () async {
      await armControllerToArmedState();
      final sessionId = controller.activeSessionId!;
      expect(controller.state, ProtectionState.armed);
      expect(controller.state.isProtected, isTrue);

      // Lifecycle pause (e.g. system sleep) -> transitions to paused (not protected)
      fakeDetector.emit(
        DetectorEvent(
          eventId: 'pause_1',
          sessionId: sessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.lifecyclePaused,
          timestamp: currentTime,
          summary: 'System entering sleep',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, ProtectionState.paused);
      expect(controller.state.isProtected, isFalse);

      // Lifecycle resume -> returns to armed
      fakeDetector.emit(
        DetectorEvent(
          eventId: 'resume_1',
          sessionId: sessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.lifecycleResumed,
          timestamp: currentTime,
          summary: 'System woke from sleep',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, ProtectionState.armed);
      expect(controller.state.isProtected, isTrue);

      // Hardware/capture failure while armed -> transitions to unavailable and records failure incident
      fakeDetector.emit(
        DetectorEvent(
          eventId: 'fail_1',
          sessionId: sessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.detectorFailed,
          timestamp: currentTime,
          summary: 'Camera disconnected unexpectedly',
          errorCode: 'CAMERA_DISCONNECTED',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state, ProtectionState.unavailable);
      expect(controller.state.isProtected, isFalse);
      expect(controller.incidents.length, 1);
      expect(
        controller.incidents.first.kind,
        IncidentKind.detectorFailureDuringMonitoring,
      );
    },
  );

  test(
    '7. Local alarm continues operating when incident saving or remote notification delivery fails',
    () async {
      await armControllerToArmedState();
      final sessionId = controller.activeSessionId!;

      // Configure both incident storage and remote notification adapter to throw exceptions
      incidentStorage.shouldThrowOnSave = true;
      incidentStorage.shouldThrowOnUpdate = true;
      notificationAdapter.shouldThrow = true;

      fakeDetector.emit(
        DetectorEvent(
          eventId: 'resilience_evt',
          sessionId: sessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: currentTime,
          summary: 'Motion trigger under storage/network failure',
          motionScore: 0.25,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Local siren and alarming state MUST remain active despite storage & network failures
      expect(controller.state, ProtectionState.alarming);
      expect(fakeAudio.isPlaying, isTrue);
      expect(fakeAudio.loopingStartCount, 1);
      expect(controller.warningMessage, isNotNull);
      expect(controller.warningMessage, contains('Local incident save failed'));
      expect(
        controller.warningMessage,
        contains('Remote alert dispatch failed'),
      );
    },
  );
}
