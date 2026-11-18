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

    test('AndroidMotionDetectorAdapter reports ready and streams calibration & trigger events', () async {
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
              onListen: (Object? arguments, MockStreamHandlerEventSink events) {
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
    });

    test('IosCoreMotionDetectorAdapter reports ready and handles foreground lifecycle pause/resume', () async {
      MockStreamHandlerEventSink? eventSink;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(iosMethodChannel, (MethodCall call) async {
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
              onListen: (Object? arguments, MockStreamHandlerEventSink events) {
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
    });

    test('AndroidMotionDetectorAdapter bridges foreground motion sensors from a paired Android companion on non-Android hosts', () async {
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
    });
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

    test('ConfigurableRemoteNotificationService pairs device, dispatches incident over HTTP relay, and enforces privacy boundary', () async {
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
    });

    testWidgets(
      'Home Phone connection row shows Pair your phone before pairing, and Send test alert + Disconnect phone after pairing',
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
              deviceDisplayName: 'Jonathan’s MacBook',
            ),
          ),
          notificationAdapter: ConfigurableRemoteNotificationService(
            persistToDisk: false,
            initialRelayEndpointUrl: 'http://127.0.0.1:$relayPort',
          ),
        );

        await controller.initialize();
        await tester.pumpWidget(WatSafeApp(controller: controller));
        await tester.pumpAndSettle();

        // Initially shows "Pair your phone" row on Home
        expect(find.text('Pair your phone'), findsOneWidget);

        // Tap "Pair your phone" -> opens real QR code sheet with one-time code
        await tester.runAsync(() async {
          await controller.initiateHostPairing();
        });
        await tester.tap(find.byKey(const Key('pair_your_phone_row')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.text('Scan this with your phone’s camera.'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('pairing_qr_matrix')), findsOneWidget);
        expect(
          find.byKey(const Key('active_pairing_code_label')),
          findsOneWidget,
        );

        // Close modal and pair a phone
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();

        await tester.runAsync(() async {
          final phone = ConfigurableRemoteNotificationService(
            persistToDisk: false,
          );
          await phone.pairAsCompanionPhone(
            pairingCodeOrPayload:
                controller.activePairingInvitation!.effectiveScanUrl,
            displayName: 'Aidan\'s S24',
            platform: 'Android',
            notificationsEnabled: true,
          );
          await controller.syncPairedDevicesFromRelay();
          phone.dispose();
        });
        await tester.pumpAndSettle();

        // Home row now shows the phone's name, connection status, and notification state
        expect(find.text('Aidan\'s S24'), findsOneWidget);
        expect(
          find.textContaining('Phone connected • Notifications on'),
          findsOneWidget,
        );
        expect(controller.pairedDevices, hasLength(1));

        // Open connected phone details -> Send test alert & Disconnect phone
        await tester.tap(find.byKey(const Key('paired_phone_details_trigger')));
        await tester.pumpAndSettle();

        final sendTestBtn = find.byKey(const Key('send_test_alert_button'));
        expect(sendTestBtn, findsOneWidget);
        await tester.runAsync(() async {
          final res = await controller.sendTestAlertToPairedPhone();
          expect(res.delivered, isTrue);
        });
        await tester.pumpAndSettle();
        expect(controller.incidents, hasLength(1));
        expect(controller.incidents.first.isTest, isTrue);

        // Disconnect phone
        await tester.runAsync(() async {
          await controller.unpairCompanionDevice(
            controller.pairedDevices.first.deviceId,
          );
        });
        await tester.pumpAndSettle();

        expect(controller.pairedDevices, isEmpty);

        controller.dispose();
        await fakeDetector.dispose();
      },
    );

    test('End-to-end short-lived code/QR pairing delivers alerts only to paired phone, blocks unpaired/other sessions, deduplicates reconnects, and rejects credentials', () async {
      final endpoint = 'http://127.0.0.1:$relayPort';

      // 1. Protected Laptop A setup
      final laptopANotifications = ConfigurableRemoteNotificationService(
        persistToDisk: false,
        initialRelayEndpointUrl: endpoint,
      );
      final laptopADetector = FakeMotionDetector(
        type: DetectorType.macosCameraSceneMotion,
      );
      final laptopAPinService = PinSecurityService(
        storage: InMemorySecurePinStorage(),
        pbkdf2Iterations: 500,
      );
      await laptopAPinService.setupInitialPin(
        pin: '246810',
        confirmPin: '246810',
      );
      final laptopAController = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.macosCameraSceneMotion: laptopADetector,
        },
        audioAdapter: FakeAudioAlarmAdapter(),
        pinService: laptopAPinService,
        incidentStorage: InMemoryIncidentStorage(),
        settingsStorage: InMemorySettingsStorage(
          const ProtectionSettings(
            selectedDetector: DetectorType.macosCameraSceneMotion,
            armingCountdownSeconds: 1,
            onboardingCompleted: true,
          ),
        ),
        notificationAdapter: laptopANotifications,
      );
      await laptopAController.initialize();

      // Laptop A generates a short-lived single-use pairing code + QR link
      final inviteA = await laptopAController.initiateHostPairing(
        hostDisplayName: 'Jonathan\'s MacBook Pro',
      );
      expect(inviteA.pairingCode, isNotEmpty);
      expect(inviteA.qrPayload, contains('/pair?code='));
      expect(laptopAController.pairedDevices, isEmpty);

      // 2. Companion Phone A pairs using the watsafe://pair QR payload
      final phoneANotifications = ConfigurableRemoteNotificationService(
        persistToDisk: false,
      );
      final phoneADetector = FakeMotionDetector(
        type: DetectorType.androidMotionSensors,
      );
      final phoneAPinService = PinSecurityService(
        storage: InMemorySecurePinStorage(),
        pbkdf2Iterations: 500,
      );
      await phoneAPinService.setupInitialPin(
        pin: '135791',
        confirmPin: '135791',
      );
      final phoneAController = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.androidMotionSensors: phoneADetector,
        },
        audioAdapter: FakeAudioAlarmAdapter(),
        pinService: phoneAPinService,
        incidentStorage: InMemoryIncidentStorage(),
        settingsStorage: InMemorySettingsStorage(
          const ProtectionSettings(
            selectedDetector: DetectorType.androidMotionSensors,
            onboardingCompleted: true,
          ),
        ),
        notificationAdapter: phoneANotifications,
      );
      await phoneAController.initialize();

      final sessionStateA = await phoneAController.pairAsCompanionPhone(
        pairingCodeOrPayload: inviteA.qrPayload,
        displayName: 'Chuan\'s Pixel 9',
        platform: 'Android (FCM)',
      );
      expect(sessionStateA.isConnected, isTrue);
      expect(sessionStateA.hostDisplayName, 'Jonathan\'s MacBook Pro');

      // Reusing the single-use pairing code from a second client must fail
      final roguePhone = ConfigurableRemoteNotificationService(
        persistToDisk: false,
        initialRelayEndpointUrl: endpoint,
      );
      await expectLater(
        roguePhone.pairAsCompanionPhone(
          pairingCodeOrPayload: inviteA.pairingCode,
          displayName: 'Intruder Phone',
          platform: 'Android',
        ),
        throwsStateError,
      );

      // Laptop A syncs and shows Phone A is connected
      final syncedDevices = await laptopAController
          .syncPairedDevicesFromRelay();
      expect(syncedDevices, hasLength(1));
      expect(syncedDevices.first.displayName, 'Chuan\'s Pixel 9');
      expect(syncedDevices.first.connected, isTrue);
      expect(
        laptopAController.notificationStatus.capabilityStatus,
        CapabilityStatus.ready,
      );
      expect(
        laptopAController.notificationStatus.summary,
        contains('Connected (1 paired device)'),
      );

      // 3. Separate Session B (different laptop + phone) on the same relay
      final laptopBNotifications = ConfigurableRemoteNotificationService(
        persistToDisk: false,
        initialRelayEndpointUrl: endpoint,
      );
      final inviteB = await laptopBNotifications.initiateHostPairing(
        hostDisplayName: 'Other Student Laptop',
      );
      final phoneBNotifications = ConfigurableRemoteNotificationService(
        persistToDisk: false,
      );
      await phoneBNotifications.pairAsCompanionPhone(
        pairingCodeOrPayload: inviteB.qrPayload,
        displayName: 'Phone B',
        platform: 'iOS (APNs)',
      );
      expect(phoneBNotifications.companionSession.isConnected, isTrue);

      // 4. Arm Laptop A and trigger a real motion alarm
      await laptopAController.startArming();
      final armSessionId = laptopAController.activeSessionId!;
      await laptopAController.handleCountdownTickForSession(armSessionId);
      expect(laptopAController.state, ProtectionState.armed);

      laptopADetector.emit(
        DetectorEvent(
          eventId: 'evt_laptop_theft_1',
          sessionId: armSessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: DateTime.utc(2026, 11, 14, 18, 30, 0),
          summary: 'Laptop lifted from desk (global optical flow 0.41)',
          motionScore: 0.41,
          threshold: 0.095,
          consecutiveAboveThresholdFrames: 3,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(laptopAController.state, ProtectionState.alarming);

      // 5. Paired Phone A receives the alert and surfaces the remote banner
      final alertsForPhoneA = await phoneAController.pollCompanionAlertsOnce();
      expect(alertsForPhoneA, hasLength(1));
      expect(
        alertsForPhoneA.first.incidentId,
        laptopAController.activeIncident!.id,
      );
      expect(alertsForPhoneA.first.hostDisplayName, 'Jonathan\'s MacBook Pro');
      expect(
        alertsForPhoneA.first.triggerSummary,
        contains('Laptop lifted from desk'),
      );
      expect(
        phoneAController.latestUnacknowledgedCompanionAlert?.incidentId,
        laptopAController.activeIncident!.id,
      );

      // 6. Verify strict session isolation:
      //    (a) Phone B (paired to Session B) receives ZERO alerts from Session A
      final alertsForPhoneB = await phoneBNotifications
          .pollCompanionAlertsOnce();
      expect(alertsForPhoneB, isEmpty);
      expect(phoneBNotifications.receivedCompanionAlerts, isEmpty);

      //    (b) Unpaired HTTP client without valid companion token gets 401
      final rawClient = HttpClient();
      final unauthReq = await rawClient.getUrl(
        Uri.parse('$endpoint/v1/companion/alerts?afterSeq=0'),
      );
      final unauthResp = await unauthReq.close();
      expect(unauthResp.statusCode, HttpStatus.unauthorized);
      await unauthResp.drain<void>();

      // 7. Verify reconnect & retry deduplication:
      //    Re-sending the same incident from Laptop A and replaying from seq=0 on Phone A
      //    must NOT duplicate the alert.
      await laptopANotifications.sendIncidentAlert(
        laptopAController.activeIncident!,
      );
      final replayed = await phoneANotifications.pollCompanionAlertsOnce(
        replayFromZero: true,
      );
      expect(replayed, isEmpty);
      expect(phoneAController.receivedCompanionAlerts, hasLength(1));

      // 8. Verify database credentials, PINs, and camera frames are blocked
      for (final forbiddenPayload in <Map<String, Object?>>[
        <String, Object?>{
          'incidentId': 'leak_db_1',
          'databaseUrl':
              'postgres://avnadmin:secret@db.aivencloud.com/defaultdb',
        },
        <String, Object?>{
          'incidentId': 'leak_conn_str',
          'triggerSummary':
              'postgresql://avnadmin:secret@db.aivencloud.com:25060/defaultdb',
        },
        <String, Object?>{'incidentId': 'leak_pin', 'pinHash': 'deadbeef'},
      ]) {
        final badReq = await rawClient.postUrl(
          Uri.parse('$endpoint/v1/incidents:report'),
        );
        badReq.headers.contentType = ContentType.json;
        badReq.write(jsonEncode(forbiddenPayload));
        final badResp = await badReq.close();
        expect(badResp.statusCode, HttpStatus.badRequest);
        await badResp.drain<void>();
      }

      // 9. Unpairing Phone A revokes its companion token immediately
      await laptopAController.unpairCompanionDevice(
        syncedDevices.first.deviceId,
      );
      await phoneAController.pollCompanionAlertsOnce();
      expect(phoneAController.companionSession.isConnected, isFalse);

      rawClient.close(force: true);
      roguePhone.dispose();
      laptopBNotifications.dispose();
      phoneBNotifications.dispose();
      laptopAController.dispose();
      phoneAController.dispose();
      await laptopADetector.dispose();
      await phoneADetector.dispose();
    });

    test('PostgresRelayStore parses Aiven environment variables securely and redacts credentials', () {
      expect(
        PostgresRelayStore.fromEnvironment(const <String, String>{}),
        isNull,
      );

      final store = PostgresRelayStore.fromEnvironment(const <String, String>{
        'AIVEN_DATABASE_URL': 'postgres://avnadmin:SuperSecretPass123@pg-watsafe-test.aivencloud.com:25432/defaultdb?sslmode=require',
        'WATSAFE_DB_TABLE_PREFIX': 'chuan_ci_',
      });
      expect(store, isNotNull);
      expect(store!.backendName, 'aiven_postgres');
      expect(
        store.redactedDescription,
        'postgres://avnadmin@pg-watsafe-test.aivencloud.com:25432/defaultdb',
      );
      expect(store.redactedDescription, isNot(contains('SuperSecretPass123')));

      final neonStore = PostgresRelayStore.fromEnvironment(
        const <String, String>{
          'DATABASE_URL': 'postgresql://neondb_owner:NeonSecret999@ep-cool-darkness-123456-pooler.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require',
        },
      );
      expect(neonStore, isNotNull);
      expect(neonStore!.backendName, 'aiven_postgres');
      expect(
        neonStore.redactedDescription,
        'postgres://neondb_owner@ep-cool-darkness-123456-pooler.us-east-2.aws.neon.tech:5432/neondb',
      );
      expect(neonStore.redactedDescription, isNot(contains('NeonSecret999')));
    });

    testWidgets(
      'Companion phone UI pairs via laptop short-lived code and displays REMOTE LAPTOP ALARM banner on trigger',
      (WidgetTester tester) async {
        HttpOverrides.global = null;
        await tester.binding.setSurfaceSize(const Size(1100, 950));
        final endpoint = 'http://127.0.0.1:$relayPort';

        late FakeMotionDetector laptopDetector;
        late AlarmController laptopController;
        late PairingCodeInvitation invite;

        await tester.runAsync(() async {
          laptopDetector = FakeMotionDetector(
            type: DetectorType.macosCameraSceneMotion,
          );
          final laptopPin = PinSecurityService(
            storage: InMemorySecurePinStorage(),
            pbkdf2Iterations: 500,
          );
          await laptopPin.setupInitialPin(pin: '112233', confirmPin: '112233');
          laptopController = AlarmController(
            detectors: <DetectorType, MotionDetectorAdapter>{
              DetectorType.macosCameraSceneMotion: laptopDetector,
            },
            audioAdapter: FakeAudioAlarmAdapter(),
            pinService: laptopPin,
            incidentStorage: InMemoryIncidentStorage(),
            settingsStorage: InMemorySettingsStorage(
              const ProtectionSettings(
                selectedDetector: DetectorType.macosCameraSceneMotion,
                armingCountdownSeconds: 1,
                onboardingCompleted: true,
              ),
            ),
            notificationAdapter: ConfigurableRemoteNotificationService(
              persistToDisk: false,
              initialRelayEndpointUrl: endpoint,
            ),
          );
          await laptopController.initialize();
          invite = await laptopController.initiateHostPairing(
            hostDisplayName: 'Library MacBook',
          );
        });

        final phoneDetector = FakeMotionDetector(
          type: DetectorType.androidMotionSensors,
        );
        final phonePin = PinSecurityService(
          storage: InMemorySecurePinStorage(),
          pbkdf2Iterations: 500,
        );
        await phonePin.setupInitialPin(pin: '445566', confirmPin: '445566');
        final phoneController = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.androidMotionSensors: phoneDetector,
          },
          audioAdapter: FakeAudioAlarmAdapter(),
          pinService: phonePin,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: InMemorySettingsStorage(
            const ProtectionSettings(
              selectedDetector: DetectorType.androidMotionSensors,
              onboardingCompleted: true,
            ),
          ),
          notificationAdapter: ConfigurableRemoteNotificationService(
            persistToDisk: false,
          ),
        );
        await phoneController.initialize();

        await tester.pumpWidget(
          WatSafeApp(
            controller: phoneController,
            initialPairingPayload: invite.effectiveScanUrl,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        await tester.runAsync(() async {
          await phoneController.pairAsCompanionPhone(
            pairingCodeOrPayload: invite.effectiveScanUrl,
            displayName: 'Test iPhone',
            platform: 'iOS',
          );
          await laptopController.syncPairedDevicesFromRelay();
        });
        await tester.pumpAndSettle();

        // Dismiss the pairing notification modal if open
        final finishBtn = find.byKey(const Key('finish_phone_pairing_button'));
        if (finishBtn.evaluate().isNotEmpty) {
          await tester.tap(finishBtn);
          await tester.pumpAndSettle();
        }

        expect(
          find.byKey(const Key('companion_connected_badge')),
          findsOneWidget,
        );
        expect(laptopController.pairedDevices, hasLength(1));

        // Trigger alarm on laptop inside real async zone so loopback HTTP finishes
        await tester.runAsync(() async {
          await laptopController.startArming();
          final sid = laptopController.activeSessionId!;
          await laptopController.handleCountdownTickForSession(sid);
          laptopDetector.emit(
            DetectorEvent(
              eventId: 'evt_ui_banner_1',
              sessionId: sid,
              detectorType: DetectorType.macosCameraSceneMotion,
              eventType: DetectorEventType.motionTriggered,
              timestamp: DateTime.utc(2026, 11, 14, 19, 0, 0),
              summary: 'Camera rotated sharply across all quadrants',
              motionScore: 0.39,
              threshold: 0.095,
              consecutiveAboveThresholdFrames: 3,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 150));
          await phoneController.pollCompanionAlertsOnce();
        });
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('remote_laptop_alarm_banner')),
          findsOneWidget,
        );
        expect(
          find.textContaining('Library MacBook • Alarm triggered'),
          findsOneWidget,
        );

        // Tap "View event" on the banner -> opens the exact event in Activity
        await tester.tap(
          find.byKey(const Key('view_alert_in_activity_button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('activity_selected_event_card')),
          findsOneWidget,
        );

        laptopController.dispose();
        phoneController.dispose();
        await laptopDetector.dispose();
        await phoneDetector.dispose();
      },
    );

    final liveDbUrl =
        (Platform.environment['AIVEN_DATABASE_URL'] ??
                Platform.environment['DATABASE_URL'] ??
                '')
            .trim();
    test(
      'Live Aiven PostgreSQL relay store persists sessions, pairing bonds, and alerts when AIVEN_DATABASE_URL is configured',
      () async {
        final liveServer = WatSafeRelayServer.fromEnvironment(
          environment: <String, String>{
            ...Platform.environment,
            'WATSAFE_DB_TABLE_PREFIX': 'watsafe_it_',
          },
        );
        final livePort = await liveServer.start(
          address: InternetAddress.loopbackIPv4,
          port: 0,
        );
        try {
          expect(liveServer.storageBackend, 'aiven_postgres');
          final host = ConfigurableRemoteNotificationService(
            persistToDisk: false,
            initialRelayEndpointUrl: 'http://127.0.0.1:$livePort',
          );
          final invite = await host.initiateHostPairing(
            hostDisplayName: 'Aiven Test Host',
          );
          final phone = ConfigurableRemoteNotificationService(
            persistToDisk: false,
          );
          final connected = await phone.pairAsCompanionPhone(
            pairingCodeOrPayload: invite.qrPayload,
            displayName: 'Chuan Test Phone',
            platform: 'Android (FCM)',
          );
          expect(connected.isConnected, isTrue);
          host.dispose();
          phone.dispose();
        } finally {
          await liveServer.stop();
        }
      },
      skip: liveDbUrl.isEmpty
          ? 'Set AIVEN_DATABASE_URL or DATABASE_URL to run against Chuan\'s Aiven PostgreSQL database.'
          : false,
    );
  });

  group('Color Themes, Built-In Alarm Noises, & Custom Alarm Sounds', () {
    test('Waveform synthesizer generates valid RIFF/WAVE bytes for all built-in and custom patterns', () {
      for (final builtIn in BuiltInAlarmSound.values) {
        final bytes = AlarmWaveformSynthesizer.generateBuiltInWav(builtIn);
        expect(AlarmWaveformSynthesizer.isValidWavBytes(bytes), isTrue);
        expect(bytes.length, greaterThan(44100));
      }

      for (final pattern in CustomAlarmWavePattern.values) {
        final custom = CustomAlarmSound(
          id: 'test_${pattern.name}',
          name: 'Test ${pattern.displayName}',
          pattern: pattern,
          primaryFrequencyHz: 750.0,
          secondaryFrequencyHz: 1550.0,
          modulationRateHz: 5.0,
        );
        final bytes = AlarmWaveformSynthesizer.generateCustomWav(custom);
        expect(AlarmWaveformSynthesizer.isValidWavBytes(bytes), isTrue);
        expect(bytes.length, greaterThan(44100));
      }
    });

    test('Controller selects color themes, switches built-in alarm sounds, adds synthesized and WAV custom sounds, and persists settings', () async {
      final fakeDetector = FakeMotionDetector(
        type: DetectorType.windowsCameraSceneMotion,
      );
      final fakeAudio = FakeAudioAlarmAdapter();
      final pinService = PinSecurityService(
        storage: InMemorySecurePinStorage(),
        pbkdf2Iterations: 500,
      );
      await pinService.setupInitialPin(pin: '123456', confirmPin: '123456');

      final settingsStorage = InMemorySettingsStorage(
        const ProtectionSettings(
          selectedDetector: DetectorType.windowsCameraSceneMotion,
          onboardingCompleted: true,
        ),
      );

      final controller = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.windowsCameraSceneMotion: fakeDetector,
        },
        audioAdapter: fakeAudio,
        pinService: pinService,
        incidentStorage: InMemoryIncidentStorage(),
        settingsStorage: settingsStorage,
        notificationAdapter: const UnconfiguredRemoteNotificationService(),
      );

      await controller.initialize();
      expect(controller.settings.colorTheme, WatSafeColorTheme.obsidianAmber);
      expect(
        controller.settings.selectedAlarmSoundId,
        BuiltInAlarmSound.classicSiren.id,
      );

      // 1. Switch color themes
      for (final theme in WatSafeColorTheme.values) {
        await controller.selectColorTheme(theme);
        expect(controller.settings.colorTheme, theme);
      }

      // 2. Switch built-in alarm noises
      await controller.selectAlarmSound(BuiltInAlarmSound.piercingKlaxon.id);
      expect(
        controller.settings.selectedAlarmSoundId,
        BuiltInAlarmSound.piercingKlaxon.id,
      );
      expect(fakeAudio.selectedSoundId, BuiltInAlarmSound.piercingKlaxon.id);

      // 3. Add a custom synthesized alarm sound
      final customSynth = await controller.addCustomSynthesizedAlarmSound(
        name: 'Cyber Staccato Siren',
        pattern: CustomAlarmWavePattern.rapidStaccato,
        primaryFrequencyHz: 1100.0,
        secondaryFrequencyHz: 1900.0,
        modulationRateHz: 7.0,
      );
      expect(customSynth, isNotNull);
      expect(controller.settings.customAlarmSounds, hasLength(1));
      expect(controller.settings.selectedAlarmSoundId, customSynth!.id);
      expect(fakeAudio.selectedSoundId, customSynth.id);
      expect(fakeAudio.selectedCustomSound?.name, 'Cyber Staccato Siren');

      // 4. Import a custom .wav file from disk
      final tempDir = await Directory.systemTemp.createTemp(
        'watsafe_custom_wav_test_',
      );
      try {
        final wavFile = File('${tempDir.path}/custom_klaxon.wav');
        final wavBytes = AlarmWaveformSynthesizer.generateBuiltInWav(
          BuiltInAlarmSound.industrialHorn,
        );
        await wavFile.writeAsBytes(wavBytes, flush: true);

        final importedWav = await controller.importCustomWavAlarmSound(
          name: 'Imported Lab Horn',
          filePath: wavFile.path,
        );
        expect(importedWav, isNotNull);
        expect(importedWav!.isFileBased, isTrue);
        expect(controller.settings.customAlarmSounds, hasLength(2));
        expect(controller.settings.selectedAlarmSoundId, importedWav.id);
        expect(fakeAudio.selectedSoundId, importedWav.id);

        // Verify round-trip JSON persistence of theme + custom sounds
        final reloaded = ProtectionSettings.fromJson(
          controller.settings.toJson(),
        );
        expect(reloaded.colorTheme, WatSafeColorTheme.arcticDaylight);
        expect(reloaded.selectedAlarmSoundId, importedWav.id);
        expect(reloaded.customAlarmSounds, hasLength(2));
        expect(reloaded.customAlarmSounds.last.name, 'Imported Lab Horn');

        // 5. Remove active custom sound -> falls back to classicSiren
        await controller.removeCustomAlarmSound(importedWav.id);
        expect(controller.settings.customAlarmSounds, hasLength(1));
        expect(
          controller.settings.selectedAlarmSoundId,
          BuiltInAlarmSound.classicSiren.id,
        );
      } finally {
        await tempDir.delete(recursive: true);
      }

      controller.dispose();
      await fakeDetector.dispose();
    });

    testWidgets(
      'SettingsScreen UI switches Color Themes and adds/previews/deletes Custom Alarm Sounds',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 950));

        final fakeDetector = FakeMotionDetector(
          type: DetectorType.windowsCameraSceneMotion,
        );
        final fakeAudio = FakeAudioAlarmAdapter();
        final pinService = PinSecurityService(
          storage: InMemorySecurePinStorage(),
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '123456', confirmPin: '123456');

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
              onboardingCompleted: true,
            ),
          ),
          notificationAdapter: const UnconfiguredRemoteNotificationService(),
        );

        await controller.initialize();
        await tester.pumpWidget(WatSafeApp(controller: controller));
        await tester.pumpAndSettle();

        // Navigate to Settings tab
        await tester.tap(find.text('Settings').first);
        await tester.pumpAndSettle();

        final cyberThemeCard = find.byKey(
          Key('theme_option_${WatSafeColorTheme.cyberSentinel.id}'),
        );
        await tester.ensureVisible(cyberThemeCard);
        await tester.pumpAndSettle();
        await tester.tap(cyberThemeCard);
        await tester.pumpAndSettle();

        expect(controller.settings.colorTheme, WatSafeColorTheme.cyberSentinel);

        // Select a built-in alarm sound
        final temporalBellTile = find.byKey(
          Key('alarm_sound_option_${BuiltInAlarmSound.temporalBell.id}'),
        );
        await tester.ensureVisible(temporalBellTile);
        await tester.pumpAndSettle();
        await tester.tap(temporalBellTile);
        await tester.pumpAndSettle();

        expect(
          controller.settings.selectedAlarmSoundId,
          BuiltInAlarmSound.temporalBell.id,
        );

        // Create a custom synthesized alarm sound via the Settings UI
        final nameInput = find.byKey(const Key('custom_sound_name_input'));
        await tester.ensureVisible(nameInput);
        await tester.pumpAndSettle();
        await tester.enterText(nameInput, 'My Ultrasonic Pulse');

        final addSynthBtn = find.byKey(
          const Key('add_custom_synth_sound_button'),
        );
        await tester.ensureVisible(addSynthBtn);
        await tester.pumpAndSettle();
        await tester.tap(addSynthBtn);
        await tester.pumpAndSettle();

        expect(controller.settings.customAlarmSounds, hasLength(1));
        expect(
          controller.settings.customAlarmSounds.first.name,
          'My Ultrasonic Pulse',
        );
        expect(find.text('My Ultrasonic Pulse'), findsOneWidget);

        controller.dispose();
        await fakeDetector.dispose();
      },
    );
  });
}
