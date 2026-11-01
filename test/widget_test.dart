import 'package:flutter/material.dart';
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
  testWidgets(
    'First-run onboarding creates PIN, opens dashboard, runs Test Alarm, and shows honest unconfigured states',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));

      final fakeDetector = FakeMotionDetector();
      final fakeAudio = FakeAudioAlarmAdapter();
      final pinStorage = InMemorySecurePinStorage();
      final pinService = PinSecurityService(
        storage: pinStorage,
        pbkdf2Iterations: 500,
      );
      final incidentStorage = InMemoryIncidentStorage();
      final settingsStorage = InMemorySettingsStorage(
        const ProtectionSettings(
          selectedDetector: DetectorType.macosCameraSceneMotion,
          armingCountdownSeconds: 5,
        ),
      );

      final controller = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.macosCameraSceneMotion: fakeDetector,
        },
        audioAdapter: fakeAudio,
        pinService: pinService,
        incidentStorage: incidentStorage,
        settingsStorage: settingsStorage,
        notificationAdapter: const UnconfiguredRemoteNotificationService(),
      );

      await controller.initialize();
      await tester.pumpWidget(WatSafeApp(controller: controller));
      await tester.pumpAndSettle();

      // Verify first-run onboarding is displayed
      expect(find.text('Welcome to WATSafe'), findsOneWidget);

      // Enter a 6-digit PIN and confirmation
      await tester.enterText(
        find.byKey(const Key('onboarding_pin_input')),
        '135790',
      );
      await tester.enterText(
        find.byKey(const Key('onboarding_confirm_pin_input')),
        '135790',
      );
      await tester.tap(find.byKey(const Key('onboarding_complete_button')));
      await tester.pumpAndSettle();

      // Should now be on the Protection Dashboard in DISARMED state
      expect(find.byKey(const Key('dashboard_state_badge')), findsOneWidget);
      expect(controller.state, ProtectionState.disarmed);

      // Trigger the independent 5-second Test Alarm and stop it manually
      final startTestFinder = find.byKey(const Key('start_test_alarm_button'));
      await tester.ensureVisible(startTestFinder);
      await tester.pumpAndSettle();
      await tester.tap(startTestFinder);
      await tester.pump();
      expect(controller.isTestAlarmRunning, isTrue);
      expect(fakeAudio.testStartCount, 1);

      final stopTestFinder = find.byKey(const Key('stop_test_alarm_button'));
      await tester.ensureVisible(stopTestFinder);
      await tester.pump();
      await tester.tap(stopTestFinder);
      await tester.pumpAndSettle();
      expect(controller.isTestAlarmRunning, isFalse);

      // Navigate to Incidents tab and verify the test event is clearly labeled
      await tester.tap(find.text('Incidents'));
      await tester.pumpAndSettle();
      expect(find.text('TEST EVENT (SIMULATED)'), findsOneWidget);

      // Navigate to Paired Devices tab and verify honest NOT CONFIGURED state
      await tester.tap(find.text('Paired Devices'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('paired_devices_status_badge')),
        findsOneWidget,
      );
      expect(
        find.text('No Paired Devices (Service Not Configured)'),
        findsOneWidget,
      );

      controller.dispose();
      await fakeDetector.dispose();
    },
  );
}
