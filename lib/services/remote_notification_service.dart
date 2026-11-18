import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/contracts/platform_contracts.dart';
import '../core/models/detector_models.dart';
import '../core/models/incident_models.dart';
import 'relay_config.dart';
import 'relay_transport.dart';

/// Default unconfigured implementation of [RemoteNotificationAdapter] used when
/// remote pairing is explicitly disabled or in baseline unconfigured tests.
class UnconfiguredRemoteNotificationService
    implements RemoteNotificationAdapter {
  const UnconfiguredRemoteNotificationService();

  @override
  Future<NotificationServiceStatus> getStatus() async {
    return const NotificationServiceStatus(
      capabilityStatus: CapabilityStatus.notConfigured,
      summary: 'No phone paired',
      detail:
          'Pair your phone on Home to receive alerts when an alarm triggers.',
    );
  }

  @override
  Future<List<PairedDeviceSummary>> listPairedDevices() async {
    return const <PairedDeviceSummary>[];
  }

  @override
  Future<NotificationDispatchResult> sendIncidentAlert(
    IncidentRecord incident,
  ) async {
    return const NotificationDispatchResult(
      delivered: false,
      capabilityStatus: CapabilityStatus.notConfigured,
      message: 'No phone paired',
    );
  }
}

/// Parsed representation of a short-lived pairing code, `https://.../pair?code=...`
/// link, `watsafe://pair?...` link, or JSON payload.
@immutable
class ParsedPairingInput {
  const ParsedPairingInput({
    required this.pairingCode,
    this.relayEndpointUrl,
    this.pairingSessionId,
  });

  final String pairingCode;
  final String? relayEndpointUrl;
  final String? pairingSessionId;
}

/// Full-featured implementation of [MutableRemoteNotificationAdapter] supporting:
/// - Laptop host session initiation with scannable `/pair?code=...` QR URLs and short-lived single-use codes
/// - Non-consuming code preview (`GET /v1/pairing/lookup`) for `"Connect to <Host>?"` confirmation
/// - Companion phone pairing, notification status sync, foreground live alert polling, and reconnect deduplication
/// - Asynchronous non-blocking incident location attachment (`POST /v1/incidents/location`)
/// - Unified HTTP relay alert delivery (`POST /v1/incidents:report`) for both test alerts and real alarms
/// - Local persistence (`watsafe_paired_devices.json`) without leaking credentials
///
/// Security & Privacy invariants:
/// - Never transmits camera frames, images, PINs/PIN hashes, or DB/push credentials.
/// - Precise coordinates are transmitted only over authenticated session requests.
class ConfigurableRemoteNotificationService
    implements MutableRemoteNotificationAdapter {
  ConfigurableRemoteNotificationService({
    this._storageDirectory,
    this.persistToDisk = true,
    this.enableBackgroundPolling = false,
    this.pollInterval = const Duration(seconds: 2),
    this.armedHeartbeatInterval = const Duration(seconds: 15),
    String? initialRelayEndpointUrl,
    List<PairedDeviceSummary>? initialDevices,
    this._httpTimeout = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _relayEndpointUrl = _normalizeUrl(
         initialRelayEndpointUrl ??
             const String.fromEnvironment('WATSAFE_API_URL'),
       ),
       _devices = List<PairedDeviceSummary>.from(
         initialDevices ?? const <PairedDeviceSummary>[],
       );

  static const String _stateFileName = 'watsafe_paired_devices.json';
  static const String _outboxFileName = 'watsafe_companion_alerts.json';
  static const String _secureCredentialKey = 'pairing_credentials';

  final Object? _storageDirectory;
  final bool persistToDisk;
  final bool enableBackgroundPolling;
  bool get usesSystemStorageDirectory =>
      persistToDisk && _storageDirectory == null;
  final Duration pollInterval;
  final Duration armedHeartbeatInterval;
  final Duration _httpTimeout;
  final DateTime Function() _clock;

  final StreamController<CompanionAlertEvent> _incomingAlertsController =
      StreamController<CompanionAlertEvent>.broadcast();
  final StreamController<Map<String, Object?>> _companionSensorController =
      StreamController<Map<String, Object?>>.broadcast();

  VoidCallback? _onStateChanged;
  String? _relayEndpointUrl;
  List<PairedDeviceSummary> _devices;
  List<PairedDeviceActionRecord> _actions = <PairedDeviceActionRecord>[];

  // Protected Laptop Host session state
  String? _hostInstallationId;
  String? _hostPairingSessionId;
  String? _hostToken;
  String _hostDisplayName = 'My Laptop';
  String _hostProtectionState = 'off';
  bool _hostArmed = false;
  String? _hostArmedSessionId;
  bool _pendingVerifiedDisarmSync = false;
  PairingCodeInvitation? _activePairingInvitation;
  Timer? _hostSyncTimer;
  Timer? _armedHeartbeatTimer;
  Future<List<PairedDeviceSummary>>? _inFlightHostSync;
  int _deviceMutationEpoch = 0;
  int _consecutiveHostSyncFailures = 0;
  DateTime? _nextAllowedBackgroundHostSyncAt;

  // Paired Companion Phone session state
  String? _companionInstallationId;
  String? _companionToken;
  CompanionSessionState _companionSession = CompanionSessionState.disconnected;
  int _companionLastAlertSeq = 0;
  final Set<String> _seenCompanionIncidentIds = <String>{};
  List<CompanionAlertEvent> _receivedCompanionAlerts = <CompanionAlertEvent>[];
  Timer? _companionPollTimer;
  Future<List<CompanionAlertEvent>>? _inFlightPoll;
  int _consecutiveCompanionFailures = 0;
  DateTime? _nextAllowedBackgroundCompanionPollAt;

  // Per-origin saved pairing snapshots for clean temporary -> permanent migration
  final Map<String, Map<String, Object?>> _credentialsByOrigin =
      <String, Map<String, Object?>>{};

  bool _foregroundActive = true;
  bool _disposed = false;
  bool _loadedFromDisk = false;
  int _deviceCounter = 0;
  int _actionCounter = 0;

  String _ensureHostInstallationId() {
    if (_hostInstallationId != null && _hostInstallationId!.isNotEmpty) {
      return _hostInstallationId!;
    }
    final rng = Random.secure();
    final bytes = List<int>.generate(8, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _hostInstallationId = 'host_inst_${_clock().millisecondsSinceEpoch}_$hex';
    return _hostInstallationId!;
  }

  String _ensureCompanionInstallationId() {
    if (_companionInstallationId != null &&
        _companionInstallationId!.isNotEmpty) {
      return _companionInstallationId!;
    }
    final rng = Random.secure();
    final bytes = List<int>.generate(8, (_) => rng.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _companionInstallationId =
        'comp_inst_${_clock().millisecondsSinceEpoch}_$hex';
    return _companionInstallationId!;
  }

  /// Stable installation device identity for the protected laptop host.
  String get hostInstallationId => _ensureHostInstallationId();

  static bool _isAuthenticErrorCode(String rawBody, String expectedErrorCode) {
    try {
      final decoded = jsonDecode(rawBody);
      return decoded is Map && decoded['error'] == expectedErrorCode;
    } catch (_) {
      return false;
    }
  }

  static String? _normalizeUrl(String? raw) {
    if (raw == null) {
      return null;
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  /// Parses a plain 6-character code (`K7M-4P9`), an `http(s)://.../pair?code=...`
  /// QR URL, a `watsafe://pair?...` deep link, or a JSON QR object.
  static ParsedPairingInput parsePairingInput(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) {
      return const ParsedPairingInput(pairingCode: '');
    }

    final lower = trimmed.toLowerCase();
    if (lower.startsWith('watsafe://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null) {
        return ParsedPairingInput(
          pairingCode: (uri.queryParameters['code'] ?? '').trim(),
          relayEndpointUrl: _normalizeUrl(uri.queryParameters['relay']),
          pairingSessionId: uri.queryParameters['session']?.trim(),
        );
      }
    }

    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null && uri.hasAuthority) {
        final code = (uri.queryParameters['code'] ?? '').trim();
        final explicitRelay = _normalizeUrl(uri.queryParameters['relay']);
        var basePath = uri.path;
        if (basePath.endsWith('/pair')) {
          basePath = basePath.substring(0, basePath.length - 5);
        } else if (basePath.endsWith('/companion')) {
          basePath = basePath.substring(0, basePath.length - 10);
        } else if (basePath == '/') {
          basePath = '';
        }
        final derivedOrigin = _normalizeUrl(
          '${uri.scheme}://${uri.authority}$basePath',
        );
        return ParsedPairingInput(
          pairingCode: code,
          relayEndpointUrl: explicitRelay ?? derivedOrigin,
          pairingSessionId: uri.queryParameters['session']?.trim(),
        );
      }
    }

    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        final map = jsonDecode(trimmed);
        if (map is Map) {
          return ParsedPairingInput(
            pairingCode: '${map['code'] ?? map['pairingCode'] ?? ''}'.trim(),
            relayEndpointUrl: _normalizeUrl(
              (map['relay'] ?? map['relayUrl']) as String?,
            ),
            pairingSessionId: map['pairingSessionId'] as String?,
          );
        }
      } catch (_) {
        // Fall through to plain code
      }
    }

    return ParsedPairingInput(pairingCode: trimmed);
  }

  @override
  String? get relayEndpointUrl => _relayEndpointUrl;

  @override
  PairingCodeInvitation? get activePairingInvitation =>
      _activePairingInvitation;

  @override
  CompanionSessionState get companionSession => _companionSession;

  @override
  List<CompanionAlertEvent> get receivedCompanionAlerts =>
      List<CompanionAlertEvent>.unmodifiable(_receivedCompanionAlerts);

  @override
  Stream<CompanionAlertEvent> get incomingCompanionAlerts =>
      _incomingAlertsController.stream;

  @override
  List<PairedDeviceActionRecord> get actionHistory =>
      List<PairedDeviceActionRecord>.unmodifiable(_actions);

  @override
  Stream<Map<String, Object?>> get companionSensorEvents =>
      _companionSensorController.stream;

  @override
  set onStateChanged(VoidCallback? callback) {
    _onStateChanged = callback;
  }

  Map<String, String> _bearerHeaders(String token) {
    return <String, String>{'Authorization': 'Bearer $token'};
  }

  Future<void> _ensureLoaded() async {
    if (_loadedFromDisk) {
      return;
    }
    _loadedFromDisk = true;
    if (!persistToDisk) {
      _ensureHostInstallationId();
      _ensureCompanionInstallationId();
      return;
    }
    bool migratedLegacyTokens = false;
    try {
      Map<String, Object?> decoded = const <String, Object?>{};
      final raw = await readPersistedJson(
        _stateFileName,
        storageDirectory: _storageDirectory,
      );
      if (raw != null && raw.trim().isNotEmpty) {
        final parsed = jsonDecode(raw);
        if (parsed is Map) {
          decoded = Map<String, Object?>.from(parsed);
        }
      }

      Map<String, Object?> secureDecoded = const <String, Object?>{};
      final rawSecure = await readSecurePersistedSecret(
        _secureCredentialKey,
        storageDirectory: _storageDirectory,
      );
      if (rawSecure != null && rawSecure.trim().isNotEmpty) {
        final parsedSecure = jsonDecode(rawSecure);
        if (parsedSecure is Map) {
          secureDecoded = Map<String, Object?>.from(parsedSecure);
        }
      }

      if (decoded.isEmpty && secureDecoded.isEmpty) {
        _ensureHostInstallationId();
        _ensureCompanionInstallationId();
        return;
      }

      _hostInstallationId =
          (secureDecoded['hostInstallationId'] as String?) ??
          (decoded['hostInstallationId'] as String?);
      _companionInstallationId =
          (secureDecoded['companionInstallationId'] as String?) ??
          (decoded['companionInstallationId'] as String?);
      _ensureHostInstallationId();
      _ensureCompanionInstallationId();

      final rawByOrigin = secureDecoded['credentialsByOrigin'];
      if (rawByOrigin is Map) {
        _credentialsByOrigin.clear();
        rawByOrigin.forEach((key, value) {
          if (key is String && value is Map) {
            _credentialsByOrigin[key] = Map<String, Object?>.from(value);
          }
        });
      }

      final savedUrl = _normalizeUrl(
        (decoded['relayEndpointUrl'] as String?) ??
            (secureDecoded['relayEndpointUrl'] as String?),
      );
      if (savedUrl != null &&
          (_relayEndpointUrl == null ||
              _relayEndpointUrl!.isEmpty ||
              !RelayConfig.hasExplicitCompileOrEnvOverride)) {
        _relayEndpointUrl = savedUrl;
      }

      final legacyHostToken = decoded['hostToken'] as String?;
      final legacyCompanionToken = decoded['companionToken'] as String?;
      if ((legacyHostToken != null && legacyHostToken.isNotEmpty) ||
          (legacyCompanionToken != null && legacyCompanionToken.isNotEmpty)) {
        migratedLegacyTokens = true;
      }

      final savedHostName = decoded['hostDisplayName'] as String?;
      if (savedHostName != null && savedHostName.trim().isNotEmpty) {
        _hostDisplayName = savedHostName.trim();
      }
      _hostPairingSessionId =
          (secureDecoded['hostPairingSessionId'] as String?) ??
          (decoded['hostPairingSessionId'] as String?);
      _hostToken = (secureDecoded['hostToken'] as String?) ?? legacyHostToken;

      final rawDevices = decoded['pairedDevices'] as List<Object?>?;
      if (rawDevices != null) {
        _devices = rawDevices
            .whereType<Map<Object?, Object?>>()
            .map(
              (item) =>
                  PairedDeviceSummary.fromJson(Map<String, Object?>.from(item)),
            )
            .toList();
      }

      final rawActions = decoded['actionHistory'] as List<Object?>?;
      if (rawActions != null) {
        _actions = rawActions
            .whereType<Map<Object?, Object?>>()
            .map(
              (item) => PairedDeviceActionRecord.fromJson(
                Map<String, Object?>.from(item),
              ),
            )
            .toList();
      }

      _companionToken =
          (secureDecoded['companionToken'] as String?) ?? legacyCompanionToken;
      _companionLastAlertSeq =
          (decoded['companionLastAlertSeq'] as num?)?.toInt() ?? 0;
      final rawSeen = decoded['seenCompanionIncidentIds'] as List<Object?>?;
      if (rawSeen != null) {
        _seenCompanionIncidentIds
          ..clear()
          ..addAll(rawSeen.whereType<String>());
      }
      final rawAlerts = decoded['receivedCompanionAlerts'] as List<Object?>?;
      if (rawAlerts != null) {
        _receivedCompanionAlerts = rawAlerts
            .whereType<Map<Object?, Object?>>()
            .map(
              (item) =>
                  CompanionAlertEvent.fromJson(Map<String, Object?>.from(item)),
            )
            .toList();
      }
      final companionSessionMap =
          decoded['companionSession'] as Map<Object?, Object?>?;
      if (_companionToken != null && companionSessionMap != null) {
        final cs = Map<String, Object?>.from(companionSessionMap);
        _companionSession = CompanionSessionState(
          isConnected: cs['isConnected'] as bool? ?? true,
          pairingSessionId: cs['pairingSessionId'] as String?,
          hostDisplayName: cs['hostDisplayName'] as String?,
          deviceId: cs['deviceId'] as String?,
          phoneDisplayName: cs['phoneDisplayName'] as String?,
          relayEndpointUrl: cs['relayEndpointUrl'] as String?,
          deliveryMode: cs['deliveryMode'] as String? ?? 'foreground_poll',
          pushServerConfigured: cs['pushServerConfigured'] as bool? ?? false,
          notificationsEnabled: cs['notificationsEnabled'] as bool? ?? false,
          statusMessage: cs['statusMessage'] as String?,
        );
        _startCompanionPollTimerIfNeeded();
        if (enableBackgroundPolling) {
          unawaited(pollCompanionAlertsOnce());
        }
      }
      if (_hostToken != null && _hostToken!.isNotEmpty) {
        _startHostSyncTimerIfNeeded();
        if (enableBackgroundPolling) {
          unawaited(syncPairedDevicesFromRelay());
        }
      }
      if (migratedLegacyTokens) {
        await _persistState();
      }
    } catch (_) {
      // Keep in-memory state if storage read fails
    }
  }

  void _snapshotCurrentOriginCredentials(String? origin) {
    final normalized = _normalizeUrl(origin);
    if (normalized == null || normalized.isEmpty) {
      return;
    }
    if ((_hostToken == null || _hostToken!.isEmpty) &&
        (_companionToken == null || _companionToken!.isEmpty) &&
        _devices.isEmpty) {
      _credentialsByOrigin.remove(normalized);
      return;
    }
    _credentialsByOrigin[normalized] = <String, Object?>{
      'hostPairingSessionId': _hostPairingSessionId,
      'hostToken': _hostToken,
      'pairedDevices': _devices.map((d) => d.toJson()).toList(),
      'companionToken': _companionToken,
    };
  }

  Future<void> _persistState() async {
    if (!persistToDisk) {
      return;
    }
    try {
      _ensureHostInstallationId();
      _ensureCompanionInstallationId();
      _snapshotCurrentOriginCredentials(_relayEndpointUrl);

      final securePayload = <String, Object?>{
        'hostInstallationId': _hostInstallationId,
        'companionInstallationId': _companionInstallationId,
        'relayEndpointUrl': _relayEndpointUrl,
        'hostPairingSessionId': _hostPairingSessionId,
        'hostToken': _hostToken,
        'companionToken': _companionToken,
        'credentialsByOrigin': _credentialsByOrigin,
      };
      await writeSecurePersistedSecret(
        _secureCredentialKey,
        jsonEncode(securePayload),
        storageDirectory: _storageDirectory,
      );

      // Never store raw bearer tokens (`hostToken` / `companionToken`) in plain state JSON.
      final payload = <String, Object?>{
        'relayEndpointUrl': _relayEndpointUrl,
        'hostInstallationId': _hostInstallationId,
        'hostDisplayName': _hostDisplayName,
        'hostPairingSessionId': _hostPairingSessionId,
        'pairedDevices': _devices.map((d) => d.toJson()).toList(),
        'actionHistory': _actions.take(30).map((a) => a.toJson()).toList(),
        'companionLastAlertSeq': _companionLastAlertSeq,
        'seenCompanionIncidentIds': _seenCompanionIncidentIds.toList(),
        'receivedCompanionAlerts': _receivedCompanionAlerts
            .take(50)
            .map((a) => a.toJson())
            .toList(),
        'companionSession': <String, Object?>{
          'isConnected': _companionSession.isConnected,
          'pairingSessionId': _companionSession.pairingSessionId,
          'hostDisplayName': _companionSession.hostDisplayName,
          'deviceId': _companionSession.deviceId,
          'phoneDisplayName': _companionSession.phoneDisplayName,
          'relayEndpointUrl': _companionSession.relayEndpointUrl,
          'deliveryMode': _companionSession.deliveryMode,
          'pushServerConfigured': _companionSession.pushServerConfigured,
          'notificationsEnabled': _companionSession.notificationsEnabled,
          'statusMessage': _companionSession.statusMessage,
        },
      };
      await writePersistedJson(
        _stateFileName,
        const JsonEncoder.withIndent('  ').convert(payload),
        storageDirectory: _storageDirectory,
      );
    } catch (_) {
      // Non-fatal persistence error
    }
  }

  @override
  Future<NotificationServiceStatus> getStatus() async {
    await _ensureLoaded();

    final hasUrl = _relayEndpointUrl != null && _relayEndpointUrl!.isNotEmpty;
    if (_companionSession.isConnected && _devices.isEmpty) {
      final hostLabel = _companionSession.hostDisplayName ?? 'your laptop';
      final notifDetail = _companionSession.notificationsEnabled
          ? (_companionSession.pushServerConfigured
                ? 'Lock-screen and background notifications are enabled.'
                : 'Notifications are enabled while WATSafe is open or running.')
          : 'Foreground alerts are active while WATSafe is open. Enable notifications in Settings for system alerts.';
      return NotificationServiceStatus(
        capabilityStatus: CapabilityStatus.ready,
        summary: 'Connected to $hostLabel',
        detail: notifDetail,
      );
    }

    if (_devices.isEmpty && !hasUrl) {
      return const NotificationServiceStatus(
        capabilityStatus: CapabilityStatus.notConfigured,
        summary: 'No phone paired',
        detail:
            'Pair your phone on Home to receive alerts when an alarm triggers.',
      );
    }

    if (_devices.isEmpty && hasUrl) {
      final invite = _activePairingInvitation;
      final hasActiveCode = invite != null && !invite.isExpiredAt(_clock());
      return NotificationServiceStatus(
        capabilityStatus: CapabilityStatus.degraded,
        summary: hasActiveCode
            ? 'Waiting for phone to scan code ${invite.pairingCode}'
            : 'Ready to pair your phone',
        detail: hasActiveCode
            ? 'Scan the QR code with your phone’s camera or enter ${invite.pairingCode} within ${invite.remainingSecondsAt(_clock())}s.'
            : 'No phone is paired yet. Choose Pair your phone on Home to connect.',
      );
    }

    final names = _devices.map((d) => d.displayName).join(', ');
    return NotificationServiceStatus(
      capabilityStatus: CapabilityStatus.ready,
      summary:
          'Connected (${_devices.length} paired device${_devices.length == 1 ? '' : 's'})',
      detail:
          'Phone connected ($names). Alerts will be sent when an alarm triggers.',
    );
  }

  @override
  Future<List<PairedDeviceSummary>> listPairedDevices() async {
    await _ensureLoaded();
    return List<PairedDeviceSummary>.unmodifiable(_devices);
  }

  @override
  Future<void> configureRelayEndpoint(String? endpointUrl) async {
    await _ensureLoaded();
    final normalized = _normalizeUrl(endpointUrl);
    if (normalized != _relayEndpointUrl) {
      _snapshotCurrentOriginCredentials(_relayEndpointUrl);
      ++_deviceMutationEpoch;
      _relayEndpointUrl = normalized;
      if (_companionSession.isConnected && normalized != null) {
        _companionSession = _companionSession.copyWith(
          relayEndpointUrl: normalized,
        );
      }
      _activePairingInvitation = null;
      _consecutiveHostSyncFailures = 0;
      if (!_hostArmed && _pendingVerifiedDisarmSync) {
        _pendingVerifiedDisarmSync = false;
      }
      _nextAllowedBackgroundHostSyncAt = null;

      if (normalized != null && _credentialsByOrigin.containsKey(normalized)) {
        final saved = _credentialsByOrigin[normalized]!;
        final savedToken = saved['hostToken'] as String?;
        if (savedToken != null && savedToken.isNotEmpty) {
          _hostPairingSessionId = saved['hostPairingSessionId'] as String?;
          _hostToken = savedToken;
          final rawDevices = saved['pairedDevices'] as List<Object?>?;
          if (rawDevices != null) {
            _devices = rawDevices
                .whereType<Map<Object?, Object?>>()
                .map(
                  (item) => PairedDeviceSummary.fromJson(
                    Map<String, Object?>.from(item),
                  ),
                )
                .toList();
          }
        }
      }
    }
    await _persistState();
    if (_hostToken != null &&
        _hostToken!.isNotEmpty &&
        _relayEndpointUrl != null &&
        _relayEndpointUrl!.isNotEmpty) {
      _startHostSyncTimerIfNeeded();
    }
  }

  /// Updates the protected laptop's display name and protection state used in
  /// host presence heartbeats so the paired phone companion accurately displays
  /// whether the laptop is online and its current protection state.
  Future<void> updateHostPresence({
    String? hostDisplayName,
    String? protectionState,
    bool sendImmediateHeartbeat = false,
  }) async {
    await _ensureLoaded();
    if (hostDisplayName != null && hostDisplayName.trim().isNotEmpty) {
      _hostDisplayName = hostDisplayName.trim();
    }
    if (protectionState != null && protectionState.trim().isNotEmpty) {
      _hostProtectionState = protectionState.trim();
    }
    if (sendImmediateHeartbeat) {
      if (_hostToken != null &&
          _hostToken!.isNotEmpty &&
          _relayEndpointUrl != null &&
          _relayEndpointUrl!.isNotEmpty) {
        _nextAllowedBackgroundHostSyncAt = null;
        await syncPairedDevicesFromRelay();
      }
    }
  }

  @override
  Future<void> syncHostArmedState({
    required bool armed,
    String? armedSessionId,
    bool disarmVerified = false,
    String? protectionState,
  }) async {
    await _ensureLoaded();
    _hostArmed = armed;
    _hostArmedSessionId = armed ? armedSessionId : null;
    if (armed) {
      _pendingVerifiedDisarmSync = false;
    } else if (disarmVerified) {
      _pendingVerifiedDisarmSync = true;
    }
    if (protectionState != null && protectionState.trim().isNotEmpty) {
      _hostProtectionState = protectionState.trim();
    } else {
      _hostProtectionState = armed ? 'armed' : 'off';
    }
    _reconfigureArmedHeartbeatTimer();

    final url = _relayEndpointUrl;
    final token = _hostToken;
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return;
    }
    // Allow up to 65s when arming over HTTPS so a spun-down Render Free service
    // can complete its ~50-60s cold start and persist `hostArmed = true`.
    final syncTimeout =
        (armed && url.startsWith('https://') && _httpTimeout.inSeconds < 65)
        ? const Duration(seconds: 65)
        : _httpTimeout;
    final res = await sendRelayJsonRequest(
      method: 'POST',
      url: '$url/v1/host/heartbeat',
      headers: _bearerHeaders(token),
      body: <String, Object?>{
        'hostDisplayName': _hostDisplayName,
        'hostDeviceId': _ensureHostInstallationId(),
        'hostProtectionState': _hostProtectionState,
        'hostArmed': _hostArmed,
        'hostArmedSessionId': ?_hostArmedSessionId,
        'disarmVerified': disarmVerified || _pendingVerifiedDisarmSync,
      },
      timeout: syncTimeout,
    );
    if (res.isSuccess && !_hostArmed && _pendingVerifiedDisarmSync) {
      _pendingVerifiedDisarmSync = false;
    }
  }

  void _reconfigureArmedHeartbeatTimer() {
    _armedHeartbeatTimer?.cancel();
    _armedHeartbeatTimer = null;
    if (_disposed || !enableBackgroundPolling || !_hostArmed) {
      return;
    }
    _armedHeartbeatTimer = Timer.periodic(armedHeartbeatInterval, (_) {
      if (_disposed || !_hostArmed) {
        _armedHeartbeatTimer?.cancel();
        _armedHeartbeatTimer = null;
        return;
      }
      final url = _relayEndpointUrl;
      final token = _hostToken;
      if (url == null || url.isEmpty || token == null || token.isEmpty) {
        return;
      }
      unawaited(
        sendRelayJsonRequest(
          method: 'POST',
          url: '$url/v1/host/heartbeat',
          headers: _bearerHeaders(token),
          body: <String, Object?>{
            'hostDisplayName': _hostDisplayName,
            'hostDeviceId': _ensureHostInstallationId(),
            'hostProtectionState': _hostProtectionState,
            'hostArmed': _hostArmed,
            'hostArmedSessionId': ?_hostArmedSessionId,
          },
          timeout: _httpTimeout,
        ),
      );
    });
  }

  /// Explicitly marks the laptop host offline on the relay (`POST /v1/host/offline`)
  /// when closing the laptop app while preserving all durable pairing credentials
  /// so reopening the laptop app reconnects automatically without re-pairing.
  Future<bool> notifyHostOffline() async {
    await _ensureLoaded();
    final url = _relayEndpointUrl;
    final token = _hostToken;
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return false;
    }
    final res = await sendRelayJsonRequest(
      method: 'POST',
      url: '$url/v1/host/offline',
      headers: _bearerHeaders(token),
      body: <String, Object?>{
        'hostDeviceId': _ensureHostInstallationId(),
        'hostProtectionState': _hostProtectionState,
      },
      timeout: const Duration(milliseconds: 1200),
    );
    return res.isSuccess;
  }

  @override
  Future<PairingCodeInvitation> initiateHostPairing({
    String? hostDisplayName,
  }) async {
    await _ensureLoaded();
    final url = _relayEndpointUrl;
    if (url == null || url.isEmpty) {
      throw StateError(
        'Pairing service is not configured right now. Check Advanced settings or your connection and try again.',
      );
    }

    final requestedName = (hostDisplayName?.trim().isNotEmpty == true)
        ? hostDisplayName!.trim()
        : _hostDisplayName;
    _hostDisplayName = requestedName;

    final response = await sendRelayJsonRequest(
      method: 'POST',
      url: '$url/v1/pairing/initiate',
      headers: _hostToken != null ? _bearerHeaders(_hostToken!) : null,
      body: <String, Object?>{
        'hostDisplayName': requestedName,
        'hostDeviceId': _ensureHostInstallationId(),
        'hostProtectionState': _hostProtectionState,
        'relayUrl': url,
      },
      timeout: _httpTimeout,
    );

    if (!response.isSuccess) {
      throw StateError(
        'Could not reach the pairing service. Make sure your laptop is online and try again.',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, Object?>;
    final sessionId = decoded['pairingSessionId'] as String? ?? '';
    final hostToken = decoded['hostToken'] as String? ?? '';
    final code = decoded['pairingCode'] as String? ?? '';
    final expiresInSeconds =
        (decoded['expiresInSeconds'] as num?)?.toInt() ?? 300;
    final expiresRaw = decoded['expiresAtUtc'] as String?;
    final expiresAt = expiresRaw != null
        ? (DateTime.tryParse(expiresRaw)?.toLocal() ??
              _clock().add(Duration(seconds: expiresInSeconds)))
        : _clock().add(Duration(seconds: expiresInSeconds));
    final qrPayload =
        decoded['qrPayload'] as String? ??
        'watsafe://pair?relay=${Uri.encodeQueryComponent(url)}&code=${Uri.encodeQueryComponent(code)}&session=${Uri.encodeQueryComponent(sessionId)}';
    final pairingUrl =
        decoded['pairingUrl'] as String? ??
        '$url/pair?code=${Uri.encodeQueryComponent(code)}&session=${Uri.encodeQueryComponent(sessionId)}';
    final resolvedHostName =
        decoded['hostDisplayName'] as String? ?? requestedName;

    if (sessionId.isEmpty || hostToken.isEmpty || code.isEmpty) {
      throw StateError(
        'The pairing service returned an incomplete response. Please try again.',
      );
    }

    _hostPairingSessionId = sessionId;
    _hostToken = hostToken;
    _activePairingInvitation = PairingCodeInvitation(
      pairingSessionId: sessionId,
      pairingCode: code,
      expiresAt: expiresAt,
      qrPayload: qrPayload,
      relayEndpointUrl: url,
      pairingUrl: pairingUrl,
      hostDisplayName: resolvedHostName,
    );
    _nextAllowedBackgroundHostSyncAt = null;

    await _persistState();
    _startHostSyncTimerIfNeeded();
    _onStateChanged?.call();
    return _activePairingInvitation!;
  }

  @override
  Future<PairingLookupPreview> lookupPairingInvitation(
    String pairingCodeOrPayload, {
    String? endpointUrlOverride,
  }) async {
    await _ensureLoaded();
    final parsed = parsePairingInput(pairingCodeOrPayload);
    final effectiveUrl =
        parsed.relayEndpointUrl ??
        _normalizeUrl(endpointUrlOverride) ??
        _relayEndpointUrl;
    if (effectiveUrl == null || effectiveUrl.isEmpty) {
      throw StateError(
        'Scan the QR code from your laptop so WATSafe knows how to connect.',
      );
    }
    if (parsed.pairingCode.isEmpty) {
      throw StateError('Enter the pairing code shown on your laptop.');
    }

    final response = await sendRelayJsonRequest(
      method: 'GET',
      url:
          '$effectiveUrl/v1/pairing/lookup?code=${Uri.encodeQueryComponent(parsed.pairingCode)}',
      timeout: _httpTimeout,
    );

    if (!response.isSuccess) {
      String detail =
          'That pairing code was not found or has expired. Generate a new code on your laptop and try again.';
      try {
        final errMap = jsonDecode(response.body) as Map<String, Object?>;
        if (errMap['message'] is String &&
            (errMap['message'] as String).trim().isNotEmpty) {
          detail = errMap['message'] as String;
        }
      } catch (_) {}
      throw StateError(detail);
    }

    final decoded = jsonDecode(response.body) as Map<String, Object?>;
    final expiresRaw = decoded['expiresAtUtc'] as String? ?? '';
    return PairingLookupPreview(
      pairingSessionId: decoded['pairingSessionId'] as String? ?? '',
      hostDisplayName: decoded['hostDisplayName'] as String? ?? 'Your Laptop',
      pairingCode: decoded['pairingCode'] as String? ?? parsed.pairingCode,
      relayEndpointUrl: effectiveUrl,
      expiresAt:
          DateTime.tryParse(expiresRaw)?.toLocal() ??
          _clock().add(const Duration(minutes: 5)),
    );
  }

  @override
  Future<List<PairedDeviceSummary>> syncPairedDevicesFromRelay() {
    final active = _inFlightHostSync;
    if (active != null) {
      return active;
    }
    final future = _executeHostDeviceSync();
    _inFlightHostSync = future;
    future.whenComplete(() {
      if (identical(_inFlightHostSync, future)) {
        _inFlightHostSync = null;
      }
    });
    return future;
  }

  Future<List<PairedDeviceSummary>> _executeHostDeviceSync() async {
    await _ensureLoaded();
    final url = _relayEndpointUrl;
    final token = _hostToken;
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return List<PairedDeviceSummary>.unmodifiable(_devices);
    }

    final syncEpoch = _deviceMutationEpoch;
    var response = await sendRelayJsonRequest(
      method: 'POST',
      url: '$url/v1/host/heartbeat',
      headers: _bearerHeaders(token),
      body: <String, Object?>{
        'hostDisplayName': _hostDisplayName,
        'hostDeviceId': _ensureHostInstallationId(),
        'hostProtectionState': _hostProtectionState,
        'hostArmed': _hostArmed,
        'hostArmedSessionId': ?_hostArmedSessionId,
        if (!_hostArmed && _pendingVerifiedDisarmSync) 'disarmVerified': true,
      },
      timeout: _httpTimeout,
    );
    if (response.statusCode == 404 || response.statusCode == 405) {
      response = await sendRelayJsonRequest(
        method: 'GET',
        url: '$url/v1/pairing/devices',
        headers: _bearerHeaders(token),
        timeout: _httpTimeout,
      );
    }

    if (syncEpoch != _deviceMutationEpoch) {
      return List<PairedDeviceSummary>.unmodifiable(_devices);
    }

    // Clear host credentials ONLY on an authentic WATSafe 401 session revocation
    // (never on Cloudflare 530, proxy HTML/401, 5xx, timeouts, or network blips!).
    if (response.statusCode == 401 &&
        response.isAuthenticWatSafe &&
        _isAuthenticErrorCode(response.body, 'UNAUTHORIZED_HOST_SESSION')) {
      _consecutiveHostSyncFailures = 0;
      if (!_hostArmed && _pendingVerifiedDisarmSync) {
        _pendingVerifiedDisarmSync = false;
      }
      _nextAllowedBackgroundHostSyncAt = null;
      _hostToken = null;
      _hostPairingSessionId = null;
      _activePairingInvitation = null;
      _devices = <PairedDeviceSummary>[];
      _credentialsByOrigin.remove(_normalizeUrl(url));
      await _persistState();
      _onStateChanged?.call();
      return const <PairedDeviceSummary>[];
    }

    if (!response.isSuccess) {
      _consecutiveHostSyncFailures += 1;
      final shift = min(_consecutiveHostSyncFailures - 1, 4);
      final backoffSeconds = min(
        30,
        max(2, pollInterval.inSeconds) * (1 << shift),
      );
      _nextAllowedBackgroundHostSyncAt = _clock().add(
        Duration(seconds: backoffSeconds),
      );
      return List<PairedDeviceSummary>.unmodifiable(_devices);
    }

    _consecutiveHostSyncFailures = 0;
    if (!_hostArmed && _pendingVerifiedDisarmSync) {
      _pendingVerifiedDisarmSync = false;
    }
    final hasActiveInvite =
        _activePairingInvitation != null &&
        !_activePairingInvitation!.isExpiredAt(_clock());
    if (!hasActiveInvite &&
        url.startsWith('https://') &&
        pollInterval >= const Duration(seconds: 2)) {
      _nextAllowedBackgroundHostSyncAt = _clock().add(
        const Duration(seconds: 10),
      );
    } else {
      _nextAllowedBackgroundHostSyncAt = null;
    }

    try {
      final decoded = jsonDecode(response.body) as Map<String, Object?>;
      final rawList = decoded['devices'] as List<Object?>? ?? const <Object?>[];
      final existingById = <String, PairedDeviceSummary>{
        for (final item in _devices) item.deviceId: item,
      };
      final updated = rawList.whereType<Map<Object?, Object?>>().map((item) {
        final parsed = PairedDeviceSummary.fromJson(
          Map<String, Object?>.from(item),
        );
        final prior = existingById[parsed.deviceId];
        if (prior != null) {
          return parsed.copyWith(
            remoteStateLabel: parsed.connected
                ? prior.remoteStateLabel
                : 'Disconnected',
            remoteSensorForwardingEnabled: prior.remoteSensorForwardingEnabled,
            isRingingRemotely: prior.isRingingRemotely,
            lastActionSummary: prior.lastActionSummary,
          );
        }
        return parsed.copyWith(
          remoteStateLabel: parsed.connected
              ? 'Phone connected'
              : 'Disconnected',
        );
      }).toList();

      if (syncEpoch != _deviceMutationEpoch) {
        return List<PairedDeviceSummary>.unmodifiable(_devices);
      }

      final changed = !_sameDeviceList(_devices, updated);
      _devices = updated;
      if (updated.isNotEmpty && _activePairingInvitation != null) {
        // Phone consumed the single-use code and is now connected!
        _activePairingInvitation = null;
      }
      if (changed) {
        await _persistState();
        _onStateChanged?.call();
      }
    } catch (_) {
      // Ignore malformed payload
    }
    return List<PairedDeviceSummary>.unmodifiable(_devices);
  }

  bool _sameDeviceList(
    List<PairedDeviceSummary> a,
    List<PairedDeviceSummary> b,
  ) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i].deviceId != b[i].deviceId ||
          a[i].connected != b[i].connected ||
          a[i].displayName != b[i].displayName ||
          a[i].notificationsEnabled != b[i].notificationsEnabled ||
          a[i].notificationChannel != b[i].notificationChannel ||
          a[i].pushSubscriptionNeedsRenewal !=
              b[i].pushSubscriptionNeedsRenewal ||
          a[i].lastPushErrorCode != b[i].lastPushErrorCode ||
          a[i].lastReceiptIncidentId != b[i].lastReceiptIncidentId) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<PairedDeviceSummary> pairDevice({
    required String displayName,
    required String platform,
    String? pairingCode,
  }) async {
    await _ensureLoaded();
    final trimmedName = displayName.trim().isEmpty
        ? 'My Phone'
        : displayName.trim();
    final trimmedPlatform = platform.trim().isEmpty ? 'Phone' : platform.trim();
    final now = _clock();
    final provisionalId =
        'dev_${++_deviceCounter}_${now.millisecondsSinceEpoch}';
    final effectiveCode = pairingCode?.isNotEmpty == true
        ? pairingCode!
        : (_activePairingInvitation?.pairingCode ?? 'LOCAL-BOND');

    if (_relayEndpointUrl != null && _relayEndpointUrl!.isNotEmpty) {
      if (_hostToken == null || _hostToken!.isEmpty) {
        await initiateHostPairing();
      }
      final postRes = await sendRelayJsonRequest(
        method: 'POST',
        url: '$_relayEndpointUrl/v1/pairing/complete',
        headers: _hostToken != null ? _bearerHeaders(_hostToken!) : null,
        body: <String, Object?>{
          'deviceId': provisionalId,
          'displayName': trimmedName,
          'platform': trimmedPlatform,
          'pairingCode': effectiveCode,
          'pairedAtUtc': now.toUtc().toIso8601String(),
        },
        timeout: _httpTimeout,
      );
      if (!postRes.isSuccess) {
        throw StateError(
          'Could not pair phone right now. Check your connection and try again.',
        );
      }
      final body = jsonDecode(postRes.body) as Map<String, Object?>;
      final serverDevice = PairedDeviceSummary.fromJson(body).copyWith(
        remoteStateLabel: 'Phone connected',
        remoteSensorForwardingEnabled: true,
        isRingingRemotely: false,
        lastActionSummary: 'Paired',
        lastSeenAt: now,
      );
      ++_deviceMutationEpoch;
      _devices = <PairedDeviceSummary>[
        ..._devices.where((d) => d.deviceId != serverDevice.deviceId),
        serverDevice,
      ];
      _activePairingInvitation = null;
      _recordAction(
        deviceId: serverDevice.deviceId,
        deviceName: serverDevice.displayName,
        commandType: PairedDeviceCommandType.syncProtectionState,
        timestamp: now,
        delivered: true,
        summary: 'Connected "${serverDevice.displayName}".',
      );
      await _persistState();
      _startHostSyncTimerIfNeeded();
      return serverDevice;
    }

    final device = PairedDeviceSummary(
      deviceId: provisionalId,
      displayName: trimmedName,
      platform: trimmedPlatform,
      pairedAt: now,
      pushChannelReady: true,
      connected: true,
      notificationsEnabled: true,
      remoteStateLabel: 'Phone connected',
      remoteSensorForwardingEnabled: true,
      isRingingRemotely: false,
      lastActionSummary: 'Paired',
      lastSeenAt: now,
    );
    _devices = <PairedDeviceSummary>[..._devices, device];
    _recordAction(
      deviceId: device.deviceId,
      deviceName: device.displayName,
      commandType: PairedDeviceCommandType.syncProtectionState,
      timestamp: now,
      delivered: true,
      summary: 'Connected "${device.displayName}".',
    );
    await _persistState();
    return device;
  }

  @override
  Future<void> unpairDevice(String deviceId) async {
    await _ensureLoaded();
    ++_deviceMutationEpoch;
    final existing = _devices.where((d) => d.deviceId == deviceId).firstOrNull;
    if (_relayEndpointUrl != null &&
        _relayEndpointUrl!.isNotEmpty &&
        _hostToken != null &&
        _hostToken!.isNotEmpty) {
      await sendRelayJsonRequest(
        method: 'DELETE',
        url:
            '$_relayEndpointUrl/v1/pairing/devices/${Uri.encodeComponent(deviceId)}',
        headers: _bearerHeaders(_hostToken!),
        timeout: _httpTimeout,
      );
    }
    ++_deviceMutationEpoch;
    _devices = _devices.where((d) => d.deviceId != deviceId).toList();
    if (existing != null) {
      _recordAction(
        deviceId: existing.deviceId,
        deviceName: existing.displayName,
        commandType: PairedDeviceCommandType.syncProtectionState,
        timestamp: _clock(),
        delivered: true,
        summary: 'Disconnected "${existing.displayName}".',
      );
    }
    await _persistState();
  }

  @override
  Future<PairedDeviceActionRecord> sendDeviceCommand({
    required String deviceId,
    required PairedDeviceCommandType command,
    Map<String, Object?>? payload,
  }) async {
    await _ensureLoaded();
    final index = _devices.indexWhere((d) => d.deviceId == deviceId);
    if (index < 0) {
      throw StateError('Paired phone not found.');
    }

    final current = _devices[index];
    final now = _clock();
    PairedDeviceSummary updated = current;
    String actionSummary;

    switch (command) {
      case PairedDeviceCommandType.sendTestPush:
        actionSummary = 'Test alert sent to "${current.displayName}".';
        updated = current.copyWith(
          remoteStateLabel: 'Phone connected',
          lastActionSummary: 'Test alert sent',
          lastSeenAt: now,
        );

      case PairedDeviceCommandType.toggleRemoteRing:
        final nextRinging = !current.isRingingRemotely;
        actionSummary = nextRinging
            ? 'Locator ring started on "${current.displayName}".'
            : 'Locator ring stopped on "${current.displayName}".';
        updated = current.copyWith(
          isRingingRemotely: nextRinging,
          remoteStateLabel: nextRinging ? 'Ringing' : 'Phone connected',
          lastActionSummary: actionSummary,
          lastSeenAt: now,
        );

      case PairedDeviceCommandType.syncProtectionState:
        final hostState =
            payload?['hostState'] as String? ??
            payload?['protectionState'] as String? ??
            'Off';
        actionSummary =
            'Synced status ($hostState) to "${current.displayName}".';
        updated = current.copyWith(
          remoteStateLabel: 'Phone connected',
          lastActionSummary: 'Status synced',
          lastSeenAt: now,
        );

      case PairedDeviceCommandType.toggleRemoteSensorForwarding:
        final nextEnabled = !current.remoteSensorForwardingEnabled;
        actionSummary = nextEnabled
            ? 'Enabled motion sensor link on "${current.displayName}".'
            : 'Paused motion sensor link on "${current.displayName}".';
        updated = current.copyWith(
          remoteSensorForwardingEnabled: nextEnabled,
          remoteStateLabel: 'Phone connected',
          lastActionSummary: actionSummary,
          lastSeenAt: now,
        );

      case PairedDeviceCommandType.simulateCompanionMotionTrigger:
        actionSummary = 'Motion detected on "${current.displayName}".';
        updated = current.copyWith(
          remoteStateLabel: 'Motion detected',
          lastActionSummary: actionSummary,
          lastSeenAt: now,
        );
        if (!_companionSensorController.isClosed) {
          _companionSensorController.add(<String, Object?>{
            'eventType': 'motionTriggered',
            'deviceId': current.deviceId,
            'deviceName': current.displayName,
            'motionScore': 0.38,
            'summary': 'Sustained motion detected on ${current.displayName}',
            'timestampMs': now.millisecondsSinceEpoch,
          });
        }
    }

    final commandPayload = <String, Object?>{
      'kind': 'paired_device_command',
      'deviceId': current.deviceId,
      'displayName': current.displayName,
      'platform': current.platform,
      'command': command.id,
      'summary': actionSummary,
      'timestampUtc': now.toUtc().toIso8601String(),
      'data': ?payload,
    };

    bool delivered = true;
    final hasUrl = _relayEndpointUrl != null && _relayEndpointUrl!.isNotEmpty;
    if (hasUrl) {
      final postOutcome = await sendRelayJsonRequest(
        method: 'POST',
        url: '$_relayEndpointUrl/v1/devices/command',
        headers: _hostToken != null ? _bearerHeaders(_hostToken!) : null,
        body: commandPayload,
        timeout: _httpTimeout,
      );
      delivered = postOutcome.isSuccess;
    }

    await _appendAlertToLocalOutbox(commandPayload);
    _devices = List<PairedDeviceSummary>.from(_devices)..[index] = updated;

    final record = _recordAction(
      deviceId: current.deviceId,
      deviceName: current.displayName,
      commandType: command,
      timestamp: now,
      delivered: delivered,
      summary: actionSummary,
    );
    await _persistState();
    return record;
  }

  PairedDeviceActionRecord _recordAction({
    required String deviceId,
    required String deviceName,
    required PairedDeviceCommandType commandType,
    required DateTime timestamp,
    required bool delivered,
    required String summary,
  }) {
    final record = PairedDeviceActionRecord(
      actionId: 'act_${++_actionCounter}_${timestamp.millisecondsSinceEpoch}',
      deviceId: deviceId,
      deviceName: deviceName,
      commandType: commandType,
      timestamp: timestamp,
      delivered: delivered,
      summary: summary,
    );
    _actions = <PairedDeviceActionRecord>[record, ..._actions];
    if (_actions.length > 40) {
      _actions = _actions.sublist(0, 40);
    }
    return record;
  }

  @override
  Future<CompanionSessionState> pairAsCompanionPhone({
    required String pairingCodeOrPayload,
    required String displayName,
    required String platform,
    String? endpointUrlOverride,
    bool notificationsEnabled = false,
    String notificationChannel = 'foreground_only',
    String? pushToken,
  }) async {
    await _ensureLoaded();
    final parsed = parsePairingInput(pairingCodeOrPayload);
    final effectiveUrl =
        parsed.relayEndpointUrl ??
        _normalizeUrl(endpointUrlOverride) ??
        _relayEndpointUrl;
    if (effectiveUrl == null || effectiveUrl.isEmpty) {
      throw StateError(
        'Scan the QR code on your laptop so WATSafe knows where to connect.',
      );
    }
    if (parsed.pairingCode.isEmpty) {
      throw StateError(
        'Enter the 6-character pairing code shown on your laptop.',
      );
    }

    final trimmedName = displayName.trim().isEmpty
        ? 'My Phone'
        : displayName.trim();
    final trimmedPlatform = platform.trim().isEmpty ? 'Phone' : platform.trim();

    final response = await sendRelayJsonRequest(
      method: 'POST',
      url: '$effectiveUrl/v1/pairing/complete',
      body: <String, Object?>{
        'pairingCode': parsed.pairingCode,
        'deviceId':
            _companionSession.deviceId ?? _ensureCompanionInstallationId(),
        'displayName': trimmedName,
        'platform': trimmedPlatform,
        'notificationsEnabled': notificationsEnabled,
        'deliveryChannel': notificationChannel,
        'pushToken': ?pushToken,
      },
      timeout: _httpTimeout,
    );

    if (!response.isSuccess) {
      String detail =
          'Could not connect with that pairing code. Generate a new code on your laptop and try again.';
      try {
        final errMap = jsonDecode(response.body) as Map<String, Object?>;
        if (errMap['message'] is String &&
            (errMap['message'] as String).trim().isNotEmpty) {
          detail = errMap['message'] as String;
        }
      } catch (_) {}
      throw StateError(detail);
    }

    final body = jsonDecode(response.body) as Map<String, Object?>;
    final sessionId = body['pairingSessionId'] as String? ?? '';
    final companionToken = body['companionToken'] as String? ?? '';
    final deviceId = body['deviceId'] as String?;
    final hostDisplayName = body['hostDisplayName'] as String? ?? 'Your Laptop';
    final pushConfigured = body['pushConfigured'] as bool? ?? false;

    if (sessionId.isEmpty || companionToken.isEmpty) {
      throw StateError(
        'The pairing service did not finish connecting. Please try again.',
      );
    }

    final isSameSession =
        _companionSession.pairingSessionId != null &&
        _companionSession.pairingSessionId == sessionId;
    if (!isSameSession) {
      _companionLastAlertSeq = 0;
      _seenCompanionIncidentIds.clear();
      _receivedCompanionAlerts = <CompanionAlertEvent>[];
    }

    _relayEndpointUrl = effectiveUrl;
    _companionToken = companionToken;
    _companionSession = CompanionSessionState(
      isConnected: true,
      pairingSessionId: sessionId,
      hostDisplayName: hostDisplayName,
      deviceId: deviceId,
      phoneDisplayName: trimmedName,
      relayEndpointUrl: effectiveUrl,
      deliveryMode: body['deliveryMode'] as String? ?? 'foreground_poll',
      pushServerConfigured: pushConfigured,
      notificationsEnabled: notificationsEnabled,
      statusMessage: 'Connected to $hostDisplayName.',
    );

    await _persistState();
    await pollCompanionAlertsOnce();
    _startCompanionPollTimerIfNeeded();
    _onStateChanged?.call();
    return _companionSession;
  }

  @override
  Future<void> updateCompanionNotificationStatus({
    required bool notificationsEnabled,
    required String deliveryChannel,
    String? pushToken,
  }) async {
    await _ensureLoaded();
    final token = _companionToken;
    final url = _companionSession.relayEndpointUrl ?? _relayEndpointUrl;
    _companionSession = _companionSession.copyWith(
      notificationsEnabled: notificationsEnabled,
      deliveryMode: deliveryChannel,
    );
    if (token != null &&
        token.isNotEmpty &&
        url != null &&
        url.isNotEmpty &&
        _companionSession.isConnected) {
      await sendRelayJsonRequest(
        method: 'POST',
        url: '$url/v1/companion/status',
        headers: _bearerHeaders(token),
        body: <String, Object?>{
          'notificationsEnabled': notificationsEnabled,
          'deliveryChannel': deliveryChannel,
          'pushToken': ?pushToken,
        },
        timeout: _httpTimeout,
      );
    }
    await _persistState();
    _onStateChanged?.call();
  }

  @override
  Future<bool> updateIncidentLocation({
    required String incidentId,
    DeviceLocationSnapshot? location,
    required IncidentLocationStatus locationStatus,
    String? locationTrackingState,
  }) async {
    await _ensureLoaded();
    final url = _relayEndpointUrl;
    final token = _hostToken;
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return false;
    }

    final body = <String, Object?>{
      'incidentId': incidentId,
      'locationStatus': locationStatus.name,
      if (location != null && location.isValid) 'location': location.toJson(),
      'locationTrackingState': ?locationTrackingState,
    };

    final response = await sendRelayJsonRequest(
      method: 'POST',
      url: '$url/v1/incidents/location',
      headers: _bearerHeaders(token),
      body: body,
      timeout: _httpTimeout,
    );
    return response.isSuccess;
  }

  @override
  Future<bool> reportHostLocation({
    DeviceLocationSnapshot? location,
    required IncidentLocationStatus locationStatus,
    required String protectionState,
    String? activeIncidentId,
    bool isBoundedAlarmTracking = false,
  }) async {
    await _ensureLoaded();
    _hostProtectionState = protectionState;
    final url = _relayEndpointUrl;
    final token = _hostToken;
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return false;
    }
    final response = await sendRelayJsonRequest(
      method: 'POST',
      url: '$url/v1/host/location',
      headers: _bearerHeaders(token),
      body: <String, Object?>{
        'hostDisplayName': _hostDisplayName,
        'hostDeviceId': _ensureHostInstallationId(),
        'protectionState': protectionState,
        'locationStatus': locationStatus.name,
        if (location != null && location.isValid) 'location': location.toJson(),
        'activeIncidentId': ?activeIncidentId,
        'isBoundedAlarmTracking': isBoundedAlarmTracking,
      },
      timeout: _httpTimeout,
    );
    return response.isSuccess;
  }

  @override
  Future<bool> reportCompanionLocation({
    DeviceLocationSnapshot? location,
    required bool sharingEnabled,
    required IncidentLocationStatus locationStatus,
  }) async {
    await _ensureLoaded();
    final token = _companionToken;
    final url = _companionSession.relayEndpointUrl ?? _relayEndpointUrl;
    if (token == null || token.isEmpty || url == null || url.isEmpty) {
      return false;
    }
    if (!sharingEnabled) {
      final res = await sendRelayJsonRequest(
        method: 'DELETE',
        url: '$url/v1/companion/location',
        headers: _bearerHeaders(token),
        timeout: _httpTimeout,
      );
      return res.isSuccess;
    }
    final res = await sendRelayJsonRequest(
      method: 'POST',
      url: '$url/v1/companion/location',
      headers: _bearerHeaders(token),
      body: <String, Object?>{
        'sharingEnabled': true,
        'locationStatus': locationStatus.name,
        if (_companionSession.deviceId != null)
          'deviceId': _companionSession.deviceId,
        if (_companionSession.pairingSessionId != null)
          'pairingSessionId': _companionSession.pairingSessionId,
        if (location != null && location.isValid) 'location': location.toJson(),
      },
      timeout: _httpTimeout,
    );
    return res.isSuccess;
  }

  @override
  Future<List<AuthorizedDeviceLocationSummary>>
  fetchAuthorizedDevicesLocations() async {
    await _ensureLoaded();
    final token = (_companionSession.isConnected && _companionToken != null)
        ? _companionToken
        : _hostToken;
    final url = _companionSession.isConnected
        ? (_companionSession.relayEndpointUrl ?? _relayEndpointUrl)
        : _relayEndpointUrl;
    if (token == null || token.isEmpty || url == null || url.isEmpty) {
      return const <AuthorizedDeviceLocationSummary>[];
    }
    final response = await sendRelayJsonRequest(
      method: 'GET',
      url: '$url/v1/devices/locations',
      headers: _bearerHeaders(token),
      timeout: _httpTimeout,
    );
    if (!response.isSuccess || !response.isAuthenticWatSafe) {
      return const <AuthorizedDeviceLocationSummary>[];
    }
    try {
      final decoded = jsonDecode(response.body) as Map<String, Object?>;
      final rawDevices =
          decoded['devices'] as List<Object?>? ?? const <Object?>[];
      return rawDevices
          .whereType<Map<Object?, Object?>>()
          .map(
            (item) => AuthorizedDeviceLocationSummary.fromJson(
              Map<String, Object?>.from(item),
            ),
          )
          .toList(growable: false);
    } catch (_) {
      return const <AuthorizedDeviceLocationSummary>[];
    }
  }

  @override
  Future<bool> deleteRelayLocationHistory() async {
    await _ensureLoaded();
    var ok = true;
    final hostUrl = _relayEndpointUrl;
    final hToken = _hostToken;
    if (hostUrl != null &&
        hostUrl.isNotEmpty &&
        hToken != null &&
        hToken.isNotEmpty) {
      final res = await sendRelayJsonRequest(
        method: 'DELETE',
        url: '$hostUrl/v1/location-history',
        headers: _bearerHeaders(hToken),
        timeout: _httpTimeout,
      );
      ok = ok && res.isSuccess;
    }
    final compUrl = _companionSession.relayEndpointUrl ?? _relayEndpointUrl;
    final cToken = _companionToken;
    if (compUrl != null &&
        compUrl.isNotEmpty &&
        cToken != null &&
        cToken.isNotEmpty &&
        cToken != hToken) {
      final res = await sendRelayJsonRequest(
        method: 'DELETE',
        url: '$compUrl/v1/location-history',
        headers: _bearerHeaders(cToken),
        timeout: _httpTimeout,
      );
      ok = ok && res.isSuccess;
    }
    if (_receivedCompanionAlerts.isNotEmpty) {
      _receivedCompanionAlerts = _receivedCompanionAlerts
          .map(
            (item) => CompanionAlertEvent(
              alertSeq: item.alertSeq,
              updatedSeq: item.updatedSeq,
              pairingSessionId: item.pairingSessionId,
              incidentId: item.incidentId,
              sessionId: item.sessionId,
              kind: item.kind,
              detectorType: item.detectorType,
              triggeredAt: item.triggeredAt,
              triggerSummary: item.triggerSummary,
              peakMotionScore: item.peakMotionScore,
              hostDisplayName: item.hostDisplayName,
              isTest: item.isTest,
              location: null,
              alarmTimeLocation: null,
              locationTrail: const <DeviceLocationSnapshot>[],
              locationStatus: IncidentLocationStatus.notRequested,
              locationTrackingState: 'stopped',
            ),
          )
          .toList(growable: false);
      await _persistState();
      _onStateChanged?.call();
    }
    return ok;
  }

  /// Polls the authenticated companion alert feed once (`GET /v1/companion/alerts`).
  ///
  /// When [replayFromZero] is true (e.g., to test reconnect replay safety),
  /// requests `afterSeq=0` while still enforcing client-side `incidentId`
  /// deduplication so previously received alerts are never duplicated.
  @override
  Future<List<CompanionAlertEvent>> pollCompanionAlertsOnce({
    bool replayFromZero = false,
  }) {
    final existing = _inFlightPoll;
    if (existing != null && !replayFromZero) {
      return existing;
    }
    final future = _executeCompanionPoll(replayFromZero: replayFromZero);
    _inFlightPoll = future;
    return future.whenComplete(() {
      if (identical(_inFlightPoll, future)) {
        _inFlightPoll = null;
      }
    });
  }

  Future<List<CompanionAlertEvent>> _executeCompanionPoll({
    required bool replayFromZero,
  }) async {
    await _ensureLoaded();
    final token = _companionToken;
    final url = _companionSession.relayEndpointUrl ?? _relayEndpointUrl;
    if (token == null || token.isEmpty || url == null || url.isEmpty) {
      return const <CompanionAlertEvent>[];
    }

    final cursor = replayFromZero ? 0 : _companionLastAlertSeq;
    final response = await sendRelayJsonRequest(
      method: 'GET',
      url: '$url/v1/companion/alerts?afterSeq=$cursor',
      headers: _bearerHeaders(token),
      timeout: _httpTimeout,
    );

    if (response.statusCode == 401 &&
        response.isAuthenticWatSafe &&
        _isAuthenticErrorCode(
          response.body,
          'UNAUTHORIZED_COMPANION_SESSION',
        )) {
      _consecutiveCompanionFailures = 0;
      _companionPollTimer?.cancel();
      _companionPollTimer = null;
      _companionToken = null;
      _companionSession = CompanionSessionState(
        isConnected: false,
        pairingSessionId: _companionSession.pairingSessionId,
        hostDisplayName: _companionSession.hostDisplayName,
        phoneDisplayName: _companionSession.phoneDisplayName,
        relayEndpointUrl: url,
        statusMessage: 'Disconnected — this phone is no longer paired.',
      );
      await _persistState();
      _onStateChanged?.call();
      return const <CompanionAlertEvent>[];
    }

    if (!response.isSuccess || !response.isAuthenticWatSafe) {
      _consecutiveCompanionFailures += 1;
      final shift = min(_consecutiveCompanionFailures - 1, 4);
      final backoffSeconds = min(
        30,
        max(2, pollInterval.inSeconds) * (1 << shift),
      );
      _nextAllowedBackgroundCompanionPollAt = _clock().add(
        Duration(seconds: backoffSeconds),
      );
      _companionSession = _companionSession.copyWith(
        isConnected: true,
        relayEndpointUrl: url,
        statusMessage: 'Service temporarily unavailable — retrying…',
      );
      _onStateChanged?.call();
      return const <CompanionAlertEvent>[];
    }

    _consecutiveCompanionFailures = 0;
    _nextAllowedBackgroundCompanionPollAt = null;

    final newlyDelivered = <CompanionAlertEvent>[];
    bool updatedExistingInPlace = false;
    try {
      final decoded = jsonDecode(response.body) as Map<String, Object?>;
      final latestSeq =
          (decoded['latestSeq'] as num?)?.toInt() ?? _companionLastAlertSeq;
      final hostName =
          decoded['hostDisplayName'] as String? ??
          _companionSession.hostDisplayName;
      final hostOnline = decoded['hostOnline'] as bool? ?? true;
      final rawAlerts =
          decoded['alerts'] as List<Object?>? ?? const <Object?>[];

      for (final item in rawAlerts.whereType<Map<Object?, Object?>>()) {
        final alert = CompanionAlertEvent.fromJson(
          Map<String, Object?>.from(item),
        );
        if (alert.effectiveCursorSeq > _companionLastAlertSeq) {
          _companionLastAlertSeq = alert.effectiveCursorSeq;
        }
        // Client-side incidentId deduplication ensures reconnects, cursor
        // replays, or asynchronous location updates never emit duplicate alerts.
        if (alert.incidentId.isNotEmpty) {
          if (_seenCompanionIncidentIds.add(alert.incidentId)) {
            newlyDelivered.add(alert);
            _receivedCompanionAlerts = <CompanionAlertEvent>[
              alert,
              ..._receivedCompanionAlerts,
            ];
            if (!_incomingAlertsController.isClosed) {
              _incomingAlertsController.add(alert);
            }
          } else {
            final idx = _receivedCompanionAlerts.indexWhere(
              (existing) => existing.incidentId == alert.incidentId,
            );
            if (idx >= 0) {
              final prior = _receivedCompanionAlerts[idx];
              final clearedLoc =
                  alert.location == null &&
                  alert.locationStatus == IncidentLocationStatus.notRequested &&
                  prior.location != null;
              if (clearedLoc ||
                  alert.location != null ||
                  alert.locationStatus != prior.locationStatus ||
                  alert.locationTrackingState != prior.locationTrackingState ||
                  alert.locationTrail.length != prior.locationTrail.length) {
                final nextList = List<CompanionAlertEvent>.from(
                  _receivedCompanionAlerts,
                );
                nextList[idx] = clearedLoc
                    ? CompanionAlertEvent(
                        alertSeq: prior.alertSeq,
                        updatedSeq: alert.updatedSeq ?? prior.updatedSeq,
                        pairingSessionId: prior.pairingSessionId,
                        incidentId: prior.incidentId,
                        sessionId: prior.sessionId,
                        kind: prior.kind,
                        detectorType: prior.detectorType,
                        triggeredAt: prior.triggeredAt,
                        triggerSummary: prior.triggerSummary,
                        peakMotionScore: prior.peakMotionScore,
                        hostDisplayName: prior.hostDisplayName,
                        isTest: prior.isTest,
                        location: null,
                        alarmTimeLocation: null,
                        locationTrail: const <DeviceLocationSnapshot>[],
                        locationStatus: IncidentLocationStatus.notRequested,
                        locationTrackingState: alert.locationTrackingState,
                      )
                    : prior.copyWith(
                        updatedSeq: alert.updatedSeq ?? prior.updatedSeq,
                        location: alert.location ?? prior.location,
                        alarmTimeLocation:
                            alert.alarmTimeLocation ?? prior.alarmTimeLocation,
                        locationTrail: alert.locationTrail.isNotEmpty
                            ? alert.locationTrail
                            : prior.locationTrail,
                        locationStatus: alert.locationStatus,
                        locationTrackingState: alert.locationTrackingState,
                      );
                _receivedCompanionAlerts = nextList;
                updatedExistingInPlace = true;
              }
            }
          }
        }
      }

      if (latestSeq > _companionLastAlertSeq) {
        _companionLastAlertSeq = latestSeq;
      }

      _companionSession = _companionSession.copyWith(
        isConnected: true,
        hostDisplayName: hostName,
        relayEndpointUrl: url,
        statusMessage: hostOnline
            ? 'Connected to ${hostName ?? "your laptop"}.'
            : 'Laptop offline — paired with ${hostName ?? "your laptop"}.',
      );

      if (newlyDelivered.isNotEmpty || updatedExistingInPlace) {
        await _persistState();
      }
      _onStateChanged?.call();
    } catch (_) {
      // Ignore malformed JSON
    }

    return newlyDelivered;
  }

  /// Rotates this companion phone's bearer credential cleanly via
  /// `POST /v1/companion/token/refresh` (with a 60-second grace window on the
  /// previous token) without re-pairing.
  Future<bool> refreshCompanionCredential() async {
    await _ensureLoaded();
    final token = _companionToken;
    final url = _companionSession.relayEndpointUrl ?? _relayEndpointUrl;
    if (token == null || token.isEmpty || url == null || url.isEmpty) {
      return false;
    }
    final res = await sendRelayJsonRequest(
      method: 'POST',
      url: '$url/v1/companion/token/refresh',
      headers: _bearerHeaders(token),
      body: const <String, Object?>{},
      timeout: _httpTimeout,
    );
    if (!res.isSuccess || !res.isAuthenticWatSafe) {
      return false;
    }
    try {
      final decoded = jsonDecode(res.body) as Map<String, Object?>;
      final rotated = decoded['companionToken'] as String?;
      if (rotated != null && rotated.isNotEmpty) {
        _companionToken = rotated;
        await _persistState();
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Future<void> disconnectCompanionSession() async {
    await _ensureLoaded();
    final token = _companionToken;
    final url = _companionSession.relayEndpointUrl ?? _relayEndpointUrl;
    _companionPollTimer?.cancel();
    _companionPollTimer = null;
    _companionToken = null;
    _companionSession = CompanionSessionState.disconnected;
    if (token != null && token.isNotEmpty && url != null && url.isNotEmpty) {
      await sendRelayJsonRequest(
        method: 'POST',
        url: '$url/v1/companion/disconnect',
        headers: _bearerHeaders(token),
        body: const <String, Object?>{},
        timeout: _httpTimeout,
      );
    }
    await _persistState();
    _onStateChanged?.call();
  }

  @override
  Future<void> resetInstallationPairingAndPush({
    String? defaultRelayUrl,
  }) async {
    await _ensureLoaded();
    ++_deviceMutationEpoch;
    _hostSyncTimer?.cancel();
    _hostSyncTimer = null;
    _armedHeartbeatTimer?.cancel();
    _armedHeartbeatTimer = null;
    _hostArmed = false;
    _hostArmedSessionId = null;
    _companionPollTimer?.cancel();
    _companionPollTimer = null;

    final currentUrl = _relayEndpointUrl;
    final currentHostToken = _hostToken;
    final companionUrl = _companionSession.relayEndpointUrl ?? currentUrl;
    final currentCompanionToken = _companionToken;

    if (currentUrl != null &&
        currentUrl.isNotEmpty &&
        currentHostToken != null &&
        currentHostToken.isNotEmpty) {
      await sendRelayJsonRequest(
        method: 'POST',
        url: '$currentUrl/v1/pairing/session/revoke',
        headers: _bearerHeaders(currentHostToken),
        body: const <String, Object?>{},
        timeout: _httpTimeout,
      );
    }

    if (companionUrl != null &&
        companionUrl.isNotEmpty &&
        currentCompanionToken != null &&
        currentCompanionToken.isNotEmpty) {
      await sendRelayJsonRequest(
        method: 'POST',
        url: '$companionUrl/v1/companion/disconnect',
        headers: _bearerHeaders(currentCompanionToken),
        body: const <String, Object?>{},
        timeout: _httpTimeout,
      );
    }

    ++_deviceMutationEpoch;
    _hostPairingSessionId = null;
    _hostToken = null;
    _activePairingInvitation = null;
    _devices = <PairedDeviceSummary>[];
    _actions = <PairedDeviceActionRecord>[];
    _companionToken = null;
    _companionLastAlertSeq = 0;
    _seenCompanionIncidentIds.clear();
    _receivedCompanionAlerts = <CompanionAlertEvent>[];
    _companionSession = CompanionSessionState.disconnected;
    _credentialsByOrigin.clear();
    _consecutiveHostSyncFailures = 0;
    if (!_hostArmed && _pendingVerifiedDisarmSync) {
      _pendingVerifiedDisarmSync = false;
    }
    _consecutiveCompanionFailures = 0;
    _nextAllowedBackgroundHostSyncAt = null;
    if (defaultRelayUrl != null) {
      _relayEndpointUrl = _normalizeUrl(defaultRelayUrl);
    }

    if (persistToDisk) {
      try {
        await deleteSecurePersistedSecret(
          _secureCredentialKey,
          storageDirectory: _storageDirectory,
        );
        await writePersistedJson(
          _outboxFileName,
          '[]',
          storageDirectory: _storageDirectory,
        );
      } catch (_) {}
    }
    await _persistState();
    _onStateChanged?.call();
  }

  @override
  Future<NotificationDispatchResult> sendUrgentPreSuspensionAlert(
    IncidentRecord incident,
  ) async {
    await _ensureLoaded();
    final hasUrl = _relayEndpointUrl != null && _relayEndpointUrl!.isNotEmpty;
    final connectedDevices = _devices.where((d) => d.connected).toList();
    if (!hasUrl && connectedDevices.isEmpty) {
      return const NotificationDispatchResult(
        delivered: false,
        capabilityStatus: CapabilityStatus.notConfigured,
        message: 'No phone paired',
      );
    }

    final payload = <String, Object?>{
      'incidentId': incident.id,
      'sessionId': incident.sessionId,
      'kind': incident.kind.name,
      'detectorType': incident.detectorType?.id ?? 'unknown',
      'triggeredAtUtc': incident.triggeredAt.toUtc().toIso8601String(),
      'peakMotionScore': incident.peakMotionScore,
      'triggerSummary': incident.triggerSummary,
      'deviceName': ?incident.deviceName,
      'isTest': incident.isTest,
      'locationStatus': incident.locationStatus.name,
      if (incident.location != null) 'location': incident.location!.toJson(),
    };

    if (hasUrl && _hostToken != null && _hostToken!.isNotEmpty) {
      final postResult = await sendRelayJsonRequest(
        method: 'POST',
        url: '$_relayEndpointUrl/v1/incidents:report',
        headers: _bearerHeaders(_hostToken!),
        body: payload,
        timeout: const Duration(milliseconds: 3800),
      );
      Map<String, Object?>? responseJson;
      if (postResult.isSuccess && postResult.body.isNotEmpty) {
        try {
          final decoded = jsonDecode(postResult.body);
          if (decoded is Map) {
            responseJson = Map<String, Object?>.from(decoded);
          }
        } catch (_) {}
      }
      final serverDelivered =
          postResult.isSuccess && (responseJson?['delivered'] as bool? ?? true);
      final relayRecorded =
          postResult.isSuccess &&
          (responseJson?['alertRecorded'] as bool? ?? true);
      final pushAcceptedCount =
          (responseJson?['pushAcceptedCount'] as num?)?.toInt() ??
          (responseJson?['pushDispatchedCount'] as num?)?.toInt() ??
          0;
      final receiptConfirmed =
          responseJson?['receiptConfirmed'] as bool? ?? false;
      final deliveryStage =
          responseJson?['deliveryStage'] as String? ??
          (postResult.isSuccess ? 'companion_poll_queued' : 'network_error');
      if (postResult.isSuccess) {
        unawaited(_appendAlertToLocalOutbox(payload));
      }
      return NotificationDispatchResult(
        delivered: serverDelivered,
        capabilityStatus: postResult.isSuccess
            ? CapabilityStatus.ready
            : CapabilityStatus.degraded,
        message: postResult.isSuccess
            ? (pushAcceptedCount > 0
                  ? 'Urgent pre-sleep alert accepted by push service'
                  : 'Urgent pre-sleep alert recorded on relay')
            : 'Pre-sleep alert could not reach relay before suspension; server watchdog will follow up',
        relayRecorded: relayRecorded,
        pushAccepted: pushAcceptedCount > 0,
        receiptConfirmed: receiptConfirmed,
        deliveryStage: deliveryStage,
      );
    }

    if (!hasUrl && connectedDevices.isNotEmpty) {
      return sendIncidentAlert(incident);
    }

    return const NotificationDispatchResult(
      delivered: false,
      capabilityStatus: CapabilityStatus.degraded,
      message: 'No active host pairing session for urgent pre-sleep alert',
    );
  }

  @override
  Future<NotificationDispatchResult> sendIncidentAlert(
    IncidentRecord incident,
  ) async {
    await _ensureLoaded();
    final hasUrl = _relayEndpointUrl != null && _relayEndpointUrl!.isNotEmpty;
    if (_devices.isEmpty && !hasUrl) {
      return const NotificationDispatchResult(
        delivered: false,
        capabilityStatus: CapabilityStatus.notConfigured,
        message: 'No phone paired',
      );
    }

    // If a pairing code was recently issued on this laptop session, sync once
    // before checking `_devices` so a phone that just paired still receives the alert.
    if (hasUrl && _hostToken != null && _devices.isEmpty) {
      await syncPairedDevicesFromRelay();
    }

    final connectedDevices = _devices.where((d) => d.connected).toList();
    if (connectedDevices.isEmpty) {
      return const NotificationDispatchResult(
        delivered: false,
        capabilityStatus: CapabilityStatus.degraded,
        message: 'No connected phone to alert',
      );
    }

    final now = _clock();
    // Strict privacy & credential invariant: whitelisted incident metadata ONLY.
    // Never camera frames, images, PINs/PIN hashes, or database credentials.
    final payload = <String, Object?>{
      'incidentId': incident.id,
      'sessionId': incident.sessionId,
      'kind': incident.kind.name,
      'detectorType': incident.detectorType?.id ?? 'unknown',
      'triggeredAtUtc': incident.triggeredAt.toUtc().toIso8601String(),
      'peakMotionScore': incident.peakMotionScore,
      'triggerSummary': incident.triggerSummary,
      'deviceName': ?incident.deviceName,
      'isTest': incident.isTest,
      'locationStatus': incident.locationStatus.name,
      if (incident.location != null) 'location': incident.location!.toJson(),
    };

    if (hasUrl) {
      if (_hostToken == null || _hostToken!.isEmpty) {
        await initiateHostPairing(hostDisplayName: incident.deviceName);
      }
      final isRemoteHttps = _relayEndpointUrl!.startsWith('https://');
      final alertTimeout = isRemoteHttps && _httpTimeout.inSeconds < 25
          ? const Duration(seconds: 25)
          : _httpTimeout;
      var postResult = await sendRelayJsonRequest(
        method: 'POST',
        url: '$_relayEndpointUrl/v1/incidents:report',
        headers: _hostToken != null ? _bearerHeaders(_hostToken!) : null,
        body: payload,
        timeout: alertTimeout,
      );
      var retryCount = 0;
      while (!postResult.isSuccess &&
          isRemoteHttps &&
          retryCount < 2 &&
          (postResult.statusCode == 0 || postResult.statusCode >= 500)) {
        retryCount += 1;
        await Future<void>.delayed(const Duration(seconds: 2));
        postResult = await sendRelayJsonRequest(
          method: 'POST',
          url: '$_relayEndpointUrl/v1/incidents:report',
          headers: _hostToken != null ? _bearerHeaders(_hostToken!) : null,
          body: payload,
          timeout: alertTimeout,
        );
      }
      Map<String, Object?>? responseJson;
      if (postResult.isSuccess && postResult.body.isNotEmpty) {
        try {
          final decoded = jsonDecode(postResult.body);
          if (decoded is Map) {
            responseJson = Map<String, Object?>.from(decoded);
          }
        } catch (_) {}
      }

      final names = connectedDevices
          .map((d) => '"${d.displayName}"')
          .join(', ');
      final relayRecorded =
          postResult.isSuccess &&
          (responseJson?['alertRecorded'] as bool? ?? true);
      final pushAcceptedCount =
          (responseJson?['pushAcceptedCount'] as num?)?.toInt() ??
          (responseJson?['pushDispatchedCount'] as num?)?.toInt() ??
          0;
      final pushFailedCount =
          (responseJson?['pushFailedCount'] as num?)?.toInt() ?? 0;
      final webMissingPushCount =
          (responseJson?['webBondsMissingPushCount'] as num?)?.toInt() ?? 0;
      final receiptConfirmed =
          responseJson?['receiptConfirmed'] as bool? ?? false;
      final deliveryStage =
          responseJson?['deliveryStage'] as String? ??
          (postResult.isSuccess ? 'companion_poll_queued' : 'network_error');
      final rawReasons = responseJson?['pushFailureReasons'];
      final failureReasons = rawReasons is List
          ? rawReasons.map((e) => '$e').where((s) => s.isNotEmpty).toList()
          : const <String>[];
      final serverDelivered =
          postResult.isSuccess && (responseJson?['delivered'] as bool? ?? true);

      String statusMsg;
      String actionLabel;
      CapabilityStatus capStatus;
      if (!postResult.isSuccess) {
        statusMsg = 'Could not reach phone alert service right now';
        actionLabel = 'Alert service unreachable';
        capStatus = CapabilityStatus.degraded;
      } else if (receiptConfirmed) {
        statusMsg = 'Phone receipt confirmed on $names';
        actionLabel = 'Phone receipt confirmed';
        capStatus = CapabilityStatus.ready;
      } else if (pushAcceptedCount > 0) {
        statusMsg =
            'Push service accepted alert for $names — awaiting phone receipt';
        actionLabel = 'Push service accepted (awaiting phone receipt)';
        capStatus = CapabilityStatus.ready;
      } else if (pushFailedCount > 0) {
        final reasonSuffix = failureReasons.isNotEmpty
            ? ' (${failureReasons.join(", ")})'
            : '';
        statusMsg =
            'Push delivery rejected$reasonSuffix — recorded in Activity only. Open WATSafe on $names and tap Repair notifications.';
        actionLabel = 'Push rejected — repair on phone';
        capStatus = CapabilityStatus.degraded;
      } else if (webMissingPushCount > 0 || !serverDelivered) {
        statusMsg =
            'Recorded in Activity only — finish enabling notifications on $names for lock-screen alerts.';
        actionLabel = 'Notifications not enabled on phone';
        capStatus = CapabilityStatus.degraded;
      } else {
        statusMsg =
            'Delivered via HTTP relay to ${connectedDevices.length} paired device(s) — awaiting phone receipt';
        actionLabel = incident.isTest
            ? 'Queued on relay (awaiting receipt)'
            : 'Alarm queued on relay (awaiting receipt)';
        capStatus = CapabilityStatus.ready;
      }

      _devices = _devices
          .map(
            (d) => d.connected
                ? d.copyWith(
                    remoteStateLabel: postResult.isSuccess
                        ? 'Phone connected'
                        : 'Connection issue',
                    lastActionSummary: actionLabel,
                    lastSeenAt: now,
                  )
                : d,
          )
          .toList();
      for (final d in connectedDevices) {
        _recordAction(
          deviceId: d.deviceId,
          deviceName: d.displayName,
          commandType: PairedDeviceCommandType.sendTestPush,
          timestamp: now,
          delivered: serverDelivered,
          summary: serverDelivered
              ? (receiptConfirmed
                    ? '${incident.isTest ? "Test alert" : "Alarm alert"} receipt confirmed on "${d.displayName}".'
                    : (pushAcceptedCount > 0
                          ? 'Push service accepted ${incident.isTest ? "test alert" : "alarm alert"} for "${d.displayName}" (awaiting phone receipt).'
                          : '${incident.isTest ? "Test alert" : "Alarm alert"} queued on relay for "${d.displayName}".'))
              : statusMsg,
        );
      }
      if (postResult.isSuccess) {
        await _appendAlertToLocalOutbox(payload);
      }
      await _persistState();
      return NotificationDispatchResult(
        delivered: serverDelivered,
        capabilityStatus: capStatus,
        message: statusMsg,
        relayRecorded: relayRecorded,
        pushAccepted: pushAcceptedCount > 0,
        receiptConfirmed: receiptConfirmed,
        deliveryStage: deliveryStage,
      );
    }

    _devices = _devices
        .map(
          (d) => d.copyWith(
            remoteStateLabel: 'Phone connected',
            lastActionSummary: incident.isTest
                ? 'Test alert sent'
                : 'Alarm alert sent',
            lastSeenAt: now,
          ),
        )
        .toList();
    for (final d in connectedDevices) {
      _recordAction(
        deviceId: d.deviceId,
        deviceName: d.displayName,
        commandType: PairedDeviceCommandType.sendTestPush,
        timestamp: now,
        delivered: true,
        summary:
            '${incident.isTest ? "Test alert" : "Alarm alert"} sent to "${d.displayName}".',
      );
    }
    await _appendAlertToLocalOutbox(payload);
    await _persistState();
    final names = connectedDevices.map((d) => d.displayName).join(', ');
    return NotificationDispatchResult(
      delivered: true,
      capabilityStatus: CapabilityStatus.ready,
      message:
          'Dispatched to ${connectedDevices.length} paired device(s): $names',
    );
  }

  void _startHostSyncTimerIfNeeded() {
    if (!enableBackgroundPolling || !_foregroundActive || _disposed) {
      return;
    }
    _hostSyncTimer?.cancel();
    _hostSyncTimer = Timer.periodic(pollInterval, (_) {
      if (_disposed || !_foregroundActive) {
        return;
      }
      if (_hostToken == null || _hostToken!.isEmpty) {
        _hostSyncTimer?.cancel();
        _hostSyncTimer = null;
        return;
      }
      final nextAllowed = _nextAllowedBackgroundHostSyncAt;
      if (nextAllowed != null && _clock().isBefore(nextAllowed)) {
        return;
      }
      unawaited(syncPairedDevicesFromRelay());
    });
  }

  void _startCompanionPollTimerIfNeeded() {
    if (!enableBackgroundPolling ||
        !_foregroundActive ||
        _disposed ||
        _companionToken == null) {
      return;
    }
    _companionPollTimer?.cancel();
    _companionPollTimer = Timer.periodic(pollInterval, (_) {
      if (_disposed || !_foregroundActive || _companionToken == null) {
        return;
      }
      final nextAllowed = _nextAllowedBackgroundCompanionPollAt;
      if (nextAllowed != null && _clock().isBefore(nextAllowed)) {
        return;
      }
      unawaited(pollCompanionAlertsOnce());
    });
  }

  @override
  void setForegroundActive(bool active) {
    if (_foregroundActive == active) {
      return;
    }
    _foregroundActive = active;
    if (!active) {
      _hostSyncTimer?.cancel();
      _hostSyncTimer = null;
      _companionPollTimer?.cancel();
      _companionPollTimer = null;
    } else {
      if (_hostToken != null && _hostToken!.isNotEmpty) {
        unawaited(syncPairedDevicesFromRelay());
        _startHostSyncTimerIfNeeded();
      }
      if (_companionToken != null) {
        unawaited(pollCompanionAlertsOnce());
        _startCompanionPollTimerIfNeeded();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _onStateChanged = null;
    _hostSyncTimer?.cancel();
    _hostSyncTimer = null;
    _armedHeartbeatTimer?.cancel();
    _armedHeartbeatTimer = null;
    _companionPollTimer?.cancel();
    _companionPollTimer = null;
    if (!_incomingAlertsController.isClosed) {
      unawaited(_incomingAlertsController.close());
    }
    if (!_companionSensorController.isClosed) {
      unawaited(_companionSensorController.close());
    }
  }

  Future<void> _appendAlertToLocalOutbox(Map<String, Object?> payload) async {
    if (!persistToDisk) {
      return;
    }
    try {
      List<Object?> existing = <Object?>[];
      final content = await readPersistedJson(
        _outboxFileName,
        storageDirectory: _storageDirectory,
      );
      if (content != null && content.trim().isNotEmpty) {
        final parsed = jsonDecode(content);
        if (parsed is List<Object?>) {
          existing = parsed;
        }
      }
      existing.insert(0, payload);
      if (existing.length > 50) {
        existing = existing.sublist(0, 50);
      }
      await writePersistedJson(
        _outboxFileName,
        const JsonEncoder.withIndent('  ').convert(existing),
        storageDirectory: _storageDirectory,
      );
    } catch (_) {
      // Non-fatal
    }
  }
}
