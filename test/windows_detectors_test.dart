import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/platform/desktop/windows_detectors.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

import 'alarm_controller_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WindowsAccelerometerDetectorAdapter', () {
    const methodChannel = MethodChannel('dev.watsafe/test_win_accel');
    const eventChannel = EventChannel('dev.watsafe/test_win_accel_events');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, null);
    });

    test(
      'reports CapabilityStatus.unsupported when GetDefault() returns no hardware',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
              if (call.method == 'checkCapability') {
                return <String, Object?>{
                  'hasAccelerometerHardware': false,
                  'deviceName': 'No Accelerometer Detected',
                  'permissionStatus': 'notApplicable',
                  'detail':
                      'Windows.Devices.Sensors.Accelerometer.GetDefault() returned nullptr.',
                };
              }
              return null;
            });

        final adapter = WindowsAccelerometerDetectorAdapter(
          methodChannel: methodChannel,
          eventChannel: eventChannel,
          isWindowsOverride: true,
        );

        final cap = await adapter.checkCapability();
        expect(cap.status, CapabilityStatus.unsupported);
        expect(cap.canArm, isFalse);
        expect(cap.guidance, contains('Windows Webcam Scene-Motion'));
        await adapter.dispose();
      },
    );

    test(
      'reports CapabilityStatus.ready and streams motion events when hardware exists',
      () async {
        MockStreamHandlerEventSink? activeSink;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
              switch (call.method) {
                case 'checkCapability':
                  return <String, Object?>{
                    'hasAccelerometerHardware': true,
                    'deviceName': 'HID 3D Accelerometer',
                    'permissionStatus': 'granted',
                    'detail': '3-axis accelerometer ready.',
                  };
                case 'startMonitoring':
                  return <String, Object?>{
                    'started': true,
                    'message': 'Monitoring active on HID 3D Accelerometer.',
                  };
                case 'updateSensitivity':
                case 'stopMonitoring':
                  return null;
              }
              return null;
            });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
              eventChannel,
              MockStreamHandler.inline(
                onListen:
                    (Object? arguments, MockStreamHandlerEventSink events) {
                      activeSink = events;
                    },
              ),
            );

        final adapter = WindowsAccelerometerDetectorAdapter(
          methodChannel: methodChannel,
          eventChannel: eventChannel,
          isWindowsOverride: true,
        );

        final cap = await adapter.checkCapability();
        expect(cap.status, CapabilityStatus.ready);
        expect(cap.canArm, isTrue);
        expect(cap.hardwareDeviceName, 'HID 3D Accelerometer');

        final received = <DetectorEvent>[];
        final sub = adapter.events.listen(received.add);

        final startResult = await adapter.startMonitoring(
          const MonitorConfig(sessionId: 'win_accel_s1', sensitivity: 0.60),
        );
        expect(startResult.started, isTrue);

        activeSink?.success(<String, Object?>{
          'sessionId': 'win_accel_s1',
          'eventType': 'motionTriggered',
          'summary': 'Sustained accelerometer motion detected',
          'motionScore': 0.16,
          'threshold': 0.095,
          'consecutiveFrames': 3,
          'timestampMs': 1700000000000,
        });
        await Future<void>.delayed(Duration.zero);

        expect(received.length, 1);
        expect(received.first.eventType, DetectorEventType.motionTriggered);
        expect(received.first.motionScore, 0.16);

        await adapter.stopMonitoring(sessionId: 'win_accel_s1');
        await sub.cancel();
        await adapter.dispose();
      },
    );
  });

  group('WindowsCameraSceneMotionDetectorAdapter', () {
    const methodChannel = MethodChannel('dev.watsafe/test_win_cam');
    const eventChannel = EventChannel('dev.watsafe/test_win_cam_events');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, null);
    });

    test(
      'reports CapabilityStatus.ready and streams scene-motion and poorInputWarning events',
      () async {
        MockStreamHandlerEventSink? activeSink;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
              switch (call.method) {
                case 'checkCapability':
                  return <String, Object?>{
                    'hasCameraHardware': true,
                    'deviceName': 'Integrated Camera',
                    'permissionStatus': 'granted',
                    'detail':
                        'Camera device Integrated Camera discovered via Windows Media Foundation.',
                  };
                case 'startMonitoring':
                  return <String, Object?>{
                    'started': true,
                    'message': 'Monitoring active on Integrated Camera.',
                  };
                case 'updateSensitivity':
                case 'stopMonitoring':
                  return null;
              }
              return null;
            });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
              eventChannel,
              MockStreamHandler.inline(
                onListen:
                    (Object? arguments, MockStreamHandlerEventSink events) {
                      activeSink = events;
                    },
              ),
            );

        final adapter = WindowsCameraSceneMotionDetectorAdapter(
          methodChannel: methodChannel,
          eventChannel: eventChannel,
          isWindowsOverride: true,
        );

        final cap = await adapter.checkCapability();
        expect(cap.status, CapabilityStatus.ready);
        expect(cap.canArm, isTrue);
        expect(cap.hardwareDeviceName, 'Integrated Camera');

        final received = <DetectorEvent>[];
        final sub = adapter.events.listen(received.add);

        final startResult = await adapter.startMonitoring(
          const MonitorConfig(sessionId: 'win_cam_s1', sensitivity: 0.60),
        );
        expect(startResult.started, isTrue);

        activeSink?.success(<String, Object?>{
          'sessionId': 'win_cam_s1',
          'eventType': 'poorInputWarning',
          'summary': 'Low light or covered camera lens detected',
          'averageLuminance': 0.01,
          'threshold': 0.095,
          'timestampMs': 1700000000000,
        });
        activeSink?.success(<String, Object?>{
          'sessionId': 'win_cam_s1',
          'eventType': 'motionTriggered',
          'summary': 'Sustained scene motion detected',
          'motionScore': 0.21,
          'threshold': 0.095,
          'averageLuminance': 0.45,
          'consecutiveFrames': 3,
          'timestampMs': 1700000001000,
        });
        await Future<void>.delayed(Duration.zero);

        expect(received.length, 2);
        expect(received[0].eventType, DetectorEventType.poorInputWarning);
        expect(received[1].eventType, DetectorEventType.motionTriggered);
        expect(received[1].motionScore, 0.21);

        await adapter.stopMonitoring(sessionId: 'win_cam_s1');
        await sub.cancel();
        await adapter.dispose();
      },
    );
  });

  test(
    'AlarmController automatically falls back from unsupported Windows Accelerometer to ready Windows Webcam on initialize',
    () async {
      final unsupportedAccel = FakeMotionDetector(
        type: DetectorType.windowsAccelerometer,
        initialCapability: const DetectorCapability(
          type: DetectorType.windowsAccelerometer,
          status: CapabilityStatus.unsupported,
          permissionStatus: PermissionStatus.notApplicable,
          summary: 'No integrated accelerometer hardware detected.',
        ),
      );
      final readyCamera = FakeMotionDetector(
        type: DetectorType.windowsCameraSceneMotion,
        initialCapability: const DetectorCapability(
          type: DetectorType.windowsCameraSceneMotion,
          status: CapabilityStatus.ready,
          permissionStatus: PermissionStatus.granted,
          hardwareDeviceName: 'Integrated Camera',
          summary: 'Ready — Integrated Camera available.',
        ),
      );

      final controller = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.windowsAccelerometer: unsupportedAccel,
          DetectorType.windowsCameraSceneMotion: readyCamera,
        },
        audioAdapter: FakeAudioAlarmAdapter(),
        pinService: PinSecurityService(
          storage: InMemorySecurePinStorage(),
          pbkdf2Iterations: 500,
        ),
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

      expect(
        controller.selectedDetectorType,
        DetectorType.windowsCameraSceneMotion,
      );
      expect(controller.state, ProtectionState.disarmed);

      controller.dispose();
      await unsupportedAccel.dispose();
      await readyCamera.dispose();
    },
  );
}
