import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../services/local_notification_service.dart';
import '../../services/location_service.dart';
import '../../services/pin_security_service.dart';
import '../../services/relay_config.dart';
import '../../services/remote_notification_service.dart';
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
    required AudioAlarmAdapter audioAdapter,
    required PinSecurityService pinService,
    required IncidentStorageAdapter incidentStorage,
    required SettingsStorageAdapter settingsStorage,
    required RemoteNotificationAdapter notificationAdapter,
    LocationServiceAdapter locationAdapter =
        const UnconfiguredLocationService(),
    LocalNotificationAdapter? localNotificationAdapter,
    DateTime Function()? clock,
    bool enableDeveloperControlsForTest = false,
  }) : _detectors = Map<DetectorType, MotionDetectorAdapter>.unmodifiable(
         detectors,
       ),
       _audioAdapter = audioAdapter,
       _pinService = pinService,
       _incidentStorage = incidentStorage,
       _settingsStorage = settingsStorage,
       _notificationAdapter = notificationAdapter,
       _locationAdapter = locationAdapter,
       _localNotificationAdapter =
           localNotificationAdapter ?? NoOpLocalNotificationService(),
       _clock = clock ?? DateTime.now,
       _enableDeveloperControlsForTest = enableDeveloperControlsForTest;

  final Map<DetectorType, MotionDetectorAdapter> _detectors;
  final AudioAlarmAdapter _audioAdapter;
  final PinSecurityService _pinService;
  final IncidentStorageAdapter _incidentStorage;
  final SettingsStorageAdapter _settingsStorage;
  final RemoteNotificationAdapter _notificationAdapter;
  final LocationServiceAdapter _locationAdapter;
  final LocalNotificationAdapter _localNotificationAdapter;
  final DateTime Function() _clock;
  final bool _enableDeveloperControlsForTest;

  final Map<DetectorType, StreamSubscription<DetectorEvent>> _subscriptions =
      <DetectorType, StreamSubscription<DetectorEvent>>{};
  final Map<DetectorType, DetectorCapability> _capabilities =
      <DetectorType, DetectorCapability>{};
  final Set<DetectorType> _activeAuxiliaryDetectors = <DetectorType>{};

  ProtectionState _state = ProtectionState.disarmed;
  ProtectionSettings _settings = const ProtectionSettings();
  bool _isInitialized = false;
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
  bool _isTestAlarmRunning = false;
  IncidentRecord? _activeTestIncident;

  DetectorEvent? _lastTelemetryEvent;
  IncidentRecord? _activeIncident;
  List<IncidentRecord> _incidents = const <IncidentRecord>[];

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

    final mutableNotifications = _notificationAdapter;
    if (mutableNotifications is MutableRemoteNotificationAdapter) {
      mutableNotifications.onStateChanged = () {
        unawaited(refreshNotificationStatus());
      };
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
                    : 'Alarm triggered — tap to view event',
                isTest: alert.isTest,
              ),
            );
          });
    }

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
  /// when an alarm triggers.
  Future<void> updateShareLocationOnAlarm(bool enabled) async {
    _settings = _settings.copyWith(shareLocationOnAlarm: enabled);
    await _persistSettingsSafely();
    notifyListeners();
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
    _statusMessage =
        'Monitoring with ${detector.detectorType.userFacingMethodName.toLowerCase()}. Enter your PIN to disarm.';
    _syncHostPresenceMetadata(immediateHeartbeatIfBackground: true);
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
      guidance =
          'No video arrived from the camera. Check any camera privacy cover and try again.';
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
    _activeSessionId = null;
    _isCalibrating = false;
    _remainingCountdownSeconds = 0;

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
        if (lifecycleState == AppLifecycleState.detached &&
            mutableNotifications is ConfigurableRemoteNotificationService &&
            mutableNotifications.enableBackgroundPolling) {
          await mutableNotifications.notifyHostOffline();
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
        final mutableNotifications = _notificationAdapter;
        if (mutableNotifications is MutableRemoteNotificationAdapter) {
          mutableNotifications.setForegroundActive(true);
        }
        unawaited(refreshPermissionStatuses());
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
        _warningMessage =
            'System suspended audio while in the background. Enter your PIN to disarm.';
      }
      notifyListeners();
      return;
    }

    if (_state == ProtectionState.armed || _state == ProtectionState.arming) {
      ++_lifecycleGeneration;
      final sessionId = _activeSessionId;
      _cancelCountdownTimer();
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
        _warningMessage =
            'Alarm remains active, though your device suspended siren audio. Tap Resume Siren Audio or enter your PIN to disarm.';
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
    _warningMessage = null;
    _statusMessage =
        'Monitoring resumed with ${detector.detectorType.userFacingMethodName.toLowerCase()}.';
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
    _testAlarmTimer?.cancel();
    _testAlarmTimer = null;
    _isTestAlarmRunning = false;
    _activeSessionId = null;
    _isCalibrating = false;
    _remainingCountdownSeconds = 0;
    _warningMessage = null;

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
      );
      _activeIncident = null;
      _replaceIncidentInMemory(resolved);
      try {
        await _incidentStorage.updateIncident(resolved);
      } catch (_) {
        _warningMessage =
            'Disarmed, though local activity history could not be saved.';
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

    try {
      await _incidentStorage.saveIncident(testIncident);
    } catch (_) {
      // Non-fatal
    }

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
    _incidents = const <IncidentRecord>[];
    try {
      await _incidentStorage.clearIncidents();
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
    } catch (_) {
      // Non-fatal
    }
    notifyListeners();
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
    if (trimmed.isNotEmpty) {
      if (RelayConfig.isEphemeralTunnelUrl(trimmed)) {
        _warningMessage =
            'Temporary tunnel addresses (*.trycloudflare.com, *.lhr.life, *.ngrok) expire when restarted. Enter a permanent HTTPS domain.';
        notifyListeners();
        return false;
      }
      if (!RelayConfig.isPermanentHttpsUrl(trimmed)) {
        _warningMessage =
            'Enter a valid https:// address (for example https://watsafe-companion.onrender.com).';
        notifyListeners();
        return false;
      }
    }

    try {
      await RelayConfig.savePermanentRelayUrl(trimmed.isEmpty ? null : trimmed);
    } catch (_) {
      _warningMessage = 'Could not save permanent companion address.';
      notifyListeners();
      return false;
    }

    final nextEndpoint = trimmed.isEmpty
        ? RelayConfig.resolveDefaultRelayUrl()
        : trimmed;
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

      if (command == PairedDeviceCommandType.simulateCompanionMotionTrigger &&
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

  void _handleDetectorEvent(DetectorEvent event) {
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
        notifyListeners();
        return;

      case DetectorEventType.poorInputWarning:
        _lastTelemetryEvent = event;
        _warningMessage = event.summary;
        final currentCap = _capabilities[event.detectorType];
        if (currentCap != null) {
          _capabilities[event.detectorType] = currentCap.copyWith(
            status: CapabilityStatus.degraded,
            statusDetail: event.summary,
          );
        }
        notifyListeners();
        return;

      case DetectorEventType.inputRecovered:
        _lastTelemetryEvent = event;
        _warningMessage = null;
        final currentCap = _capabilities[event.detectorType];
        if (currentCap != null) {
          _capabilities[event.detectorType] = currentCap.copyWith(
            status: CapabilityStatus.ready,
            statusDetail: event.summary,
          );
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

    final alarmGeneration = ++_alarmGeneration;
    _alarmAudioRequested = true;
    _alarmInterruptedByLifecycle = false;
    _state = ProtectionState.alarming;
    final initialLocStatus = _determineInitialLocationStatus();
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
    );
    _activeIncident = incident;
    _incidents = <IncidentRecord>[incident, ..._incidents];
    _statusMessage = 'Alarm triggered — ${event.summary}';
    _syncHostPresenceMetadata(immediateHeartbeatIfBackground: true);
    notifyListeners();

    // 1. Start local siren and send initial phone notification immediately (never delayed by location!).
    unawaited(_triggerAudioPersistAndNotify(incident, alarmGeneration));

    // 2. Capture protected device location asynchronously in parallel and attach when ready.
    if (_settings.shareLocationOnAlarm) {
      unawaited(_captureAndAttachIncidentLocation(incident.id));
    }
  }

  Future<void> _captureAndAttachIncidentLocation(String incidentId) async {
    if (!_locationAdapter.isSupported) {
      await _applyLocationResultToIncident(
        incidentId: incidentId,
        location: null,
        status: IncidentLocationStatus.unavailable,
      );
      return;
    }

    ({DeviceLocationSnapshot? location, IncidentLocationStatus status}) capture;
    try {
      capture = await _locationAdapter.captureCurrentLocation();
    } catch (_) {
      capture = (location: null, status: IncidentLocationStatus.unavailable);
    }

    await _applyLocationResultToIncident(
      incidentId: incidentId,
      location: capture.location,
      status: capture.status,
    );
  }

  Future<void> _applyLocationResultToIncident({
    required String incidentId,
    required DeviceLocationSnapshot? location,
    required IncidentLocationStatus status,
  }) async {
    final existing = _findIncidentById(incidentId);
    if (existing == null) {
      return;
    }
    final updated = existing.copyWith(
      location: location ?? existing.location,
      locationStatus: status,
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
        );
      } catch (_) {
        // Non-fatal; local record still retains location status.
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

    var latestIncident = _findIncidentById(incident.id) ?? incident;
    try {
      await _incidentStorage.saveIncident(latestIncident);
    } catch (_) {
      if (alarmGeneration == _alarmGeneration) {
        warnings.add('Local incident save failed.');
      }
    }

    try {
      latestIncident = _findIncidentById(incident.id) ?? latestIncident;
      final dispatchResult = await _notificationAdapter.sendIncidentAlert(
        latestIncident,
      );
      latestIncident = (_findIncidentById(incident.id) ?? latestIncident)
          .copyWith(
            remoteNotificationAttempted: true,
            remoteNotificationStatus: dispatchResult.message,
          );
      if (_activeIncident?.id == latestIncident.id) {
        _activeIncident = latestIncident;
      }
      _replaceIncidentInMemory(latestIncident);
      await _incidentStorage.updateIncident(latestIncident);

      // If async location finished right before or during initial report, push
      // a location update too so the relay event definitely has it attached.
      final postDispatch = _findIncidentById(incident.id);
      final mutable = _notificationAdapter;
      if (dispatchResult.delivered &&
          postDispatch != null &&
          postDispatch.location != null &&
          mutable is MutableRemoteNotificationAdapter) {
        unawaited(
          mutable.updateIncidentLocation(
            incidentId: postDispatch.id,
            location: postDispatch.location,
            locationStatus: postDispatch.locationStatus,
          ),
        );
      }
    } catch (_) {
      if (alarmGeneration == _alarmGeneration) {
        warnings.add('Remote alert dispatch failed.');
      }
      latestIncident = (_findIncidentById(incident.id) ?? latestIncident)
          .copyWith(
            remoteNotificationAttempted: true,
            remoteNotificationStatus: 'Phone alert failed',
          );
      if (_activeIncident?.id == latestIncident.id) {
        _activeIncident = latestIncident;
      }
      _replaceIncidentInMemory(latestIncident);
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

    // Never show "Protected" when a required detector has failed or stopped.
    ++_lifecycleGeneration;
    final failedSessionId = _activeSessionId;
    _cancelCountdownTimer();
    _activeSessionId = null;
    _isCalibrating = false;
    _remainingCountdownSeconds = 0;
    _state = ProtectionState.unavailable;
    _statusMessage = 'Monitoring stopped — ${event.summary}';
    _warningMessage =
        'Motion detection stopped (${event.summary}). This device is NOT protected.';

    final currentCap = _capabilities[event.detectorType];
    if (currentCap != null) {
      _capabilities[event.detectorType] = currentCap.copyWith(
        status: CapabilityStatus.unsupported,
        summary: event.summary,
        statusDetail: event.errorCode,
      );
    }

    unawaited(_stopSessionDetectorsSafely(failedSessionId));

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
    );
    _incidents = <IncidentRecord>[failureIncident, ..._incidents];
    unawaited(_saveIncidentSafely(failureIncident));
    notifyListeners();
  }

  void _replaceIncidentInMemory(IncidentRecord updated) {
    _incidents = _incidents
        .map((item) => item.id == updated.id ? updated : item)
        .toList(growable: false);
  }

  Future<void> _saveIncidentSafely(IncidentRecord incident) async {
    try {
      await _incidentStorage.saveIncident(incident);
    } catch (_) {
      // Non-fatal
    }
  }

  Future<void> _updateIncidentSafely(IncidentRecord incident) async {
    try {
      await _incidentStorage.updateIncident(incident);
    } catch (_) {
      // Non-fatal
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
    _cancelCountdownTimer();
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

    await _incidentStorage.clearIncidents();
    _incidents = const <IncidentRecord>[];
    _activeIncident = null;
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
    );
    await _persistSettingsSafely();

    _state = ProtectionState.disarmed;
    await refreshCapabilities();
    await refreshNotificationStatus();
    notifyListeners();
  }

  @override
  void dispose() {
    ++_alarmGeneration;
    ++_lifecycleGeneration;
    _cancelCountdownTimer();
    _testAlarmTimer?.cancel();
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
