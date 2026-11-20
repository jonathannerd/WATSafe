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
      expect(find.byKey(const Key('home_detector_readiness_strip')), findsOneWidget);
      expect(find.text('Camera ready'), findsOneWidget);
      expect(find.text('Setup checklist'), findsNothing);
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

      await tester.tap(find.byKey(const Key('activity_filter_alarms')));
      await tester.pumpAndSettle();
      expect(find.text('No matching activity'), findsOneWidget);

      await tester.tap(find.byKey(const Key('activity_filter_testAlerts')));
      await tester.pumpAndSettle();
      expect(find.text('Test alert'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('activity_search_field')),
        'Jonathan',
      );
      await tester.pumpAndSettle();
      expect(find.text('Test alert'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('activity_search_field')),
        'no matching device',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matching activity'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('activity_search_field')),
        '',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('activity_export_report_button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Incident report copied as CSV.'),
        findsOneWidget,
      );

      // The Home screen remains focused: no setup checklist is shown.
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(find.text('Setup checklist'), findsNothing);
      expect(
        find.byKey(const Key('home_setup_readiness_card')),
        findsNothing,
      );

      // Privacy Center exposes local-only Safe Zones and privacy explanations.
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      // Settings may retain its previously opened category in the tab stack.
      final settingsBackButton = find.byKey(
        const Key('settings_category_back_button'),
      );
      if (settingsBackButton.evaluate().isNotEmpty) {
        await tester.tap(settingsBackButton);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('settings_category_location')));
      await tester.pumpAndSettle();
      expect(find.text('Privacy Center'), findsOneWidget);
      expect(find.byKey(const Key('safe_zones_card')), findsOneWidget);
      expect(find.text('Privacy at a glance'), findsOneWidget);

      // Charger-disconnect alerts are configurable under Protection.
      await tester.tap(find.byKey(const Key('settings_category_back_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_category_protection')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('alert_on_ac_power_disconnect_switch')),
        findsOneWidget,
      );

      controller.dispose();
      await fakeDetector.dispose();
    },
  );
}
