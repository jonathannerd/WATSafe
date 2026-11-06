import '../services/audio_alarm_service.dart';
import '../services/local_storage_service.dart';
import '../services/secure_pin_storage_service.dart';
import 'app_services.dart';
import 'platform_detector_registry.dart';

AppServices createAppServices() => (
  detectors: PlatformDetectorRegistry.createDefaultDetectors(),
  defaultDetector: PlatformDetectorRegistry.defaultDetectorForCurrentPlatform(),
  audio: PlatformAudioAlarmService(),
  pinStorage: PlatformSecurePinStorage(),
  incidents: FileIncidentStorage(),
  settings: FileSettingsStorage(),
);
