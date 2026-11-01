import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/pin_security_service.dart';
import '../contracts/platform_contracts.dart';
import '../models/detector_models.dart';
import '../models/incident_models.dart';
import '../models/settings_models.dart';
import 'alarm_state.dart';

/// Central protection state machine coordinating detector readiness, arming
/// countdown, session-scoped event filtering, local siren playback, PIN
/// verification, incident persistence, and remote alert dispatch.
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

  ProtectionState _state = ProtectionState.disarmed;
  ProtectionSettings _settings = const ProtectionSettings();
  bool _isInitialized = false;
  bool _hasPinConfigured = false;
  String? _activeSessionId;
  int _sessionSequence = 0;
  int _incidentSequence = 0;
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

  /// Initializes settings, PIN state, incident history, detector capabilities,
  /// and event stream subscriptions.
  Future<void> initialize() async {
    try {
      _settings = await _settingsStorage.loadSettings();
    } catch (_) {
      _settings = const ProtectionSettings();
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

    for (final entry in _detectors.entries) {
      await _subscriptions[entry.key]?.cancel();
      _subscriptions[entry.key] = entry.value.events.listen(
        _handleDetectorEvent,
      );
    }

    await refreshCapabilities();
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
    return status;
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
    if (_state == ProtectionState.arming ||
        _state == ProtectionState.armed ||
        _state == ProtectionState.alarming) {
      return false;
    }

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

    _cancelCountdownTimer();
    final sessionId = _nextSessionId();
    _activeSessionId = sessionId;
    _remainingCountdownSeconds = _settings.armingCountdownSeconds;
    _isCalibrating = false;
    _lastTelemetryEvent = null;
    _warningMessage = capability.status == CapabilityStatus.degraded
        ? capability.statusDetail
        : null;
    _state = ProtectionState.arming;
    _statusMessage =
        'Arming in $_remainingCountdownSeconds seconds — step back and stabilize device.';
    notifyListeners();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(handleCountdownTickForSession(sessionId));
    });
    return true;
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

    DetectorStartResult startResult;
    try {
      startResult = await detector.startMonitoring(
        MonitorConfig(
          sessionId: sessionId,
          sensitivity: _settings.motionSensitivity,
        ),
      );
    } catch (error) {
      startResult = DetectorStartResult(
        started: false,
        status: CapabilityStatus.unsupported,
        message: 'Detector initialization failed: $error',
        errorCode: 'START_EXCEPTION',
      );
    }

    // Check if the session was cancelled or superseded while awaiting native startup.
    if (_activeSessionId != sessionId || _state != ProtectionState.arming) {
      unawaited(detector.stopMonitoring(sessionId: sessionId));
      return;
    }

    _isCalibrating = false;
    if (!startResult.started) {
      _failArmingSession(sessionId: sessionId, reason: startResult.message);
      return;
    }

    _state = ProtectionState.armed;
    _statusMessage =
        'Protected — ${detector.detectorType.displayName} is actively monitoring.';
    notifyListeners();
  }

  void _failArmingSession({required String sessionId, required String reason}) {
    if (_activeSessionId != sessionId) {
      return;
    }
    _cancelCountdownTimer();
    _activeSessionId = null;
    _isCalibrating = false;
    _remainingCountdownSeconds = 0;
    _state = ProtectionState.unavailable;
    _statusMessage = 'Failed to arm: $reason';
    _warningMessage = reason;
    notifyListeners();
  }

  /// Cancels an in-progress arming countdown or disarms with PIN.
  ///
  /// For security, once the countdown has started (`arming`), `armed`, `paused`,
  /// or `alarming`, disarming with `verifyAndDisarm` is preferred; however,
  /// `cancelArmingWithPin` or `verifyAndDisarm` handles PIN verification, while
  /// `cancelArming` allows aborting the countdown before the device enters `armed`.
  Future<void> cancelArming() async {
    if (_state != ProtectionState.arming) {
      return;
    }
    final oldSessionId = _activeSessionId;
    _cancelCountdownTimer();
    _activeSessionId = null;
    _isCalibrating = false;
    _remainingCountdownSeconds = 0;

    final detector = selectedDetector;
    if (detector != null && oldSessionId != null) {
      try {
        await detector.stopMonitoring(sessionId: oldSessionId);
      } catch (_) {
        // Ignore stop errors on cancel
      }
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

  /// Verifies [pin] and, if valid, stops any active siren, stops detector
  /// monitoring, resolves the active incident, and transitions to `disarmed`.
  ///
  /// If [pin] is wrong or locked out, protection and any active alarm remain
  /// active without interruption.
  Future<PinVerificationResult> verifyAndDisarm(String pin) async {
    final result = await _pinService.verifyPin(pin);
    if (!result.verified) {
      _warningMessage = result.message;
      notifyListeners();
      return result;
    }

    final endedSessionId = _activeSessionId;
    _cancelCountdownTimer();
    _activeSessionId = null;
    _isCalibrating = false;
    _remainingCountdownSeconds = 0;
    _warningMessage = null;

    // Stop local audio immediately
    try {
      await _audioAdapter.stopAlarm();
    } catch (_) {
      // Continue disarming even if audio adapter reports an error
    }

    // Stop active detector capture
    final detector = selectedDetector;
    if (detector != null) {
      try {
        await detector.stopMonitoring(sessionId: endedSessionId);
      } catch (_) {
        // Continue disarming
      }
    }

    // Resolve active incident if present
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
    } catch (error) {
      _warningMessage = 'Audio playback error during Test Alarm: $error';
    }

    try {
      await _incidentStorage.saveIncident(testIncident);
    } catch (error) {
      _warningMessage = 'Test alarm started, but incident save failed: $error';
    }

    _testAlarmTimer = Timer(const Duration(seconds: 5), () {
      unawaited(stopTestAlarm(autoCompleted: true));
    });
    notifyListeners();
    return true;
  }

  /// Stops an active Test Alarm immediately.
  Future<void> stopTestAlarm({bool autoCompleted = false}) async {
    if (!_isTestAlarmRunning) {
      return;
    }
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
        _handleLifecyclePaused(event);
        return;

      case DetectorEventType.lifecycleResumed:
        _handleLifecycleResumed(event);
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
    unawaited(_triggerAudioPersistAndNotify(incident));
  }

  Future<void> _triggerAudioPersistAndNotify(IncidentRecord incident) async {
    final warnings = <String>[];

    try {
      await _audioAdapter.startLoopingAlarm(volume: _settings.alarmVolume);
    } catch (error) {
      warnings.add('Local audio failed to start ($error).');
    }

    var workingIncident = incident;

    try {
      await _incidentStorage.saveIncident(workingIncident);
    } catch (error) {
      warnings.add('Local incident save failed ($error).');
    }

    try {
      final dispatchResult = await _notificationAdapter.sendIncidentAlert(
        workingIncident,
      );
      workingIncident = workingIncident.copyWith(
        remoteNotificationAttempted: true,
        remoteNotificationStatus: dispatchResult.message,
      );
      if (_activeIncident?.id == workingIncident.id) {
        _activeIncident = workingIncident;
      }
      _replaceIncidentInMemory(workingIncident);
      await _incidentStorage.updateIncident(workingIncident);
    } catch (error) {
      warnings.add('Remote alert dispatch failed ($error).');
      workingIncident = workingIncident.copyWith(
        remoteNotificationAttempted: true,
        remoteNotificationStatus: 'Failed ($error)',
      );
      if (_activeIncident?.id == workingIncident.id) {
        _activeIncident = workingIncident;
      }
      _replaceIncidentInMemory(workingIncident);
    }

    if (warnings.isNotEmpty) {
      _warningMessage = warnings.join(' ');
    }
    notifyListeners();
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

    // Never show "Protected" when a required detector has failed or stopped.
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

    final detector = _detectors[event.detectorType];
    if (detector != null && failedSessionId != null) {
      unawaited(detector.stopMonitoring(sessionId: failedSessionId));
    }

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

  void _handleLifecyclePaused(DetectorEvent event) {
    if (_state == ProtectionState.alarming) {
      // Keep alarm state active if lifecycle pauses during an active alarm.
      _warningMessage =
          'System lifecycle change during active alarm: ${event.summary}';
      notifyListeners();
      return;
    }
    if (_state == ProtectionState.armed || _state == ProtectionState.arming) {
      _cancelCountdownTimer();
      _isCalibrating = false;
      _state = ProtectionState.paused;
      _statusMessage = 'Monitoring paused — ${event.summary}';
      _warningMessage =
          'Monitoring is paused (${event.summary}). Device is not actively protected while paused.';
      notifyListeners();
    }
  }

  void _handleLifecycleResumed(DetectorEvent event) {
    if (_state != ProtectionState.paused) {
      return;
    }
    _state = ProtectionState.armed;
    _warningMessage = null;
    _statusMessage =
        'Protected — Monitoring resumed (${event.detectorType.displayName}).';
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
    _cancelCountdownTimer();
    _testAlarmTimer?.cancel();
    for (final sub in _subscriptions.values) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }
}
