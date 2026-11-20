import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../services/audio_alarm_service.dart';
import '../../services/local_notification_service.dart';
import '../../services/location_service.dart';
import '../../services/pin_security_service.dart';
import '../../services/relay_config.dart';
import '../../services/remote_notification_service.dart';
import '../../services/system_lifecycle_service.dart';
import '../contracts/platform_contracts.dart';
import '../models/detector_models.dart';
import '../models/incident_models.dart';
import '../models/settings_models.dart';
import 'alarm_state.dart';

/// Central protection state machine coordinating detector readiness, arming
/// countdown, session-scoped event filtering, lifecycle pause/resume, local
/// siren playback, PIN verification, incident persistence, non-blocking
/// location capture, and paired phone notifications.
class AlarmController extends ChangeNotifier {
  AlarmController({
    required Map<DetectorType, MotionDetectorAdapter> detectors,
    required this._audioAdapter,
    required this._pinService,
    required this._incidentStorage,
    required this._settingsStorage,
    required this._notificationAdapter,
    this._locationAdapter = const UnconfiguredLocationService(),
    LocalNotificationAdapter? localNotificationAdapter,
    SystemLifecycleAdapter? systemLifecycleAdapter,
    DateTime Function()? clock,
    this._enableDeveloperControlsForTest = false,
    this._regularLocationRefreshInterval = const Duration(minutes: 4),
    this._postAlarmLocationInterval = const Duration(seconds: 15),
    this._postAlarmTrackingMaxDuration = const Duration(minutes: 15),
    this._postAlarmMaxSamples = 40,
    this._ambiguousMotionConfirmationWindow = const Duration(
      milliseconds: 2400,
    ),
    this._inputInteractionGracePeriod = const Duration(seconds: 8),
  }) : _detectors = Map<DetectorType, MotionDetectorAdapter>.unmodifiable(
         detectors,
       ),
       _localNotificationAdapter =
           localNotificationAdapter ?? NoOpLocalNotificationService(),
       _systemLifecycleAdapter =
           systemLifecycleAdapter ?? const NoOpSystemLifecycleService(),
       _clock = clock ?? DateTime.now;

  final Map<DetectorType, MotionDetectorAdapter> _detectors;
  final AudioAlarmAdapter _audioAdapter;
  final PinSecurityService _pinService;
  final IncidentStorageAdapter _incidentStorage;
  final SettingsStorageAdapter _settingsStorage;
  final RemoteNotificationAdapter _notificationAdapter;
  final LocationServiceAdapter _locationAdapter;
  final LocalNotificationAdapter _localNotificationAdapter;
  final SystemLifecycleAdapter _systemLifecycleAdapter;
  final DateTime Function() _clock;
  final bool _enableDeveloperControlsForTest;
  final Duration _regularLocationRefreshInterval;
  final Duration _postAlarmLocationInterval;
  final Duration _postAlarmTrackingMaxDuration;
  final int _postAlarmMaxSamples;
  final Duration _ambiguousMotionConfirmationWindow;
  final Duration _inputInteractionGracePeriod;

  final Map<DetectorType, StreamSubscription<DetectorEvent>> _subscriptions =
      <DetectorType, StreamSubscription<DetectorEvent>>{};
  final Map<DetectorType, DetectorCapability> _capabilities =
      <DetectorType, DetectorCapability>{};
  final Set<DetectorType> _activeAuxiliaryDetectors = <DetectorType>{};

  ProtectionState _state = ProtectionState.disarmed;
  ProtectionSettings _settings = const ProtectionSettings();
  bool _isInitialized = false;
  bool _isDisposed = false;
  bool _hasPinConfigured = false;
  bool _isPreparingToArm = false;
  String? _activeSessionId;
  int _sessionSequence = 0;
  int _incidentSequence = 0;
  int _alarmGeneration = 0;
  int _lifecycleGeneration = 0;
  bool _alarmAudioRequested = false;
  bool _alarmInterruptedByLifecycle = false;
  bool _isRestartingAlarmAudio = false;
  Future<PinVerificationResult>? _inFlightDisarm;
  Future<bool>? _inFlightLifecycleResume;
  int _remainingCountdownSeconds = 0;
  bool _isCalibrating = false;

  Timer? _countdownTimer;
  Timer? _testAlarmTimer;
  Timer? _regularLocationTimer;
  Timer? _postAlarmLocationTimer;
  Timer? _confirmationResetTimer;
  Future<DeviceLocationSnapshot?>? _inFlightHostLocationCapture;
  DateTime? _lastHostLocationAttemptAt;
  String? _lastReportedHostLocationSignature;
  bool _isTestAlarmRunning = false;
  IncidentRecord? _activeTestIncident;

  // Bounded post-alarm location tracking & protected-device location state.
  DeviceLocationSnapshot? _hostLatestLocation;
  IncidentLocationStatus _hostLocationStatus =
      IncidentLocationStatus.notRequested;
  DeviceLocationSnapshot? _companionLatestLocation;
  IncidentLocationStatus _companionLocationStatus =
      IncidentLocationStatus.notRequested;
  List<AuthorizedDeviceLocationSummary> _authorizedDeviceLocations =
      const <AuthorizedDeviceLocationSummary>[];
  bool _isPostAlarmTrackingActive = false;
  String _postAlarmTrackingState = 'idle';
  DateTime? _postAlarmStartedAt;
  int _postAlarmSampleCount = 0;

  // Native OS power / lid / termination / idle-input lifecycle state.
  StreamSubscription<SystemLifecycleEvent>? _systemLifecycleSubscription;
  SystemLifecycleCapabilities _systemLifecycleCapabilities =
      const SystemLifecycleCapabilities.unsupported();
  Timer? _inputGraceTimer;
  bool _isInputInteractionGraceActive = false;
  Future<void>? _inFlightUrgentAlertFuture;
  String? _notifiedArmedSessionId;
  bool _activeIncidentNeedsWakeRetry = false;
  bool _activeIncidentPushFailed = false;
  Future<void>? _inFlightWakeReconcile;

  // Ambiguous camera-only movement confirmation stage ("Movement detected — checking…").
  bool _isConfirmingMovement = false;
  DateTime? _confirmationStartedAt;

  // Safe silent Guided Protection Test state.
  bool _isGuidedTestRunning = false;
  String? _guidedTestSessionId;
  String _guidedTestPhase = 'idle';
  int _guidedTestFalseTriggers = 0;
  bool _guidedTestPickupDetected = false;
  Duration? _guidedTestPickupLatency;
  DateTime? _guidedTestPhaseStartedAt;

  DetectorEvent? _lastTelemetryEvent;
  IncidentRecord? _activeIncident;
  List<IncidentRecord> _incidents = const <IncidentRecord>[];
  int _incidentHistoryGeneration = 0;
  final Set<Future<void>> _inFlightIncidentWrites = <Future<void>>{};

  String _statusMessage = 'Starting WATSafe…';
  String? _warningMessage;

  PermissionStatus _locationPermissionStatus = PermissionStatus.notDetermined;
  PermissionStatus _localNotificationPermissionStatus =
      PermissionStatus.notDetermined;

  NotificationServiceStatus _notificationStatus =
      const NotificationServiceStatus(
        capabilityStatus: CapabilityStatus.notConfigured,
        summary: 'No phone paired',
        detail:
            'Pair your phone on Home to receive alerts when an alarm triggers.',
      );
  List<PairedDeviceSummary> _pairedDevices = const <PairedDeviceSummary>[];
  StreamSubscription<CompanionAlertEvent>? _companionAlertsSubscription;
  StreamSubscription<String>? _notificationTapsSubscription;
  CompanionAlertEvent? _latestUnacknowledgedCompanionAlert;
  String? _lastHostDisplayName;
  bool _isPreviewingOnboarding = false;

  String? _selectedActivityIncidentId;
  int _openActivityNonce = 0;
  final StreamController<String> _openActivityIncidentController =
      StreamController<String>.broadcast();

  // Public getters
  ProtectionState get state => _state;
  ProtectionSettings get settings => _settings;
  bool get isInitialized => _isInitialized;
  bool get hasPinConfigured => _hasPinConfigured;
  bool get isPreviewingOnboarding => _isPreviewingOnboarding;
  bool get enableDeveloperControls =>
      kDebugMode || _enableDeveloperControlsForTest;
  String? get activeSessionId => _activeSessionId;
  int get remainingCountdownSeconds => _remainingCountdownSeconds;
  bool get isCalibrating => _isCalibrating;
  bool get isTestAlarmRunning => _isTestAlarmRunning;
  bool get isAudioPlaying => _audioAdapter.isPlaying;
  bool get wasAlarmInterruptedByLifecycle => _alarmInterruptedByLifecycle;
  Set<DetectorType> get activeAuxiliaryDetectors =>
      Set<DetectorType>.unmodifiable(_activeAuxiliaryDetectors);
  String get audioLimitationsNote => _audioAdapter.audioLimitationsNote;
  String get pinStorageDescription => _pinService.storageBackendDescription;
  int get failedPinAttempts => _pinService.failedAttempts;
  bool get isPinLockedOut => _pinService.isLockedOut;
  Duration get remainingPinLockout => _pinService.remainingLockout;

  bool get isLocationSupported => _locationAdapter.isSupported;
  PermissionStatus get locationPermissionStatus => _locationPermissionStatus;
  DeviceLocationSnapshot? get hostLatestLocation => _hostLatestLocation;
  IncidentLocationStatus get hostLocationStatus => _hostLocationStatus;
  DeviceLocationSnapshot? get companionLatestLocation =>
      _companionLatestLocation;
  IncidentLocationStatus get companionLocationStatus =>
      _companionLocationStatus;
  bool get isPostAlarmTrackingActive => _isPostAlarmTrackingActive;
  String get postAlarmTrackingState => _postAlarmTrackingState;
  bool get isConfirmingMovement => _isConfirmingMovement;
  String? get confirmationMessage =>
      _isConfirmingMovement ? 'Movement detected — checking…' : null;
  SystemLifecycleCapabilities get systemLifecycleCapabilities =>
      _systemLifecycleCapabilities;
  bool get isInputInteractionGraceActive => _isInputInteractionGraceActive;
  bool get isInputInteractionDetectionSupported =>
      _systemLifecycleCapabilities.supportsInputInteractionDetection ||
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.windows));
  bool get isCompanionMode =>
      companionSession.isConnected &&
      _pairedDevices.isEmpty &&
      _state == ProtectionState.disarmed;

  bool get isGuidedTestRunning => _isGuidedTestRunning;
  String get guidedTestPhase => _guidedTestPhase;
  int get guidedTestFalseTriggers => _guidedTestFalseTriggers;
  bool get guidedTestPickupDetected => _guidedTestPickupDetected;
  Duration? get guidedTestPickupLatency => _guidedTestPickupLatency;

  /// Authorized devices for the current user/pairing relationship, always
  /// attributing protected-device coordinates strictly to the protected device
  /// and never mislabeling the companion phone's position as the laptop's.
  List<AuthorizedDeviceLocationSummary> get authorizedDeviceLocations {
    final now = _clock();
    final session = companionSession;
    final companionMode = isCompanionMode;

    if (_authorizedDeviceLocations.isNotEmpty) {
      if (companionMode) {
        return _authorizedDeviceLocations
            .map((entry) {
              if (entry.isProtectedDevice) {
                return entry;
              }
              final isSelf =
                  entry.isCurrentRequester ||
                  (session.deviceId != null &&
                      entry.deviceId == session.deviceId);
              if (!isSelf) {
                return entry;
              }
              final effectiveLoc = _settings.shareCompanionPhoneLocation
                  ? (_companionLatestLocation ?? entry.latestLocation)
                  : entry.latestLocation;
              final effectiveSharing =
                  _settings.shareCompanionPhoneLocation ||
                  entry.locationSharingEnabled;
              final isFreshLivePhone =
                  effectiveLoc != null &&
                  !effectiveLoc.isLastKnown &&
                  effectiveSharing &&
                  entry.online &&
                  now.difference(effectiveLoc.capturedAt) <=
                      const Duration(seconds: 90);
              return AuthorizedDeviceLocationSummary(
                deviceId: entry.deviceId,
                displayName: entry.displayName,
                role: entry.role,
                platform: entry.platform,
                online: entry.online,
                connectionStatusLabel:
                    entry.connectionStatusLabel ??
                    (entry.online ? 'Online' : 'Offline'),
                protectionStatusLabel: entry.protectionStatusLabel,
                isCurrentRequester: true,
                locationSharingEnabled: effectiveSharing,
                readableLocationSummary: entry.readableLocationSummary,
                isAlarming: false,
                trackingState: effectiveLoc != null
                    ? (isFreshLivePhone && entry.trackingState == 'live'
                          ? 'live'
                          : 'last_known')
                    : 'unavailable',
                latestLocation: effectiveLoc,
                locationStatus: effectiveLoc != null
                    ? IncidentLocationStatus.attached
                    : (_settings.shareCompanionPhoneLocation
                          ? _companionLocationStatus
                          : entry.locationStatus),
                statusExplanation: _buildCompanionSelfLocationExplanation(
                  effectiveLoc,
                  effectiveSharing,
                ),
                lastSeenAt: effectiveLoc?.capturedAt ?? entry.lastSeenAt ?? now,
              );
            })
            .toList(growable: false);
      }
      // Merge fresher local protected-device state on the host itself and
      // downgrade any cached companion phone coordinate older than 90s to last_known.
      return _authorizedDeviceLocations
          .map((entry) {
            if (!entry.isProtectedDevice) {
              final compLoc = entry.latestLocation;
              if (compLoc != null &&
                  entry.trackingState == 'live' &&
                  (compLoc.isLastKnown ||
                      now.difference(compLoc.capturedAt) >
                          const Duration(seconds: 90))) {
                return AuthorizedDeviceLocationSummary(
                  deviceId: entry.deviceId,
                  displayName: entry.displayName,
                  role: entry.role,
                  platform: entry.platform,
                  online: entry.online,
                  connectionStatusLabel: entry.connectionStatusLabel,
                  protectionStatusLabel: entry.protectionStatusLabel,
                  isCurrentRequester: entry.isCurrentRequester,
                  locationSharingEnabled: entry.locationSharingEnabled,
                  readableLocationSummary: entry.readableLocationSummary,
                  isAlarming: entry.isAlarming,
                  trackingState: 'last_known',
                  latestLocation: compLoc,
                  locationStatus: entry.locationStatus,
                  statusExplanation: entry.statusExplanation,
                  lastSeenAt: entry.lastSeenAt,
                );
              }
              return entry;
            }
            final localLoc = _activeIncident?.location ?? _hostLatestLocation;
            final localAlarmLoc =
                _activeIncident?.effectiveAlarmLocation ??
                entry.alarmTimeLocation;
            final localTrail =
                _activeIncident != null &&
                    _activeIncident!.locationTrail.isNotEmpty
                ? _activeIncident!.locationTrail
                : entry.locationTrail;
            final localStatus = _activeIncident != null
                ? _activeIncident!.locationStatus
                : _hostLocationStatus;
            final effectiveLoc = localLoc ?? entry.latestLocation;
            final isRecentHostFix =
                effectiveLoc != null &&
                !effectiveLoc.isLastKnown &&
                now.difference(effectiveLoc.capturedAt) <=
                    const Duration(minutes: 15);
            final tracking = _isPostAlarmTrackingActive
                ? (_postAlarmTrackingState == 'reconnecting'
                      ? 'reconnecting'
                      : 'live')
                : (effectiveLoc != null
                      ? (isRecentHostFix ? 'recent' : 'last_known')
                      : entry.trackingState);
            return AuthorizedDeviceLocationSummary(
              deviceId: entry.deviceId,
              displayName: effectiveDeviceName,
              role: 'protected_device',
              platform: entry.platform,
              online: true,
              connectionStatusLabel: 'Online',
              protectionStatusLabel: _state.badgeLabel,
              isCurrentRequester: true,
              locationSharingEnabled: _settings.shareLocationOnAlarm,
              readableLocationSummary: entry.readableLocationSummary,
              isAlarming: _state == ProtectionState.alarming,
              trackingState: tracking,
              latestLocation: effectiveLoc,
              alarmTimeLocation: localAlarmLoc,
              locationTrail: localTrail,
              locationStatus: localLoc != null
                  ? localStatus
                  : entry.locationStatus,
              statusExplanation: _buildLocalLocationExplanation(
                effectiveLoc,
                localLoc != null ? localStatus : entry.locationStatus,
              ),
              activeIncidentId: _activeIncident?.id ?? entry.activeIncidentId,
              lastSeenAt: effectiveLoc?.capturedAt ?? entry.lastSeenAt ?? now,
            );
          })
          .toList(growable: false);
    }

    if (companionMode) {
      CompanionAlertEvent? latestAlertWithLoc;
      for (final alert in receivedCompanionAlerts) {
        if (alert.location != null) {
          latestAlertWithLoc = alert;
          break;
        }
      }
      final fallbackAlert = receivedCompanionAlerts.isNotEmpty
          ? receivedCompanionAlerts.first
          : null;
      final hostOfflineFromStatus = (session.statusMessage ?? '')
          .toLowerCase()
          .contains('offline');
      final hostOnline = !hostOfflineFromStatus;
      final isHostInterrupted = fallbackAlert?.kind == 'protectionInterrupted';
      final isHostAlarming = fallbackAlert?.locationTrackingState == 'live';
      final hostStatusLabel = isHostAlarming
          ? 'Alarm triggered'
          : (isHostInterrupted
                ? 'Protection interrupted'
                : (hostOnline ? 'Protected' : 'Protection off'));
      final resolvedLoc = latestAlertWithLoc?.location;
      final resolvedStatus =
          latestAlertWithLoc?.locationStatus ??
          fallbackAlert?.locationStatus ??
          IncidentLocationStatus.notRequested;
      final tracking = !hostOnline
          ? (resolvedLoc != null ? 'last_known' : 'unavailable')
          : (fallbackAlert?.locationTrackingState == 'live'
                ? 'live'
                : (resolvedLoc != null ? 'last_known' : 'unavailable'));
      final selfLoc = _settings.shareCompanionPhoneLocation
          ? _companionLatestLocation
          : null;
      return <AuthorizedDeviceLocationSummary>[
        AuthorizedDeviceLocationSummary(
          deviceId: 'host_${session.pairingSessionId ?? "paired"}',
          displayName: session.hostDisplayName ?? 'Protected Device',
          role: 'protected_device',
          platform: 'Protected laptop',
          online: hostOnline,
          connectionStatusLabel: hostOnline ? 'Online' : 'Offline',
          protectionStatusLabel: hostStatusLabel,
          isAlarming: isHostAlarming,
          trackingState: tracking,
          latestLocation: resolvedLoc,
          alarmTimeLocation:
              latestAlertWithLoc?.alarmTimeLocation ?? resolvedLoc,
          locationTrail:
              latestAlertWithLoc?.locationTrail ??
              const <DeviceLocationSnapshot>[],
          locationStatus: resolvedStatus,
          statusExplanation: resolvedLoc == null
              ? (!hostOnline
                    ? 'Device is offline or sleeping. New coordinates arrive when it reconnects.'
                    : _buildCompanionMissingLocationExplanation(resolvedStatus))
              : null,
          activeIncidentId: fallbackAlert?.incidentId,
          lastSeenAt: resolvedLoc?.capturedAt ?? fallbackAlert?.triggeredAt,
        ),
        AuthorizedDeviceLocationSummary(
          deviceId: session.deviceId ?? 'companion_self',
          displayName: session.phoneDisplayName ?? 'My Phone',
          role: 'companion_phone',
          platform: 'Phone companion',
          online: true,
          connectionStatusLabel: 'Online',
          protectionStatusLabel: 'Companion · Alerts on',
          isCurrentRequester: true,
          locationSharingEnabled: _settings.shareCompanionPhoneLocation,
          trackingState: selfLoc != null ? 'last_known' : 'unavailable',
          latestLocation: selfLoc,
          locationStatus: selfLoc != null
              ? IncidentLocationStatus.attached
              : (_settings.shareCompanionPhoneLocation
                    ? _companionLocationStatus
                    : IncidentLocationStatus.notRequested),
          statusExplanation: _buildCompanionSelfLocationExplanation(
            selfLoc,
            _settings.shareCompanionPhoneLocation,
          ),
          lastSeenAt: selfLoc?.capturedAt ?? now,
        ),
      ];
    }

    final localHostLoc = _activeIncident?.location ?? _hostLatestLocation;
    final localHostStatus = !_settings.shareLocationOnAlarm
        ? IncidentLocationStatus.notRequested
        : (localHostLoc != null
              ? IncidentLocationStatus.attached
              : (_activeIncident?.locationStatus ?? _hostLocationStatus));
    final isRecentLocalHostFix =
        localHostLoc != null &&
        !localHostLoc.isLastKnown &&
        now.difference(localHostLoc.capturedAt) <= const Duration(minutes: 15);
    final localTracking = _isPostAlarmTrackingActive
        ? (_postAlarmTrackingState == 'reconnecting' ? 'reconnecting' : 'live')
        : (localHostLoc != null
              ? (isRecentLocalHostFix ? 'recent' : 'last_known')
              : 'unavailable');
    return <AuthorizedDeviceLocationSummary>[
      AuthorizedDeviceLocationSummary(
        deviceId: 'local_protected_host',
        displayName: effectiveDeviceName,
        role: 'protected_device',
        platform: selectedDetectorType.userFacingMethodName,
        online: true,
        connectionStatusLabel: 'Online',
        protectionStatusLabel: _state.badgeLabel,
        isCurrentRequester: true,
        locationSharingEnabled: _settings.shareLocationOnAlarm,
        isAlarming: _state == ProtectionState.alarming,
        trackingState: localTracking,
        latestLocation: localHostLoc,
        alarmTimeLocation:
            _activeIncident?.effectiveAlarmLocation ?? localHostLoc,
        locationTrail:
            _activeIncident?.locationTrail ?? const <DeviceLocationSnapshot>[],
        locationStatus: localHostStatus,
        statusExplanation: _buildLocalLocationExplanation(
          localHostLoc,
          localHostStatus,
        ),
        activeIncidentId: _activeIncident?.id,
        lastSeenAt: localHostLoc?.capturedAt ?? now,
      ),
      for (final phone in _pairedDevices)
        AuthorizedDeviceLocationSummary(
          deviceId: phone.deviceId,
          displayName: phone.displayName,
          role: 'companion_phone',
          platform: phone.platform,
          online: phone.connected,
          connectionStatusLabel: phone.connected ? 'Online' : 'Offline',
          protectionStatusLabel: phone.notificationsEnabled
              ? 'Companion · Alerts on'
              : 'Companion · Paired',
          trackingState: 'unavailable',
          locationStatus: IncidentLocationStatus.notRequested,
          statusExplanation: 'Paired companion phone. Share phone location from the phone app to view both devices on the map.',
          lastSeenAt: phone.lastSeenAt,
        ),
    ];
  }

  String? _buildCompanionSelfLocationExplanation(
    DeviceLocationSnapshot? loc,
    bool sharingEnabled,
  ) {
    if (loc != null) {
      return 'Foreground phone location is shared while WATSafe is open.';
    }
    if (!sharingEnabled) {
      return 'Phone location sharing is off. Tap "Share this phone’s location" to show this phone alongside your laptop.';
    }
    if (_companionLocationStatus == IncidentLocationStatus.permissionDenied ||
        _locationPermissionStatus == PermissionStatus.denied ||
        _locationPermissionStatus == PermissionStatus.restricted) {
      return 'Phone location permission was denied. Allow Location access in system settings, then tap Refresh.';
    }
    if (_companionLocationStatus == IncidentLocationStatus.pending) {
      return 'Getting this phone’s foreground location…';
    }
    return 'Open WATSafe and tap Refresh to update this phone’s foreground location.';
  }

  String? _buildLocalLocationExplanation(
    DeviceLocationSnapshot? loc,
    IncidentLocationStatus status,
  ) {
    if (loc != null) {
      return null;
    }
    if (!_settings.shareLocationOnAlarm) {
      return 'Location sharing is turned off in Settings.';
    }
    if (!_locationAdapter.isSupported) {
      return 'Location services are not supported on this device.';
    }
    if (status == IncidentLocationStatus.permissionDenied ||
        _locationPermissionStatus == PermissionStatus.denied ||
        _locationPermissionStatus == PermissionStatus.restricted) {
      return 'Location permission is turned off. Allow location access in system settings to locate this device.';
    }
    if (status == IncidentLocationStatus.pending) {
      return 'Getting device location…';
    }
    return 'No location recorded yet. Tap Refresh or arm protection to capture this device\'s position.';
  }

  String _buildCompanionMissingLocationExplanation(
    IncidentLocationStatus status,
  ) {
    switch (status) {
      case IncidentLocationStatus.permissionDenied:
        return 'Location permission is turned off on the protected device.';
      case IncidentLocationStatus.pending:
        return 'Getting device location…';
      case IncidentLocationStatus.unavailable:
        return 'The protected device could not determine a Wi-Fi or GPS fix.';
      case IncidentLocationStatus.notRequested:
      case IncidentLocationStatus.attached:
        return 'Location sharing has not reported a position from the protected device yet.';
    }
  }

  bool get isLocalNotificationsSupported =>
      _localNotificationAdapter.isSupported;
  String get localNotificationChannelKind =>
      _localNotificationAdapter.channelKind;
  PermissionStatus get localNotificationPermissionStatus =>
      _localNotificationPermissionStatus;

  String get effectiveDeviceName {
    final custom = _settings.deviceDisplayName.trim();
    if (custom.isNotEmpty) {
      return custom;
    }
    final rememberedHost = _lastHostDisplayName?.trim();
    if (rememberedHost != null && rememberedHost.isNotEmpty) {
      return rememberedHost;
    }
    final inviteHost = activePairingInvitation?.hostDisplayName?.trim();
    if (inviteHost != null && inviteHost.isNotEmpty) {
      return inviteHost;
    }
    switch (_settings.selectedDetector) {
      case DetectorType.macosCameraSceneMotion:
        return 'My MacBook';
      case DetectorType.windowsCameraSceneMotion:
      case DetectorType.windowsAccelerometer:
        return 'My Laptop';
      case DetectorType.iosCoreMotionForeground:
        return 'My iPhone';
      case DetectorType.androidMotionSensors:
        return 'My Phone';
      case DetectorType.browserCameraSceneMotion:
        break;
    }
    if (kIsWeb) {
      return 'My Browser';
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
        return 'My MacBook';
      case TargetPlatform.windows:
        return 'My Laptop';
      case TargetPlatform.iOS:
        return 'My iPhone';
      case TargetPlatform.android:
        return 'My Phone';
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return 'My Device';
    }
  }

  DetectorType get selectedDetectorType => _settings.selectedDetector;
  MotionDetectorAdapter? get selectedDetector =>
      _detectors[_settings.selectedDetector];

  DetectorCapability? get selectedCapability =>
      _capabilities[_settings.selectedDetector];

  Map<DetectorType, DetectorCapability> get capabilities =>
      Map<DetectorType, DetectorCapability>.unmodifiable(_capabilities);

  /// Registered detectors relevant to this device (sorted so ready/supported
  /// detectors appear first without cluttering the user with unsupported OS drivers).
  List<DetectorType> get availableHostDetectors {
    final hostEligible = _detectors.keys.where((type) {
      final cap = _capabilities[type];
      if (type == _settings.selectedDetector) {
        return true;
      }
      if (cap == null) {
        return false;
      }
      return cap.canArm || cap.status == CapabilityStatus.permissionRequired;
    }).toList();
    if (hostEligible.isNotEmpty) {
      return hostEligible;
    }
    return _detectors.keys.toList(growable: false);
  }

  DetectorEvent? get lastTelemetryEvent => _lastTelemetryEvent;
  IncidentRecord? get activeIncident => _activeIncident;
  List<IncidentRecord> get incidents =>
      List<IncidentRecord>.unmodifiable(_incidents);

  String get statusMessage => _statusMessage;
  String? get warningMessage => _warningMessage;
  NotificationServiceStatus get notificationStatus => _notificationStatus;
  List<PairedDeviceSummary> get pairedDevices =>
      List<PairedDeviceSummary>.unmodifiable(_pairedDevices);
  List<PairedDeviceActionRecord> get pairedDeviceActions {
    final adapter = _notificationAdapter;
    if (adapter is MutableRemoteNotificationAdapter) {
      return adapter.actionHistory;
    }
    return const <PairedDeviceActionRecord>[];
  }

  bool get canManagePairing =>
      _notificationAdapter is MutableRemoteNotificationAdapter;
  String? get relayEndpointUrl {
    final adapter = _notificationAdapter;
    return adapter is MutableRemoteNotificationAdapter
        ? adapter.relayEndpointUrl
        : null;
  }

  /// True when [relayEndpointUrl] is a stable, non-ephemeral `https://` origin
  /// suitable for one-time iPhone Home Screen PWA installation and durable pairing.
  bool get isPermanentRelayConfigured =>
      RelayConfig.isPermanentHttpsUrl(relayEndpointUrl);

  /// True when [relayEndpointUrl] is a temporary quick-tunnel hostname
  /// (`*.trycloudflare.com`, `*.lhr.life`, `*.ngrok-free.app`, etc.) that will
  /// change when the tunnel restarts.
  bool get isEphemeralTunnelRelay =>
      RelayConfig.isEphemeralTunnelUrl(relayEndpointUrl);

  void _syncHostPresenceMetadata({
    bool immediateHeartbeatIfBackground = false,
  }) {
    final adapter = _notificationAdapter;
    if (adapter is ConfigurableRemoteNotificationService) {
      unawaited(
        adapter.updateHostPresence(
          hostDisplayName: effectiveDeviceName,
          protectionState: _state.name,
          sendImmediateHeartbeat:
              immediateHeartbeatIfBackground && adapter.enableBackgroundPolling,
        ),
      );
    }
  }

  PairingCodeInvitation? get activePairingInvitation {
    final adapter = _notificationAdapter;
    return adapter is MutableRemoteNotificationAdapter
        ? adapter.activePairingInvitation
        : null;
  }

  CompanionSessionState get companionSession {
    final adapter = _notificationAdapter;
    return adapter is MutableRemoteNotificationAdapter
        ? adapter.companionSession
        : CompanionSessionState.disconnected;
  }

  List<CompanionAlertEvent> get receivedCompanionAlerts {
    final adapter = _notificationAdapter;
    return adapter is MutableRemoteNotificationAdapter
        ? adapter.receivedCompanionAlerts
        : const <CompanionAlertEvent>[];
  }

  CompanionAlertEvent? get latestUnacknowledgedCompanionAlert =>
      _latestUnacknowledgedCompanionAlert;

  String? get selectedActivityIncidentId => _selectedActivityIncidentId;
  int get openActivityNonce => _openActivityNonce;
  Stream<String> get onOpenActivityIncident =>
      _openActivityIncidentController.stream;

  void openIncidentInActivity(String incidentId) {
    if (incidentId.trim().isEmpty) {
      return;
    }
    _selectedActivityIncidentId = incidentId.trim();
    ++_openActivityNonce;
    if (_latestUnacknowledgedCompanionAlert?.incidentId ==
        _selectedActivityIncidentId) {
      _latestUnacknowledgedCompanionAlert = null;
    }
    if (!_openActivityIncidentController.isClosed) {
      _openActivityIncidentController.add(_selectedActivityIncidentId!);
    }
    notifyListeners();
  }

  void clearSelectedActivityIncident() {
    if (_selectedActivityIncidentId != null) {
      _selectedActivityIncidentId = null;
      notifyListeners();
    }
  }

  void dismissCompanionAlertBanner() {
    if (_latestUnacknowledgedCompanionAlert != null) {
      _latestUnacknowledgedCompanionAlert = null;
      notifyListeners();
    }
  }

  /// Initializes settings, PIN state, incident history, permissions, detector
  /// capabilities, and event stream subscriptions.
  Future<void> initialize() async {
    try {
      _settings = await _settingsStorage.loadSettings();
    } catch (_) {
      _settings = const ProtectionSettings();
    }

    if (!_detectors.containsKey(_settings.selectedDetector) &&
        _detectors.isNotEmpty) {
      _settings = _settings.copyWith(selectedDetector: _detectors.keys.first);
    }

    await _syncAudioAdapterSound();

    try {
      _hasPinConfigured = await _pinService.hasConfiguredPin();
    } catch (_) {
      _hasPinConfigured = false;
    }

    try {
      _incidents = await _incidentStorage.loadIncidents();
    } catch (_) {
      _incidents = const <IncidentRecord>[];
    }

    await refreshPermissionStatuses(notify: false);
    _hostLocationStatus = _determineInitialHostLocationStatus();
    for (final item in _incidents) {
      if (item.location != null) {
        _hostLatestLocation = item.location;
        if (_settings.shareLocationOnAlarm) {
          _hostLocationStatus = IncidentLocationStatus.attached;
        }
        break;
      }
    }

    final mutableNotifications = _notificationAdapter;
    if (mutableNotifications is MutableRemoteNotificationAdapter &&
        !RelayConfig.hasExplicitCompileOrEnvOverride) {
      final allowHostDiskConfig =
          mutableNotifications is ConfigurableRemoteNotificationService &&
          mutableNotifications.usesSystemStorageDirectory;
      final savedSettingsPermanent = _settings.permanentRelayEndpointUrl.trim();
      final savedFilePermanent = allowHostDiskConfig
          ? RelayConfig.persistedPermanentRelayUrl?.trim()
          : null;
      final effectivePermanent =
          RelayConfig.isPermanentHttpsUrl(savedSettingsPermanent)
          ? savedSettingsPermanent
          : (RelayConfig.isPermanentHttpsUrl(savedFilePermanent)
                ? savedFilePermanent
                : null);
      if (effectivePermanent != null) {
        try {
          await mutableNotifications.configureRelayEndpoint(effectivePermanent);
        } catch (_) {
          // Keep current endpoint and retry on background poll.
        }
      }
      if (effectivePermanent != null &&
          savedSettingsPermanent != effectivePermanent) {
        _settings = _settings.copyWith(
          permanentRelayEndpointUrl: effectivePermanent,
        );
        await _persistSettingsSafely();
      }
    }

    try {
      _notificationStatus = await _notificationAdapter.getStatus();
      _pairedDevices = await _notificationAdapter.listPairedDevices();
    } catch (_) {
      // Keep default unconfigured status
    }

    await _notificationTapsSubscription?.cancel();
    _notificationTapsSubscription = _localNotificationAdapter.notificationTaps
        .listen(openIncidentInActivity);
    final initialTappedIncidentId = _localNotificationAdapter
        .consumeInitialTappedIncidentId();
    if (initialTappedIncidentId != null &&
        initialTappedIncidentId.trim().isNotEmpty) {
      _selectedActivityIncidentId = initialTappedIncidentId.trim();
    }

    if (mutableNotifications is MutableRemoteNotificationAdapter) {
      mutableNotifications.onStateChanged = () {
        unawaited(refreshNotificationStatus());
      };
      mutableNotifications.onHostLocationRefreshRequested =
          _handleRemoteHostLocationRefreshRequest;
      await _companionAlertsSubscription?.cancel();
      _companionAlertsSubscription = mutableNotifications
          .incomingCompanionAlerts
          .listen((alert) {
            _latestUnacknowledgedCompanionAlert = alert;
            notifyListeners();
            unawaited(
              _localNotificationAdapter.showAlertNotification(
                incidentId: alert.incidentId,
                deviceName: alert.hostDisplayName ?? 'Protected Device',
                message: alert.isTest
                    ? 'Test alert — tap to view event'
                    : (alert.kind == 'protectionInterrupted'
                          ? 'Protection interrupted — tap to view status and last known location'
                          : 'Alarm triggered — tap to view event'),
                isTest: alert.isTest,
              ),
            );
          });
    }

    try {
      _systemLifecycleCapabilities = await _systemLifecycleAdapter.initialize();
    } catch (_) {
      _systemLifecycleCapabilities =
          const SystemLifecycleCapabilities.unsupported();
    }
    await _systemLifecycleSubscription?.cancel();
    _systemLifecycleSubscription = _systemLifecycleAdapter.events.listen(
      _handleSystemLifecycleEvent,
    );

    for (final entry in _detectors.entries) {
      await _subscriptions[entry.key]?.cancel();
      _subscriptions[entry.key] = entry.value.events.listen(
        _handleDetectorEvent,
      );
    }

    await refreshCapabilities();
    if (_settings.selectedDetector == DetectorType.windowsAccelerometer) {
      final accelCap = _capabilities[DetectorType.windowsAccelerometer];
      final camCap = _capabilities[DetectorType.windowsCameraSceneMotion];
      if ((accelCap == null || !accelCap.canArm) &&
          camCap != null &&
          (camCap.canArm ||
              camCap.status == CapabilityStatus.permissionRequired)) {
        _settings = _settings.copyWith(
          selectedDetector: DetectorType.windowsCameraSceneMotion,
        );
        await _persistSettingsSafely();
        await refreshCapabilities();
      }
    }
    _isInitialized = true;
    _syncHostPresenceMetadata(immediateHeartbeatIfBackground: true);
    _ensureRegularLocationSchedule(immediateCapture: true);
    notifyListeners();

    if (_selectedActivityIncidentId != null &&
        !_openActivityIncidentController.isClosed) {
      final targetId = _selectedActivityIncidentId!;
      scheduleMicrotask(() {
        if (!_openActivityIncidentController.isClosed) {
          _openActivityIncidentController.add(targetId);
        }
      });
    }
  }

  /// Refreshes location and notification permission statuses without prompting.
  Future<void> refreshPermissionStatuses({bool notify = true}) async {
    try {
      _locationPermissionStatus = await _locationAdapter.checkPermission();
    } catch (_) {
      _locationPermissionStatus = PermissionStatus.notApplicable;
    }
    try {
      _localNotificationPermissionStatus = await _localNotificationAdapter
          .checkPermission();
    } catch (_) {
      _localNotificationPermissionStatus = PermissionStatus.notApplicable;
    }
    if (notify) {
      notifyListeners();
    }
  }

  /// Requests location permission on the protected device so its location can
  /// be shared with a paired phone when an alarm triggers.
  Future<PermissionStatus> requestLocationPermission() async {
    try {
      _locationPermissionStatus = await _locationAdapter.requestPermission();
    } catch (_) {
      _locationPermissionStatus = PermissionStatus.denied;
    }
    if (_locationPermissionStatus == PermissionStatus.granted &&
        _settings.shareLocationOnAlarm) {
      _ensureRegularLocationSchedule(immediateCapture: true);
    }
    notifyListeners();
    return _locationPermissionStatus;
  }

  /// Requests OS or browser notification permission and syncs the updated
  /// delivery capability to the relay if paired as a companion phone.
  Future<PermissionStatus> requestLocalNotificationPermission() async {
    try {
      _localNotificationPermissionStatus = await _localNotificationAdapter
          .requestPermission();
    } catch (_) {
      _localNotificationPermissionStatus = PermissionStatus.denied;
    }

    final enabled =
        _localNotificationPermissionStatus == PermissionStatus.granted;
    final adapter = _notificationAdapter;
    if (adapter is MutableRemoteNotificationAdapter &&
        adapter.companionSession.isConnected) {
      final token = await _localNotificationAdapter.getPushRegistrationToken();
      await adapter.updateCompanionNotificationStatus(
        notificationsEnabled: enabled,
        deliveryChannel: enabled
            ? _localNotificationAdapter.channelKind
            : 'foreground_only',
        pushToken: token,
      );
      await refreshNotificationStatus();
    } else {
      notifyListeners();
    }
    return _localNotificationPermissionStatus;
  }

  /// Opens an external Maps or settings URL safely via the platform adapter.
  Future<bool> openExternalUrl(String url) {
    return _localNotificationAdapter.openExternalUrl(url);
  }

  /// Updates this device's friendly display name (shown during phone pairing
  /// and in alarm notifications).
  Future<void> updateDeviceDisplayName(String name) async {
    _settings = _settings.copyWith(deviceDisplayName: name.trim());
    await _persistSettingsSafely();
    _syncHostPresenceMetadata(immediateHeartbeatIfBackground: true);
    notifyListeners();
  }

  /// Enables or disables sharing this device's location with a paired phone
  /// when protection is active or an alarm triggers.
  ///
  /// Requests OS location permission at the point of need when enabled, and
  /// immediately halts any active location reporting when turned off.
  Future<void> updateShareLocationOnAlarm(bool enabled) async {
    _settings = _settings.copyWith(shareLocationOnAlarm: enabled);
    await _persistSettingsSafely();

    if (!enabled) {
      _stopRegularLocationSchedule();
      _stopPostAlarmLocationTracking(markIncidentStopped: true);
      _hostLocationStatus = IncidentLocationStatus.notRequested;
      _lastReportedHostLocationSignature = null;
      final adapter = _notificationAdapter;
      if (adapter is MutableRemoteNotificationAdapter) {
        unawaited(
          adapter.reportHostLocation(
            location: null,
            locationStatus: IncidentLocationStatus.notRequested,
            protectionState: _state.badgeLabel,
          ),
        );
      }
      notifyListeners();
      return;
    }

    if (_locationAdapter.isSupported &&
        _locationPermissionStatus == PermissionStatus.notDetermined) {
      await requestLocationPermission();
    } else {
      await refreshPermissionStatuses(notify: false);
    }
    _hostLocationStatus = _determineInitialHostLocationStatus();
    _ensureRegularLocationSchedule(immediateCapture: true);
    _syncNativeLifecycleContextOnly();
    notifyListeners();
  }

  /// Enables or disables triggering an immediate tamper alarm and phone alert
  /// when the webcam is covered or loses visibility while armed.
  Future<void> updateAlertOnCameraObstruction(bool enabled) async {
    _settings = _settings.copyWith(alertOnCameraObstruction: enabled);
    await _persistSettingsSafely();
    notifyListeners();
  }

  /// Enables or disables optional keyboard/trackpad activity warnings while
  /// protection is armed on supported desktop platforms.
  ///
  /// Uses OS idle-input timing only (no keylogging or Accessibility hooks) and
  /// grants an 8-second grace period to enter the disarm PIN before alarming.
  Future<void> updateAlertOnInputInteraction(bool enabled) async {
    _settings = _settings.copyWith(alertOnInputInteraction: enabled);
    await _persistSettingsSafely();
    if (!enabled) {
      _clearInputInteractionGrace(notify: false);
    }
    _syncNativeLifecycleContextOnly();
    notifyListeners();
  }

  /// Explicitly enables or disables sharing this companion phone's own
  /// foreground location on the Devices map.
  ///
  /// Requests OS/browser geolocation permission strictly on user opt-in and
  /// clears stored phone coordinates immediately when disabled.
  Future<void> updateShareCompanionPhoneLocation(bool enabled) async {
    _settings = _settings.copyWith(shareCompanionPhoneLocation: enabled);
    await _persistSettingsSafely();

    final adapter = _notificationAdapter;
    if (!enabled) {
      _companionLatestLocation = null;
      _companionLocationStatus = IncidentLocationStatus.notRequested;
      if (adapter is MutableRemoteNotificationAdapter &&
          adapter.companionSession.isConnected) {
        unawaited(
          adapter.reportCompanionLocation(
            location: null,
            sharingEnabled: false,
            locationStatus: IncidentLocationStatus.notRequested,
          ),
        );
      }
      await refreshAuthorizedDeviceLocations();
      notifyListeners();
      return;
    }

    if (_locationAdapter.isSupported &&
        _locationPermissionStatus == PermissionStatus.notDetermined) {
      await requestLocationPermission();
    } else {
      await refreshPermissionStatuses(notify: false);
    }
    await refreshCompanionPhoneLocation(highAccuracy: true);
  }

  /// Captures and uploads this companion phone's foreground location when
  /// explicitly opted in by the user, without modifying the protected laptop's
  /// location record.
  Future<DeviceLocationSnapshot?> refreshCompanionPhoneLocation({
    bool highAccuracy = false,
  }) async {
    if (!_settings.shareCompanionPhoneLocation) {
      _companionLocationStatus = IncidentLocationStatus.notRequested;
      notifyListeners();
      return null;
    }
    if (!_locationAdapter.isSupported) {
      _companionLocationStatus = IncidentLocationStatus.unavailable;
      notifyListeners();
      return null;
    }

    await refreshPermissionStatuses(notify: false);
    final adapter = _notificationAdapter;
    if (_locationPermissionStatus == PermissionStatus.denied ||
        _locationPermissionStatus == PermissionStatus.restricted) {
      _companionLocationStatus = IncidentLocationStatus.permissionDenied;
      if (adapter is MutableRemoteNotificationAdapter &&
          adapter.companionSession.isConnected) {
        unawaited(
          adapter.reportCompanionLocation(
            location: null,
            sharingEnabled: true,
            locationStatus: IncidentLocationStatus.permissionDenied,
          ),
        );
      }
      notifyListeners();
      return null;
    }

    _companionLocationStatus = IncidentLocationStatus.pending;
    notifyListeners();

    ({DeviceLocationSnapshot? location, IncidentLocationStatus status}) capture;
    try {
      capture = await _locationAdapter.captureCurrentLocation(
        highAccuracy: highAccuracy,
      );
    } catch (_) {
      capture = (location: null, status: IncidentLocationStatus.unavailable);
    }

    if (capture.location != null &&
        DeviceLocationSnapshot.isValidCoordinates(
          capture.location!.latitude,
          capture.location!.longitude,
          accuracyMeters: capture.location!.accuracyMeters,
        )) {
      _companionLatestLocation = capture.location;
      _companionLocationStatus = IncidentLocationStatus.attached;
    } else {
      _companionLocationStatus =
          capture.status == IncidentLocationStatus.attached
          ? IncidentLocationStatus.unavailable
          : capture.status;
    }

    if (adapter is MutableRemoteNotificationAdapter &&
        adapter.companionSession.isConnected) {
      await adapter.reportCompanionLocation(
        location: _companionLatestLocation,
        sharingEnabled: true,
        locationStatus: _companionLocationStatus,
      );
      await refreshAuthorizedDeviceLocations();
    }
    notifyListeners();
    return _companionLatestLocation;
  }

  /// Selects one of the user-facing sensitivity presets (`Fewer false alarms`,
  /// `Balanced`, `Higher sensitivity`).
  Future<void> selectSensitivityPreset(MotionSensitivityPreset preset) {
    return updateSettings(motionSensitivity: preset.sensitivityValue);
  }

  /// Captures the protected device's current location on demand (for example,
  /// on launch, resume, periodic 4-minute intervals, or phone Devices refresh)
  /// and syncs it to the authorized pairing session if sharing is enabled.
  ///
  /// Deduplicates concurrent location captures and skips redundant relay writes
  /// when neither measurement timestamp, location status, nor protection state
  /// changed.
  Future<DeviceLocationSnapshot?> refreshProtectedDeviceLocation({
    bool highAccuracy = false,
    bool reportToRelay = true,
    bool forceReport = false,
  }) {
    final active = _inFlightHostLocationCapture;
    if (active != null) {
      return active;
    }
    final future = _executeRefreshProtectedDeviceLocation(
      highAccuracy: highAccuracy,
      reportToRelay: reportToRelay,
      forceReport: forceReport,
    );
    _inFlightHostLocationCapture = future;
    future.whenComplete(() {
      if (identical(_inFlightHostLocationCapture, future)) {
        _inFlightHostLocationCapture = null;
      }
    });
    return future;
  }

  Future<DeviceLocationSnapshot?> _executeRefreshProtectedDeviceLocation({
    required bool highAccuracy,
    required bool reportToRelay,
    required bool forceReport,
  }) async {
    if (!_settings.shareLocationOnAlarm) {
      _hostLocationStatus = IncidentLocationStatus.notRequested;
      notifyListeners();
      return null;
    }
    if (!_locationAdapter.isSupported) {
      _hostLocationStatus = IncidentLocationStatus.unavailable;
      notifyListeners();
      return null;
    }

    await refreshPermissionStatuses(notify: false);
    if (_locationPermissionStatus == PermissionStatus.denied ||
        _locationPermissionStatus == PermissionStatus.restricted) {
      _hostLocationStatus = IncidentLocationStatus.permissionDenied;
      final adapter = _notificationAdapter;
      final sig = 'denied|${_state.badgeLabel}';
      if (reportToRelay &&
          adapter is MutableRemoteNotificationAdapter &&
          (forceReport || _lastReportedHostLocationSignature != sig)) {
        unawaited(
          adapter
              .reportHostLocation(
                location: null,
                locationStatus: IncidentLocationStatus.permissionDenied,
                protectionState: _state.badgeLabel,
              )
              .then((reported) {
                if (reported) {
                  _lastReportedHostLocationSignature = sig;
                }
              }),
        );
      }
      notifyListeners();
      return null;
    }
    if (_locationPermissionStatus == PermissionStatus.notDetermined) {
      return _hostLatestLocation;
    }

    _lastHostLocationAttemptAt = _clock();
    if (_hostLatestLocation == null) {
      _hostLocationStatus = IncidentLocationStatus.pending;
      notifyListeners();
    }

    ({DeviceLocationSnapshot? location, IncidentLocationStatus status}) capture;
    try {
      capture = await _locationAdapter.captureCurrentLocation(
        highAccuracy: highAccuracy,
      );
    } catch (_) {
      capture = (location: null, status: IncidentLocationStatus.unavailable);
    }

    if (capture.location != null &&
        DeviceLocationSnapshot.isValidCoordinates(
          capture.location!.latitude,
          capture.location!.longitude,
          accuracyMeters: capture.location!.accuracyMeters,
        )) {
      _hostLatestLocation = capture.location;
      _hostLocationStatus = IncidentLocationStatus.attached;
      _syncNativeLifecycleContextOnly();
    } else if (_hostLatestLocation == null) {
      _hostLocationStatus = capture.status == IncidentLocationStatus.attached
          ? IncidentLocationStatus.unavailable
          : capture.status;
    }
    notifyListeners();

    final adapter = _notificationAdapter;
    if (reportToRelay &&
        _settings.shareLocationOnAlarm &&
        adapter is MutableRemoteNotificationAdapter) {
      final loc = _hostLatestLocation;
      final signature =
          '${loc?.capturedAt.toUtc().toIso8601String() ?? 'none'}|'
          '${loc?.latitude.toStringAsFixed(6) ?? ''}|'
          '${loc?.longitude.toStringAsFixed(6) ?? ''}|'
          '${_hostLocationStatus.name}|${_state.badgeLabel}|'
          '${_activeIncident?.id ?? ''}|$_isPostAlarmTrackingActive';
      if (forceReport || _lastReportedHostLocationSignature != signature) {
        unawaited(
          adapter
              .reportHostLocation(
                location: loc,
                locationStatus: _hostLocationStatus,
                protectionState: _state.badgeLabel,
                activeIncidentId: _activeIncident?.id,
                isBoundedAlarmTracking: _isPostAlarmTrackingActive,
              )
              .then((reported) {
                if (reported) {
                  _lastReportedHostLocationSignature = signature;
                }
              }),
        );
      }
    }
    return _hostLatestLocation;
  }

  /// Queries the relay for authorized devices in the current pairing session.
  Future<List<AuthorizedDeviceLocationSummary>>
  refreshAuthorizedDeviceLocations({bool requestHostRefresh = false}) async {
    final adapter = _notificationAdapter;
    if (adapter is MutableRemoteNotificationAdapter) {
      try {
        final devices = await adapter.fetchAuthorizedDevicesLocations(
          requestHostRefresh: requestHostRefresh,
        );
        if (devices.isNotEmpty) {
          _authorizedDeviceLocations = devices;
        }
      } catch (_) {
        // Keep cached / local fallback list when offline.
      }
    }
    notifyListeners();
    return authorizedDeviceLocations;
  }

  /// Deletes all stored location coordinates and trails locally and on the
  /// paired relay session while preserving pairings, PIN, and incident summaries.
  Future<bool> deleteStoredLocationHistory() async {
    _stopPostAlarmLocationTracking(markIncidentStopped: true);
    _lastReportedHostLocationSignature = null;
    _hostLatestLocation = null;
    _hostLocationStatus = _settings.shareLocationOnAlarm
        ? _determineInitialHostLocationStatus()
        : IncidentLocationStatus.notRequested;
    _companionLatestLocation = null;
    _companionLocationStatus = _settings.shareCompanionPhoneLocation
        ? IncidentLocationStatus.notRequested
        : IncidentLocationStatus.notRequested;

    final updatedIncidents = <IncidentRecord>[];
    for (final item in _incidents) {
      final scrubbed = item.withoutLocationHistory();
      updatedIncidents.add(scrubbed);
      if (item.location != null ||
          item.alarmTimeLocation != null ||
          item.locationTrail.isNotEmpty) {
        await _updateIncidentSafely(scrubbed);
      }
    }
    _incidents = updatedIncidents;
    if (_activeIncident != null) {
      _activeIncident = _activeIncident!.withoutLocationHistory();
    }
    _authorizedDeviceLocations = _authorizedDeviceLocations
        .map(
          (d) => AuthorizedDeviceLocationSummary(
            deviceId: d.deviceId,
            displayName: d.displayName,
            role: d.role,
            platform: d.platform,
            online: d.online,
            connectionStatusLabel: d.connectionStatusLabel,
            protectionStatusLabel: d.protectionStatusLabel,
            isCurrentRequester: d.isCurrentRequester,
            locationSharingEnabled: d.locationSharingEnabled,
            isAlarming: d.isAlarming,
            trackingState: 'unavailable',
            latestLocation: null,
            alarmTimeLocation: null,
            locationTrail: const <DeviceLocationSnapshot>[],
            locationStatus: IncidentLocationStatus.notRequested,
            statusExplanation: 'Stored location history was deleted.',
            activeIncidentId: d.activeIncidentId,
            lastSeenAt: d.lastSeenAt,
          ),
        )
        .toList(growable: false);

    var relayDeleted = true;
    final adapter = _notificationAdapter;
    if (adapter is MutableRemoteNotificationAdapter) {
      try {
        relayDeleted = await adapter.deleteRelayLocationHistory();
      } catch (_) {
        relayDeleted = false;
      }
    }
    notifyListeners();
    return relayDeleted;
  }

  IncidentLocationStatus _determineInitialHostLocationStatus() {
    if (!_settings.shareLocationOnAlarm) {
      return IncidentLocationStatus.notRequested;
    }
    if (!_locationAdapter.isSupported) {
      return IncidentLocationStatus.unavailable;
    }
    if (_locationPermissionStatus == PermissionStatus.denied ||
        _locationPermissionStatus == PermissionStatus.restricted) {
      return IncidentLocationStatus.permissionDenied;
    }
    return _hostLatestLocation != null
        ? IncidentLocationStatus.attached
        : IncidentLocationStatus.notRequested;
  }

  void _handleRemoteHostLocationRefreshRequest() {
    if (_isDisposed ||
        isCompanionMode ||
        !_settings.shareLocationOnAlarm ||
        !_locationAdapter.isSupported ||
        _isPostAlarmTrackingActive) {
      return;
    }
    final lastAttempt = _lastHostLocationAttemptAt;
    if (lastAttempt != null &&
        _clock().difference(lastAttempt) < const Duration(seconds: 25)) {
      // Recently measured; re-report latest measurement metadata if needed
      // without issuing overlapping OS location calls.
      unawaited(
        refreshProtectedDeviceLocation(highAccuracy: false, forceReport: true),
      );
      return;
    }
    unawaited(
      refreshProtectedDeviceLocation(highAccuracy: false, forceReport: true),
    );
  }

  void _ensureRegularLocationSchedule({
    bool immediateCapture = true,
    Duration? minElapsedSinceLastAttempt,
  }) {
    if (_isDisposed ||
        isCompanionMode ||
        !_settings.shareLocationOnAlarm ||
        !_locationAdapter.isSupported ||
        _isPostAlarmTrackingActive) {
      _stopRegularLocationSchedule();
      return;
    }
    if (_locationPermissionStatus != PermissionStatus.granted &&
        _locationPermissionStatus != PermissionStatus.notApplicable) {
      _stopRegularLocationSchedule();
      return;
    }

    if (immediateCapture) {
      final lastAttempt = _lastHostLocationAttemptAt;
      final allowed =
          minElapsedSinceLastAttempt == null ||
          lastAttempt == null ||
          _clock().difference(lastAttempt) >= minElapsedSinceLastAttempt;
      if (allowed) {
        unawaited(refreshProtectedDeviceLocation(highAccuracy: false));
      }
    }

    _regularLocationTimer ??= Timer.periodic(_regularLocationRefreshInterval, (
      _,
    ) {
      if (_isDisposed ||
          isCompanionMode ||
          !_settings.shareLocationOnAlarm ||
          !_locationAdapter.isSupported) {
        _stopRegularLocationSchedule();
        return;
      }
      if (_isPostAlarmTrackingActive) {
        return;
      }
      unawaited(refreshProtectedDeviceLocation(highAccuracy: false));
    });
  }

  void _stopRegularLocationSchedule() {
    _regularLocationTimer?.cancel();
    _regularLocationTimer = null;
  }

  void _startPostAlarmLocationTracking(String incidentId, int alarmGeneration) {
    _stopRegularLocationSchedule();
    _stopPostAlarmLocationTracking(markIncidentStopped: false);
    if (!_settings.shareLocationOnAlarm) {
      return;
    }
    if (!_locationAdapter.isSupported) {
      unawaited(
        _applyLocationResultToIncident(
          incidentId: incidentId,
          location: null,
          status: IncidentLocationStatus.unavailable,
          isInitialAlarmCapture: true,
          trackingState: 'stopped',
        ),
      );
      return;
    }
    _isPostAlarmTrackingActive = true;
    _postAlarmTrackingState = 'live';
    _postAlarmStartedAt = _clock();
    _postAlarmSampleCount = 0;

    // Initial high-accuracy alarm-time capture (non-blocking).
    unawaited(
      _captureAndAttachIncidentLocation(
        incidentId,
        isInitialAlarmCapture: true,
        trackingState: 'live',
      ),
    );

    _postAlarmLocationTimer = Timer.periodic(_postAlarmLocationInterval, (_) {
      if (alarmGeneration != _alarmGeneration ||
          _state != ProtectionState.alarming ||
          !_settings.shareLocationOnAlarm ||
          _activeIncident?.id != incidentId) {
        _stopPostAlarmLocationTracking(markIncidentStopped: true);
        return;
      }
      final startedAt = _postAlarmStartedAt ?? _clock();
      final elapsed = _clock().difference(startedAt);
      if (_postAlarmSampleCount >= _postAlarmMaxSamples ||
          elapsed >= _postAlarmTrackingMaxDuration) {
        _stopPostAlarmLocationTracking(markIncidentStopped: true);
        notifyListeners();
        return;
      }
      _postAlarmSampleCount += 1;
      unawaited(
        _captureAndAttachIncidentLocation(
          incidentId,
          isInitialAlarmCapture: false,
          trackingState: 'live',
        ),
      );
    });
  }

  void _stopPostAlarmLocationTracking({required bool markIncidentStopped}) {
    _postAlarmLocationTimer?.cancel();
    _postAlarmLocationTimer = null;
    final wasActive = _isPostAlarmTrackingActive;
    _isPostAlarmTrackingActive = false;
    _postAlarmTrackingState = markIncidentStopped ? 'stopped' : 'idle';
    _postAlarmStartedAt = null;
    _postAlarmSampleCount = 0;

    if (markIncidentStopped && wasActive) {
      final active = _activeIncident;
      if (active != null && active.locationTrackingState != 'stopped') {
        final updated = active.copyWith(locationTrackingState: 'stopped');
        _activeIncident = updated;
        _replaceIncidentInMemory(updated);
        unawaited(_updateIncidentSafely(updated));
        final adapter = _notificationAdapter;
        if (adapter is MutableRemoteNotificationAdapter) {
          unawaited(
            adapter.updateIncidentLocation(
              incidentId: updated.id,
              location: updated.location,
              locationStatus: updated.locationStatus,
              locationTrackingState: 'stopped',
            ),
          );
        }
      }
    }
    if (markIncidentStopped && !_isDisposed && _isInitialized) {
      _ensureRegularLocationSchedule(immediateCapture: false);
    }
  }

  void _clearMovementConfirmationStage({bool notify = false}) {
    _confirmationResetTimer?.cancel();
    _confirmationResetTimer = null;
    final changed = _isConfirmingMovement;
    _isConfirmingMovement = false;
    _confirmationStartedAt = null;
    if (changed && _state == ProtectionState.armed) {
      _statusMessage =
          'Monitoring with ${selectedDetectorType.userFacingMethodName.toLowerCase()}. Enter your PIN to disarm.';
    }
    if (changed && notify) {
      notifyListeners();
    }
  }

  /// Starts a safe, silent Guided Protection Test so users can test passerby
  /// rejection and gentle pickup detection on their own device without sounding
  /// the siren or sending panic notifications to paired phones.
  Future<bool> startGuidedProtectionTest() async {
    if (_state != ProtectionState.disarmed &&
        _state != ProtectionState.unavailable) {
      _warningMessage =
          'Turn protection off before starting the guided protection test.';
      notifyListeners();
      return false;
    }
    if (_isTestAlarmRunning) {
      await stopTestAlarm();
    }
    if (_isGuidedTestRunning) {
      await stopGuidedProtectionTest();
    }

    final detector = selectedDetector;
    if (detector == null) {
      _warningMessage = 'Motion detection is not available on this device.';
      notifyListeners();
      return false;
    }

    final cap = await detector.checkCapability();
    _capabilities[detector.detectorType] = cap;
    if (!cap.canArm) {
      _warningMessage = cap.guidance ?? cap.summary;
      notifyListeners();
      return false;
    }

    final testSessionId =
        'guided_test_${++_sessionSequence}_${_clock().millisecondsSinceEpoch}';
    _guidedTestSessionId = testSessionId;
    _isGuidedTestRunning = true;
    _guidedTestPhase = 'calibrating';
    _guidedTestFalseTriggers = 0;
    _guidedTestPickupDetected = false;
    _guidedTestPickupLatency = null;
    _guidedTestPhaseStartedAt = _clock();
    _warningMessage = null;
    notifyListeners();

    final startResult = await detector.startMonitoring(
      MonitorConfig(
        sessionId: testSessionId,
        sensitivity: _settings.motionSensitivity,
      ),
    );
    if (!_isGuidedTestRunning || _guidedTestSessionId != testSessionId) {
      unawaited(detector.stopMonitoring(sessionId: testSessionId));
      return false;
    }
    if (!startResult.started) {
      _isGuidedTestRunning = false;
      _guidedTestSessionId = null;
      _guidedTestPhase = 'failed';
      _warningMessage = startResult.message;
      notifyListeners();
      return false;
    }

    _guidedTestPhase = 'passerby_check';
    _guidedTestPhaseStartedAt = _clock();
    notifyListeners();
    return true;
  }

  /// Advances the Guided Protection Test from Step 1 (everyday scene motion
  /// check) to Step 2 (gentle lift / tilt check).
  void advanceGuidedTestToLiftStep() {
    if (!_isGuidedTestRunning) {
      return;
    }
    _guidedTestPhase = 'lift_check';
    _guidedTestPhaseStartedAt = _clock();
    _guidedTestPickupDetected = false;
    _guidedTestPickupLatency = null;
    notifyListeners();
  }

  /// Stops an active Guided Protection Test and releases camera/sensor hardware.
  Future<void> stopGuidedProtectionTest() async {
    final sid = _guidedTestSessionId;
    final wasRunning = _isGuidedTestRunning;
    _isGuidedTestRunning = false;
    _guidedTestSessionId = null;
    if (_guidedTestPhase != 'completed') {
      _guidedTestPhase = 'idle';
    }
    if (sid != null) {
      try {
        await selectedDetector?.stopMonitoring(sessionId: sid);
      } catch (_) {
        // Ignore stop errors
      }
    }
    if (wasRunning) {
      notifyListeners();
    }
  }

  /// Refreshes capability and permission status across all registered detectors.
  Future<void> refreshCapabilities() async {
    for (final entry in _detectors.entries) {
      try {
        _capabilities[entry.key] = await entry.value.checkCapability();
      } catch (error) {
        _capabilities[entry.key] = DetectorCapability(
          type: entry.key,
          status: CapabilityStatus.unsupported,
          permissionStatus: PermissionStatus.notApplicable,
          summary: 'Motion detection is unavailable right now.',
          statusDetail: '$error',
        );
      }
    }

    final currentCap = selectedCapability;
    if (_state == ProtectionState.disarmed ||
        _state == ProtectionState.unavailable) {
      if (currentCap == null || !currentCap.canArm) {
        _state = ProtectionState.unavailable;
        _statusMessage =
            currentCap?.summary ??
            'Motion detection needs setup before arming.';
      } else {
        _state = ProtectionState.disarmed;
        _statusMessage =
            'Protection is off. Ready to arm using ${currentCap.type.userFacingMethodName.toLowerCase()}.';
      }
    }
    notifyListeners();
  }

  /// Requests OS permission for the currently selected detector.
  Future<PermissionStatus> requestSelectedDetectorPermission() async {
    final detector = selectedDetector;
    if (detector == null) {
      return PermissionStatus.notApplicable;
    }
    final status = await detector.requestPermission();
    await refreshCapabilities();
    if (_state == ProtectionState.disarmed) {
      _warningMessage = null;
      notifyListeners();
    }
    return status;
  }

  /// Retries capability inspection and clears stale initialization warnings when
  /// the detector becomes ready again.
  Future<bool> retrySelectedDetectorSetup() async {
    if (_state == ProtectionState.paused) {
      return resumePausedMonitoring(
        reason: 'User requested monitoring retry',
        userInitiated: true,
      );
    }
    await refreshCapabilities();
    final cap = selectedCapability;
    if (cap != null && cap.canArm && _state == ProtectionState.disarmed) {
      _warningMessage = null;
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Selects a detector modality when not actively armed/alarming.
  Future<bool> selectDetector(DetectorType type) async {
    if (_state == ProtectionState.arming ||
        _state == ProtectionState.armed ||
        _state == ProtectionState.alarming ||
        _state == ProtectionState.paused) {
      _warningMessage = 'Turn protection off before changing motion detection.';
      notifyListeners();
      return false;
    }
    if (!_detectors.containsKey(type)) {
      _warningMessage =
          'That motion detection option is not available on this device.';
      notifyListeners();
      return false;
    }
    _settings = _settings.copyWith(selectedDetector: type);
    await _persistSettingsSafely();
    _warningMessage = null;
    await refreshCapabilities();
    return true;
  }

  /// Completes initial PIN creation during onboarding.
  Future<PinValidationResult> setupInitialPin({
    required String pin,
    required String confirmPin,
    String? deviceDisplayName,
  }) async {
    final result = await _pinService.setupInitialPin(
      pin: pin,
      confirmPin: confirmPin,
    );
    if (result.isValid) {
      _hasPinConfigured = true;
      _settings = _settings.copyWith(
        onboardingCompleted: true,
        deviceDisplayName: deviceDisplayName != null
            ? deviceDisplayName.trim()
            : _settings.deviceDisplayName,
      );
      await _persistSettingsSafely();
      await refreshCapabilities();
    }
    notifyListeners();
    return result;
  }

  /// Changes the user's PIN after verifying the current PIN.
  Future<PinValidationResult> changePin({
    required String currentPin,
    required String newPin,
    required String confirmNewPin,
  }) async {
    final result = await _pinService.changePin(
      currentPin: currentPin,
      newPin: newPin,
      confirmNewPin: confirmNewPin,
    );
    notifyListeners();
    return result;
  }

  /// Updates sensitivity, countdown duration, or alarm volume.
  Future<void> updateSettings({
    double? motionSensitivity,
    int? armingCountdownSeconds,
    double? alarmVolume,
  }) async {
    _settings = _settings.copyWith(
      motionSensitivity: motionSensitivity,
      armingCountdownSeconds: armingCountdownSeconds,
      alarmVolume: alarmVolume,
    );
    await _persistSettingsSafely();

    if (motionSensitivity != null && _state == ProtectionState.armed) {
      final detector = selectedDetector;
      if (detector != null) {
        try {
          await detector.updateSensitivity(_settings.motionSensitivity);
        } catch (_) {
          // Non-fatal
        }
      }
      for (final auxType in _activeAuxiliaryDetectors) {
        try {
          await _detectors[auxType]?.updateSensitivity(
            _settings.motionSensitivity,
          );
        } catch (_) {
          // Non-fatal
        }
      }
    }
    if (alarmVolume != null && _audioAdapter.isPlaying) {
      try {
        await _audioAdapter.setVolume(_settings.alarmVolume);
      } catch (_) {
        // Non-fatal
      }
    }
    notifyListeners();
  }

  /// Selects a UI color theme and persists the preference.
  Future<void> selectColorTheme(WatSafeColorTheme colorTheme) async {
    _settings = _settings.copyWith(colorTheme: colorTheme);
    await _persistSettingsSafely();
    notifyListeners();
  }

  /// Selects an alarm sound (built-in or custom) and updates the audio adapter.
  Future<void> selectAlarmSound(String soundId) async {
    _settings = _settings.copyWith(selectedAlarmSoundId: soundId);
    await _persistSettingsSafely();
    await _syncAudioAdapterSound();
    notifyListeners();
  }

  /// Adds a custom synthesized alarm sound and selects it as active.
  Future<CustomAlarmSound?> addCustomSynthesizedAlarmSound({
    required String name,
    required CustomAlarmWavePattern pattern,
    required double primaryFrequencyHz,
    required double secondaryFrequencyHz,
    required double modulationRateHz,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      _warningMessage = 'Enter a name for your custom alarm sound.';
      notifyListeners();
      return null;
    }

    final custom = CustomAlarmSound(
      id: 'custom_synth_${_clock().millisecondsSinceEpoch}_${_settings.customAlarmSounds.length + 1}',
      name: trimmedName,
      pattern: pattern,
      primaryFrequencyHz: primaryFrequencyHz.clamp(200.0, 3200.0),
      secondaryFrequencyHz: secondaryFrequencyHz.clamp(200.0, 3200.0),
      modulationRateHz: modulationRateHz.clamp(0.5, 12.0),
    );

    final updatedList = <CustomAlarmSound>[
      ..._settings.customAlarmSounds,
      custom,
    ];
    _settings = _settings.copyWith(
      customAlarmSounds: updatedList,
      selectedAlarmSoundId: custom.id,
    );
    _warningMessage = null;
    await _persistSettingsSafely();
    await _syncAudioAdapterSound();
    notifyListeners();
    return custom;
  }

  /// Opens the native OS file picker (if supported) to choose a `.wav` file.
  Future<String?> browseCustomAudioFilePath() async {
    return _audioAdapter.pickCustomAudioFilePath();
  }

  /// Adds a custom `.wav` file alarm sound after validating the file exists and
  /// has a valid RIFF/WAVE header.
  Future<CustomAlarmSound?> importCustomWavAlarmSound({
    required String name,
    required String filePath,
  }) async {
    final trimmedPath = filePath.trim();
    if (trimmedPath.isEmpty) {
      _warningMessage = 'Select or enter a valid .wav audio file path.';
      notifyListeners();
      return null;
    }

    final file = File(trimmedPath);
    if (!await file.exists()) {
      _warningMessage = 'Audio file not found at "$trimmedPath".';
      notifyListeners();
      return null;
    }

    try {
      final bytes = await file.readAsBytes();
      if (!AlarmWaveformSynthesizer.isValidWavBytes(bytes)) {
        _warningMessage = 'Selected file is not a valid uncompressed RIFF/WAVE (.wav) audio file.';
        notifyListeners();
        return null;
      }
    } catch (error) {
      _warningMessage = 'Could not read custom audio file: $error';
      notifyListeners();
      return null;
    }

    final normalized = trimmedPath.replaceAll('\\', '/');
    final fileName = normalized.split('/').last;
    final fallbackName = fileName.replaceAll(
      RegExp(r'\.wav$', caseSensitive: false),
      '',
    );
    final effectiveName = name.trim().isNotEmpty ? name.trim() : fallbackName;

    final custom = CustomAlarmSound(
      id: 'custom_wav_${_clock().millisecondsSinceEpoch}_${_settings.customAlarmSounds.length + 1}',
      name: effectiveName,
      filePath: trimmedPath,
    );

    final updatedList = <CustomAlarmSound>[
      ..._settings.customAlarmSounds,
      custom,
    ];
    _settings = _settings.copyWith(
      customAlarmSounds: updatedList,
      selectedAlarmSoundId: custom.id,
    );
    _warningMessage = null;
    await _persistSettingsSafely();
    await _syncAudioAdapterSound();
    notifyListeners();
    return custom;
  }

  /// Deletes a user-added custom alarm sound and reverts selection to the
  /// default siren if the deleted sound was selected.
  Future<void> removeCustomAlarmSound(String customSoundId) async {
    final updatedList = _settings.customAlarmSounds
        .where((s) => s.id != customSoundId)
        .toList(growable: false);
    final nextSelectedId = _settings.selectedAlarmSoundId == customSoundId
        ? BuiltInAlarmSound.classicSiren.id
        : _settings.selectedAlarmSoundId;
    _settings = _settings.copyWith(
      customAlarmSounds: updatedList,
      selectedAlarmSoundId: nextSelectedId,
    );
    await _persistSettingsSafely();
    await _syncAudioAdapterSound();
    notifyListeners();
  }

  /// Plays a short 3-second preview of the currently selected alarm sound.
  Future<void> previewSelectedAlarmSound() async {
    if (_state == ProtectionState.alarming) {
      return;
    }
    await _syncAudioAdapterSound();
    await startTestAlarm();
  }

  Future<void> _syncAudioAdapterSound() async {
    final option = _settings.selectedAlarmSoundOption;
    try {
      await _audioAdapter.configureAlarmSound(
        soundId: option.id,
        customSound: option.customSound,
      );
    } catch (_) {
      // Non-fatal
    }
  }

  /// Verifies detector readiness and starts the arming countdown.
  Future<bool> startArming() async {
    if (_isPreparingToArm ||
        _state == ProtectionState.arming ||
        _state == ProtectionState.armed ||
        _state == ProtectionState.alarming ||
        _state == ProtectionState.paused) {
      return false;
    }

    _isPreparingToArm = true;
    try {
      if (_isTestAlarmRunning) {
        await stopTestAlarm();
      }
      if (_isGuidedTestRunning) {
        await stopGuidedProtectionTest();
      }

      _hasPinConfigured = await _pinService.hasConfiguredPin();
      if (!_hasPinConfigured) {
        _warningMessage =
            'Create a 6-digit (or longer) PIN before arming protection.';
        notifyListeners();
        return false;
      }

      final detector = selectedDetector;
      if (detector == null) {
        _state = ProtectionState.unavailable;
        _statusMessage = 'Motion detection is not available on this device.';
        notifyListeners();
        return false;
      }

      final capability = await detector.checkCapability();
      _capabilities[detector.detectorType] = capability;

      if (!capability.canArm) {
        _state = ProtectionState.unavailable;
        _statusMessage = capability.summary;
        _warningMessage = capability.guidance ?? capability.statusDetail;
        notifyListeners();
        return false;
      }

      String? audioPrepWarning;
      try {
        await _audioAdapter.prepareForAlarm();
      } catch (_) {
        audioPrepWarning = 'Could not prepare speaker output for the siren.';
      }

      if (_state != ProtectionState.disarmed &&
          _state != ProtectionState.unavailable) {
        return false;
      }

      _cancelCountdownTimer();
      final sessionId = _nextSessionId();
      _activeSessionId = sessionId;
      _activeAuxiliaryDetectors.clear();
      _remainingCountdownSeconds = _settings.armingCountdownSeconds;
      _isCalibrating = false;
      _lastTelemetryEvent = null;
      _warningMessage = capability.status == CapabilityStatus.degraded
          ? capability.statusDetail
          : audioPrepWarning;
      _state = ProtectionState.arming;
      _statusMessage =
          'Arming in $_remainingCountdownSeconds seconds — keep this device steady.';
      notifyListeners();

      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(handleCountdownTickForSession(sessionId));
      });
      return true;
    } finally {
      _isPreparingToArm = false;
    }
  }

  /// Processes a single countdown tick for [sessionId].
  /// Ignored if [sessionId] is stale or the session was cancelled/disarmed.
  @visibleForTesting
  Future<void> handleCountdownTickForSession(String sessionId) async {
    if (_state != ProtectionState.arming ||
        _activeSessionId != sessionId ||
        _isCalibrating) {
      return;
    }

    _remainingCountdownSeconds -= 1;
    if (_remainingCountdownSeconds > 0) {
      _statusMessage =
          'Arming in $_remainingCountdownSeconds second${_remainingCountdownSeconds == 1 ? '' : 's'} — keep this device steady.';
      notifyListeners();
      return;
    }

    _cancelCountdownTimer();
    await _initializeAndCalibrateSession(sessionId);
  }

  Future<void> _initializeAndCalibrateSession(String sessionId) async {
    if (_state != ProtectionState.arming || _activeSessionId != sessionId) {
      return;
    }

    final detector = selectedDetector;
    if (detector == null) {
      _failArmingSession(
        sessionId: sessionId,
        reason: 'Motion detection became unavailable before arming completed.',
      );
      return;
    }

    _isCalibrating = true;
    _statusMessage =
        'Calibrating ${detector.detectorType.userFacingMethodName.toLowerCase()}…';
    notifyListeners();

    final monitorConfig = MonitorConfig(
      sessionId: sessionId,
      sensitivity: _settings.motionSensitivity,
    );

    DetectorStartResult startResult;
    try {
      startResult = await detector.startMonitoring(monitorConfig);
    } catch (error) {
      startResult = DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: 'Could not start motion detection: $error',
        errorCode: 'START_EXCEPTION',
      );
    }

    // Check if the session was cancelled, paused, or superseded while awaiting native startup.
    if (_activeSessionId != sessionId || _state != ProtectionState.arming) {
      unawaited(detector.stopMonitoring(sessionId: sessionId));
      return;
    }

    _isCalibrating = false;
    if (!startResult.started) {
      unawaited(detector.stopMonitoring(sessionId: sessionId));
      _updateCapabilityOnStartFailure(detector.detectorType, startResult);
      _failArmingSession(sessionId: sessionId, reason: startResult.message);
      return;
    }

    await _startSupportedAuxiliaryMotionSensors(
      primaryType: detector.detectorType,
      config: monitorConfig,
    );

    if (_activeSessionId != sessionId || _state != ProtectionState.arming) {
      await _stopSessionDetectorsSafely(sessionId);
      return;
    }

    _state = ProtectionState.armed;
    _notifiedArmedSessionId = null;
    _activeIncidentNeedsWakeRetry = false;
    _activeIncidentPushFailed = false;
    _clearMovementConfirmationStage();
    _clearInputInteractionGrace();
    if (startResult.status == CapabilityStatus.degraded) {
      final currentCap = _capabilities[detector.detectorType];
      if (currentCap != null) {
        _capabilities[detector.detectorType] = currentCap.copyWith(
          status: CapabilityStatus.degraded,
          statusDetail: startResult.message,
        );
      }
    }
    final isCameraBlockedAtArm =
        detector.detectorType.usesCamera &&
        (_capabilities[detector.detectorType]?.status ==
                CapabilityStatus.degraded ||
            startResult.status == CapabilityStatus.degraded);
    if (isCameraBlockedAtArm) {
      _warningMessage = 'Camera appears covered or too dark. Uncover the camera for visual motion detection — lid and connection alerts remain active.';
      _statusMessage = 'Camera view blocked — lid and connection alerts active. Enter your PIN to disarm.';
    } else {
      _statusMessage =
          'Monitoring with ${detector.detectorType.userFacingMethodName.toLowerCase()}. Enter your PIN to disarm.';
    }
    _syncArmedLifecycleAndWatchdog(
      armed: true,
      armedSessionId: sessionId,
      protectionState: 'armed',
    );
    _syncHostPresenceMetadata(immediateHeartbeatIfBackground: true);
    _ensureRegularLocationSchedule(
      immediateCapture: true,
      minElapsedSinceLastAttempt: const Duration(seconds: 20),
    );
    notifyListeners();
  }

  /// Starts any ready non-camera device-motion sensors alongside a primary
  /// camera detector as a separate corroborating input.
  Future<void> _startSupportedAuxiliaryMotionSensors({
    required DetectorType primaryType,
    required MonitorConfig config,
  }) async {
    _activeAuxiliaryDetectors.clear();
    if (!primaryType.usesCamera) {
      return;
    }
    for (final entry in _detectors.entries) {
      if (entry.key == primaryType ||
          entry.key.usesCamera ||
          entry.key == DetectorType.androidMotionSensors ||
          entry.key == DetectorType.iosCoreMotionForeground) {
        continue;
      }
      final cap = _capabilities[entry.key];
      if (cap == null || !cap.canArm) {
        continue;
      }
      try {
        final res = await entry.value.startMonitoring(config);
        if (res.started && _activeSessionId == config.sessionId) {
          _activeAuxiliaryDetectors.add(entry.key);
        } else {
          await entry.value.stopMonitoring(sessionId: config.sessionId);
        }
      } catch (_) {
        // Auxiliary sensor failure does not block primary camera monitoring.
      }
    }
  }

  Future<void> _stopSessionDetectorsSafely(String? sessionId) async {
    final auxToStop = List<DetectorType>.from(_activeAuxiliaryDetectors);
    _activeAuxiliaryDetectors.clear();
    final primary = selectedDetector;
    if (primary != null) {
      try {
        await primary.stopMonitoring(sessionId: sessionId);
      } catch (_) {
        // Ignore stop errors
      }
    }
    for (final auxType in auxToStop) {
      try {
        await _detectors[auxType]?.stopMonitoring(sessionId: sessionId);
      } catch (_) {
        // Ignore stop errors
      }
    }
  }

  void _updateCapabilityOnStartFailure(
    DetectorType type,
    DetectorStartResult result,
  ) {
    final existing = _capabilities[type];
    final code = result.errorCode ?? '';
    final isPermDenied =
        result.status == CapabilityStatus.permissionRequired ||
        code.contains('PERMISSION');
    final String guidance;
    if (isPermDenied) {
      guidance = type.usesCamera
          ? 'Allow camera access in your system or browser settings, then try again.'
          : 'Allow motion sensor access in your system settings, then try again.';
    } else if (code == 'CAMERA_BUSY' || code == 'SOURCE_ACTIVATE_FAILED') {
      guidance =
          'Another app is using the camera. Close video apps and try again.';
    } else if (code == 'NO_CAMERA_HARDWARE') {
      guidance = 'No camera was found. Connect a camera and try again.';
    } else if (code == 'FRAME_TIMEOUT') {
      guidance = 'No video arrived from the camera. Check any camera privacy cover and try again.';
    } else {
      guidance = '${result.message} Try again when ready.';
    }
    _capabilities[type] = DetectorCapability(
      type: type,
      status: isPermDenied
          ? CapabilityStatus.permissionRequired
          : CapabilityStatus.unsupported,
      permissionStatus: isPermDenied
          ? PermissionStatus.denied
          : (existing?.permissionStatus ?? PermissionStatus.notDetermined),
      hardwareDeviceName: existing?.hardwareDeviceName,
      summary: result.message,
      statusDetail: result.errorCode,
      guidance: guidance,
    );
  }

  void _failArmingSession({required String sessionId, required String reason}) {
    if (_activeSessionId != sessionId) {
      return;
    }
    _cancelCountdownTimer();
    _ensureRegularLocationSchedule(immediateCapture: false);
    _clearMovementConfirmationStage();
    _activeSessionId = null;
    _activeAuxiliaryDetectors.clear();
    _isCalibrating = false;
    _remainingCountdownSeconds = 0;
    _state = ProtectionState.unavailable;
    _statusMessage = 'Could not arm: $reason';
    _warningMessage = reason;
    notifyListeners();
  }

  /// Cancels an in-progress arming countdown before the device enters `armed`.
  Future<void> cancelArming() async {
    if (_state != ProtectionState.arming) {
      return;
    }
    final oldSessionId = _activeSessionId;
    ++_lifecycleGeneration;
    _cancelCountdownTimer();
    _ensureRegularLocationSchedule(immediateCapture: false);
    _clearMovementConfirmationStage();
    _clearInputInteractionGrace();
    _activeSessionId = null;
    _isCalibrating = false;
    _remainingCountdownSeconds = 0;
    _syncArmedLifecycleAndWatchdog(
      armed: false,
      disarmVerified: true,
      protectionState: 'off',
    );

    if (oldSessionId != null) {
      await _stopSessionDetectorsSafely(oldSessionId);
    }

    final cap = selectedCapability;
    if (cap != null && cap.canArm) {
      _state = ProtectionState.disarmed;
      _statusMessage = 'Arming cancelled. Protection is off.';
    } else {
      _state = ProtectionState.unavailable;
      _statusMessage =
          cap?.summary ?? 'Arming cancelled. Motion detection needs setup.';
    }
    notifyListeners();
  }

  /// Handles Flutter application lifecycle transitions (`hidden`, `paused`,
  /// `resumed`, `detached`) across desktop, mobile, and browser targets.
  Future<void> handleAppLifecycleState(AppLifecycleState lifecycleState) async {
    switch (lifecycleState) {
      case AppLifecycleState.inactive:
        return;

      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        final mutableNotifications = _notificationAdapter;
        if (mutableNotifications is MutableRemoteNotificationAdapter) {
          mutableNotifications.setForegroundActive(false);
        }
        if (lifecycleState == AppLifecycleState.detached) {
          if (_state == ProtectionState.armed) {
            await _triggerImmediateInterruptionAlert(
              summary:
                  'Protection interrupted — WATSafe was closed while armed.',
            );
          }
          _stopRegularLocationSchedule();
          _stopPostAlarmLocationTracking(markIncidentStopped: true);
          _clearMovementConfirmationStage();
          _clearInputInteractionGrace();
          unawaited(stopGuidedProtectionTest());
          if (mutableNotifications is ConfigurableRemoteNotificationService &&
              mutableNotifications.enableBackgroundPolling) {
            await mutableNotifications.notifyHostOffline();
          }
          if (_state == ProtectionState.alarming) {
            return;
          }
        }
        final detector = selectedDetector;
        if (_state != ProtectionState.alarming &&
            detector != null &&
            detector.supportsBackgroundMonitoring &&
            lifecycleState != AppLifecycleState.detached) {
          return;
        }
        final label = lifecycleState == AppLifecycleState.hidden
            ? 'App window hidden'
            : 'App moved to background';
        await _pauseMonitoringForLifecycle(label);
        return;

      case AppLifecycleState.resumed:
        await _reconcileWakeFromSleep();
        final mutableNotifications = _notificationAdapter;
        if (mutableNotifications is MutableRemoteNotificationAdapter) {
          mutableNotifications.setForegroundActive(true);
        }
        unawaited(refreshPermissionStatuses());
        if (isCompanionMode && _settings.shareCompanionPhoneLocation) {
          unawaited(refreshCompanionPhoneLocation());
        } else {
          _ensureRegularLocationSchedule(
            immediateCapture: true,
            minElapsedSinceLastAttempt: const Duration(seconds: 30),
          );
        }
        await _handleAppForegroundResumed('App returned to foreground');
        return;
    }
  }

  Future<void> _pauseMonitoringForLifecycle(String reason) async {
    if (_state == ProtectionState.alarming) {
      _alarmInterruptedByLifecycle = true;
      final sessionId = _activeSessionId;
      await _stopSessionDetectorsSafely(sessionId);
      if (_audioAdapter.isPlaying) {
        _warningMessage = 'Alarm remains active — enter your PIN to disarm.';
      } else {
        _warningMessage = 'System suspended audio while in the background. Enter your PIN to disarm.';
      }
      notifyListeners();
      return;
    }

    if (_state == ProtectionState.armed || _state == ProtectionState.arming) {
      ++_lifecycleGeneration;
      final sessionId = _activeSessionId;
      _cancelCountdownTimer();
      _clearMovementConfirmationStage();
      _isCalibrating = false;
      _remainingCountdownSeconds = 0;
      _state = ProtectionState.paused;
      _statusMessage = 'Monitoring paused while WATSafe was in the background.';
      _warningMessage =
          'Protection was paused ($reason). Tap Resume monitoring to continue.';
      notifyListeners();

      await _stopSessionDetectorsSafely(sessionId);
    }
  }

  Future<void> _handleAppForegroundResumed(String reason) async {
    if (_state == ProtectionState.alarming) {
      await _ensureActiveAlarmAudioOnResume(reason);
      return;
    }
    if (_state == ProtectionState.paused) {
      await resumePausedMonitoring(reason: reason);
    }
  }

  Future<void> _ensureActiveAlarmAudioOnResume(String reason) async {
    if (_state != ProtectionState.alarming) {
      return;
    }
    if (_audioAdapter.isPlaying) {
      if (_alarmInterruptedByLifecycle) {
        _warningMessage = 'Alarm active — enter your PIN to disarm.';
        notifyListeners();
      }
      return;
    }
    if (_isRestartingAlarmAudio) {
      return;
    }

    _isRestartingAlarmAudio = true;
    final gen = _alarmGeneration;
    try {
      await _audioAdapter.startLoopingAlarm(volume: _settings.alarmVolume);
      if (gen != _alarmGeneration || _state != ProtectionState.alarming) {
        await _audioAdapter.stopAlarm();
        return;
      }
      _warningMessage = 'Alarm active — enter your PIN to disarm.';
    } catch (_) {
      if (gen == _alarmGeneration && _state == ProtectionState.alarming) {
        _warningMessage = 'Alarm remains active, though your device suspended siren audio. Tap Resume Siren Audio or enter your PIN to disarm.';
      }
    } finally {
      _isRestartingAlarmAudio = false;
      notifyListeners();
    }
  }

  /// Manually resumes siren playback on user interaction if the OS/browser
  /// suspended audio during an active alarm.
  Future<void> resumeInterruptedAlarmAudio() async {
    if (_state != ProtectionState.alarming || _isRestartingAlarmAudio) {
      return;
    }
    _isRestartingAlarmAudio = true;
    final gen = _alarmGeneration;
    try {
      await _audioAdapter.prepareForAlarm();
      if (gen != _alarmGeneration || _state != ProtectionState.alarming) {
        return;
      }
      await _audioAdapter.startLoopingAlarm(volume: _settings.alarmVolume);
      if (gen != _alarmGeneration || _state != ProtectionState.alarming) {
        await _audioAdapter.stopAlarm();
        return;
      }
      _alarmInterruptedByLifecycle = false;
      _warningMessage = null;
    } catch (_) {
      if (gen == _alarmGeneration && _state == ProtectionState.alarming) {
        _warningMessage = 'Could not resume siren audio.';
      }
    } finally {
      _isRestartingAlarmAudio = false;
      notifyListeners();
    }
  }

  /// Restores detector monitoring for a `paused` session using a single-flight
  /// guard so repeated lifecycle resume notifications never spawn duplicate
  /// camera streams, detectors, or timers.
  Future<bool> resumePausedMonitoring({
    String reason = 'App resumed',
    bool userInitiated = false,
  }) {
    if (_state != ProtectionState.paused) {
      return Future<bool>.value(_state == ProtectionState.armed);
    }
    final existing = _inFlightLifecycleResume;
    if (existing != null) {
      return existing;
    }

    final future = _executeLifecycleResume(
      reason: reason,
      userInitiated: userInitiated,
    );
    _inFlightLifecycleResume = future;
    return future.whenComplete(() {
      if (identical(_inFlightLifecycleResume, future)) {
        _inFlightLifecycleResume = null;
      }
    });
  }

  Future<bool> _executeLifecycleResume({
    required String reason,
    required bool userInitiated,
  }) async {
    final sessionId = _activeSessionId;
    final detector = selectedDetector;
    if (sessionId == null || detector == null) {
      _state = ProtectionState.unavailable;
      _statusMessage = 'Cannot resume monitoring right now.';
      notifyListeners();
      return false;
    }

    final resumeGen = ++_lifecycleGeneration;

    if (userInitiated) {
      try {
        await _audioAdapter.prepareForAlarm();
      } catch (_) {
        // Continue attempting detector restart
      }
    }

    DetectorCapability capability;
    try {
      capability = await detector.checkCapability();
      _capabilities[detector.detectorType] = capability;
    } catch (_) {
      capability = DetectorCapability(
        type: detector.detectorType,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary: 'Motion detection could not be checked right now.',
      );
      _capabilities[detector.detectorType] = capability;
    }

    if (resumeGen != _lifecycleGeneration ||
        _activeSessionId != sessionId ||
        _state != ProtectionState.paused) {
      return false;
    }

    if (!capability.canArm) {
      _statusMessage = 'Monitoring paused — ${capability.summary}';
      _warningMessage =
          capability.guidance ??
          '${capability.summary} Tap Resume monitoring when ready, or disarm with your PIN.';
      notifyListeners();
      return false;
    }

    final monitorConfig = MonitorConfig(
      sessionId: sessionId,
      sensitivity: _settings.motionSensitivity,
    );

    DetectorStartResult startResult;
    try {
      startResult = await detector.startMonitoring(monitorConfig);
    } catch (error) {
      startResult = DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: 'Could not restart motion detection: $error',
        errorCode: 'RESUME_START_EXCEPTION',
      );
    }

    if (resumeGen != _lifecycleGeneration ||
        _activeSessionId != sessionId ||
        _state != ProtectionState.paused) {
      unawaited(detector.stopMonitoring(sessionId: sessionId));
      return false;
    }

    if (!startResult.started) {
      unawaited(detector.stopMonitoring(sessionId: sessionId));
      _statusMessage = 'Monitoring paused — ${startResult.message}';
      _warningMessage =
          'Could not resume motion detection (${startResult.message}). Tap Resume Monitoring to try again or enter your PIN to disarm.';
      notifyListeners();
      return false;
    }

    await _startSupportedAuxiliaryMotionSensors(
      primaryType: detector.detectorType,
      config: monitorConfig,
    );

    if (resumeGen != _lifecycleGeneration ||
        _activeSessionId != sessionId ||
        _state != ProtectionState.paused) {
      await _stopSessionDetectorsSafely(sessionId);
      return false;
    }

    _state = ProtectionState.armed;
    _notifiedArmedSessionId = null;
    _activeIncidentNeedsWakeRetry = false;
    _activeIncidentPushFailed = false;
    _clearMovementConfirmationStage();
    _clearInputInteractionGrace();
    _warningMessage = null;
    _statusMessage =
        'Monitoring resumed with ${detector.detectorType.userFacingMethodName.toLowerCase()}.';
    _syncArmedLifecycleAndWatchdog(
      armed: true,
      armedSessionId: sessionId,
      protectionState: 'armed',
    );
    _ensureRegularLocationSchedule(
      immediateCapture: true,
      minElapsedSinceLastAttempt: const Duration(seconds: 20),
    );
    notifyListeners();
    return true;
  }

  /// Verifies [pin] and, if valid, immediately invalidates any active or
  /// in-flight alarm playback, stops the siren and detector monitoring,
  /// resolves the active incident, and transitions to `disarmed`.
  Future<PinVerificationResult> verifyAndDisarm(String pin) async {
    while (_inFlightDisarm != null) {
      try {
        await _inFlightDisarm;
      } catch (_) {
        break;
      }
    }

    final future = _executeVerifyAndDisarm(pin);
    _inFlightDisarm = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightDisarm, future)) {
        _inFlightDisarm = null;
      }
    }
  }

  Future<PinVerificationResult> _executeVerifyAndDisarm(String pin) async {
    final result = await _pinService.verifyPin(pin);
    if (!result.verified) {
      _warningMessage = result.message;
      notifyListeners();
      return result;
    }

    final pinPersistenceWarning = result.securityStatePersisted
        ? null
        : (result.message ??
              'PIN verified, but secure PIN state could not be saved.');
    final hadActiveProtection =
        _state == ProtectionState.arming ||
        _state == ProtectionState.armed ||
        _state == ProtectionState.alarming ||
        _state == ProtectionState.paused ||
        _activeSessionId != null ||
        _activeIncident != null;
    final shouldStopAudio =
        _state == ProtectionState.alarming ||
        _alarmAudioRequested ||
        _audioAdapter.isPlaying ||
        _isTestAlarmRunning;

    // Invalidate any in-flight siren startup, lifecycle resume, or stale callbacks.
    ++_alarmGeneration;
    ++_lifecycleGeneration;
    _alarmAudioRequested = false;
    _alarmInterruptedByLifecycle = false;

    final endedSessionId = _activeSessionId;
    _cancelCountdownTimer();
    _stopPostAlarmLocationTracking(markIncidentStopped: true);
    _ensureRegularLocationSchedule(immediateCapture: false);
    _clearMovementConfirmationStage();
    _clearInputInteractionGrace();
    _testAlarmTimer?.cancel();
    _testAlarmTimer = null;
    _isTestAlarmRunning = false;
    _activeSessionId = null;
    _notifiedArmedSessionId = null;
    _activeIncidentNeedsWakeRetry = false;
    _activeIncidentPushFailed = false;
    _isCalibrating = false;
    _remainingCountdownSeconds = 0;
    _warningMessage = pinPersistenceWarning;
    _syncArmedLifecycleAndWatchdog(
      armed: false,
      disarmVerified: true,
      protectionState: 'off',
    );

    if (!hadActiveProtection && !shouldStopAudio) {
      notifyListeners();
      return result;
    }

    final currentCap = selectedCapability;
    _state = (currentCap != null && currentCap.canArm)
        ? ProtectionState.disarmed
        : ProtectionState.unavailable;
    _statusMessage = 'Protection turned off.';

    if (shouldStopAudio) {
      try {
        await _audioAdapter.stopAlarm();
      } catch (_) {
        // Continue disarming even if audio adapter reports an error
      }
    }

    if (endedSessionId != null || _activeAuxiliaryDetectors.isNotEmpty) {
      await _stopSessionDetectorsSafely(endedSessionId);
    }

    final currentTestIncident = _activeTestIncident;
    if (currentTestIncident != null) {
      final resolvedTest = currentTestIncident.copyWith(
        resolvedAt: _clock(),
        resolutionSummary: 'Stopped with PIN',
      );
      _activeTestIncident = null;
      _replaceIncidentInMemory(resolvedTest);
      unawaited(_updateIncidentSafely(resolvedTest));
    }

    final currentIncident = _activeIncident;
    if (currentIncident != null) {
      // Re-fetch from _incidents in case async location arrived while alarming.
      final latestStored =
          _findIncidentById(currentIncident.id) ?? currentIncident;
      final resolved = latestStored.copyWith(
        resolvedAt: _clock(),
        resolutionSummary: 'Disarmed with verified PIN',
        locationTrackingState: 'stopped',
      );
      _activeIncident = null;
      _replaceIncidentInMemory(resolved);
      notifyListeners();
      try {
        await _updateIncidentSafely(resolved, rethrowOnError: true);
      } catch (_) {
        const historyWarning =
            'Disarmed, though local activity history could not be saved.';
        _warningMessage = _warningMessage == null
            ? historyWarning
            : '$_warningMessage $historyWarning';
      }
      final adapter = _notificationAdapter;
      if (adapter is MutableRemoteNotificationAdapter) {
        unawaited(
          adapter.updateIncidentLocation(
            incidentId: resolved.id,
            location: resolved.location,
            locationStatus: resolved.locationStatus,
            locationTrackingState: 'stopped',
          ),
        );
      }
    }

    await refreshCapabilities();
    if (_state != ProtectionState.unavailable) {
      _state = ProtectionState.disarmed;
      _statusMessage = 'Protection turned off.';
    }
    _syncHostPresenceMetadata(immediateHeartbeatIfBackground: true);
    notifyListeners();
    return result;
  }

  /// Starts a clearly labeled local siren sound check lasting at most 5 seconds.
  Future<bool> startTestAlarm() async {
    if (_state == ProtectionState.arming ||
        _state == ProtectionState.armed ||
        _state == ProtectionState.alarming ||
        _state == ProtectionState.paused) {
      _warningMessage = 'Turn protection off before testing the siren.';
      notifyListeners();
      return false;
    }

    if (_isTestAlarmRunning) {
      return true;
    }

    final testGeneration = ++_alarmGeneration;
    _testAlarmTimer?.cancel();
    _isTestAlarmRunning = true;
    final now = _clock();
    final testIncident = IncidentRecord(
      id: 'test_inc_${++_incidentSequence}_${now.millisecondsSinceEpoch}',
      sessionId: 'test_session_${now.millisecondsSinceEpoch}',
      kind: IncidentKind.manualTestAlarm,
      detectorType: selectedDetectorType,
      triggeredAt: now,
      deviceName: effectiveDeviceName,
      triggerSummary: 'Local siren test (5 seconds)',
      resolutionSummary: 'Siren test running',
      remoteNotificationAttempted: false,
      remoteNotificationStatus: 'Local speaker test only',
    );
    _activeTestIncident = testIncident;
    _incidents = <IncidentRecord>[testIncident, ..._incidents];
    _statusMessage = 'Playing 5-second siren test…';
    notifyListeners();

    try {
      await _audioAdapter.startTestAlarm(
        volume: _settings.alarmVolume,
        maxDuration: const Duration(seconds: 5),
      );
      if (!_isTestAlarmRunning || testGeneration != _alarmGeneration) {
        await _audioAdapter.stopAlarm();
        return false;
      }
    } catch (_) {
      if (testGeneration == _alarmGeneration) {
        _warningMessage = 'Could not play siren test audio on this device.';
      }
    }

    await _saveIncidentSafely(testIncident);

    if (!_isTestAlarmRunning || testGeneration != _alarmGeneration) {
      return true;
    }

    _testAlarmTimer = Timer(const Duration(seconds: 5), () {
      if (testGeneration == _alarmGeneration) {
        unawaited(stopTestAlarm(autoCompleted: true));
      }
    });
    notifyListeners();
    return true;
  }

  /// Stops an active local Test Alarm immediately.
  Future<void> stopTestAlarm({bool autoCompleted = false}) async {
    if (!_isTestAlarmRunning) {
      return;
    }
    ++_alarmGeneration;
    _testAlarmTimer?.cancel();
    _testAlarmTimer = null;
    _isTestAlarmRunning = false;

    try {
      await _audioAdapter.stopAlarm();
    } catch (_) {
      // Ignore stop error
    }

    final testIncident = _activeTestIncident;
    if (testIncident != null) {
      final resolved = testIncident.copyWith(
        resolvedAt: _clock(),
        resolutionSummary: autoCompleted
            ? 'Siren test finished'
            : 'Siren test stopped',
      );
      _activeTestIncident = null;
      _replaceIncidentInMemory(resolved);
      try {
        await _incidentStorage.updateIncident(resolved);
      } catch (_) {
        // Non-fatal
      }
    }

    final cap = selectedCapability;
    _statusMessage = (cap != null && cap.canArm)
        ? 'Siren test finished. Protection is off.'
        : (cap?.summary ?? 'Siren test finished.');
    notifyListeners();
  }

  /// Sends a real test alert to the paired phone using the exact same incident
  /// delivery + non-blocking location pipeline as a real alarm trigger.
  Future<NotificationDispatchResult> sendTestAlertToPairedPhone() async {
    final now = _clock();
    final hostLabel = effectiveDeviceName;
    final initialLocStatus = _determineInitialLocationStatus();
    final incident = IncidentRecord(
      id: 'test_alert_${++_incidentSequence}_${now.millisecondsSinceEpoch}',
      sessionId: _activeSessionId ?? 'test_alert_${now.millisecondsSinceEpoch}',
      kind: IncidentKind.manualTestAlarm,
      detectorType: selectedDetectorType,
      triggeredAt: now,
      resolvedAt: now,
      deviceName: hostLabel,
      triggerSummary: 'Test alert from $hostLabel',
      resolutionSummary: 'Test alert sent to paired phone',
      locationStatus: initialLocStatus,
    );

    _incidents = <IncidentRecord>[incident, ..._incidents];
    notifyListeners();
    await _saveIncidentSafely(incident);

    // Kick off non-blocking location lookup in parallel so it never delays the alert.
    if (_settings.shareLocationOnAlarm) {
      unawaited(_captureAndAttachIncidentLocation(incident.id));
    }

    NotificationDispatchResult result;
    try {
      result = await _notificationAdapter.sendIncidentAlert(incident);
    } catch (_) {
      result = const NotificationDispatchResult(
        delivered: false,
        capabilityStatus: CapabilityStatus.degraded,
        message: 'Could not reach paired phone right now.',
      );
    }

    final latest = _findIncidentById(incident.id) ?? incident;
    final updated = latest.copyWith(
      remoteNotificationAttempted: true,
      remoteNotificationStatus: result.message,
    );
    _replaceIncidentInMemory(updated);
    await _updateIncidentSafely(updated);
    await refreshNotificationStatus();
    return result;
  }

  /// Clears stored local incident history when not actively alarming.
  Future<void> clearIncidentHistory() async {
    if (_state == ProtectionState.alarming) {
      return;
    }
    ++_incidentHistoryGeneration;
    _incidents = const <IncidentRecord>[];
    try {
      await _drainAndClearIncidentStorage();
    } catch (_) {
      _warningMessage = 'Could not clear activity history.';
    }
    notifyListeners();
  }

  /// Refreshes remote notification service status and paired device list.
  Future<void> refreshNotificationStatus() async {
    try {
      _notificationStatus = await _notificationAdapter.getStatus();
      _pairedDevices = await _notificationAdapter.listPairedDevices();
      await _reconcileConfirmedPhoneReceipts();
    } catch (_) {
      // Non-fatal
    }
    notifyListeners();
  }

  Future<void> _reconcileConfirmedPhoneReceipts() async {
    for (final device in _pairedDevices) {
      final receiptId = device.lastReceiptIncidentId;
      if (receiptId == null || receiptId.isEmpty) {
        continue;
      }
      final existing = _findIncidentById(receiptId);
      if (existing == null) {
        continue;
      }
      final prevStatus = existing.remoteNotificationStatus;
      if (prevStatus.startsWith('Phone receipt confirmed')) {
        continue;
      }
      final sourceNote = device.lastReceiptSource == 'push_sw'
          ? ' (push notification received)'
          : '';
      final updated = existing.copyWith(
        remoteNotificationAttempted: true,
        remoteNotificationStatus:
            'Phone receipt confirmed on "${device.displayName}"$sourceNote',
      );
      if (_activeIncident?.id == updated.id) {
        _activeIncident = updated;
      }
      _replaceIncidentInMemory(updated);
      await _updateIncidentSafely(updated);
    }
  }

  /// Configures an optional custom backend relay endpoint URL (under Advanced).
  Future<bool> configureRelayEndpoint(String? endpointUrl) async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      return false;
    }
    try {
      await adapter.configureRelayEndpoint(endpointUrl);
      _syncHostPresenceMetadata();
      await refreshNotificationStatus();
      return true;
    } catch (_) {
      _warningMessage = 'Could not save custom service address.';
      notifyListeners();
      return false;
    }
  }

  /// Validates and persists a permanent `https://` companion & relay origin to
  /// `~/.watsafe/relay_service.json` so both `WATSafe.app` and `./scripts/run_watsafe.sh`
  /// automatically reconnect to the same permanent address on every startup.
  ///
  /// Passing `null` or an empty string clears the saved permanent override.
  Future<bool> savePermanentRelayEndpoint(String? endpointUrl) async {
    final trimmed = endpointUrl?.trim() ?? '';
    final normalized = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
    if (normalized.isNotEmpty) {
      if (RelayConfig.isEphemeralTunnelUrl(normalized)) {
        _warningMessage = 'Temporary tunnel addresses (*.trycloudflare.com, *.lhr.life, *.ngrok) expire when restarted. Enter a permanent HTTPS domain.';
        notifyListeners();
        return false;
      }
      if (RelayConfig.isPlaceholderUrl(normalized)) {
        _warningMessage = 'Replace the placeholder hostname with your actual deployed https:// service URL.';
        notifyListeners();
        return false;
      }
      if (!RelayConfig.isPermanentHttpsUrl(normalized)) {
        _warningMessage = 'Enter a valid https:// address (for example https://<your-render-service>.onrender.com).';
        notifyListeners();
        return false;
      }
    }

    try {
      await RelayConfig.savePermanentRelayUrl(
        normalized.isEmpty ? null : normalized,
      );
      _settings = _settings.copyWith(permanentRelayEndpointUrl: normalized);
      await _persistSettingsSafely();
    } catch (_) {
      _warningMessage = 'Could not save permanent companion address.';
      notifyListeners();
      return false;
    }

    final nextEndpoint = normalized.isEmpty
        ? RelayConfig.resolveDefaultRelayUrl()
        : normalized;
    final configured = await configureRelayEndpoint(nextEndpoint);
    if (configured) {
      _warningMessage = null;
      notifyListeners();
    }
    return configured;
  }

  /// Pairs a new companion mobile device for remote alert delivery.
  Future<PairedDeviceSummary?> pairCompanionDevice({
    required String displayName,
    required String platform,
    String? pairingCode,
  }) async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      return null;
    }
    try {
      final device = await adapter.pairDevice(
        displayName: displayName,
        platform: platform,
        pairingCode: pairingCode,
      );
      await refreshNotificationStatus();
      await refreshCapabilities();
      return device;
    } catch (_) {
      _warningMessage = 'Could not connect phone right now. Please try again.';
      notifyListeners();
      return null;
    }
  }

  /// Removes a paired companion device by [deviceId] and revokes its access.
  Future<bool> unpairCompanionDevice(String deviceId) async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      return false;
    }
    try {
      await adapter.unpairDevice(deviceId);
      await refreshNotificationStatus();
      await refreshCapabilities();
      return true;
    } catch (_) {
      _warningMessage = 'Could not disconnect phone right now.';
      notifyListeners();
      return false;
    }
  }

  /// Generates a short-lived single-use pairing code and scannable QR URL so a
  /// phone can connect to this device.
  Future<PairingCodeInvitation> initiateHostPairing({
    String? hostDisplayName,
  }) async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      throw StateError('Phone pairing is not available in this configuration.');
    }
    final resolvedHostName =
        (hostDisplayName != null && hostDisplayName.trim().isNotEmpty)
        ? hostDisplayName.trim()
        : effectiveDeviceName;
    final invite = await adapter.initiateHostPairing(
      hostDisplayName: resolvedHostName,
    );
    _lastHostDisplayName = invite.hostDisplayName ?? resolvedHostName;
    _lastReportedHostLocationSignature = null;
    if (!isCompanionMode && _settings.shareLocationOnAlarm) {
      unawaited(
        refreshProtectedDeviceLocation(highAccuracy: false, forceReport: true),
      );
    }
    await refreshNotificationStatus();
    return invite;
  }

  /// Looks up a pairing code without consuming it so the phone can ask
  /// `"Connect to <Host Name>?"` with a single Connect button.
  Future<PairingLookupPreview> lookupPairingInvitation(
    String pairingCodeOrPayload, {
    String? endpointUrlOverride,
  }) async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      throw StateError('Phone pairing is not available in this configuration.');
    }
    return adapter.lookupPairingInvitation(
      pairingCodeOrPayload,
      endpointUrlOverride: endpointUrlOverride,
    );
  }

  /// Queries the relay for companion devices currently paired to this laptop
  /// session and updates [pairedDevices], [notificationStatus], and detector
  /// capabilities.
  Future<List<PairedDeviceSummary>> syncPairedDevicesFromRelay() async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      return _pairedDevices;
    }
    final synced = await adapter.syncPairedDevicesFromRelay();
    await refreshNotificationStatus();
    await refreshCapabilities();
    return synced;
  }

  /// Pairs this app instance as a companion phone using a laptop's short-lived
  /// pairing code, `/pair?code=...` URL, or `watsafe://pair?...` link.
  Future<CompanionSessionState> pairAsCompanionPhone({
    required String pairingCodeOrPayload,
    required String displayName,
    required String platform,
    String? endpointUrlOverride,
    bool? notificationsEnabledOverride,
  }) async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      throw StateError('Phone pairing is not available in this configuration.');
    }
    await refreshPermissionStatuses(notify: false);
    final notifEnabled =
        notificationsEnabledOverride ??
        (_localNotificationPermissionStatus == PermissionStatus.granted);
    final pushToken = await _localNotificationAdapter
        .getPushRegistrationToken();
    final session = await adapter.pairAsCompanionPhone(
      pairingCodeOrPayload: pairingCodeOrPayload,
      displayName: displayName,
      platform: platform,
      endpointUrlOverride: endpointUrlOverride,
      notificationsEnabled: notifEnabled,
      notificationChannel: notifEnabled
          ? _localNotificationAdapter.channelKind
          : 'foreground_only',
      pushToken: pushToken,
    );
    await refreshNotificationStatus();
    return session;
  }

  /// Polls the relay once for any new alerts dispatched by the paired laptop.
  Future<List<CompanionAlertEvent>> pollCompanionAlertsOnce() async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      return const <CompanionAlertEvent>[];
    }
    final alerts = await adapter.pollCompanionAlertsOnce();
    if (alerts.isNotEmpty) {
      _latestUnacknowledgedCompanionAlert = alerts.first;
    }
    await refreshNotificationStatus();
    return alerts;
  }

  /// Disconnects this phone's active companion session.
  Future<void> disconnectCompanionSession() async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      return;
    }
    await adapter.disconnectCompanionSession();
    _latestUnacknowledgedCompanionAlert = null;
    await refreshNotificationStatus();
  }

  /// Dispatches a command to a paired device (preserved for adapter/API compatibility).
  Future<PairedDeviceActionRecord?> executePairedDeviceCommand({
    required String deviceId,
    required PairedDeviceCommandType command,
  }) async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      return null;
    }
    try {
      final record = await adapter.sendDeviceCommand(
        deviceId: deviceId,
        command: command,
        payload: <String, Object?>{
          'hostState': _state.badgeLabel,
          'protectionState': _state.badgeLabel,
          'detector': selectedDetectorType.userFacingMethodName,
          'selectedDetector': selectedDetectorType.userFacingMethodName,
          'motionSensitivity': _settings.motionSensitivity,
          'activeSessionId': _activeSessionId,
        },
      );
      await refreshNotificationStatus();
      await refreshCapabilities();

      if (enableDeveloperControls &&
          command == PairedDeviceCommandType.simulateCompanionMotionTrigger &&
          _state == ProtectionState.armed &&
          _activeSessionId != null) {
        _handleMotionTrigger(
          DetectorEvent(
            eventId:
                'companion_tamper_${_clock().millisecondsSinceEpoch}_$deviceId',
            sessionId: _activeSessionId!,
            detectorType: selectedDetectorType,
            eventType: DetectorEventType.motionTriggered,
            timestamp: _clock(),
            summary: record.summary,
            motionScore: 0.88,
            threshold: MonitorConfig(
              sessionId: _activeSessionId!,
              sensitivity: _settings.motionSensitivity,
            ).motionScoreThreshold,
            consecutiveAboveThresholdFrames: 3,
            isSimulatedTest: true,
          ),
        );
      }

      return record;
    } catch (_) {
      _warningMessage = 'Could not reach paired phone right now.';
      notifyListeners();
      return null;
    }
  }

  void _handleGuidedTestDetectorEvent(DetectorEvent event) {
    switch (event.eventType) {
      case DetectorEventType.calibrationStarted:
      case DetectorEventType.calibrationCompleted:
      case DetectorEventType.telemetryFrame:
        _lastTelemetryEvent = event;
        notifyListeners();
        return;
      case DetectorEventType.poorInputWarning:
        _lastTelemetryEvent = event;
        _warningMessage = event.summary;
        notifyListeners();
        return;
      case DetectorEventType.cameraObstructed:
        _lastTelemetryEvent = event;
        _warningMessage = event.summary;
        notifyListeners();
        return;
      case DetectorEventType.inputRecovered:
        _lastTelemetryEvent = event;
        _warningMessage = null;
        notifyListeners();
        return;
      case DetectorEventType.motionTriggered:
        _lastTelemetryEvent = event;
        if (_guidedTestPhase == 'passerby_check') {
          _guidedTestFalseTriggers += 1;
          notifyListeners();
          return;
        }
        if (_guidedTestPhase == 'lift_check') {
          _guidedTestPickupDetected = true;
          _guidedTestPickupLatency = _guidedTestPhaseStartedAt != null
              ? event.timestamp.difference(_guidedTestPhaseStartedAt!)
              : Duration.zero;
          _guidedTestPhase = 'completed';
          unawaited(stopGuidedProtectionTest());
          notifyListeners();
          return;
        }
        return;
      case DetectorEventType.detectorFailed:
        _warningMessage = event.summary;
        _guidedTestPhase = 'failed';
        unawaited(stopGuidedProtectionTest());
        notifyListeners();
        return;
      case DetectorEventType.lifecyclePaused:
      case DetectorEventType.lifecycleResumed:
        return;
    }
  }

  void _handleDetectorEvent(DetectorEvent event) {
    if (_isGuidedTestRunning &&
        _guidedTestSessionId != null &&
        event.sessionId == _guidedTestSessionId) {
      _handleGuidedTestDetectorEvent(event);
      return;
    }

    // Strictly ignore any late or foreign events that do not match the current session.
    if (_activeSessionId == null || event.sessionId != _activeSessionId) {
      return;
    }

    switch (event.eventType) {
      case DetectorEventType.calibrationStarted:
        _statusMessage = event.summary;
        notifyListeners();
        return;

      case DetectorEventType.calibrationCompleted:
        _statusMessage = event.summary;
        notifyListeners();
        return;

      case DetectorEventType.telemetryFrame:
        _lastTelemetryEvent = event;
        if (_isConfirmingMovement) {
          final threshold = event.threshold;
          final score = event.motionScore;
          final elapsed = _confirmationStartedAt != null
              ? _clock().difference(_confirmationStartedAt!)
              : Duration.zero;
          if (threshold != null &&
              score != null &&
              score < threshold * 0.55 &&
              elapsed >= const Duration(milliseconds: 450)) {
            _clearMovementConfirmationStage(notify: false);
          }
        }
        notifyListeners();
        return;

      case DetectorEventType.poorInputWarning:
        _lastTelemetryEvent = event;
        final currentCap = _capabilities[event.detectorType];
        if (currentCap != null) {
          _capabilities[event.detectorType] = currentCap.copyWith(
            status: CapabilityStatus.degraded,
            statusDetail: event.summary,
          );
        }
        if (_state != ProtectionState.alarming) {
          _warningMessage = event.summary;
          if (_state == ProtectionState.armed &&
              event.summary.toLowerCase().contains('lid and connection')) {
            _statusMessage = 'Camera view blocked — lid and connection alerts active. Enter your PIN to disarm.';
          }
        }
        notifyListeners();
        return;

      case DetectorEventType.cameraObstructed:
        _handleCameraObstruction(event);
        return;

      case DetectorEventType.inputRecovered:
        _lastTelemetryEvent = event;
        final currentCap = _capabilities[event.detectorType];
        if (currentCap != null) {
          _capabilities[event.detectorType] = currentCap.copyWith(
            status: CapabilityStatus.ready,
            statusDetail: event.summary,
          );
        }
        // Removing an obstruction must never automatically disarm or clear an active alarm.
        if (_state != ProtectionState.alarming) {
          _warningMessage = null;
          if (_state == ProtectionState.armed) {
            _statusMessage =
                'Monitoring with ${event.detectorType.userFacingMethodName.toLowerCase()}. Enter your PIN to disarm.';
          }
        }
        notifyListeners();
        return;

      case DetectorEventType.motionTriggered:
        _handleMotionTrigger(event);
        return;

      case DetectorEventType.detectorFailed:
        _handleDetectorFailure(event);
        return;

      case DetectorEventType.lifecyclePaused:
        unawaited(_pauseMonitoringForLifecycle(event.summary));
        return;

      case DetectorEventType.lifecycleResumed:
        unawaited(_handleAppForegroundResumed(event.summary));
        return;
    }
  }

  IncidentLocationStatus _determineInitialLocationStatus() {
    if (!_settings.shareLocationOnAlarm) {
      return IncidentLocationStatus.notRequested;
    }
    if (!_locationAdapter.isSupported) {
      return IncidentLocationStatus.unavailable;
    }
    if (_locationPermissionStatus == PermissionStatus.denied) {
      return IncidentLocationStatus.permissionDenied;
    }
    return IncidentLocationStatus.pending;
  }

  void _handleMotionTrigger(DetectorEvent event) {
    _lastTelemetryEvent = event;

    // One active incident starts one alarm, even if many events arrive.
    if (_state == ProtectionState.alarming) {
      final currentIncident = _activeIncident;
      if (currentIncident != null && event.motionScore != null) {
        final previousPeak = currentIncident.peakMotionScore ?? 0.0;
        if (event.motionScore! > previousPeak) {
          final latest =
              _findIncidentById(currentIncident.id) ?? currentIncident;
          final updated = latest.copyWith(peakMotionScore: event.motionScore);
          _activeIncident = updated;
          _replaceIncidentInMemory(updated);
          unawaited(_updateIncidentSafely(updated));
          notifyListeners();
        }
      }
      return;
    }

    // Only armed sessions accept detector triggers.
    if (_state != ProtectionState.armed) {
      return;
    }

    // Brief confirmation stage ("Movement detected — checking…") for borderline,
    // ambiguous camera-only motion so passing reflections, brief table bumps,
    // or small lighting shifts settle without firing a false alarm, while clear
    // pickup-and-carry ego-motion or AC-unplug-corroborated movement triggers
    // immediately.
    final threshold = event.threshold;
    final score = event.motionScore;
    final isAmbiguousCameraTrigger =
        event.detectorType.usesCamera &&
        !event.isSimulatedTest &&
        _activeAuxiliaryDetectors.isEmpty &&
        event.acPowerUnplugged != true &&
        threshold != null &&
        threshold > 0 &&
        score != null &&
        score >= threshold &&
        score < threshold * 1.38 &&
        (event.coherentBlocks == null || event.coherentBlocks! < 7);

    if (isAmbiguousCameraTrigger && !_isConfirmingMovement) {
      _isConfirmingMovement = true;
      _confirmationStartedAt = _clock();
      _statusMessage = 'Movement detected — checking…';
      _confirmationResetTimer?.cancel();
      _confirmationResetTimer = Timer(_ambiguousMotionConfirmationWindow, () {
        _clearMovementConfirmationStage(notify: true);
      });
      notifyListeners();
      return;
    }

    _clearMovementConfirmationStage(notify: false);
    _stopRegularLocationSchedule();

    final alarmGeneration = ++_alarmGeneration;
    _alarmAudioRequested = true;
    _alarmInterruptedByLifecycle = false;
    _state = ProtectionState.alarming;
    final initialLocStatus = _determineInitialLocationStatus();
    final initialTrackingState =
        (_settings.shareLocationOnAlarm && _locationAdapter.isSupported)
        ? 'live'
        : 'idle';
    final incident = IncidentRecord(
      id: 'inc_${++_incidentSequence}_${event.timestamp.millisecondsSinceEpoch}',
      sessionId: event.sessionId,
      kind: IncidentKind.realDetectorTrigger,
      detectorType: event.detectorType,
      triggeredAt: event.timestamp,
      deviceName: effectiveDeviceName,
      triggerSummary: event.summary,
      peakMotionScore: event.motionScore,
      resolutionSummary: 'Alarm active — enter PIN to disarm',
      locationStatus: initialLocStatus,
      locationTrackingState: initialTrackingState,
    );
    _activeIncident = incident;
    _incidents = <IncidentRecord>[incident, ..._incidents];
    _statusMessage = 'Alarm triggered — ${event.summary}';
    _syncHostPresenceMetadata(immediateHeartbeatIfBackground: true);
    notifyListeners();

    // 1. Start local siren and send initial phone notification immediately (never delayed by location!).
    unawaited(_triggerAudioPersistAndNotify(incident, alarmGeneration));

    // 2. Capture protected device location asynchronously in parallel and start bounded post-alarm tracking.
    if (_settings.shareLocationOnAlarm) {
      _startPostAlarmLocationTracking(incident.id, alarmGeneration);
    }
  }

  Future<void> _captureAndAttachIncidentLocation(
    String incidentId, {
    bool isInitialAlarmCapture = false,
    String trackingState = 'live',
  }) async {
    if (!_locationAdapter.isSupported) {
      await _applyLocationResultToIncident(
        incidentId: incidentId,
        location: null,
        status: IncidentLocationStatus.unavailable,
        isInitialAlarmCapture: isInitialAlarmCapture,
        trackingState: 'stopped',
      );
      return;
    }

    ({DeviceLocationSnapshot? location, IncidentLocationStatus status}) capture;
    try {
      capture = await _locationAdapter.captureCurrentLocation(
        highAccuracy: true,
      );
    } catch (_) {
      capture = (location: null, status: IncidentLocationStatus.unavailable);
    }

    final validLocation =
        (capture.location != null && capture.location!.isValid)
        ? capture.location
        : null;
    final resolvedStatus = validLocation != null
        ? IncidentLocationStatus.attached
        : (capture.status == IncidentLocationStatus.attached
              ? IncidentLocationStatus.unavailable
              : capture.status);

    if (resolvedStatus == IncidentLocationStatus.permissionDenied) {
      _locationPermissionStatus = PermissionStatus.denied;
      _hostLocationStatus = IncidentLocationStatus.permissionDenied;
      _stopPostAlarmLocationTracking(markIncidentStopped: false);
    } else if (validLocation != null) {
      _hostLatestLocation = validLocation;
      _hostLocationStatus = IncidentLocationStatus.attached;
    }

    final resolvedTrackingState = !_isPostAlarmTrackingActive
        ? 'stopped'
        : (validLocation != null
              ? trackingState
              : (resolvedStatus == IncidentLocationStatus.permissionDenied
                    ? 'stopped'
                    : 'reconnecting'));
    _postAlarmTrackingState = resolvedTrackingState;

    await _applyLocationResultToIncident(
      incidentId: incidentId,
      location: validLocation,
      status: resolvedStatus,
      isInitialAlarmCapture: isInitialAlarmCapture,
      trackingState: resolvedTrackingState,
    );
  }

  Future<void> _applyLocationResultToIncident({
    required String incidentId,
    required DeviceLocationSnapshot? location,
    required IncidentLocationStatus status,
    bool isInitialAlarmCapture = false,
    String? trackingState,
  }) async {
    final existing = _findIncidentById(incidentId);
    if (existing == null) {
      return;
    }
    final validLocation = (location != null && location.isValid)
        ? location
        : null;
    final resolvedLatest = validLocation ?? existing.location;
    final resolvedAlarmTime = existing.alarmTimeLocation ?? validLocation;
    final resolvedTrail = validLocation != null
        ? DeviceLocationSnapshot.appendFilteredTrailPoint(
            existing.locationTrail,
            validLocation,
            maxPoints: 60,
          )
        : existing.locationTrail;
    final resolvedStatus = resolvedLatest != null
        ? IncidentLocationStatus.attached
        : status;
    final resolvedTracking = trackingState ?? existing.locationTrackingState;

    final updated = existing.copyWith(
      location: resolvedLatest,
      alarmTimeLocation: resolvedAlarmTime,
      locationTrail: resolvedTrail,
      locationStatus: resolvedStatus,
      locationTrackingState: resolvedTracking,
    );
    if (_activeIncident?.id == incidentId) {
      _activeIncident = updated;
    }
    _replaceIncidentInMemory(updated);
    notifyListeners();
    await _updateIncidentSafely(updated);

    final adapter = _notificationAdapter;
    if (adapter is MutableRemoteNotificationAdapter) {
      try {
        await adapter.updateIncidentLocation(
          incidentId: incidentId,
          location: updated.location,
          locationStatus: updated.locationStatus,
          locationTrackingState: updated.locationTrackingState,
        );
        if (validLocation != null) {
          await adapter.reportHostLocation(
            location: validLocation,
            locationStatus: updated.locationStatus,
            protectionState: _state.badgeLabel,
            activeIncidentId: incidentId,
            isBoundedAlarmTracking: _isPostAlarmTrackingActive,
          );
        }
      } catch (_) {
        if (_isPostAlarmTrackingActive) {
          _postAlarmTrackingState = 'reconnecting';
          notifyListeners();
        }
      }
    }
  }

  Future<void> _triggerAudioPersistAndNotify(
    IncidentRecord incident,
    int alarmGeneration,
  ) async {
    final warnings = <String>[];

    final isStillActiveAlarm =
        alarmGeneration == _alarmGeneration &&
        _state == ProtectionState.alarming &&
        _activeIncident?.id == incident.id;
    if (isStillActiveAlarm) {
      try {
        await _audioAdapter.startLoopingAlarm(volume: _settings.alarmVolume);
        if (alarmGeneration != _alarmGeneration ||
            _state != ProtectionState.alarming ||
            _activeIncident?.id != incident.id) {
          try {
            await _audioAdapter.stopAlarm();
          } catch (_) {
            // Ignore stop error
          }
        }
      } catch (_) {
        if (alarmGeneration == _alarmGeneration &&
            _state == ProtectionState.alarming) {
          warnings.add('Speaker siren could not start on this device.');
        }
      }
    }

    final historyGen = _incidentHistoryGeneration;
    var latestIncident = _findIncidentById(incident.id) ?? incident;
    if (historyGen == _incidentHistoryGeneration &&
        _findIncidentById(incident.id) != null) {
      try {
        await _saveIncidentSafely(latestIncident, rethrowOnError: true);
      } catch (_) {
        if (alarmGeneration == _alarmGeneration) {
          warnings.add('Local incident save failed.');
        }
      }
    }

    if (historyGen != _incidentHistoryGeneration || _isDisposed) {
      return;
    }

    final motionAlertCompleter = Completer<void>();
    _inFlightUrgentAlertFuture = motionAlertCompleter.future;
    try {
      latestIncident = _findIncidentById(incident.id) ?? latestIncident;
      final dispatchResult = await _notificationAdapter.sendIncidentAlert(
        latestIncident,
      );
      if (historyGen != _incidentHistoryGeneration ||
          _isDisposed ||
          _findIncidentById(incident.id) == null) {
        return;
      }
      if (dispatchResult.delivered ||
          dispatchResult.pushAccepted ||
          dispatchResult.deduplicatedByWatchdog) {
        _notifiedArmedSessionId = incident.sessionId;
        _activeIncidentNeedsWakeRetry = false;
        _syncNativeLifecycleContextOnly();
      } else if (dispatchResult.pushFailed) {
        _activeIncidentPushFailed = true;
        _activeIncidentNeedsWakeRetry = false;
        if (alarmGeneration == _alarmGeneration) {
          warnings.add(dispatchResult.message);
        }
      } else if (!dispatchResult.relayRecorded) {
        _activeIncidentNeedsWakeRetry = true;
      }
      latestIncident = (_findIncidentById(incident.id) ?? latestIncident)
          .copyWith(
            remoteNotificationAttempted: true,
            remoteNotificationStatus: dispatchResult.message,
          );
      if (_activeIncident?.id == latestIncident.id) {
        _activeIncident = latestIncident;
      }
      _replaceIncidentInMemory(latestIncident);
      await _updateIncidentSafely(latestIncident);

      // If async location finished right before or during initial report, push
      // a location update too so the relay event definitely has it attached.
      final postDispatch = _findIncidentById(incident.id);
      final mutable = _notificationAdapter;
      if ((dispatchResult.delivered || dispatchResult.relayRecorded) &&
          postDispatch != null &&
          postDispatch.location != null &&
          mutable is MutableRemoteNotificationAdapter) {
        unawaited(
          mutable.updateIncidentLocation(
            incidentId: postDispatch.id,
            location: postDispatch.location,
            locationStatus: postDispatch.locationStatus,
            locationTrackingState: postDispatch.locationTrackingState,
          ),
        );
      }
    } catch (_) {
      if (alarmGeneration == _alarmGeneration) {
        warnings.add('Remote alert dispatch failed.');
      }
      _activeIncidentNeedsWakeRetry = true;
      latestIncident = (_findIncidentById(incident.id) ?? latestIncident)
          .copyWith(
            remoteNotificationAttempted: true,
            remoteNotificationStatus: 'Phone alert failed',
          );
      if (_activeIncident?.id == latestIncident.id) {
        _activeIncident = latestIncident;
      }
      _replaceIncidentInMemory(latestIncident);
    } finally {
      if (!motionAlertCompleter.isCompleted) {
        motionAlertCompleter.complete();
      }
      if (identical(_inFlightUrgentAlertFuture, motionAlertCompleter.future)) {
        _inFlightUrgentAlertFuture = null;
      }
    }

    if (warnings.isNotEmpty &&
        alarmGeneration == _alarmGeneration &&
        _state == ProtectionState.alarming) {
      _warningMessage = warnings.join(' ');
    }
    notifyListeners();
  }

  IncidentRecord? _findIncidentById(String id) {
    for (final item in _incidents) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  void _syncNativeLifecycleContextOnly({bool disarmVerified = false}) {
    final effectiveArmed =
        !disarmVerified &&
        (_state == ProtectionState.armed || _state == ProtectionState.alarming);
    final mutable = _notificationAdapter;
    final creds = mutable is MutableRemoteNotificationAdapter
        ? mutable.emergencyHostCredentials
        : null;
    final sessionId = _activeSessionId;
    final lastKnown =
        (_settings.shareLocationOnAlarm && _hostLatestLocation != null)
        ? _hostLatestLocation!.copyWith(isLastKnown: true).toJson()
        : null;
    unawaited(
      _systemLifecycleAdapter.syncProtectionState(
        armed: effectiveArmed,
        monitorInputInteraction:
            !disarmVerified &&
            _state == ProtectionState.armed &&
            _settings.alertOnInputInteraction,
        armedSessionId: sessionId,
        correlationIncidentId: sessionId != null ? 'lid_$sessionId' : null,
        alreadyNotifiedSessionId: _notifiedArmedSessionId,
        relayEndpointUrl: creds?.endpointUrl ?? relayEndpointUrl,
        hostToken: creds?.hostToken,
        deviceName: effectiveDeviceName,
        detectorType: selectedDetectorType.id,
        shareLocationOnAlarm: _settings.shareLocationOnAlarm,
        lastKnownLocationJson: lastKnown,
        alarmVolume: _settings.alarmVolume,
      ),
    );
  }

  void _syncArmedLifecycleAndWatchdog({
    required bool armed,
    String? armedSessionId,
    bool disarmVerified = false,
    String? protectionState,
  }) {
    final mutable = _notificationAdapter;
    final creds = mutable is MutableRemoteNotificationAdapter
        ? mutable.emergencyHostCredentials
        : null;
    final effectiveSessionId = armedSessionId ?? _activeSessionId;
    final effectiveArmed =
        !disarmVerified && (armed || _state == ProtectionState.alarming);
    final lastKnown =
        (_settings.shareLocationOnAlarm && _hostLatestLocation != null)
        ? _hostLatestLocation!.copyWith(isLastKnown: true).toJson()
        : null;
    unawaited(
      _systemLifecycleAdapter.syncProtectionState(
        armed: effectiveArmed,
        monitorInputInteraction:
            !disarmVerified && armed && _settings.alertOnInputInteraction,
        armedSessionId: effectiveSessionId,
        correlationIncidentId: effectiveSessionId != null
            ? 'lid_$effectiveSessionId'
            : null,
        alreadyNotifiedSessionId: disarmVerified
            ? null
            : _notifiedArmedSessionId,
        relayEndpointUrl: creds?.endpointUrl ?? relayEndpointUrl,
        hostToken: creds?.hostToken,
        deviceName: effectiveDeviceName,
        detectorType: selectedDetectorType.id,
        shareLocationOnAlarm: _settings.shareLocationOnAlarm,
        lastKnownLocationJson: lastKnown,
        alarmVolume: _settings.alarmVolume,
      ),
    );
    if (mutable is MutableRemoteNotificationAdapter) {
      unawaited(
        mutable.syncHostArmedState(
          armed: armed,
          armedSessionId: armedSessionId,
          disarmVerified: disarmVerified,
          protectionState: protectionState ?? _state.name,
        ),
      );
    }
  }

  void _clearInputInteractionGrace({bool notify = false}) {
    _inputGraceTimer?.cancel();
    _inputGraceTimer = null;
    final wasActive = _isInputInteractionGraceActive;
    _isInputInteractionGraceActive = false;
    if (wasActive && notify) {
      notifyListeners();
    }
  }

  void _releaseFlushTokenWhenUrgentWorkDone(String? flushToken) {
    if (flushToken == null || flushToken.isEmpty) {
      return;
    }
    final inFlight = _inFlightUrgentAlertFuture;
    if (inFlight != null) {
      unawaited(
        inFlight.whenComplete(() {
          unawaited(_systemLifecycleAdapter.completeUrgentFlush(flushToken));
        }),
      );
    } else {
      unawaited(_systemLifecycleAdapter.completeUrgentFlush(flushToken));
    }
  }

  void _handleLifecycleInterruptionSignal({
    required SystemLifecycleEvent event,
    required String fallbackSummary,
  }) {
    if (_state == ProtectionState.armed) {
      final sessionId = event.sessionId ?? _activeSessionId;
      final deterministicId =
          (event.incidentId != null && event.incidentId!.trim().isNotEmpty)
          ? event.incidentId!.trim()
          : (sessionId != null ? 'lid_$sessionId' : null);
      unawaited(
        _triggerImmediateInterruptionAlert(
          summary: fallbackSummary,
          flushToken: event.flushToken,
          explicitIncidentId: deterministicId,
          triggeredAtOverride: event.timestamp,
          nativeReport: event.nativeEmergencyReport,
          stopDetectorsForSleep:
              event.type == SystemLifecycleEventType.lidClosed ||
              event.type == SystemLifecycleEventType.systemWillSleep ||
              event.type == SystemLifecycleEventType.systemWillPowerOff,
        ),
      );
      return;
    }

    if (_state == ProtectionState.alarming) {
      final nativeReport = event.nativeEmergencyReport;
      if (nativeReport != null &&
          (nativeReport.delivered ||
              nativeReport.pushAccepted ||
              nativeReport.deduplicatedByWatchdog) &&
          _activeIncident != null &&
          _notifiedArmedSessionId != _activeIncident!.sessionId) {
        _notifiedArmedSessionId = _activeIncident!.sessionId;
        _activeIncidentNeedsWakeRetry = false;
        final statusText = nativeReport.deduplicatedByWatchdog
            ? 'Server watchdog already alerted paired phone while laptop was unreachable'
            : 'Urgent pre-sleep alert accepted by push service';
        final reconciled = _activeIncident!.copyWith(
          remoteNotificationAttempted: true,
          remoteNotificationStatus: statusText,
        );
        _activeIncident = reconciled;
        _replaceIncidentInMemory(reconciled);
        unawaited(_updateIncidentSafely(reconciled));
        notifyListeners();
      } else if (_activeIncident != null &&
          _activeIncidentNeedsWakeRetry &&
          !_activeIncidentPushFailed &&
          _inFlightUrgentAlertFuture == null) {
        // Earlier delivery attempt failed — do NOT suppress this follow-up retry!
        unawaited(
          _retryFailedInterruptionAlert(
            _activeIncident!,
            flushToken: event.flushToken,
          ),
        );
        return;
      }
    }

    _releaseFlushTokenWhenUrgentWorkDone(event.flushToken);
  }

  Future<void> _retryFailedInterruptionAlert(
    IncidentRecord incident, {
    String? flushToken,
  }) async {
    final retryCompleter = Completer<void>();
    _inFlightUrgentAlertFuture = retryCompleter.future;
    NotificationDispatchResult? dispatchResult;
    try {
      final mutable = _notificationAdapter;
      if (mutable is MutableRemoteNotificationAdapter) {
        dispatchResult = await mutable.sendUrgentPreSuspensionAlert(incident);
      } else {
        dispatchResult = await _notificationAdapter.sendIncidentAlert(incident);
      }
    } catch (_) {
      dispatchResult = null;
    } finally {
      if (!retryCompleter.isCompleted) {
        retryCompleter.complete();
      }
      if (identical(_inFlightUrgentAlertFuture, retryCompleter.future)) {
        _inFlightUrgentAlertFuture = null;
      }
      if (flushToken != null && flushToken.isNotEmpty) {
        unawaited(_systemLifecycleAdapter.completeUrgentFlush(flushToken));
      }
    }
    if (dispatchResult == null || _isDisposed) {
      return;
    }
    if (dispatchResult.delivered ||
        dispatchResult.pushAccepted ||
        dispatchResult.deduplicatedByWatchdog) {
      _notifiedArmedSessionId = incident.sessionId;
      _activeIncidentNeedsWakeRetry = false;
      _syncNativeLifecycleContextOnly();
    } else if (dispatchResult.pushFailed) {
      _activeIncidentPushFailed = true;
      _activeIncidentNeedsWakeRetry = false;
      _warningMessage = dispatchResult.message;
    } else if (!dispatchResult.relayRecorded) {
      _activeIncidentNeedsWakeRetry = true;
    } else {
      _activeIncidentNeedsWakeRetry = false;
    }
    final latest = _findIncidentById(incident.id) ?? incident;
    final updated = latest.copyWith(
      remoteNotificationAttempted: true,
      remoteNotificationStatus: dispatchResult.message,
    );
    if (_activeIncident?.id == updated.id) {
      _activeIncident = updated;
    }
    _replaceIncidentInMemory(updated);
    await _updateIncidentSafely(updated);
    notifyListeners();
  }

  /// Reconciles any native pre-sleep emergency report captured while the
  /// Flutter Dart isolate was frozen during sleep, and flushes any failed
  /// pre-sleep alert once on wake (deduplicated against the server watchdog)
  /// without ever triggering a delayed duplicate camera-motion alarm on reopen.
  Future<void> _reconcileWakeFromSleep() {
    final existing = _inFlightWakeReconcile;
    if (existing != null) {
      return existing;
    }
    final future = _executeWakeReconciliation();
    _inFlightWakeReconcile = future;
    future.whenComplete(() {
      if (identical(_inFlightWakeReconcile, future)) {
        _inFlightWakeReconcile = null;
      }
    });
    return future;
  }

  Future<void> _executeWakeReconciliation() async {
    NativeEmergencyReportSummary? pendingNative;
    try {
      pendingNative = await _systemLifecycleAdapter
          .consumePendingEmergencyReport();
    } catch (_) {
      pendingNative = null;
    }

    if (pendingNative != null) {
      final matchesActiveArmedSession =
          (_state == ProtectionState.armed ||
              _state == ProtectionState.paused) &&
          (_activeSessionId == null ||
              pendingNative.sessionId.isEmpty ||
              pendingNative.sessionId == _activeSessionId);
      if (matchesActiveArmedSession) {
        final summary = pendingNative.summary.trim().isNotEmpty
            ? pendingNative.summary.trim()
            : (pendingNative.eventType == SystemLifecycleEventType.lidClosed
                  ? 'Protection interrupted — laptop lid closed while armed.'
                  : 'Protection interrupted — laptop went to sleep while armed.');
        await _triggerImmediateInterruptionAlert(
          summary: summary,
          explicitIncidentId: pendingNative.incidentId.isNotEmpty
              ? pendingNative.incidentId
              : (_activeSessionId != null ? 'lid_$_activeSessionId' : null),
          triggeredAtOverride: pendingNative.triggeredAt,
          nativeReport: pendingNative,
          stopDetectorsForSleep: true,
        );
        return;
      }

      if (_state == ProtectionState.alarming && _activeIncident != null) {
        if ((pendingNative.delivered ||
                pendingNative.pushAccepted ||
                pendingNative.deduplicatedByWatchdog) &&
            _notifiedArmedSessionId != _activeIncident!.sessionId) {
          _notifiedArmedSessionId = _activeIncident!.sessionId;
          _activeIncidentNeedsWakeRetry = false;
          final statusText = pendingNative.deduplicatedByWatchdog
              ? 'Server watchdog already alerted paired phone while laptop was unreachable'
              : 'Urgent pre-sleep alert accepted by push service';
          final updated = _activeIncident!.copyWith(
            remoteNotificationAttempted: true,
            remoteNotificationStatus: statusText,
          );
          _activeIncident = updated;
          _replaceIncidentInMemory(updated);
          await _updateIncidentSafely(updated);
          notifyListeners();
        } else if (pendingNative.pushFailed) {
          _activeIncidentPushFailed = true;
          _activeIncidentNeedsWakeRetry = false;
          _warningMessage = 'Push delivery rejected — open WATSafe on your phone to repair notifications.';
          notifyListeners();
        }
      }
    }

    if (_state == ProtectionState.alarming &&
        _activeIncident != null &&
        _activeIncidentNeedsWakeRetry &&
        !_activeIncidentPushFailed &&
        _inFlightUrgentAlertFuture == null) {
      await _retryFailedInterruptionAlert(_activeIncident!);
    }
  }

  void _handleSystemLifecycleEvent(SystemLifecycleEvent event) {
    switch (event.type) {
      case SystemLifecycleEventType.lidClosed:
        _handleLifecycleInterruptionSignal(
          event: event,
          fallbackSummary:
              'Protection interrupted — laptop lid closed while armed.',
        );
        return;

      case SystemLifecycleEventType.systemWillSleep:
        _handleLifecycleInterruptionSignal(
          event: event,
          fallbackSummary:
              'Protection interrupted — laptop is going to sleep while armed.',
        );
        return;

      case SystemLifecycleEventType.systemWillPowerOff:
        _handleLifecycleInterruptionSignal(
          event: event,
          fallbackSummary: 'Protection interrupted — system shutdown or restart initiated while armed.',
        );
        return;

      case SystemLifecycleEventType.sessionResignedActive:
        _handleLifecycleInterruptionSignal(
          event: event,
          fallbackSummary: 'Protection interrupted — user session logged out or switched while armed.',
        );
        return;

      case SystemLifecycleEventType.appWillTerminate:
        _handleLifecycleInterruptionSignal(
          event: event,
          fallbackSummary:
              'Protection interrupted — WATSafe was closed while armed.',
        );
        return;

      case SystemLifecycleEventType.userInputDetected:
        if (_state == ProtectionState.armed &&
            _settings.alertOnInputInteraction &&
            !_isInputInteractionGraceActive) {
          final armedSession = _activeSessionId;
          _isInputInteractionGraceActive = true;
          final graceSeconds = _inputInteractionGracePeriod.inSeconds;
          _warningMessage =
              'Keyboard or trackpad activity detected — enter your PIN within $graceSeconds seconds to disarm.';
          notifyListeners();
          _inputGraceTimer?.cancel();
          _inputGraceTimer = Timer(_inputInteractionGracePeriod, () {
            _inputGraceTimer = null;
            _isInputInteractionGraceActive = false;
            if (_state != ProtectionState.armed ||
                armedSession == null ||
                _activeSessionId != armedSession) {
              return;
            }
            _handleMotionTrigger(
              DetectorEvent(
                eventId:
                    'input_tamper_${_clock().millisecondsSinceEpoch}_$armedSession',
                sessionId: armedSession,
                detectorType: selectedDetectorType,
                eventType: DetectorEventType.motionTriggered,
                timestamp: _clock(),
                summary: 'Keyboard or trackpad interaction detected while armed without PIN disarm.',
                motionScore: 1.0,
                threshold: 0.25,
                consecutiveAboveThresholdFrames: 3,
              ),
            );
          });
        }
        return;

      case SystemLifecycleEventType.systemDidWake:
      case SystemLifecycleEventType.lidOpened:
        unawaited(() async {
          await _reconcileWakeFromSleep();
          if (_isDisposed) {
            return;
          }
          _syncHostPresenceMetadata(immediateHeartbeatIfBackground: true);
          _ensureRegularLocationSchedule(
            immediateCapture: true,
            minElapsedSinceLastAttempt: const Duration(seconds: 30),
          );
          if (_state == ProtectionState.alarming) {
            await _ensureActiveAlarmAudioOnResume('System woke from sleep');
          }
        }());
        return;

      case SystemLifecycleEventType.screensDidSleep:
        return;
    }
  }

  void _handleCameraObstruction(DetectorEvent event) {
    _lastTelemetryEvent = event;
    final currentCap = _capabilities[event.detectorType];
    if (currentCap != null) {
      _capabilities[event.detectorType] = currentCap.copyWith(
        status: CapabilityStatus.degraded,
        statusDetail: event.summary,
      );
    }

    if (_state == ProtectionState.alarming || _state != ProtectionState.armed) {
      notifyListeners();
      return;
    }

    if (!_settings.alertOnCameraObstruction) {
      _warningMessage = 'Camera view is obstructed. Camera obstruction alarm is turned off in Settings.';
      notifyListeners();
      return;
    }

    final summary = event.summary.trim().isNotEmpty
        ? event.summary.trim()
        : 'Camera blocked — webcam view obstructed while armed.';
    _syncArmedLifecycleAndWatchdog(
      armed: true,
      armedSessionId: _activeSessionId,
      protectionState: 'interrupted',
    );
    unawaited(_triggerImmediateInterruptionAlert(summary: summary));
  }

  /// Immediately records a `protectionInterrupted` incident, attaches the
  /// latest known coordinates with their original timestamp (never waiting on
  /// fresh geolocation), and initiates the urgent remote phone alert and local
  /// siren in parallel before the OS suspends or terminates the process.
  Future<void> _triggerImmediateInterruptionAlert({
    required String summary,
    String? flushToken,
    String? explicitIncidentId,
    DateTime? triggeredAtOverride,
    NativeEmergencyReportSummary? nativeReport,
    bool stopDetectorsForSleep = false,
  }) async {
    final canTriggerFromCurrentState =
        _state == ProtectionState.armed ||
        (nativeReport != null && _state == ProtectionState.paused);
    if (!canTriggerFromCurrentState) {
      _releaseFlushTokenWhenUrgentWorkDone(flushToken);
      return;
    }

    _clearMovementConfirmationStage(notify: false);
    _clearInputInteractionGrace(notify: false);
    _stopRegularLocationSchedule();

    final now = _clock();
    final triggeredAt = triggeredAtOverride ?? now;
    final sessionId =
        _activeSessionId ?? 'interrupted_${now.millisecondsSinceEpoch}';
    final alarmGeneration = ++_alarmGeneration;
    _alarmAudioRequested = true;
    _alarmInterruptedByLifecycle = false;
    _state = ProtectionState.alarming;
    if (stopDetectorsForSleep) {
      unawaited(_stopSessionDetectorsSafely(sessionId));
    }

    final lastKnown =
        (_settings.shareLocationOnAlarm && _hostLatestLocation != null)
        ? _hostLatestLocation!.copyWith(isLastKnown: true)
        : null;
    final initialLocStatus = lastKnown != null
        ? IncidentLocationStatus.attached
        : _determineInitialLocationStatus();
    final initialTrackingState =
        (_settings.shareLocationOnAlarm && _locationAdapter.isSupported)
        ? 'live'
        : (lastKnown != null ? 'last_known' : 'idle');

    final isCameraBlocked = summary.toLowerCase().startsWith('camera blocked');
    final resolvedIncidentId =
        (explicitIncidentId != null && explicitIncidentId.trim().isNotEmpty)
        ? explicitIncidentId.trim()
        : 'int_${++_incidentSequence}_${now.millisecondsSinceEpoch}';
    final nativeAlreadyDelivered =
        nativeReport != null &&
        (nativeReport.delivered ||
            nativeReport.pushAccepted ||
            nativeReport.deduplicatedByWatchdog);
    final nativeAlreadyRejectedPush =
        nativeReport != null &&
        nativeReport.pushFailed &&
        !nativeAlreadyDelivered;

    String? initialRemoteStatus;
    if (nativeAlreadyDelivered) {
      _notifiedArmedSessionId = sessionId;
      _activeIncidentNeedsWakeRetry = false;
      initialRemoteStatus = nativeReport.deduplicatedByWatchdog
          ? 'Server watchdog already alerted paired phone while laptop was unreachable'
          : (nativeReport.pushAccepted
                ? 'Urgent pre-sleep alert accepted by push service'
                : 'Urgent pre-sleep alert recorded on relay');
    } else if (nativeAlreadyRejectedPush) {
      _activeIncidentPushFailed = true;
      _activeIncidentNeedsWakeRetry = false;
      initialRemoteStatus = 'Push delivery rejected — recorded on relay only. Open WATSafe on your phone to repair notifications.';
      _warningMessage = initialRemoteStatus;
    }

    final incident = IncidentRecord(
      id: resolvedIncidentId,
      sessionId: sessionId,
      kind: IncidentKind.protectionInterrupted,
      detectorType: selectedDetectorType,
      triggeredAt: triggeredAt,
      deviceName: effectiveDeviceName,
      triggerSummary: summary,
      resolutionSummary: isCameraBlocked
          ? 'Camera blocked — enter PIN to disarm'
          : 'Protection interrupted — enter PIN to disarm',
      location: lastKnown,
      alarmTimeLocation: lastKnown,
      locationTrail: lastKnown != null
          ? <DeviceLocationSnapshot>[lastKnown]
          : const <DeviceLocationSnapshot>[],
      locationStatus: initialLocStatus,
      locationTrackingState: initialTrackingState,
      remoteNotificationAttempted:
          nativeAlreadyDelivered || nativeAlreadyRejectedPush,
      remoteNotificationStatus: initialRemoteStatus ?? 'Not sent',
    );
    _activeIncident = incident;
    _incidents = <IncidentRecord>[
      incident,
      ..._incidents.where((item) => item.id != incident.id),
    ];
    _statusMessage = summary;
    notifyListeners();

    final localSaveFuture = _saveIncidentSafely(incident);

    // 1. Fire urgent network alert immediately unless the native emergency
    //    bridge already completed delivery (or push was definitively rejected).
    final Future<void> urgentNetworkFuture;
    if (nativeAlreadyDelivered || nativeAlreadyRejectedPush) {
      if (flushToken != null && flushToken.isNotEmpty) {
        unawaited(_systemLifecycleAdapter.completeUrgentFlush(flushToken));
      }
      _syncNativeLifecycleContextOnly();
      urgentNetworkFuture = localSaveFuture;
    } else {
      final networkHttpCompleter = Completer<void>();
      _inFlightUrgentAlertFuture = networkHttpCompleter.future;
      urgentNetworkFuture = () async {
        NotificationDispatchResult? dispatchResult;
        try {
          final mutable = _notificationAdapter;
          if (mutable is MutableRemoteNotificationAdapter) {
            dispatchResult = await mutable.sendUrgentPreSuspensionAlert(
              incident,
            );
          } else {
            dispatchResult = await _notificationAdapter.sendIncidentAlert(
              incident,
            );
          }
        } catch (_) {
          dispatchResult = null;
        } finally {
          if (!networkHttpCompleter.isCompleted) {
            networkHttpCompleter.complete();
          }
          if (identical(
            _inFlightUrgentAlertFuture,
            networkHttpCompleter.future,
          )) {
            _inFlightUrgentAlertFuture = null;
          }
          if (flushToken != null && flushToken.isNotEmpty) {
            unawaited(_systemLifecycleAdapter.completeUrgentFlush(flushToken));
          }
        }

        if (dispatchResult != null) {
          if (dispatchResult.delivered ||
              dispatchResult.pushAccepted ||
              dispatchResult.deduplicatedByWatchdog) {
            _notifiedArmedSessionId = sessionId;
            _activeIncidentNeedsWakeRetry = false;
            _syncNativeLifecycleContextOnly();
          } else if (dispatchResult.pushFailed) {
            _activeIncidentPushFailed = true;
            _activeIncidentNeedsWakeRetry = false;
            if (alarmGeneration == _alarmGeneration &&
                _state == ProtectionState.alarming) {
              _warningMessage = dispatchResult.message;
            }
          } else if (!dispatchResult.relayRecorded) {
            _activeIncidentNeedsWakeRetry = true;
          } else {
            _activeIncidentNeedsWakeRetry = false;
          }
        } else {
          _activeIncidentNeedsWakeRetry = true;
        }

        await localSaveFuture;
        final latest = _findIncidentById(incident.id) ?? incident;
        final updated = latest.copyWith(
          remoteNotificationAttempted: true,
          remoteNotificationStatus:
              dispatchResult?.message ??
              'Pre-sleep alert failed; server watchdog will follow up',
        );
        if (_activeIncident?.id == updated.id) {
          _activeIncident = updated;
        }
        _replaceIncidentInMemory(updated);
        await _updateIncidentSafely(updated);
        notifyListeners();
      }();
    }

    // 2. Start local siren immediately in parallel (best-effort before sleep).
    final localSirenFuture = () async {
      if (alarmGeneration != _alarmGeneration ||
          _state != ProtectionState.alarming ||
          _activeIncident?.id != incident.id) {
        return;
      }
      try {
        await _audioAdapter.startLoopingAlarm(volume: _settings.alarmVolume);
        if (alarmGeneration != _alarmGeneration ||
            _state != ProtectionState.alarming ||
            _activeIncident?.id != incident.id) {
          await _audioAdapter.stopAlarm();
        }
      } catch (_) {
        // Non-fatal during impending OS sleep
      }
    }();

    // 3. Kick off non-blocking location tracking in case the laptop stays awake
    //    (for example clamshell mode on external power/display or cancelled quit).
    if (_settings.shareLocationOnAlarm) {
      _startPostAlarmLocationTracking(incident.id, alarmGeneration);
    }

    await Future.wait<void>(<Future<void>>[
      urgentNetworkFuture,
      localSirenFuture,
    ]);
  }

  void _handleDetectorFailure(DetectorEvent event) {
    // An already active siren must not stop because the detector later fails.
    if (_state == ProtectionState.alarming) {
      _warningMessage = 'Motion sensor stopped while alarm is active.';
      final currentCap = _capabilities[event.detectorType];
      if (currentCap != null) {
        _capabilities[event.detectorType] = currentCap.copyWith(
          status: CapabilityStatus.unsupported,
          statusDetail: event.summary,
        );
      }
      notifyListeners();
      return;
    }

    // If only an auxiliary corroborating sensor failed, keep primary monitoring active.
    if (event.detectorType != selectedDetectorType &&
        _activeAuxiliaryDetectors.contains(event.detectorType)) {
      _activeAuxiliaryDetectors.remove(event.detectorType);
      unawaited(
        _detectors[event.detectorType]?.stopMonitoring(
          sessionId: _activeSessionId,
        ),
      );
      _warningMessage =
          'Secondary sensor stopped; ${selectedDetectorType.userFacingMethodName.toLowerCase()} monitoring remains active.';
      notifyListeners();
      return;
    }

    // Camera unplugging, permission revocation, or capture failure while armed
    // is treated as an immediate protection interruption: sound the local siren,
    // alert the paired phone, and keep armed lid/sleep & watchdog protection active
    // until disarmed with the PIN.
    if (_state == ProtectionState.armed && event.detectorType.usesCamera) {
      final currentCap = _capabilities[event.detectorType];
      if (currentCap != null) {
        _capabilities[event.detectorType] = currentCap.copyWith(
          status: CapabilityStatus.unsupported,
          summary: event.summary,
          statusDetail: event.errorCode,
        );
      }
      _warningMessage =
          'Camera disconnected or unavailable while armed (${event.summary}).';
      unawaited(_stopSessionDetectorsSafely(_activeSessionId));
      _syncArmedLifecycleAndWatchdog(
        armed: true,
        armedSessionId: _activeSessionId,
        protectionState: 'interrupted',
      );
      unawaited(
        _triggerImmediateInterruptionAlert(
          summary:
              'Protection interrupted — camera unavailable while armed (${event.summary}).',
        ),
      );
      return;
    }

    // Never show "Protected" when a required detector has failed or stopped.
    final wasArmed = _state == ProtectionState.armed;
    ++_lifecycleGeneration;
    final failedSessionId = _activeSessionId;
    _cancelCountdownTimer();
    _ensureRegularLocationSchedule(immediateCapture: false);
    _clearMovementConfirmationStage();
    _clearInputInteractionGrace();
    _activeSessionId = null;
    _isCalibrating = false;
    _remainingCountdownSeconds = 0;
    _state = ProtectionState.unavailable;
    _statusMessage = 'Monitoring stopped — ${event.summary}';
    _warningMessage =
        'Motion detection stopped (${event.summary}). This device is NOT protected.';
    unawaited(
      _systemLifecycleAdapter.syncProtectionState(
        armed: false,
        monitorInputInteraction: false,
      ),
    );

    final currentCap = _capabilities[event.detectorType];
    if (currentCap != null) {
      _capabilities[event.detectorType] = currentCap.copyWith(
        status: CapabilityStatus.unsupported,
        summary: event.summary,
        statusDetail: event.errorCode,
      );
    }

    unawaited(_stopSessionDetectorsSafely(failedSessionId));

    final lastKnown =
        (_settings.shareLocationOnAlarm && _hostLatestLocation != null)
        ? _hostLatestLocation!.copyWith(isLastKnown: true)
        : null;
    final failureIncident = IncidentRecord(
      id: 'fail_inc_${++_incidentSequence}_${event.timestamp.millisecondsSinceEpoch}',
      sessionId: event.sessionId,
      kind: IncidentKind.detectorFailureDuringMonitoring,
      detectorType: event.detectorType,
      triggeredAt: event.timestamp,
      resolvedAt: event.timestamp,
      deviceName: effectiveDeviceName,
      triggerSummary: 'Monitoring stopped: ${event.summary}',
      resolutionSummary: 'Protection paused due to sensor issue',
      location: lastKnown,
      alarmTimeLocation: lastKnown,
      locationStatus: lastKnown != null
          ? IncidentLocationStatus.attached
          : IncidentLocationStatus.notRequested,
      locationTrackingState: lastKnown != null ? 'last_known' : 'idle',
    );
    _incidents = <IncidentRecord>[failureIncident, ..._incidents];
    unawaited(() async {
      await _saveIncidentSafely(failureIncident);
      if (wasArmed && failedSessionId != null) {
        try {
          final res = await _notificationAdapter.sendIncidentAlert(
            failureIncident,
          );
          final updated =
              (_findIncidentById(failureIncident.id) ?? failureIncident)
                  .copyWith(
                    remoteNotificationAttempted: true,
                    remoteNotificationStatus: res.message,
                  );
          _replaceIncidentInMemory(updated);
          await _updateIncidentSafely(updated);
          notifyListeners();
        } catch (_) {}
      }
    }());
    notifyListeners();
  }

  void _replaceIncidentInMemory(IncidentRecord updated) {
    _incidents = _incidents
        .map((item) => item.id == updated.id ? updated : item)
        .toList(growable: false);
  }

  Future<void> _trackIncidentStorageWrite(Future<void> Function() writeOp) {
    late final Future<void> tracked;
    tracked = () async {
      try {
        await writeOp();
      } finally {
        _inFlightIncidentWrites.remove(tracked);
      }
    }();
    _inFlightIncidentWrites.add(tracked);
    return tracked;
  }

  Future<void> _drainAndClearIncidentStorage() async {
    if (_inFlightIncidentWrites.isNotEmpty) {
      await Future.wait(
        _inFlightIncidentWrites.map((f) => f.catchError((_) {})),
      );
    }
    await _incidentStorage.clearIncidents();
  }

  Future<void> _saveIncidentSafely(
    IncidentRecord incident, {
    bool rethrowOnError = false,
  }) async {
    final expectedGeneration = _incidentHistoryGeneration;
    if (_isDisposed ||
        expectedGeneration != _incidentHistoryGeneration ||
        _findIncidentById(incident.id) == null) {
      return;
    }
    try {
      await _trackIncidentStorageWrite(() async {
        if (_isDisposed ||
            expectedGeneration != _incidentHistoryGeneration ||
            _findIncidentById(incident.id) == null) {
          return;
        }
        await _incidentStorage.saveIncident(incident);
      });
    } catch (_) {
      if (rethrowOnError) {
        rethrow;
      }
    }
  }

  Future<void> _updateIncidentSafely(
    IncidentRecord incident, {
    bool rethrowOnError = false,
  }) async {
    final expectedGeneration = _incidentHistoryGeneration;
    if (_isDisposed ||
        expectedGeneration != _incidentHistoryGeneration ||
        _findIncidentById(incident.id) == null) {
      return;
    }
    try {
      await _trackIncidentStorageWrite(() async {
        if (_isDisposed ||
            expectedGeneration != _incidentHistoryGeneration ||
            _findIncidentById(incident.id) == null) {
          return;
        }
        await _incidentStorage.updateIncident(incident);
      });
    } catch (_) {
      if (rethrowOnError) {
        rethrow;
      }
    }
  }

  Future<void> _persistSettingsSafely() async {
    try {
      await _settingsStorage.saveSettings(_settings);
    } catch (_) {
      // Non-fatal
    }
  }

  String _nextSessionId() {
    _sessionSequence += 1;
    return 'session_${_sessionSequence}_${_clock().millisecondsSinceEpoch}';
  }

  void _cancelCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  /// Opens the onboarding screen in read-only preview mode (development builds
  /// only), keeping all saved PIN, pairing, settings, and Activity data intact.
  void startOnboardingPreview() {
    if (!enableDeveloperControls) {
      return;
    }
    _isPreviewingOnboarding = true;
    notifyListeners();
  }

  /// Exits onboarding preview mode without modifying saved settings or PIN.
  void exitOnboardingPreview() {
    if (!_isPreviewingOnboarding) {
      return;
    }
    _isPreviewingOnboarding = false;
    notifyListeners();
  }

  /// Development-only demo reset scoped strictly to this installation:
  /// 1. Stops active monitoring detectors, countdown/test timers, and siren audio
  /// 2. Revokes this installation's pairing session & push bonds on the relay
  /// 3. Deletes this installation's PIN from secure storage
  /// 4. Clears Activity incidents, settings, and onboarding state, returning
  ///    immediately to the welcome screen.
  Future<void> resetDemoAndRestartOnboarding() async {
    if (!enableDeveloperControls) {
      throw StateError(
        'Reset demo and restart onboarding is only available in development builds.',
      );
    }

    ++_alarmGeneration;
    ++_lifecycleGeneration;
    ++_incidentHistoryGeneration;
    _incidents = const <IncidentRecord>[];
    _activeIncident = null;
    _cancelCountdownTimer();
    _stopRegularLocationSchedule();
    _stopPostAlarmLocationTracking(markIncidentStopped: false);
    _clearMovementConfirmationStage();
    _clearInputInteractionGrace();
    await stopGuidedProtectionTest();
    _testAlarmTimer?.cancel();
    _testAlarmTimer = null;
    _isTestAlarmRunning = false;
    _activeTestIncident = null;
    _alarmAudioRequested = false;
    _alarmInterruptedByLifecycle = false;
    _isRestartingAlarmAudio = false;
    _isPreparingToArm = false;
    _isCalibrating = false;
    _remainingCountdownSeconds = 0;

    final previousSessionId = _activeSessionId;
    _activeSessionId = null;
    unawaited(
      _systemLifecycleAdapter.syncProtectionState(
        armed: false,
        monitorInputInteraction: false,
      ),
    );

    await _audioAdapter.stopAlarm();
    await _stopSessionDetectorsSafely(previousSessionId);

    final mutableNotifications = _notificationAdapter;
    if (mutableNotifications is MutableRemoteNotificationAdapter) {
      await mutableNotifications.resetInstallationPairingAndPush(
        defaultRelayUrl: mutableNotifications.relayEndpointUrl,
      );
    }

    await _pinService.clearPinForInstallationReset();
    _hasPinConfigured = false;

    await _drainAndClearIncidentStorage();
    _incidents = const <IncidentRecord>[];
    _activeIncident = null;
    _hostLatestLocation = null;
    _hostLocationStatus = IncidentLocationStatus.notRequested;
    _companionLatestLocation = null;
    _companionLocationStatus = IncidentLocationStatus.notRequested;
    _authorizedDeviceLocations = const <AuthorizedDeviceLocationSummary>[];
    _selectedActivityIncidentId = null;
    _latestUnacknowledgedCompanionAlert = null;
    _lastTelemetryEvent = null;
    _lastHostDisplayName = null;
    _warningMessage = null;
    _pairedDevices = const <PairedDeviceSummary>[];
    _isPreviewingOnboarding = false;

    final resetDetector = _detectors.containsKey(_settings.selectedDetector)
        ? _settings.selectedDetector
        : (_detectors.isNotEmpty
              ? _detectors.keys.first
              : DetectorType.macosCameraSceneMotion);

    _settings = ProtectionSettings(
      selectedDetector: resetDetector,
      onboardingCompleted: false,
      permanentRelayEndpointUrl: _settings.permanentRelayEndpointUrl,
    );
    await _persistSettingsSafely();

    _state = ProtectionState.disarmed;
    await refreshCapabilities();
    await refreshNotificationStatus();
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_isDisposed) {
      return;
    }
    super.notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    ++_alarmGeneration;
    ++_lifecycleGeneration;
    ++_incidentHistoryGeneration;
    _incidents = const <IncidentRecord>[];
    _activeIncident = null;
    _cancelCountdownTimer();
    _stopRegularLocationSchedule();
    _stopPostAlarmLocationTracking(markIncidentStopped: false);
    _clearMovementConfirmationStage();
    _clearInputInteractionGrace();
    unawaited(stopGuidedProtectionTest());
    _testAlarmTimer?.cancel();
    unawaited(_systemLifecycleSubscription?.cancel());
    _systemLifecycleAdapter.dispose();
    unawaited(_companionAlertsSubscription?.cancel());
    unawaited(_notificationTapsSubscription?.cancel());
    if (!_openActivityIncidentController.isClosed) {
      unawaited(_openActivityIncidentController.close());
    }
    _localNotificationAdapter.dispose();
    final mutableNotifications = _notificationAdapter;
    if (mutableNotifications is MutableRemoteNotificationAdapter) {
      mutableNotifications.dispose();
    }
    for (final sub in _subscriptions.values) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }
}
