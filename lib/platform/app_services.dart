import '../core/contracts/platform_contracts.dart';
import '../core/models/detector_models.dart';
import '../services/system_lifecycle_service.dart';

typedef AppServices = ({
  Map<DetectorType, MotionDetectorAdapter> detectors,
  DetectorType defaultDetector,
  AudioAlarmAdapter audio,
  SecurePinStorageAdapter pinStorage,
  IncidentStorageAdapter incidents,
  SettingsStorageAdapter settings,
  RemoteNotificationAdapter notifications,
  LocationServiceAdapter location,
  LocalNotificationAdapter localNotifications,
  SystemLifecycleAdapter systemLifecycle,
});
