import '../../core/models/detector_models.dart';
import '../../services/relay_config.dart';
import '../../services/remote_notification_service.dart';
import '../app_services.dart';
import 'browser_alarm_audio.dart';
import 'browser_camera_detector.dart';
import 'browser_location_service.dart';
import 'browser_notification_service.dart';
import 'browser_storage.dart';

AppServices createAppServices() {
  final storage = BrowserStorage();
  final camera = BrowserCameraDetector();
  final queryRelay = Uri.base.queryParameters['relay']?.trim();
  final defaultRelay = (queryRelay != null && queryRelay.isNotEmpty)
      ? queryRelay
      : RelayConfig.resolveDefaultRelayUrl();
  return (
    detectors: {camera.detectorType: camera},
    defaultDetector: DetectorType.browserCameraSceneMotion,
    audio: BrowserAlarmAudio(),
    pinStorage: storage,
    incidents: storage,
    settings: storage,
    notifications: ConfigurableRemoteNotificationService(
      enableBackgroundPolling: true,
      initialRelayEndpointUrl: defaultRelay,
    ),
    location: BrowserLocationService(),
    localNotifications: BrowserNotificationService(),
  );
}
