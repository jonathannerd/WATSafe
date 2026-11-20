import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/incident_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_notification_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/location_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

import 'alarm_controller_test.dart'
    show FakeMotionDetector, FailingNotificationAdapter;

class _RecordingLocalNotifications extends NoOpLocalNotificationService {
  final List<String> messages = <String>[];

  @override
  Future<bool> showAlertNotification({
    required String incidentId,
    required String deviceName,
    required String message,
    bool isTest = false,
  }) async {
    messages.add(message);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Safe Zones monitor locally while relay location sharing is off', () async {
    final detector = FakeMotionDetector();
    final center = DeviceLocationSnapshot(
      latitude: 43.4723,
      longitude: -80.5449,
      capturedAt: DateTime.utc(2026, 11, 20, 12),
      accuracyMeters: 8,
    );
    final outside = DeviceLocationSnapshot(
      latitude: 43.4923,
      longitude: -80.5449,
      capturedAt: DateTime.utc(2026, 11, 20, 12, 5),
      accuracyMeters: 8,
    );
    final location = FakeLocationService(
      permission: PermissionStatus.granted,
      queuedLocations: <DeviceLocationSnapshot?>[center, outside],
    );
    final localNotifications = _RecordingLocalNotifications();
    final controller = AlarmController(
      detectors: <DetectorType, MotionDetectorAdapter>{
        DetectorType.macosCameraSceneMotion: detector,
      },
      audioAdapter: FakeAudioAlarmAdapter(),
      pinService: PinSecurityService(
        storage: InMemorySecurePinStorage(),
        pbkdf2Iterations: 500,
      ),
      incidentStorage: InMemoryIncidentStorage(),
      settingsStorage: InMemorySettingsStorage(
        const ProtectionSettings(
          onboardingCompleted: true,
          shareLocationOnAlarm: false,
        ),
      ),
      notificationAdapter: FailingNotificationAdapter(),
      locationAdapter: location,
      localNotificationAdapter: localNotifications,
    );

    try {
      await controller.initialize();
      final added = await controller.addSafeZoneFromCurrentLocation(
        name: 'Campus',
        radiusMeters: 500,
      );
      expect(added, isTrue);
      expect(controller.settings.shareLocationOnAlarm, isFalse);
      expect(controller.settings.safeZones, hasLength(1));
      expect(location.captureCount, 1);

      // A second local capture crosses the boundary and produces a local alert.
      await controller.refreshProtectedDeviceLocation();
      await Future<void>.delayed(Duration.zero);

      expect(location.captureCount, 2);
      expect(localNotifications.messages, hasLength(1));
      expect(localNotifications.messages.single, contains('left the safe zone'));
      expect(controller.settings.shareLocationOnAlarm, isFalse);
    } finally {
      controller.dispose();
      await detector.dispose();
    }
  });

  test('charger disconnect telemetry produces one local alert per armed session', () async {
    final detector = FakeMotionDetector();
    final localNotifications = _RecordingLocalNotifications();
    final controller = AlarmController(
      detectors: <DetectorType, MotionDetectorAdapter>{
        DetectorType.macosCameraSceneMotion: detector,
      },
      audioAdapter: FakeAudioAlarmAdapter(),
      pinService: PinSecurityService(
        storage: InMemorySecurePinStorage(),
        pbkdf2Iterations: 500,
      ),
      incidentStorage: InMemoryIncidentStorage(),
      settingsStorage: InMemorySettingsStorage(
        const ProtectionSettings(
          onboardingCompleted: true,
          armingCountdownSeconds: 3,
          alertOnAcPowerDisconnect: true,
        ),
      ),
      notificationAdapter: FailingNotificationAdapter(),
      localNotificationAdapter: localNotifications,
    );

    try {
      await controller.initialize();
      await controller.setupInitialPin(pin: '246810', confirmPin: '246810');
      expect(await controller.startArming(), isTrue);
      final sessionId = controller.activeSessionId!;
      for (var i = 0; i < 3; i++) {
        await controller.handleCountdownTickForSession(sessionId);
      }
      expect(controller.state.name, 'armed');

      final event = DetectorEvent(
        eventId: 'charger-disconnect-1',
        sessionId: sessionId,
        detectorType: DetectorType.macosCameraSceneMotion,
        eventType: DetectorEventType.telemetryFrame,
        timestamp: DateTime.utc(2026, 11, 20, 12),
        summary: 'Charger disconnected',
        acPowerUnplugged: true,
      );
      detector.emit(event);
      detector.emit(event);
      await Future<void>.delayed(Duration.zero);

      expect(localNotifications.messages, hasLength(1));
      expect(localNotifications.messages.single, contains('Charger disconnected'));
    } finally {
      controller.dispose();
      await detector.dispose();
    }
  });
}
