import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
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
    this.supportsBackgroundMonitoring = false,
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
  @override
  final bool supportsBackgroundMonitoring;
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
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('2. Calibration and readiness failure prevents arming and never shows Protected', () async {
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
  });

  test('3. Duplicate detector events produce only one active incident and one siren start', () async {
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
  });

  test('4. Correct and incorrect PIN behavior, backoff lockout, and PIN change validation', () async {
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
  });

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

  test('6. Detector failure and lifecycle changes update status accurately and never show Protected when failed or paused', () async {
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

    // Camera hardware/capture failure while armed -> triggers protection-interruption alarm
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

    expect(controller.state, ProtectionState.alarming);
    expect(fakeAudio.isPlaying, isTrue);
    expect(controller.incidents.length, 1);
    expect(controller.incidents.first.kind, IncidentKind.protectionInterrupted);
    expect((await controller.verifyAndDisarm('246810')).verified, isTrue);
    expect(controller.state, ProtectionState.disarmed);
    expect(fakeAudio.isPlaying, isFalse);
  });

  test('7. Local alarm continues operating when incident saving or remote notification delivery fails', () async {
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
    expect(controller.warningMessage, contains('Remote alert dispatch failed'));
  });

  test('8. Disarming while siren startup is still pending stops audio and never restarts siren', () async {
    await armControllerToArmedState();
    final sessionId = controller.activeSessionId!;

    // Hold startLoopingAlarm pending across an async boundary
    final startPending = Completer<void>();
    fakeAudio.pendingStartCompleter = startPending;

    fakeDetector.emit(
      DetectorEvent(
        eventId: 'evt_pending_audio',
        sessionId: sessionId,
        detectorType: DetectorType.macosCameraSceneMotion,
        eventType: DetectorEventType.motionTriggered,
        timestamp: currentTime,
        summary: 'Motion trigger with slow audio startup',
        motionScore: 0.22,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state, ProtectionState.alarming);
    expect(fakeAudio.loopingStartCount, 1);
    expect(fakeAudio.isPlaying, isTrue);

    // User enters a wrong PIN while startup is still pending -> alarm stays active
    final wrong = await controller.verifyAndDisarm('999999');
    expect(wrong.verified, isFalse);
    expect(controller.state, ProtectionState.alarming);
    expect(fakeAudio.stopCount, 0);
    expect(fakeAudio.isPlaying, isTrue);

    // User enters the correct PIN while startLoopingAlarm Future is STILL pending
    final disarmed = await controller.verifyAndDisarm('246810');
    expect(disarmed.verified, isTrue);
    expect(controller.state, ProtectionState.disarmed);
    expect(fakeAudio.isPlaying, isFalse);
    expect(fakeAudio.stopCount, greaterThanOrEqualTo(1));

    // Now allow the pending startLoopingAlarm Future to finish
    startPending.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Siren MUST remain stopped and controller MUST remain disarmed
    expect(controller.state, ProtectionState.disarmed);
    expect(fakeAudio.isPlaying, isFalse);
    expect(controller.activeIncident, isNull);
    expect(controller.incidents.first.resolvedAt, isNotNull);
    expect(
      controller.incidents.first.resolutionSummary,
      'Disarmed with verified PIN',
    );
  });

  test('9. Invalid and repeated state transitions & concurrent PIN submissions are guarded', () async {
    // Motion trigger while disarmed is ignored
    fakeDetector.emit(
      DetectorEvent(
        eventId: 'ignored_disarmed',
        sessionId: 'session_none',
        detectorType: DetectorType.macosCameraSceneMotion,
        eventType: DetectorEventType.motionTriggered,
        timestamp: currentTime,
        summary: 'Ignored trigger while disarmed',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ProtectionState.disarmed);
    expect(fakeAudio.loopingStartCount, 0);

    // Start arming -> repeated startArming returns false without creating second session
    expect(await controller.startArming(), isTrue);
    final armingSessionId = controller.activeSessionId!;
    expect(await controller.startArming(), isFalse);
    expect(controller.activeSessionId, armingSessionId);

    // Motion trigger during arming countdown (before armed) is ignored
    fakeDetector.emit(
      DetectorEvent(
        eventId: 'ignored_arming',
        sessionId: armingSessionId,
        detectorType: DetectorType.macosCameraSceneMotion,
        eventType: DetectorEventType.motionTriggered,
        timestamp: currentTime,
        summary: 'Ignored trigger during countdown',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ProtectionState.arming);
    expect(fakeAudio.loopingStartCount, 0);

    // Complete countdown -> armed
    for (var i = 0; i < 3; i++) {
      await controller.handleCountdownTickForSession(armingSessionId);
    }
    expect(controller.state, ProtectionState.armed);
    expect(await controller.startArming(), isFalse);

    // cancelArming when already armed is a no-op (requires PIN to disarm)
    await controller.cancelArming();
    expect(controller.state, ProtectionState.armed);

    // Trigger alarm -> alarming
    fakeDetector.emit(
      DetectorEvent(
        eventId: 'trigger_real',
        sessionId: armingSessionId,
        detectorType: DetectorType.macosCameraSceneMotion,
        eventType: DetectorEventType.motionTriggered,
        timestamp: currentTime,
        summary: 'Real trigger',
        motionScore: 0.30,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ProtectionState.alarming);
    expect(fakeAudio.loopingStartCount, 1);

    // Concurrent repeated PIN submissions do not cause duplicate stopAlarm calls
    final results = await Future.wait(<Future<PinVerificationResult>>[
      controller.verifyAndDisarm('246810'),
      controller.verifyAndDisarm('246810'),
    ]);
    expect(results[0].verified, isTrue);
    expect(results[1].verified, isTrue);
    expect(controller.state, ProtectionState.disarmed);
    expect(fakeAudio.isPlaying, isFalse);
    expect(fakeAudio.stopCount, 1);

    // Another sequential submission while already disarmed also avoids duplicate stopAlarm
    final extraDisarm = await controller.verifyAndDisarm('246810');
    expect(extraDisarm.verified, isTrue);
    expect(fakeAudio.stopCount, 1);
  });

  test('10. Minimize/suspend during arming or armed pauses cleanly, prevents duplicate streams on repeated resume, and stays paused if restart fails', () async {
    // A: Minimize mid-countdown (arming, before detector ever started)
    expect(await controller.startArming(), isTrue);
    final sessionId = controller.activeSessionId!;
    expect(controller.state, ProtectionState.arming);
    expect(fakeDetector.startCount, 0);

    await controller.handleAppLifecycleState(AppLifecycleState.hidden);
    expect(controller.state, ProtectionState.paused);
    expect(controller.state.isProtected, isFalse);

    // Stale countdown tick after pause is ignored
    await controller.handleCountdownTickForSession(sessionId);
    expect(controller.state, ProtectionState.paused);

    // Suppose camera is temporarily busy when app first resumes -> stays PAUSED
    fakeDetector.nextStartResult = const DetectorStartResult(
      started: false,
      status: CapabilityStatus.unsupported,
      message: 'Camera temporarily busy.',
      errorCode: 'CAMERA_BUSY',
    );
    await controller.handleAppLifecycleState(AppLifecycleState.resumed);
    expect(controller.state, ProtectionState.paused);
    expect(controller.state.isProtected, isFalse);
    expect(controller.warningMessage, contains('Resume Monitoring'));
    expect(fakeDetector.startCount, 1);

    // Camera becomes available; fire three concurrent resume signals
    fakeDetector.nextStartResult = const DetectorStartResult(
      started: true,
      status: CapabilityStatus.ready,
      message: 'Camera restarted.',
    );
    fakeDetector.emit(
      DetectorEvent(
        eventId: 'dup_resume_evt',
        sessionId: sessionId,
        detectorType: DetectorType.macosCameraSceneMotion,
        eventType: DetectorEventType.lifecycleResumed,
        timestamp: currentTime,
        summary: 'Native wake notification',
      ),
    );
    await Future.wait(<Future<void>>[
      controller.handleAppLifecycleState(AppLifecycleState.resumed),
      controller.handleAppLifecycleState(AppLifecycleState.resumed),
    ]);
    await Future<void>.delayed(Duration.zero);

    // Single-flight guard: only ONE additional startMonitoring call occurred!
    expect(controller.state, ProtectionState.armed);
    expect(controller.state.isProtected, isTrue);
    expect(fakeDetector.startCount, 2);
  });

  test('11. Minimize, suspend, and repeated resume during active alarm preserve alarming state, require PIN, and never duplicate sirens', () async {
    await armControllerToArmedState();
    final sessionId = controller.activeSessionId!;

    fakeDetector.emit(
      DetectorEvent(
        eventId: 'alarm_before_min',
        sessionId: sessionId,
        detectorType: DetectorType.macosCameraSceneMotion,
        eventType: DetectorEventType.motionTriggered,
        timestamp: currentTime,
        summary: 'Laptop moved sharply',
        motionScore: 0.35,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ProtectionState.alarming);
    expect(fakeAudio.isPlaying, isTrue);
    expect(fakeAudio.loopingStartCount, 1);

    // Minimize and resume repeatedly while siren is already playing
    await controller.handleAppLifecycleState(AppLifecycleState.hidden);
    expect(controller.state, ProtectionState.alarming);
    expect(fakeAudio.isPlaying, isTrue);

    await controller.handleAppLifecycleState(AppLifecycleState.resumed);
    await controller.handleAppLifecycleState(AppLifecycleState.resumed);
    expect(controller.state, ProtectionState.alarming);
    // Siren was still playing -> zero duplicate startLoopingAlarm calls
    expect(fakeAudio.loopingStartCount, 1);

    // Simulate OS/browser interrupting audio while backgrounded, plus autoplay block on resume
    await fakeAudio.stopAlarm();
    expect(fakeAudio.isPlaying, isFalse);
    await controller.handleAppLifecycleState(AppLifecycleState.paused);
    expect(controller.state, ProtectionState.alarming);
    expect(controller.warningMessage, contains('suspended audio'));

    fakeAudio.shouldThrowOnStart = true;
    await controller.handleAppLifecycleState(AppLifecycleState.resumed);
    expect(controller.state, ProtectionState.alarming);
    expect(fakeAudio.isPlaying, isFalse);
    expect(controller.warningMessage, contains('Resume Siren Audio'));

    // User taps Resume Siren Audio -> audio resumes
    fakeAudio.shouldThrowOnStart = false;
    await controller.resumeInterruptedAlarmAudio();
    expect(controller.state, ProtectionState.alarming);
    expect(fakeAudio.isPlaying, isTrue);

    // Normal PIN verification is still required to disarm
    final wrong = await controller.verifyAndDisarm('111111');
    expect(wrong.verified, isFalse);
    expect(controller.state, ProtectionState.alarming);
    expect(fakeAudio.isPlaying, isTrue);

    final right = await controller.verifyAndDisarm('246810');
    expect(right.verified, isTrue);
    expect(controller.state, ProtectionState.disarmed);
    expect(fakeAudio.isPlaying, isFalse);
  });

  test('12. Background-capable detector (Android Foreground Service) stays armed on app pause and exits armed if service stops', () async {
    final bgDetector = FakeMotionDetector(
      type: DetectorType.androidMotionSensors,
      supportsBackgroundMonitoring: true,
    );
    final bgController = AlarmController(
      detectors: <DetectorType, MotionDetectorAdapter>{
        DetectorType.androidMotionSensors: bgDetector,
      },
      audioAdapter: fakeAudio,
      pinService: pinService,
      incidentStorage: incidentStorage,
      settingsStorage: InMemorySettingsStorage(
        const ProtectionSettings(
          selectedDetector: DetectorType.androidMotionSensors,
          armingCountdownSeconds: 3,
          onboardingCompleted: true,
        ),
      ),
      notificationAdapter: notificationAdapter,
      clock: () => currentTime,
    );
    await bgController.initialize();

    expect(await bgController.startArming(), isTrue);
    final sessionId = bgController.activeSessionId!;
    for (var i = 0; i < 3; i++) {
      await bgController.handleCountdownTickForSession(sessionId);
    }
    expect(bgController.state, ProtectionState.armed);

    // Screen turns off / app enters background while foreground service is active
    await bgController.handleAppLifecycleState(AppLifecycleState.paused);
    expect(bgController.state, ProtectionState.armed);
    expect(bgDetector.stopCount, 0);

    // Foreground service stopped by user/OS -> transitions out of armed immediately
    bgDetector.emit(
      DetectorEvent(
        eventId: 'fgs_stopped',
        sessionId: sessionId,
        detectorType: DetectorType.androidMotionSensors,
        eventType: DetectorEventType.detectorFailed,
        timestamp: currentTime,
        summary: 'Foreground monitoring service was stopped.',
        errorCode: 'SERVICE_STOPPED',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(bgController.state, ProtectionState.unavailable);
    expect(bgController.state.isProtected, isFalse);

    bgController.dispose();
    await bgDetector.dispose();
  });

  group('PlatformSecurePinStorage', () {
    const testChannel = MethodChannel('dev.watsafe/test_secure_storage');
    late Directory tempDir;
    late File fallbackFile;

    const sampleRecord = StoredPinRecord(
      algorithm: 'PBKDF2-HMAC-SHA256',
      iterations: 20000,
      saltBase64: 'c2FsdF9ieXRlc18xMjM0NTY=',
      hashBase64: 'aGFzaF9ieXRlc18xMjM0NTY3ODkwYWJjZGVm',
      updatedAtUtcIso: '2026-10-30T12:00:00.000Z',
    );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('watsafe_pin_test_');
      fallbackFile = File(
        '${tempDir.path}${Platform.pathSeparator}watsafe_pin_hash.json',
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(testChannel, null);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      '1. Native write success does not create fallback file and reads from native channel',
      () async {
        String? nativeStoredPayload;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(testChannel, (MethodCall call) async {
              switch (call.method) {
                case 'writePinRecord':
                  final args = call.arguments as Map<Object?, Object?>?;
                  nativeStoredPayload = args?['payload'] as String?;
                  return 'macOS Security Keychain (PBKDF2-HMAC-SHA256)';
                case 'readPinRecord':
                  return nativeStoredPayload;
              }
              return null;
            });

        final storage = PlatformSecurePinStorage(
          channel: testChannel,
          fallbackDirectory: tempDir,
          supportsNativeChannelOverride: true,
        );

        await storage.writePinRecord(sampleRecord);

        expect(await fallbackFile.exists(), isFalse);
        expect(
          storage.storageBackendDescription,
          'macOS Security Keychain (PBKDF2-HMAC-SHA256)',
        );

        final loaded = await storage.readPinRecord();
        expect(loaded, isNotNull);
        expect(loaded!.algorithm, sampleRecord.algorithm);
        expect(loaded.iterations, sampleRecord.iterations);
        expect(loaded.saltBase64, sampleRecord.saltBase64);
        expect(loaded.hashBase64, sampleRecord.hashBase64);
        expect(loaded.updatedAtUtcIso, sampleRecord.updatedAtUtcIso);
        expect(
          storage.storageBackendDescription,
          'macOS Security Keychain (PBKDF2-HMAC-SHA256)',
        );
      },
    );

    test(
      '2. Native write success removes any pre-existing stale fallback file',
      () async {
        var shouldFailNativeWrite = true;
        String? nativeStoredPayload;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(testChannel, (MethodCall call) async {
              if (call.method == 'writePinRecord') {
                if (shouldFailNativeWrite) {
                  throw PlatformException(
                    code: 'DPAPI_WRITE_FAILED',
                    message: 'Simulated native storage failure',
                  );
                }
                final args = call.arguments as Map<Object?, Object?>?;
                nativeStoredPayload = args?['payload'] as String?;
                return 'Windows DPAPI (CryptProtectData PBKDF2-HMAC-SHA256)';
              }
              if (call.method == 'readPinRecord') {
                return nativeStoredPayload;
              }
              return null;
            });

        final storage = PlatformSecurePinStorage(
          channel: testChannel,
          fallbackDirectory: tempDir,
          supportsNativeChannelOverride: true,
        );

        // First write fails natively -> creates fallback file
        await storage.writePinRecord(sampleRecord);
        expect(await fallbackFile.exists(), isTrue);
        expect(
          storage.storageBackendDescription,
          'Local Restricted Storage (0600 PBKDF2-SHA256)',
        );

        // Second write succeeds natively -> deletes stale fallback file
        shouldFailNativeWrite = false;
        await storage.writePinRecord(sampleRecord);
        expect(await fallbackFile.exists(), isFalse);
        expect(
          storage.storageBackendDescription,
          'Windows DPAPI (CryptProtectData PBKDF2-HMAC-SHA256)',
        );
      },
    );

    test(
      '3. Native write failure (PlatformException and MissingPluginException) falls back to local file',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(testChannel, (MethodCall call) async {
              throw PlatformException(
                code: 'KEYSTORE_WRITE_FAILED',
                message: 'Simulated keystore error',
              );
            });

        final storage = PlatformSecurePinStorage(
          channel: testChannel,
          fallbackDirectory: tempDir,
          supportsNativeChannelOverride: true,
        );

        await storage.writePinRecord(sampleRecord);
        expect(await fallbackFile.exists(), isTrue);
        expect(
          storage.storageBackendDescription,
          'Local Restricted Storage (0600 PBKDF2-SHA256)',
        );

        final loadedFromPlatformExceptionFallback = await storage
            .readPinRecord();
        expect(loadedFromPlatformExceptionFallback, isNotNull);
        expect(
          loadedFromPlatformExceptionFallback!.hashBase64,
          sampleRecord.hashBase64,
        );

        // Verify MissingPluginException also falls back cleanly
        await fallbackFile.delete();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(testChannel, null);

        await storage.writePinRecord(sampleRecord);
        expect(await fallbackFile.exists(), isTrue);

        final loadedFromMissingPluginFallback = await storage.readPinRecord();
        expect(loadedFromMissingPluginFallback, isNotNull);
        expect(
          loadedFromMissingPluginFallback!.saltBase64,
          sampleRecord.saltBase64,
        );
      },
    );

    test('4. deletePinRecord removes both native and fallback records', () async {
      String? nativeStoredPayload = '{"algorithm":"PBKDF2-HMAC-SHA256"}';
      var nativeDeleteCalled = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(testChannel, (MethodCall call) async {
            switch (call.method) {
              case 'readPinRecord':
                return nativeStoredPayload;
              case 'deletePinRecord':
                nativeDeleteCalled = true;
                nativeStoredPayload = null;
                return null;
            }
            return null;
          });

      final storage = PlatformSecurePinStorage(
        channel: testChannel,
        fallbackDirectory: tempDir,
        supportsNativeChannelOverride: false,
      );
      // Write to fallback file first
      await storage.writePinRecord(sampleRecord);
      expect(await fallbackFile.exists(), isTrue);

      // Now use native-enabled instance to delete both native and fallback records
      final nativeStorage = PlatformSecurePinStorage(
        channel: testChannel,
        fallbackDirectory: tempDir,
        supportsNativeChannelOverride: true,
      );
      await nativeStorage.deletePinRecord();

      expect(nativeDeleteCalled, isTrue);
      expect(nativeStoredPayload, isNull);
      expect(await fallbackFile.exists(), isFalse);
      expect(await nativeStorage.readPinRecord(), isNull);
    });
  });
}
