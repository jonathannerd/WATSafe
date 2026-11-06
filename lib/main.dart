import 'dart:async';

import 'package:flutter/material.dart';

import 'core/alarm/alarm_controller.dart';
import 'core/contracts/platform_contracts.dart';
import 'core/models/detector_models.dart';
import 'core/models/settings_models.dart';
import 'features/shell/watsafe_shell.dart';
import 'features/theme/watsafe_theme.dart';
import 'platform/app_services_native.dart'
    if (dart.library.js_interop) 'platform/web/app_services_web.dart'
    as platform;
import 'services/pin_security_service.dart';
import 'services/remote_notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final services = platform.createAppServices();

  final controller = AlarmController(
    detectors: services.detectors,
    audioAdapter: services.audio,
    pinService: PinSecurityService(storage: services.pinStorage),
    incidentStorage: services.incidents,
    settingsStorage: _PlatformDefaultSettingsDecorator(
      services.settings,
      services.defaultDetector,
    ),
    notificationAdapter: const UnconfiguredRemoteNotificationService(),
  );

  await controller.initialize();
  runApp(WatSafeApp(controller: controller));
}

/// Ensures the initial default detector matches the current host platform when
/// no settings file has been saved yet.
class _PlatformDefaultSettingsDecorator implements SettingsStorageAdapter {
  _PlatformDefaultSettingsDecorator(this._inner, this._defaultDetector);

  final SettingsStorageAdapter _inner;
  final DetectorType _defaultDetector;

  @override
  Future<ProtectionSettings> loadSettings() async {
    final loaded = await _inner.loadSettings();
    if (!loaded.onboardingCompleted) {
      return loaded.copyWith(selectedDetector: _defaultDetector);
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
