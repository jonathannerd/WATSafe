import '../../core/models/detector_models.dart';
import '../../services/remote_notification_service.dart';
import '../app_services.dart';
import 'browser_alarm_audio.dart';
import 'browser_camera_detector.dart';
import 'browser_storage.dart';

AppServices createAppServices() {
  final storage = BrowserStorage();
  final camera = BrowserCameraDetector();
  return (
    detectors: {camera.detectorType: camera},
    defaultDetector: DetectorType.browserCameraSceneMotion,
    audio: BrowserAlarmAudio(),
    pinStorage: storage,
    incidents: storage,
    settings: storage,
    notifications: ConfigurableRemoteNotificationService(
      enableBackgroundPolling: true,
    ),
  );
}
