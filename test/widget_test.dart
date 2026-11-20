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
    'First-run onboarding creates PIN, opens 3-task Home/Activity/Settings shell, runs siren test, and shows Pair your phone row',
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

      // Enter device name and a 6-digit PIN + confirmation
      await tester.enterText(
        find.byKey(const Key('onboarding_device_name_input')),
        'Jonathan’s MacBook',
      );
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

      // Should now be on Home in Off state with "Arm protection" and "Pair your phone"
      expect(find.byKey(const Key('dashboard_state_badge')), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Arm protection'), findsOneWidget);
      expect(find.text('Pair your phone'), findsOneWidget);
      expect(controller.state, ProtectionState.disarmed);

      // Verify 3-task navigation: Home, Activity, Settings
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Activity'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);

      // Navigate to Settings -> Alarm and run the 5-second local siren test
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings_category_alarm')));
      await tester.pumpAndSettle();

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

      // Navigate to Activity and verify the test event is recorded cleanly
      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      expect(find.text('Test alert'), findsOneWidget);
      expect(find.textContaining('Jonathan’s MacBook'), findsOneWidget);

      controller.dispose();
      await fakeDetector.dispose();
    },
  );
  testWidgets('iPad portrait and landscape use the adaptive navigation rail without layout errors', (WidgetTester tester) async {
    final fakeDetector = FakeMotionDetector();
    final pinStorage = InMemorySecurePinStorage();
    final pinService = PinSecurityService(
      storage: pinStorage,
      pbkdf2Iterations: 500,
    );
    await pinService.setupInitialPin(pin: '135790', confirmPin: '135790');
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
      notificationAdapter: const UnconfiguredRemoteNotificationService(),
    );

    try {
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      await controller.initialize();
      await tester.pumpWidget(WatSafeApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('desktop_navigation_rail')), findsOneWidget);
      expect(find.byKey(const Key('compact_navigation_bar')), findsNothing);
      expect(tester.takeException(), isNull);

      // A 768pt-wide portrait iPad still uses the rail at the current breakpoint.
      await tester.binding.setSurfaceSize(const Size(768, 1024));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('desktop_navigation_rail')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings_category_list')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.binding.setSurfaceSize(null);
      controller.dispose();
      await fakeDetector.dispose();
    }
  });

}
