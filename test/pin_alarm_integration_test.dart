import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/main.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

import 'alarm_controller_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const audioChannel = MethodChannel('dev.watsafe/test_pin_audio_boundary');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioChannel, null);
  });

  testWidgets(
    'Real PIN entry UI -> AlarmController -> PlatformAudioAlarmService boundary & IncidentStorageAdapter',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 850));

      final nativeAudioCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioChannel, (MethodCall call) async {
            nativeAudioCalls.add(call.method);
            return null;
          });

      final audioService = PlatformAudioAlarmService(
        channel: audioChannel,
        assetLoader: () async => Uint8List.fromList(<int>[82, 73, 70, 70]),
      );
      final fakeDetector = FakeMotionDetector(
        type: DetectorType.macosCameraSceneMotion,
        supportsBackgroundMonitoring: true,
      );
      final pinStorage = InMemorySecurePinStorage();
      final pinService = PinSecurityService(
        storage: pinStorage,
        pbkdf2Iterations: 500,
      );
      final incidentStorage = InMemoryIncidentStorage();
      final settingsStorage = InMemorySettingsStorage(
        const ProtectionSettings(
          selectedDetector: DetectorType.macosCameraSceneMotion,
          armingCountdownSeconds: 3,
        ),
      );

      final controller = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.macosCameraSceneMotion: fakeDetector,
        },
        audioAdapter: audioService,
        pinService: pinService,
        incidentStorage: incidentStorage,
        settingsStorage: settingsStorage,
        notificationAdapter: const UnconfiguredRemoteNotificationService(),
      );
      addTearDown(() async {
        controller.dispose();
        await fakeDetector.dispose();
      });

      await controller.initialize();
      await tester.pumpWidget(WatSafeApp(controller: controller));
      await tester.pumpAndSettle();

      // 1. Complete first-run PIN setup through real OnboardingScreen UI
      expect(find.text('Welcome to WATSafe'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('onboarding_pin_input')),
        '246810',
      );
      await tester.enterText(
        find.byKey(const Key('onboarding_confirm_pin_input')),
        '246810',
      );
      await tester.tap(find.byKey(const Key('onboarding_complete_button')));
      await tester.pumpAndSettle();

      // 2. Arm protection from Home UI
      expect(find.text('Off'), findsWidgets);
      await tester.tap(find.byKey(const Key('arm_protection_button')));
      await tester.pump();
      expect(controller.state, ProtectionState.arming);

      // Advance countdown 3s -> transitions to ARMED / Protected
      final armSessionId = controller.activeSessionId!;
      await tester.pump(const Duration(seconds: 3));
      while (controller.state == ProtectionState.arming &&
          controller.activeSessionId == armSessionId) {
        await controller.handleCountdownTickForSession(armSessionId);
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.state, ProtectionState.armed);
      expect(find.text('Protected'), findsWidgets);

      // 3. Trigger motion -> transitions to ALARMING and plays looping siren
      final sessionId = controller.activeSessionId!;
      fakeDetector.emit(
        DetectorEvent(
          eventId: 'it_trigger_1',
          sessionId: sessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: DateTime.utc(2026, 11, 13, 15, 0, 0),
          summary: 'Laptop lifted from desk',
          motionScore: 0.31,
          threshold: 0.095,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Verify visible ActiveAlarmScreen UI and native startLoopingAlarm call
      expect(controller.state, ProtectionState.alarming);
      expect(find.text('Alarm triggered'), findsWidgets);
      expect(find.text('Laptop lifted from desk'), findsOneWidget);
      expect(audioService.isPlaying, isTrue);
      expect(nativeAudioCalls, contains('startLoopingAlarm'));
      expect(nativeAudioCalls, isNot(contains('stopAlarm')));

      // 4. Submit an INCORRECT PIN in ActiveAlarmScreen -> alarm & siren stay active
      final pinField = find.byKey(const Key('alarm_pin_input'));
      final disarmBtn = find.byKey(const Key('alarm_disarm_button'));
      await Scrollable.ensureVisible(tester.element(pinField));
      await tester.pump();
      await tester.tap(pinField);
      await tester.pump();
      await tester.enterText(pinField, '999999');
      await tester.pump();
      await Scrollable.ensureVisible(tester.element(disarmBtn));
      await tester.pump();
      await tester.tap(disarmBtn);
      for (var i = 0; i < 30 && controller.failedPinAttempts == 0; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.state, ProtectionState.alarming);
      expect(find.text('Alarm triggered'), findsWidgets);
      expect(find.textContaining('Incorrect PIN'), findsWidgets);
      expect(audioService.isPlaying, isTrue);
      expect(nativeAudioCalls, isNot(contains('stopAlarm')));

      // 5. Submit the CORRECT PIN in ActiveAlarmScreen -> stops siren & disarms
      await Scrollable.ensureVisible(tester.element(pinField));
      await tester.pump();
      await tester.tap(pinField);
      await tester.pump();
      await tester.enterText(pinField, '246810');
      await tester.pump();
      await Scrollable.ensureVisible(tester.element(disarmBtn));
      await tester.pump();
      await tester.tap(disarmBtn);
      // Allow async PBKDF2 verification to complete and exit ActiveAlarmScreen
      for (
        var i = 0;
        i < 40 && controller.state == ProtectionState.alarming;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.state, ProtectionState.disarmed);
      expect(find.text('Alarm triggered'), findsNothing);
      expect(find.text('Off'), findsWidgets);
      expect(audioService.isPlaying, isFalse);
      expect(nativeAudioCalls.where((m) => m == 'stopAlarm').length, equals(1));

      // Verify persisted incident resolution in IncidentStorageAdapter
      final savedIncidents = await incidentStorage.loadIncidents();
      expect(savedIncidents, hasLength(1));
      expect(savedIncidents.first.resolvedAt, isNotNull);
      expect(
        savedIncidents.first.resolutionSummary,
        'Disarmed with verified PIN',
      );
    },
  );

  test('PlatformAudioAlarmService cancels native siren when stopAlarm runs during in-flight channel startup', () async {
    final startGate = Completer<void>();
    final calls = <String>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioChannel, (MethodCall call) async {
          calls.add(call.method);
          if (call.method == 'startLoopingAlarm') {
            await startGate.future;
          }
          return null;
        });

    final audioService = PlatformAudioAlarmService(
      channel: audioChannel,
      assetLoader: () async => Uint8List.fromList(<int>[82, 73, 70, 70]),
    );

    final startFuture = audioService.startLoopingAlarm(volume: 0.85);
    await Future<void>.delayed(Duration.zero);
    expect(calls, <String>['startLoopingAlarm']);
    expect(audioService.isPlaying, isTrue);

    // Disarm stops the alarm before native startLoopingAlarm completes
    await audioService.stopAlarm();
    expect(audioService.isPlaying, isFalse);

    // Complete the pending native startLoopingAlarm call
    startGate.complete();
    await startFuture;

    // PlatformAudioAlarmService must remain stopped and send a compensating stopAlarm
    expect(audioService.isPlaying, isFalse);
    expect(calls.last, 'stopAlarm');
  });

  test('PlatformSecurePinStorage uses native storage without a duplicate fallback', () async {
    const secureChannel = MethodChannel('dev.watsafe/test_secure_storage');
    final tempDir = await Directory.systemTemp.createTemp(
      'watsafe_pin_merge_test_',
    );
    final fallbackFile = File(
      '${tempDir.path}${Platform.pathSeparator}watsafe_pin_hash.json',
    );
    String? nativeStoredPayload;
    var simulateNativeChannelUnavailableOnRead = false;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureChannel, (MethodCall call) async {
          switch (call.method) {
            case 'writePinRecord':
              final args = call.arguments as Map<Object?, Object?>?;
              nativeStoredPayload = args?['payload'] as String?;
              return 'Native Keychain/Keystore Test Adapter';
            case 'readPinRecord':
              if (simulateNativeChannelUnavailableOnRead) {
                return null;
              }
              return nativeStoredPayload;
            case 'deletePinRecord':
              nativeStoredPayload = null;
              return null;
          }
          return null;
        });

    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureChannel, null);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final pinStorage = PlatformSecurePinStorage(
      channel: secureChannel,
      fallbackDirectory: tempDir,
    );
    final pinService = PinSecurityService(
      storage: pinStorage,
      pbkdf2Iterations: 500,
    );
    final fakeDetector = FakeMotionDetector(
      type: DetectorType.macosCameraSceneMotion,
    );
    final fakeAudio = FakeAudioAlarmAdapter();
    final controller = AlarmController(
      detectors: <DetectorType, MotionDetectorAdapter>{
        DetectorType.macosCameraSceneMotion: fakeDetector,
      },
      audioAdapter: fakeAudio,
      pinService: pinService,
      incidentStorage: InMemoryIncidentStorage(),
      settingsStorage: InMemorySettingsStorage(
        const ProtectionSettings(
          selectedDetector: DetectorType.macosCameraSceneMotion,
          armingCountdownSeconds: 1,
        ),
      ),
      notificationAdapter: const UnconfiguredRemoteNotificationService(),
    );
    addTearDown(() async {
      controller.dispose();
      await fakeDetector.dispose();
    });

    await controller.initialize();
    expect(controller.hasPinConfigured, isFalse);

    // 1. Onboarding PIN setup writes to native secure storage only.
    final setupRes = await controller.setupInitialPin(
      pin: '314159',
      confirmPin: '314159',
    );
    expect(setupRes.isValid, isTrue);
    expect(controller.hasPinConfigured, isTrue);
    expect(nativeStoredPayload, isNotNull);
    expect(await fallbackFile.exists(), isFalse);

    // 2. Arm and trigger alarm, then disarm via native channel read
    await controller.startArming();
    final sid1 = controller.activeSessionId!;
    while (controller.state == ProtectionState.arming &&
        controller.activeSessionId == sid1) {
      await controller.handleCountdownTickForSession(sid1);
    }
    expect(controller.state, ProtectionState.armed);
    fakeDetector.emit(
      DetectorEvent(
        eventId: 'pin_store_trig_1',
        sessionId: sid1,
        detectorType: DetectorType.macosCameraSceneMotion,
        eventType: DetectorEventType.motionTriggered,
        timestamp: DateTime.utc(2026, 11, 15, 18, 0, 0),
        summary: 'Tamper trigger 1',
        motionScore: 0.42,
        threshold: 0.095,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.state, ProtectionState.alarming);

    final disarm1 = await controller.verifyAndDisarm('314159');
    expect(disarm1.verified, isTrue);
    expect(controller.state, ProtectionState.disarmed);
    expect(fakeAudio.stopCount, greaterThanOrEqualTo(1));

    // 3. When native reads become unavailable, do not fall back to a duplicate
    // file that was intentionally not created after native storage succeeded.
    simulateNativeChannelUnavailableOnRead = true;
    expect(await controller.startArming(), isFalse);
    expect(controller.activeSessionId, isNull);
    expect(controller.hasPinConfigured, isFalse);
    expect(
      controller.warningMessage,
      contains('Create a 6-digit (or longer) PIN'),
    );
    expect(await fallbackFile.exists(), isFalse);

    // Restore native reads and confirm protection can be armed and disarmed.
    simulateNativeChannelUnavailableOnRead = false;
    expect(await controller.startArming(), isTrue);
    final sid2 = controller.activeSessionId!;
    while (controller.state == ProtectionState.arming &&
        controller.activeSessionId == sid2) {
      await controller.handleCountdownTickForSession(sid2);
    }
    expect(controller.state, ProtectionState.armed);
    fakeDetector.emit(
      DetectorEvent(
        eventId: 'pin_store_trig_2',
        sessionId: sid2,
        detectorType: DetectorType.macosCameraSceneMotion,
        eventType: DetectorEventType.motionTriggered,
        timestamp: DateTime.utc(2026, 11, 15, 18, 5, 0),
        summary: 'Tamper trigger 2',
        motionScore: 0.45,
        threshold: 0.095,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.state, ProtectionState.alarming);

    final disarm2 = await controller.verifyAndDisarm('314159');
    expect(disarm2.verified, isTrue);
    expect(controller.state, ProtectionState.disarmed);
  });
}
