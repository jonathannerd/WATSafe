import '../services/audio_alarm_service.dart';
import '../services/local_notification_service.dart';
import '../services/local_storage_service.dart';
import '../services/location_service.dart';
import '../services/relay_config.dart';
import '../services/remote_notification_service.dart';
import '../services/secure_pin_storage_service.dart';
import '../services/system_lifecycle_service.dart';
import 'app_services.dart';
import 'platform_detector_registry.dart';

AppServices createAppServices() {
  final notifications = ConfigurableRemoteNotificationService(
    enableBackgroundPolling: true,
    initialRelayEndpointUrl: RelayConfig.resolveDefaultRelayUrl(),
  );
  return (
    detectors: PlatformDetectorRegistry.createDefaultDetectors(
      notificationAdapter: notifications,
    ),
    defaultDetector:
        PlatformDetectorRegistry.defaultDetectorForCurrentPlatform(),
    audio: PlatformAudioAlarmService(),
    pinStorage: PlatformSecurePinStorage(),
    incidents: FileIncidentStorage(),
    settings: FileSettingsStorage(),
    notifications: notifications,
    location: PlatformLocationService(),
    localNotifications: PlatformLocalNotificationService(),
    systemLifecycle: PlatformSystemLifecycleService(),
  );
}
