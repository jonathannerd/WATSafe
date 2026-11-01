import 'dart:async';

import 'package:flutter/material.dart';

import 'core/alarm/alarm_controller.dart';
import 'core/models/settings_models.dart';
import 'features/shell/watsafe_shell.dart';
import 'features/theme/watsafe_theme.dart';
import 'platform/platform_detector_registry.dart';
import 'services/audio_alarm_service.dart';
import 'services/local_storage_service.dart';
import 'services/pin_security_service.dart';
import 'services/remote_notification_service.dart';
import 'services/secure_pin_storage_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final pinStorage = PlatformSecurePinStorage();
  final pinService = PinSecurityService(storage: pinStorage);
  final incidentStorage = FileIncidentStorage();
  final settingsStorage = FileSettingsStorage();
  final audioAdapter = PlatformAudioAlarmService();
  final notificationAdapter = const UnconfiguredRemoteNotificationService();
  final detectors = PlatformDetectorRegistry.createDefaultDetectors();

  final controller = AlarmController(
    detectors: detectors,
    audioAdapter: audioAdapter,
    pinService: pinService,
    incidentStorage: incidentStorage,
    settingsStorage: _PlatformDefaultSettingsDecorator(settingsStorage),
    notificationAdapter: notificationAdapter,
  );

  await controller.initialize();
  runApp(WatSafeApp(controller: controller));
}

/// Ensures the initial default detector matches the current host platform when
/// no settings file has been saved yet.
class _PlatformDefaultSettingsDecorator extends FileSettingsStorage {
  _PlatformDefaultSettingsDecorator(this._inner);

  final FileSettingsStorage _inner;

  @override
  Future<ProtectionSettings> loadSettings() async {
    final loaded = await _inner.loadSettings();
    if (!loaded.onboardingCompleted) {
      return loaded.copyWith(
        selectedDetector:
            PlatformDetectorRegistry.defaultDetectorForCurrentPlatform(),
      );
    }
    return loaded;
  }

  @override
  Future<void> saveSettings(ProtectionSettings settings) {
    return _inner.saveSettings(settings);
  }
}

/// Root WATSafe Material 3 application widget.
class WatSafeApp extends StatelessWidget {
  const WatSafeApp({super.key, required this.controller});

  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WATSafe',
      debugShowCheckedModeBanner: false,
      theme: WatSafeTheme.darkTheme(),
      home: WatSafeShell(controller: controller),
    );
  }
}
