import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../services/pin_security_service.dart';
import '../contracts/platform_contracts.dart';
import '../models/detector_models.dart';
import '../models/incident_models.dart';
import '../models/settings_models.dart';
import 'alarm_state.dart';

/// Central protection state machine coordinating detector readiness, arming
/// countdown, session-scoped event filtering, lifecycle pause/resume, local
/// siren playback, PIN verification, incident persistence, and remote alerts.
class AlarmController extends ChangeNotifier {
  AlarmController({
    required Map<DetectorType, MotionDetectorAdapter> detectors,
    required AudioAlarmAdapter audioAdapter,
    required PinSecurityService pinService,
    required IncidentStorageAdapter incidentStorage,
    required SettingsStorageAdapter settingsStorage,
    required RemoteNotificationAdapter notificationAdapter,
    DateTime Function()? clock,
  }) : _detectors = Map<DetectorType, MotionDetectorAdapter>.unmodifiable(
         detectors,
       ),
       _audioAdapter = audioAdapter,
       _pinService = pinService,
       _incidentStorage = incidentStorage,
       _settingsStorage = settingsStorage,
       _notificationAdapter = notificationAdapter,
       _clock = clock ?? DateTime.now;

  final Map<DetectorType, MotionDetectorAdapter> _detectors;
  final AudioAlarmAdapter _audioAdapter;
  final PinSecurityService _pinService;
  final IncidentStorageAdapter _incidentStorage;
  final SettingsStorageAdapter _settingsStorage;
  final RemoteNotificationAdapter _notificationAdapter;
  final DateTime Function() _clock;

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

  String _statusMessage = 'Initializing WATSafe protection controller...';
  String? _warningMessage;

  NotificationServiceStatus
  _notificationStatus = const NotificationServiceStatus(
    capabilityStatus: CapabilityStatus.notConfigured,
    summary: 'Not configured',
    detail:
        'Remote pairing and push notifications are not configured in this local milestone.',
  );
  List<PairedDeviceSummary> _pairedDevices = const <PairedDeviceSummary>[];
  StreamSubscription<CompanionAlertEvent>? _companionAlertsSubscription;
  CompanionAlertEvent? _latestUnacknowledgedCompanionAlert;

  // Public getters
  ProtectionState get state => _state;
  ProtectionSettings get settings => _settings;
  bool get isInitialized => _isInitialized;
  bool get hasPinConfigured => _hasPinConfigured;
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

  DetectorType get selectedDetectorType => _settings.selectedDetector;
  MotionDetectorAdapter? get selectedDetector =>
      _detectors[_settings.selectedDetector];

  DetectorCapability? get selectedCapability =>
      _capabilities[_settings.selectedDetector];

  Map<DetectorType, DetectorCapability> get capabilities =>
      Map<DetectorType, DetectorCapability>.unmodifiable(_capabilities);

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

  void dismissCompanionAlertBanner() {
    if (_latestUnacknowledgedCompanionAlert != null) {
      _latestUnacknowledgedCompanionAlert = null;
      notifyListeners();
    }
  }

  /// Initializes settings, PIN state, incident history, detector capabilities,
  /// and event stream subscriptions.
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

    try {
      _notificationStatus = await _notificationAdapter.getStatus();
      _pairedDevices = await _notificationAdapter.listPairedDevices();
    } catch (_) {
      // Keep default unconfigured status
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
          summary: 'Failed to inspect detector capability.',
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
            currentCap?.summary ?? 'Selected detector is unavailable.';
      } else {
        _state = ProtectionState.disarmed;
        _statusMessage = 'Ready to arm (${currentCap.type.displayName}).';
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
      _warningMessage = 'Disarm protection before switching detectors.';
      notifyListeners();
      return false;
    }
    if (!_detectors.containsKey(type)) {
      _warningMessage = 'Selected detector is not registered on this platform.';
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
  }) async {
    final result = await _pinService.setupInitialPin(
      pin: pin,
      confirmPin: confirmPin,
    );
    if (result.isValid) {
      _hasPinConfigured = true;
      _settings = _settings.copyWith(onboardingCompleted: true);
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
            'Set up a 6-digit (or longer) security PIN before arming protection.';
        notifyListeners();
        return false;
      }

      final detector = selectedDetector;
      if (detector == null) {
        _state = ProtectionState.unavailable;
        _statusMessage = 'No detector adapter registered for selection.';
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
      } catch (error) {
        audioPrepWarning = 'Could not prepare alarm audio output: $error';
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
          'Arming in $_remainingCountdownSeconds seconds — step back and stabilize device.';
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
          'Arming in $_remainingCountdownSeconds second${_remainingCountdownSeconds == 1 ? '' : 's'} — stabilize device.';
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
        reason: 'Selected detector became unavailable before calibration.',
      );
      return;
    }

    _isCalibrating = true;
    _statusMessage =
        'Initializing and calibrating ${detector.detectorType.displayName}...';
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
        message: 'Detector initialization failed: $error',
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
    final auxNote = _activeAuxiliaryDetectors.isEmpty
        ? ''
        : ' + ${_activeAuxiliaryDetectors.map((t) => t.displayName).join(", ")}';
    _statusMessage =
        'Protected — ${detector.detectorType.displayName}$auxNote actively monitoring.';
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
      guidance =
          'Enable camera/sensor access in your OS or browser privacy settings, then click Retry Detector Check.';
    } else if (code == 'CAMERA_BUSY' || code == 'SOURCE_ACTIVATE_FAILED') {
      guidance =
          'Another application may be holding exclusive access to the camera. Close video/meeting apps and click Retry Detector Check.';
    } else if (code == 'NO_CAMERA_HARDWARE') {
      guidance =
          'Connect a compatible webcam and click Retry Detector Check, or use Test Alarm to verify local siren audio.';
    } else if (code == 'FRAME_TIMEOUT') {
      guidance =
          'No video frames arrived from the camera. Check any hardware privacy switch or USB connection, then click Retry Detector Check.';
    } else {
      guidance = '${result.message} Click Retry Detector Check to try again.';
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
    _statusMessage = 'Failed to arm: $reason';
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
      _statusMessage = 'Arming cancelled. Protection is disarmed.';
    } else {
      _state = ProtectionState.unavailable;
      _statusMessage =
          cap?.summary ?? 'Arming cancelled. Detector unavailable.';
    }
    notifyListeners();
  }

  /// Handles Flutter application lifecycle transitions (`hidden`, `paused`,
  /// `resumed`, `detached`) across desktop, mobile, and browser targets.
  ///
  /// - Distinguishes an active `alarming` state (preserved across minimize and
  ///   resume; requires PIN disarm) from pre-trigger `arming`/`armed`
  ///   monitoring (paused when background monitoring is unsupported).
  /// - Coalesces repeated `resumed` events so duplicate camera streams,
  ///   detectors, timers, or sirens are never created.
  Future<void> handleAppLifecycleState(AppLifecycleState lifecycleState) async {
    switch (lifecycleState) {
      case AppLifecycleState.inactive:
        // Transient window focus changes on desktop/mobile do not suspend
        // visible camera or foreground sensor monitoring.
        return;

      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        final mutableNotifications = _notificationAdapter;
        if (mutableNotifications is MutableRemoteNotificationAdapter) {
          mutableNotifications.setForegroundActive(false);
        }
        final detector = selectedDetector;
        if (_state != ProtectionState.alarming &&
            detector != null &&
            detector.supportsBackgroundMonitoring &&
            lifecycleState != AppLifecycleState.detached) {
          // Active Android Foreground Service continues monitoring while backgrounded.
          return;
        }
        final label = lifecycleState == AppLifecycleState.hidden
            ? 'Application window minimized or hidden'
            : 'Application suspended to background';
        await _pauseMonitoringForLifecycle(label);
        return;

      case AppLifecycleState.resumed:
        final mutableNotifications = _notificationAdapter;
        if (mutableNotifications is MutableRemoteNotificationAdapter) {
          mutableNotifications.setForegroundActive(true);
        }
        await _handleAppForegroundResumed(
          'Application returned to active foreground',
        );
        return;
    }
  }

  Future<void> _pauseMonitoringForLifecycle(String reason) async {
    if (_state == ProtectionState.alarming) {
      _alarmInterruptedByLifecycle = true;
      final sessionId = _activeSessionId;
      // Release camera/sensor hardware cleanly while preserving the active alarm.
      await _stopSessionDetectorsSafely(sessionId);
      if (_audioAdapter.isPlaying) {
        _warningMessage =
            'System lifecycle change during active alarm ($reason). '
            'Alarm state is preserved — enter your PIN to disarm.';
      } else {
        _warningMessage =
            'OS or browser suspended audio/monitoring during active alarm ($reason). '
            'Alarm remains active — resume siren or enter your PIN to disarm.';
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
      _statusMessage = 'Monitoring paused — $reason';
      _warningMessage =
          'Monitoring is paused ($reason). Device is not actively protected while paused.';
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
        _warningMessage =
            'Active alarm preserved across minimize/resume ($reason). Enter your PIN to disarm.';
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
      _warningMessage =
          'Active alarm restored after suspension. Enter your PIN to disarm.';
    } catch (_) {
      if (gen == _alarmGeneration && _state == ProtectionState.alarming) {
        _warningMessage =
            'Active alarm preserved, but the OS/browser suspended siren audio. '
            'Tap "Resume Siren Audio" or enter your PIN to disarm.';
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
    } catch (error) {
      if (gen == _alarmGeneration && _state == ProtectionState.alarming) {
        _warningMessage = 'Could not resume siren audio ($error).';
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
    String reason = 'Application resumed',
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
      _statusMessage = 'Cannot resume monitoring — no active detector session.';
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
    } catch (error) {
      capability = DetectorCapability(
        type: detector.detectorType,
        status: CapabilityStatus.unsupported,
        permissionStatus: PermissionStatus.notApplicable,
        summary: 'Failed to inspect detector on resume: $error',
      );
      _capabilities[detector.detectorType] = capability;
    }

    if (resumeGen != _lifecycleGeneration ||
        _activeSessionId != sessionId ||
        _state != ProtectionState.paused) {
      return false;
    }

    if (!capability.canArm) {
      _statusMessage = 'Monitoring remains paused — ${capability.summary}';
      _warningMessage =
          capability.guidance ??
          capability.statusDetail ??
          '${capability.summary} Tap "Resume Monitoring" after resolving or disarm with your PIN.';
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
        message: 'Detector failed to restart on resume: $error',
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
          'Could not automatically restore ${detector.detectorType.displayName} (${startResult.message}). '
          'Tap "Resume Monitoring" to retry or disarm with your PIN.';
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
        'Protected — Monitoring resumed (${detector.detectorType.displayName}).';
    notifyListeners();
    return true;
  }

  /// Verifies [pin] and, if valid, immediately invalidates any active or
  /// in-flight alarm playback, stops the siren and detector monitoring,
  /// resolves the active incident, and transitions to `disarmed`.
  ///
  /// Concurrent or repeated submissions are serialized so duplicate audio
  /// operations never occur. If [pin] is wrong or locked out, protection and
  /// any active alarm remain sounding without interruption.
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
    _statusMessage = 'Disarmed with PIN.';

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
        resolutionSummary: 'Test alarm stopped via PIN disarm',
      );
      _activeTestIncident = null;
      _replaceIncidentInMemory(resolvedTest);
      unawaited(_updateIncidentSafely(resolvedTest));
    }

    final currentIncident = _activeIncident;
    if (currentIncident != null) {
      final resolved = currentIncident.copyWith(
        resolvedAt: _clock(),
        resolutionSummary: 'Disarmed with verified PIN',
      );
      _activeIncident = null;
      _replaceIncidentInMemory(resolved);
      try {
        await _incidentStorage.updateIncident(resolved);
      } catch (_) {
        _warningMessage =
            'Disarmed, but updating local incident history failed.';
      }
    }

    await refreshCapabilities();
    if (_state != ProtectionState.unavailable) {
      _state = ProtectionState.disarmed;
      _statusMessage = 'Disarmed with PIN.';
    }
    notifyListeners();
    return result;
  }

  /// Starts a clearly labeled local Test Alarm that lasts at most 5 seconds
  /// and can be stopped immediately without arming the detector.
  Future<bool> startTestAlarm() async {
    if (_state == ProtectionState.arming ||
        _state == ProtectionState.armed ||
        _state == ProtectionState.alarming ||
        _state == ProtectionState.paused) {
      _warningMessage =
          'Test Alarm is only available while protection is disarmed.';
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
      triggerSummary: 'Manual Test Alarm (Simulated — max 5s)',
      resolutionSummary: 'Test alarm running',
      remoteNotificationAttempted: false,
      remoteNotificationStatus: 'Skipped for local test alarm',
    );
    _activeTestIncident = testIncident;
    _incidents = <IncidentRecord>[testIncident, ..._incidents];
    _statusMessage =
        'Test Alarm active (automatically stops within 5 seconds).';
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
    } catch (error) {
      if (testGeneration == _alarmGeneration) {
        _warningMessage = 'Audio playback error during Test Alarm: $error';
      }
    }

    try {
      await _incidentStorage.saveIncident(testIncident);
    } catch (error) {
      if (testGeneration == _alarmGeneration) {
        _warningMessage =
            'Test alarm started, but incident save failed: $error';
      }
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

  /// Stops an active Test Alarm immediately.
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
            ? 'Test alarm completed (5s limit)'
            : 'Test alarm stopped manually',
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
        ? 'Test alarm finished. Ready to arm.'
        : (cap?.summary ?? 'Test alarm finished.');
    notifyListeners();
  }

  /// Clears stored local incident history when not actively alarming.
  Future<void> clearIncidentHistory() async {
    if (_state == ProtectionState.alarming) {
      return;
    }
    _incidents = const <IncidentRecord>[];
    try {
      await _incidentStorage.clearIncidents();
    } catch (error) {
      _warningMessage = 'Could not clear incident storage: $error';
    }
    notifyListeners();
  }

  /// Refreshes remote notification service status and paired device list.
  Future<void> refreshNotificationStatus() async {
    try {
      _notificationStatus = await _notificationAdapter.getStatus();
      _pairedDevices = await _notificationAdapter.listPairedDevices();
    } catch (error) {
      _warningMessage = 'Could not refresh remote notification status: $error';
    }
    notifyListeners();
  }

  /// Configures the optional backend relay endpoint URL when supported by the
  /// active [RemoteNotificationAdapter].
  Future<bool> configureRelayEndpoint(String? endpointUrl) async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      return false;
    }
    try {
      await adapter.configureRelayEndpoint(endpointUrl);
      await refreshNotificationStatus();
      return true;
    } catch (error) {
      _warningMessage = 'Failed to update relay endpoint: $error';
      notifyListeners();
      return false;
    }
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
    } catch (error) {
      _warningMessage = 'Failed to pair companion device: $error';
      notifyListeners();
      return null;
    }
  }

  /// Removes a paired companion device by [deviceId].
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
    } catch (error) {
      _warningMessage = 'Failed to unpair companion device: $error';
      notifyListeners();
      return false;
    }
  }

  /// Generates a short-lived single-use pairing code and QR payload on the
  /// configured relay so a companion phone can pair with this laptop session.
  Future<PairingCodeInvitation> initiateHostPairing({
    String? hostDisplayName,
  }) async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      throw StateError('Pairing is not enabled on this notification adapter.');
    }
    final invite = await adapter.initiateHostPairing(
      hostDisplayName: hostDisplayName,
    );
    await refreshNotificationStatus();
    return invite;
  }

  /// Queries the relay for companion devices currently paired to this laptop
  /// session and updates [pairedDevices], [notificationStatus], and detector
  /// capabilities (such as Paired Android Companion Sensor Bridging).
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
  /// pairing code or `watsafe://pair?...` QR payload.
  Future<CompanionSessionState> pairAsCompanionPhone({
    required String pairingCodeOrPayload,
    required String displayName,
    required String platform,
    String? endpointUrlOverride,
  }) async {
    final adapter = _notificationAdapter;
    if (adapter is! MutableRemoteNotificationAdapter) {
      throw StateError('Companion pairing is not supported by this adapter.');
    }
    final session = await adapter.pairAsCompanionPhone(
      pairingCodeOrPayload: pairingCodeOrPayload,
      displayName: displayName,
      platform: platform,
      endpointUrlOverride: endpointUrlOverride,
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

  /// Dispatches an interactive command to a paired companion device (such as
  /// sending a test push alert, ringing/locating the phone, syncing protection
  /// state, toggling its remote foreground sensor link, or triggering a
  /// companion motion tamper alert).
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
          'detector': selectedDetectorType.displayName,
          'selectedDetector': selectedDetectorType.displayName,
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
    } catch (error) {
      _warningMessage = 'Paired device command failed: $error';
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

  void _handleMotionTrigger(DetectorEvent event) {
    _lastTelemetryEvent = event;

    // One active incident starts one alarm, even if many events arrive.
    if (_state == ProtectionState.alarming) {
      final currentIncident = _activeIncident;
      if (currentIncident != null && event.motionScore != null) {
        final previousPeak = currentIncident.peakMotionScore ?? 0.0;
        if (event.motionScore! > previousPeak) {
          final updated = currentIncident.copyWith(
            peakMotionScore: event.motionScore,
          );
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
    final incident = IncidentRecord(
      id: 'inc_${++_incidentSequence}_${event.timestamp.millisecondsSinceEpoch}',
      sessionId: event.sessionId,
      kind: IncidentKind.realDetectorTrigger,
      detectorType: event.detectorType,
      triggeredAt: event.timestamp,
      triggerSummary: event.summary,
      peakMotionScore: event.motionScore,
      resolutionSummary: 'Alarm active — awaiting PIN disarm',
    );
    _activeIncident = incident;
    _incidents = <IncidentRecord>[incident, ..._incidents];
    _statusMessage = 'ALARM TRIGGERED: ${event.summary}';
    notifyListeners();

    // Start local audio immediately without waiting for storage or network requests.
    unawaited(_triggerAudioPersistAndNotify(incident, alarmGeneration));
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
      } catch (error) {
        if (alarmGeneration == _alarmGeneration &&
            _state == ProtectionState.alarming) {
          warnings.add('Local audio failed to start ($error).');
        }
      }
    }

    var latestIncident = _findIncidentById(incident.id) ?? incident;
    try {
      await _incidentStorage.saveIncident(latestIncident);
    } catch (error) {
      if (alarmGeneration == _alarmGeneration) {
        warnings.add('Local incident save failed ($error).');
      }
    }

    try {
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
    } catch (error) {
      if (alarmGeneration == _alarmGeneration) {
        warnings.add('Remote alert dispatch failed ($error).');
      }
      latestIncident = (_findIncidentById(incident.id) ?? latestIncident)
          .copyWith(
            remoteNotificationAttempted: true,
            remoteNotificationStatus: 'Failed ($error)',
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
      _warningMessage =
          'Detector reported failure while alarm is active: ${event.summary}';
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
          'Auxiliary sensor (${event.detectorType.displayName}) stopped: ${event.summary}. '
          'Primary ${selectedDetectorType.displayName} monitoring remains active.';
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
        'Detector failed (${event.summary}). Device is NOT protected.';

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
      triggerSummary: 'Detector failure: ${event.summary}',
      resolutionSummary: 'Monitoring halted; state set to Unavailable',
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

  @override
  void dispose() {
    ++_alarmGeneration;
    ++_lifecycleGeneration;
    _cancelCountdownTimer();
    _testAlarmTimer?.cancel();
    unawaited(_companionAlertsSubscription?.cancel());
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
