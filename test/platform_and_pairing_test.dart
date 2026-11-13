import 'dart:convert';
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
import 'package:watsafe/platform/mobile/android_motion_detector.dart';
import 'package:watsafe/platform/mobile/ios_motion_detector.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

import '../backend/server.dart';
import 'alarm_controller_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android & iOS Mobile Detector Adapters', () {
    const androidMethodChannel = MethodChannel(
      'dev.watsafe/test_android_motion',
    );
    const androidEventChannel = EventChannel(
      'dev.watsafe/test_android_motion_events',
    );
    const iosMethodChannel = MethodChannel('dev.watsafe/test_ios_motion');
    const iosEventChannel = EventChannel('dev.watsafe/test_ios_motion_events');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(androidMethodChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(androidEventChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(iosMethodChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(iosEventChannel, null);
    });

    test(
      'AndroidMotionDetectorAdapter reports ready and streams calibration & trigger events',
      () async {
        MockStreamHandlerEventSink? eventSink;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(androidMethodChannel, (
              MethodCall call,
            ) async {
              switch (call.method) {
                case 'checkCapability':
                  return <String, Object?>{
                    'hasMotionHardware': true,
                    'deviceName': 'Bosch BMI260 Linear Accelerometer',
                    'permissionStatus': 'granted',
                    'detail': 'Android SensorManager ready.',
                  };
                case 'startMonitoring':
                  return <String, Object?>{
                    'started': true,
                    'message':
                        'Monitoring active on Bosch BMI260 Linear Accelerometer.',
                  };
                case 'updateSensitivity':
                case 'stopMonitoring':
                  return null;
              }
              return null;
            });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
              androidEventChannel,
              MockStreamHandler.inline(
                onListen:
                    (Object? arguments, MockStreamHandlerEventSink events) {
                      eventSink = events;
                    },
              ),
            );

        final adapter = AndroidMotionDetectorAdapter(
          methodChannel: androidMethodChannel,
          eventChannel: androidEventChannel,
          isAndroidOverride: true,
        );

        final cap = await adapter.checkCapability();
        expect(cap.status, CapabilityStatus.ready);
        expect(cap.canArm, isTrue);
        expect(cap.hardwareDeviceName, 'Bosch BMI260 Linear Accelerometer');

        final received = <DetectorEvent>[];
        final sub = adapter.events.listen(received.add);

        final startRes = await adapter.startMonitoring(
          const MonitorConfig(sessionId: 'android_sess_1', sensitivity: 0.7),
        );
        expect(startRes.started, isTrue);

        eventSink?.success(<String, Object?>{
          'sessionId': 'android_sess_1',
          'eventType': 'motionTriggered',
          'summary': 'Android motion trigger (score 0.290 >= threshold 0.088)',
          'motionScore': 0.29,
          'threshold': 0.088,
          'consecutiveFrames': 3,
          'timestampMs': 1730000001000,
        });

        await Future<void>.delayed(Duration.zero);
        expect(received, hasLength(1));
        expect(received.first.eventType, DetectorEventType.motionTriggered);
        expect(received.first.detectorType, DetectorType.androidMotionSensors);

        await sub.cancel();
        await adapter.dispose();
      },
    );

    test(
      'IosCoreMotionDetectorAdapter reports ready and handles foreground lifecycle pause/resume',
      () async {
        MockStreamHandlerEventSink? eventSink;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(iosMethodChannel, (
              MethodCall call,
            ) async {
              switch (call.method) {
                case 'checkCapability':
                  return <String, Object?>{
                    'hasMotionHardware': true,
                    'deviceName': 'Apple Core Motion IMU',
                    'permissionStatus': 'granted',
                    'detail': 'CMMotionManager ready.',
                  };
                case 'startMonitoring':
                  return <String, Object?>{
                    'started': true,
                    'message': 'Foreground Core Motion monitoring active.',
                  };
                case 'stopMonitoring':
                  return null;
              }
              return null;
            });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
              iosEventChannel,
              MockStreamHandler.inline(
                onListen:
                    (Object? arguments, MockStreamHandlerEventSink events) {
                      eventSink = events;
                    },
              ),
            );

        final adapter = IosCoreMotionDetectorAdapter(
          methodChannel: iosMethodChannel,
          eventChannel: iosEventChannel,
          isIOSOverride: true,
        );

        final cap = await adapter.checkCapability();
        expect(cap.status, CapabilityStatus.ready);
        expect(cap.canArm, isTrue);

        final received = <DetectorEvent>[];
        final sub = adapter.events.listen(received.add);

        final startRes = await adapter.startMonitoring(
          const MonitorConfig(sessionId: 'ios_sess_1', sensitivity: 0.6),
        );
        expect(startRes.started, isTrue);

        eventSink?.success(<String, Object?>{
          'sessionId': 'ios_sess_1',
          'eventType': 'lifecyclePaused',
          'summary': 'iOS app left foreground; Core Motion paused.',
          'timestampMs': 1730000002000,
        });
        eventSink?.success(<String, Object?>{
          'sessionId': 'ios_sess_1',
          'eventType': 'lifecycleResumed',
          'summary': 'iOS app returned to foreground; Core Motion resumed.',
          'timestampMs': 1730000003000,
        });

        await Future<void>.delayed(Duration.zero);
        expect(received, hasLength(2));
        expect(received[0].eventType, DetectorEventType.lifecyclePaused);
        expect(received[1].eventType, DetectorEventType.lifecycleResumed);

        await sub.cancel();
        await adapter.dispose();
      },
    );

    test(
      'AndroidMotionDetectorAdapter bridges foreground motion sensors from a paired Android companion on non-Android hosts',
      () async {
        final notificationService = ConfigurableRemoteNotificationService(
          persistToDisk: false,
        );
        final adapter = AndroidMotionDetectorAdapter(
          isAndroidOverride: false,
          notificationAdapter: notificationService,
        );

        // Without a paired Android device, capability is unsupported
        var cap = await adapter.checkCapability();
        expect(cap.status, CapabilityStatus.unsupported);

        // Pair an Android device
        final paired = await notificationService.pairDevice(
          displayName: 'Aidan\'s Pixel 9',
          platform: 'Android (FCM)',
          pairingCode: 'WAT-777',
        );

        // Now AndroidMotionDetectorAdapter is ready via Paired Android Companion Sensor Bridging
        cap = await adapter.checkCapability();
        expect(cap.status, CapabilityStatus.ready);
        expect(cap.canArm, isTrue);
        expect(
          cap.hardwareDeviceName,
          contains('Aidan\'s Pixel 9 (Android Foreground Service)'),
        );

        // Pause sensor forwarding and verify permissionRequired state + requestPermission re-enable
        await notificationService.sendDeviceCommand(
          deviceId: paired.deviceId,
          command: PairedDeviceCommandType.toggleRemoteSensorForwarding,
        );
        cap = await adapter.checkCapability();
        expect(cap.status, CapabilityStatus.permissionRequired);

        final perm = await adapter.requestPermission();
        expect(perm, PermissionStatus.granted);
        cap = await adapter.checkCapability();
        expect(cap.status, CapabilityStatus.ready);

        // Start monitoring and trigger companion motion tamper
        final received = <DetectorEvent>[];
        final sub = adapter.events.listen(received.add);

        final startRes = await adapter.startMonitoring(
          const MonitorConfig(
            sessionId: 'bridged_android_sess_1',
            sensitivity: 0.7,
          ),
        );
        expect(startRes.started, isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          received.any(
            (e) => e.eventType == DetectorEventType.calibrationCompleted,
          ),
          isTrue,
        );

        await notificationService.sendDeviceCommand(
          deviceId: paired.deviceId,
          command: PairedDeviceCommandType.simulateCompanionMotionTrigger,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(
          received.any((e) => e.eventType == DetectorEventType.motionTriggered),
          isTrue,
        );

        await sub.cancel();
        await adapter.dispose();
      },
    );
  });

  group('Dynamic Permission Button Label & Icon', () {
    testWidgets(
      'Displays Grant Motion Sensor Permission for non-camera detectors and Grant Camera Permission for camera detectors',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 800));

        final accelDetector = FakeMotionDetector(
          type: DetectorType.windowsAccelerometer,
          initialCapability: const DetectorCapability(
            type: DetectorType.windowsAccelerometer,
            status: CapabilityStatus.permissionRequired,
            permissionStatus: PermissionStatus.denied,
            summary: 'Motion sensor permission required.',
          ),
        );
        final camDetector = FakeMotionDetector(
          type: DetectorType.windowsCameraSceneMotion,
          initialCapability: const DetectorCapability(
            type: DetectorType.windowsCameraSceneMotion,
            status: CapabilityStatus.permissionRequired,
            permissionStatus: PermissionStatus.denied,
            summary: 'Camera permission required.',
          ),
        );

        final pinStorage = InMemorySecurePinStorage();
        final pinService = PinSecurityService(
          storage: pinStorage,
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '123456', confirmPin: '123456');

        final controller = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.windowsAccelerometer: accelDetector,
            DetectorType.windowsCameraSceneMotion: camDetector,
          },
          audioAdapter: FakeAudioAlarmAdapter(),
          pinService: pinService,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: InMemorySettingsStorage(
            const ProtectionSettings(
              selectedDetector: DetectorType.windowsAccelerometer,
              onboardingCompleted: true,
            ),
          ),
          notificationAdapter: const UnconfiguredRemoteNotificationService(),
        );

        await controller.initialize();
        // Force selection back to windowsAccelerometer to verify its permission button label
        await controller.selectDetector(DetectorType.windowsAccelerometer);

        await tester.pumpWidget(WatSafeApp(controller: controller));
        await tester.pumpAndSettle();

        expect(find.text('Grant Motion Sensor Permission'), findsOneWidget);
        expect(find.text('Grant Camera Permission'), findsNothing);

        // Switch to camera detector and verify label switches to Grant Camera Permission
        await controller.selectDetector(DetectorType.windowsCameraSceneMotion);
        await tester.pumpAndSettle();

        expect(find.text('Grant Camera Permission'), findsOneWidget);
        expect(find.text('Grant Motion Sensor Permission'), findsNothing);

        controller.dispose();
        await accelDetector.dispose();
        await camDetector.dispose();
      },
    );
  });

  group('Remote Device Pairing & Live HTTP Relay Server Integration', () {
    late WatSafeRelayServer relayServer;
    late int relayPort;

    setUp(() async {
      HttpOverrides.global = null;
      relayServer = WatSafeRelayServer();
      relayPort = await relayServer.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
    });

    tearDown(() async {
      await relayServer.stop();
    });

    test(
      'ConfigurableRemoteNotificationService pairs device, dispatches incident over HTTP relay, and enforces privacy boundary',
      () async {
        final notificationService = ConfigurableRemoteNotificationService(
          persistToDisk: false,
          initialRelayEndpointUrl: 'http://127.0.0.1:$relayPort',
        );

        final fakeDetector = FakeMotionDetector(
          type: DetectorType.windowsCameraSceneMotion,
        );
        final fakeAudio = FakeAudioAlarmAdapter();
        final pinStorage = InMemorySecurePinStorage();
        final pinService = PinSecurityService(
          storage: pinStorage,
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '654321', confirmPin: '654321');

        final controller = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.windowsCameraSceneMotion: fakeDetector,
          },
          audioAdapter: fakeAudio,
          pinService: pinService,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: InMemorySettingsStorage(
            const ProtectionSettings(
              selectedDetector: DetectorType.windowsCameraSceneMotion,
              armingCountdownSeconds: 1,
              onboardingCompleted: true,
            ),
          ),
          notificationAdapter: notificationService,
        );

        await controller.initialize();
        expect(
          controller.notificationStatus.capabilityStatus,
          CapabilityStatus.degraded,
        );

        // Pair a companion phone
        final paired = await controller.pairCompanionDevice(
          displayName: 'Aidan\'s S24',
          platform: 'Android (FCM)',
          pairingCode: 'WAT-999',
        );
        expect(paired, isNotNull);
        expect(controller.pairedDevices, hasLength(1));
        expect(
          controller.notificationStatus.capabilityStatus,
          CapabilityStatus.ready,
        );
        expect(relayServer.pairedDevices, hasLength(1));

        // Arm and trigger a real alarm
        await controller.startArming();
        final sessionId = controller.activeSessionId!;
        await controller.handleCountdownTickForSession(sessionId);
        expect(controller.state, ProtectionState.armed);

        fakeDetector.emit(
          DetectorEvent(
            eventId: 'evt_trigger_1',
            sessionId: sessionId,
            detectorType: DetectorType.windowsCameraSceneMotion,
            eventType: DetectorEventType.motionTriggered,
            timestamp: DateTime.utc(2026, 11, 13, 4, 0, 0),
            summary: 'Sustained global camera ego-motion detected',
            motionScore: 0.34,
            threshold: 0.095,
            consecutiveAboveThresholdFrames: 3,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(controller.state, ProtectionState.alarming);
        expect(relayServer.reportedIncidents, hasLength(1));
        expect(controller.activeIncident?.remoteNotificationAttempted, isTrue);
        expect(
          controller.activeIncident?.remoteNotificationStatus,
          contains('Delivered via HTTP relay to 1 paired device(s)'),
        );

        // Verify relay server rejects payloads violating privacy boundary (camera frames or PINs)
        final client = HttpClient();
        final req = await client.postUrl(
          Uri.parse('http://127.0.0.1:$relayPort/v1/incidents:report'),
        );
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode(<String, Object?>{
            'incidentId': 'bad_inc_1',
            'frameBytes': 'base64_camera_frame_leak',
          }),
        );
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.badRequest);
        await resp.drain<void>();
        client.close(force: true);

        controller.dispose();
        await fakeDetector.dispose();
      },
    );

    testWidgets(
      'PairedDevicesScreen interactively pairs and unpairs a companion device',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 900));

        final fakeDetector = FakeMotionDetector();
        final pinStorage = InMemorySecurePinStorage();
        final pinService = PinSecurityService(
          storage: pinStorage,
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '112233', confirmPin: '112233');

        final controller = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.macosCameraSceneMotion: fakeDetector,
          },
          audioAdapter: FakeAudioAlarmAdapter(),
          pinService: pinService,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: InMemorySettingsStorage(
            const ProtectionSettings(
              selectedDetector: DetectorType.macosCameraSceneMotion,
              onboardingCompleted: true,
            ),
          ),
          notificationAdapter: ConfigurableRemoteNotificationService(
            persistToDisk: false,
          ),
        );

        await controller.initialize();
        await tester.pumpWidget(WatSafeApp(controller: controller));
        await tester.pumpAndSettle();

        // Open Paired Devices tab
        await tester.tap(find.text('Paired Devices'));
        await tester.pumpAndSettle();

        // Initially unconfigured
        expect(
          find.text('No Paired Devices (Service Not Configured)'),
          findsOneWidget,
        );

        // Enter companion device name and tap Pair Companion Device
        await tester.enterText(
          find.byKey(const Key('pair_device_name_input')),
          'Aidan\'s S24',
        );
        final pairBtn = find.byKey(const Key('pair_device_submit_button'));
        await tester.ensureVisible(pairBtn);
        await tester.tap(pairBtn);
        await tester.pumpAndSettle();

        expect(find.text('Aidan\'s S24'), findsOneWidget);
        expect(find.text('PUSH READY'), findsOneWidget);
        expect(controller.pairedDevices, hasLength(1));

        final deviceId = controller.pairedDevices.first.deviceId;

        // 1. Send Test Alert to paired device
        final testPushBtn = find.byKey(Key('cmd_test_push_$deviceId'));
        await tester.ensureVisible(testPushBtn);
        await tester.tap(testPushBtn);
        await tester.pumpAndSettle();
        expect(controller.pairedDeviceActions, isNotEmpty);
        expect(
          controller.pairedDeviceActions.first.commandType,
          PairedDeviceCommandType.sendTestPush,
        );
        expect(
          find.byKey(const Key('paired_device_activity_log_card')),
          findsOneWidget,
        );

        // 2. Ring / Locate paired device and verify badge updates to RINGING
        final ringBtn = find.byKey(Key('cmd_ring_$deviceId'));
        await tester.ensureVisible(ringBtn);
        await tester.tap(ringBtn);
        await tester.pumpAndSettle();
        expect(controller.pairedDevices.first.isRingingRemotely, isTrue);
        expect(find.text('RINGING'), findsOneWidget);
        expect(find.text('Stop Ringing'), findsOneWidget);

        // Stop ringing
        await tester.tap(ringBtn);
        await tester.pumpAndSettle();
        expect(controller.pairedDevices.first.isRingingRemotely, isFalse);

        // 3. Sync Protection Status to paired device
        final syncBtn = find.byKey(Key('cmd_sync_$deviceId'));
        await tester.ensureVisible(syncBtn);
        await tester.tap(syncBtn);
        await tester.pumpAndSettle();
        expect(
          controller.pairedDeviceActions.first.commandType,
          PairedDeviceCommandType.syncProtectionState,
        );

        // 4. Toggle Foreground Sensor Link
        final sensorBtn = find.byKey(Key('cmd_toggle_sensor_$deviceId'));
        await tester.ensureVisible(sensorBtn);
        await tester.tap(sensorBtn);
        await tester.pumpAndSettle();
        expect(
          controller.pairedDevices.first.remoteSensorForwardingEnabled,
          isFalse,
        );
        expect(find.text('SENSOR LINK PAUSED'), findsOneWidget);

        // Re-enable Foreground Sensor Link
        await tester.tap(sensorBtn);
        await tester.pumpAndSettle();
        expect(
          controller.pairedDevices.first.remoteSensorForwardingEnabled,
          isTrue,
        );
        expect(find.text('SENSOR LINK ACTIVE'), findsOneWidget);

        // Unpair the device
        final unpairBtn = find.byKey(Key('unpair_device_$deviceId'));
        await tester.ensureVisible(unpairBtn);
        await tester.tap(unpairBtn);
        await tester.pumpAndSettle();

        expect(controller.pairedDevices, isEmpty);

        controller.dispose();
        await fakeDetector.dispose();
      },
    );
  });
}
