import 'dart:async';

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

      // 2. Arm protection from Dashboard UI
      expect(find.text('DISARMED'), findsWidgets);
      await tester.tap(find.byKey(const Key('arm_protection_button')));
      await tester.pump();
      expect(controller.state, ProtectionState.arming);

      // Advance countdown 3s -> transitions to ARMED / PROTECTED
      // (Avoid pumpAndSettle while Protected because WatSafeShieldGraphic runs a continuous wave animation.)
      final armSessionId = controller.activeSessionId!;
      await tester.pump(const Duration(seconds: 3));
      while (controller.state == ProtectionState.arming &&
          controller.activeSessionId == armSessionId) {
        await controller.handleCountdownTickForSession(armSessionId);
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.state, ProtectionState.armed);
      expect(find.text('PROTECTED'), findsWidgets);

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
      expect(find.text('ALARM ACTIVE — SIREN SOUNDING'), findsOneWidget);
      expect(find.text('Laptop lifted from desk'), findsOneWidget);
      expect(audioService.isPlaying, isTrue);
      expect(nativeAudioCalls, contains('startLoopingAlarm'));
      expect(nativeAudioCalls, isNot(contains('stopAlarm')));

      // 4. Submit an INCORRECT PIN in ActiveAlarmScreen -> alarm & siren stay active
      // (Use Scrollable.ensureVisible + pump instead of tester.ensureVisible, because
      // tester.ensureVisible calls pumpAndSettle while ActiveAlarmScreen runs its live wave animation.)
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
      expect(find.text('ALARM ACTIVE — SIREN SOUNDING'), findsOneWidget);
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
      expect(find.text('ALARM ACTIVE — SIREN SOUNDING'), findsNothing);
      expect(find.text('DISARMED'), findsWidgets);
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

  test(
    'PlatformAudioAlarmService cancels native siren when stopAlarm runs during in-flight channel startup',
    () async {
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
    },
  );
}
