import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/contracts/platform_contracts.dart';
import '../core/models/detector_models.dart';
import '../core/models/incident_models.dart';
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
      summary: 'Not configured',
      detail:
          'Remote device pairing and APNs/FCM push notifications are not configured in this local milestone. '
          'Server credentials remain strictly server-side once the backend service is deployed.',
    );
  }

  @override
  Future<List<PairedDeviceSummary>> listPairedDevices() async {
    // Never fabricate paired devices; only return real paired devices when configured.
    return const <PairedDeviceSummary>[];
  }

  @override
  Future<NotificationDispatchResult> sendIncidentAlert(
    IncidentRecord incident,
  ) async {
    return const NotificationDispatchResult(
      delivered: false,
      capabilityStatus: CapabilityStatus.notConfigured,
      message: 'Not configured (local-only milestone)',
    );
  }
}

/// Parsed representation of a short-lived pairing code or `watsafe://pair?...`
/// QR link.
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
/// - Laptop host session initiation with short-lived single-use pairing codes & QR payloads
/// - Companion phone pairing, foreground live alert polling, and reconnect deduplication
/// - Authenticated session-scoped HTTP relay delivery (`POST /v1/incidents:report`)
/// - Local persistence (`watsafe_paired_devices.json`) without leaking credentials
///
/// Security & Privacy invariants:
/// - Never transmits camera frames, images, PINs/PIN hashes, or DB credentials.
/// - Reports `CapabilityStatus.notConfigured` until a device is paired or a relay URL is configured.
class ConfigurableRemoteNotificationService
    implements MutableRemoteNotificationAdapter {
  ConfigurableRemoteNotificationService({
    Object? storageDirectory,
    this.persistToDisk = true,
    this.enableBackgroundPolling = false,
    this.pollInterval = const Duration(seconds: 2),
    String? initialRelayEndpointUrl,
    List<PairedDeviceSummary>? initialDevices,
    Duration httpTimeout = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _storageDirectory = storageDirectory,
       _httpTimeout = httpTimeout,
       _clock = clock ?? DateTime.now,
       _relayEndpointUrl = _normalizeUrl(
         initialRelayEndpointUrl ??
             const String.fromEnvironment('WATSAFE_API_URL'),
       ),
       _devices = List<PairedDeviceSummary>.from(
         initialDevices ?? const <PairedDeviceSummary>[],
       );

  static const String _stateFileName = 'watsafe_paired_devices.json';
  static const String _outboxFileName = 'watsafe_companion_alerts.json';

  final Object? _storageDirectory;
  final bool persistToDisk;
  final bool enableBackgroundPolling;
  final Duration pollInterval;
  final Duration _httpTimeout;
  final DateTime Function() _clock;

  final StreamController<CompanionAlertEvent> _incomingAlertsController =
      StreamController<CompanionAlertEvent>.broadcast();

  VoidCallback? _onStateChanged;
  String? _relayEndpointUrl;
  List<PairedDeviceSummary> _devices;

  // Protected Laptop Host session state
  String? _hostPairingSessionId;
  String? _hostToken;
  PairingCodeInvitation? _activePairingInvitation;
  Timer? _hostSyncTimer;

  // Paired Companion Phone session state
  String? _companionToken;
  CompanionSessionState _companionSession = CompanionSessionState.disconnected;
  int _companionLastAlertSeq = 0;
  final Set<String> _seenCompanionIncidentIds = <String>{};
  List<CompanionAlertEvent> _receivedCompanionAlerts = <CompanionAlertEvent>[];
  Timer? _companionPollTimer;
  Future<List<CompanionAlertEvent>>? _inFlightPoll;

  bool _foregroundActive = true;
  bool _disposed = false;
  bool _loadedFromDisk = false;
  int _deviceCounter = 0;

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

  /// Parses either a plain 6-character code (`K7M-4P9`), a `watsafe://pair?...`
  /// QR URI, or a JSON QR object `{ "code": "...", "relay": "..." }`.
  static ParsedPairingInput parsePairingInput(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) {
      return const ParsedPairingInput(pairingCode: '');
    }

    if (trimmed.toLowerCase().startsWith('watsafe://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null) {
        return ParsedPairingInput(
          pairingCode: (uri.queryParameters['code'] ?? '').trim(),
          relayEndpointUrl: _normalizeUrl(uri.queryParameters['relay']),
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
      return;
    }
    try {
      final raw = await readPersistedJson(
        _stateFileName,
        storageDirectory: _storageDirectory,
      );
      if (raw == null || raw.trim().isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      final savedUrl = _normalizeUrl(decoded['relayEndpointUrl'] as String?);
      if (savedUrl != null) {
        _relayEndpointUrl = savedUrl;
      }
      _hostPairingSessionId = decoded['hostPairingSessionId'] as String?;
      _hostToken = decoded['hostToken'] as String?;

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

      _companionToken = decoded['companionToken'] as String?;
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
          statusMessage: cs['statusMessage'] as String?,
        );
        _startCompanionPollTimerIfNeeded();
      }
    } catch (_) {
      // Keep in-memory state if storage read fails
    }
  }

  Future<void> _persistState() async {
    if (!persistToDisk) {
      return;
    }
    try {
      final payload = <String, Object?>{
        'relayEndpointUrl': _relayEndpointUrl,
        'hostPairingSessionId': _hostPairingSessionId,
        'hostToken': _hostToken,
        'pairedDevices': _devices.map((d) => d.toJson()).toList(),
        'companionToken': _companionToken,
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
      return NotificationServiceStatus(
        capabilityStatus: CapabilityStatus.ready,
        summary:
            'Connected to ${_companionSession.hostDisplayName ?? "Laptop"} (Companion Mode)',
        detail:
            'Receiving live foreground alerts for session ${_companionSession.pairingSessionId ?? "active"} '
            'via ${_companionSession.relayEndpointUrl ?? _relayEndpointUrl ?? "relay"}. '
            'Keep WATSafe open in the foreground to receive alerts immediately (background push requires APNs/FCM deployment keys).',
      );
    }

    if (_devices.isEmpty && !hasUrl) {
      return const NotificationServiceStatus(
        capabilityStatus: CapabilityStatus.notConfigured,
        summary: 'Not configured',
        detail:
            'No companion devices paired yet. Pair a companion phone below or configure a backend relay URL to enable remote incident alerts.',
      );
    }

    if (_devices.isEmpty && hasUrl) {
      final invite = _activePairingInvitation;
      final hasActiveCode = invite != null && !invite.isExpiredAt(_clock());
      return NotificationServiceStatus(
        capabilityStatus: CapabilityStatus.degraded,
        summary: hasActiveCode
            ? 'Awaiting phone pairing (Code ${invite.pairingCode})'
            : 'Relay configured (0 paired devices)',
        detail: hasActiveCode
            ? 'Enter pairing code ${invite.pairingCode} or scan the QR payload on your phone within '
                  '${invite.remainingSecondsAt(_clock())}s to link it to this laptop session.'
            : 'Connected to relay endpoint $_relayEndpointUrl, but no companion devices are paired yet. '
                  'Generate a pairing code & QR below to connect your phone.',
      );
    }

    final modeLabel = hasUrl
        ? 'HTTP Relay ($_relayEndpointUrl)'
        : 'Local Companion Outbox Relay';
    return NotificationServiceStatus(
      capabilityStatus: CapabilityStatus.ready,
      summary:
          'Connected (${_devices.length} paired device${_devices.length == 1 ? '' : 's'})',
      detail:
          'Active session-scoped alert routing via $modeLabel to '
          '${_devices.map((d) => "${d.displayName} (${d.platform})").join(", ")}. '
          'Payloads contain metadata only (never camera frames, PINs, or database credentials).',
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
      _relayEndpointUrl = normalized;
      _activePairingInvitation = null;
    }
    await _persistState();
  }

  @override
  Future<PairingCodeInvitation> initiateHostPairing({
    String? hostDisplayName,
  }) async {
    await _ensureLoaded();
    final url = _relayEndpointUrl;
    if (url == null || url.isEmpty) {
      throw StateError(
        'Configure and save a Backend Relay URL (for example http://<laptop-lan-ip>:8787) before generating a live pairing code.',
      );
    }

    final response = await sendRelayJsonRequest(
      method: 'POST',
      url: '$url/v1/pairing/initiate',
      headers: _hostToken != null ? _bearerHeaders(_hostToken!) : null,
      body: <String, Object?>{
        'hostDisplayName': (hostDisplayName?.trim().isNotEmpty == true)
            ? hostDisplayName!.trim()
            : 'WATSafe Laptop',
        'relayUrl': url,
      },
      timeout: _httpTimeout,
    );

    if (!response.isSuccess) {
      throw StateError(
        'Could not initiate pairing with relay $url (${response.errorSummary ?? "HTTP ${response.statusCode}"}).',
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

    if (sessionId.isEmpty || hostToken.isEmpty || code.isEmpty) {
      throw StateError(
        'Relay returned an incomplete pairing session response.',
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
    );

    await _persistState();
    _startHostSyncTimerIfNeeded();
    _onStateChanged?.call();
    return _activePairingInvitation!;
  }

  @override
  Future<List<PairedDeviceSummary>> syncPairedDevicesFromRelay() async {
    await _ensureLoaded();
    final url = _relayEndpointUrl;
    final token = _hostToken;
    if (url == null || url.isEmpty || token == null || token.isEmpty) {
      return List<PairedDeviceSummary>.unmodifiable(_devices);
    }

    final response = await sendRelayJsonRequest(
      method: 'GET',
      url: '$url/v1/pairing/devices',
      headers: _bearerHeaders(token),
      timeout: _httpTimeout,
    );
    if (!response.isSuccess) {
      return List<PairedDeviceSummary>.unmodifiable(_devices);
    }

    try {
      final decoded = jsonDecode(response.body) as Map<String, Object?>;
      final rawList = decoded['devices'] as List<Object?>? ?? const <Object?>[];
      final updated = rawList
          .whereType<Map<Object?, Object?>>()
          .map(
            (item) =>
                PairedDeviceSummary.fromJson(Map<String, Object?>.from(item)),
          )
          .toList();

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
          a[i].displayName != b[i].displayName) {
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
        ? 'Companion Phone'
        : displayName.trim();
    final trimmedPlatform = platform.trim().isEmpty
        ? 'Android (FCM)'
        : platform.trim();
    final now = _clock();
    final provisionalId =
        'dev_${++_deviceCounter}_${now.millisecondsSinceEpoch}';

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
          'pairingCode':
              pairingCode ??
              _activePairingInvitation?.pairingCode ??
              'HOST-BOND',
          'pairedAtUtc': now.toUtc().toIso8601String(),
        },
        timeout: _httpTimeout,
      );
      if (!postRes.isSuccess) {
        throw StateError(
          'Relay pairing failed (${postRes.errorSummary ?? "HTTP ${postRes.statusCode}"}).',
        );
      }
      final body = jsonDecode(postRes.body) as Map<String, Object?>;
      final serverDevice = PairedDeviceSummary.fromJson(body);
      _devices = <PairedDeviceSummary>[
        ..._devices.where((d) => d.deviceId != serverDevice.deviceId),
        serverDevice,
      ];
      _activePairingInvitation = null;
      await _persistState();
      return serverDevice;
    }

    final device = PairedDeviceSummary(
      deviceId: provisionalId,
      displayName: trimmedName,
      platform: trimmedPlatform,
      pairedAt: now,
      pushChannelReady: true,
      connected: true,
    );
    _devices = <PairedDeviceSummary>[..._devices, device];
    await _persistState();
    return device;
  }

  @override
  Future<void> unpairDevice(String deviceId) async {
    await _ensureLoaded();
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
    _devices = _devices.where((d) => d.deviceId != deviceId).toList();
    await _persistState();
  }

  @override
  Future<CompanionSessionState> pairAsCompanionPhone({
    required String pairingCodeOrPayload,
    required String displayName,
    required String platform,
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
        'Enter the Laptop Relay URL or paste a watsafe://pair QR link.',
      );
    }
    if (parsed.pairingCode.isEmpty) {
      throw StateError(
        'Enter the 6-character pairing code shown on your laptop.',
      );
    }

    final trimmedName = displayName.trim().isEmpty
        ? 'Companion Phone'
        : displayName.trim();
    final trimmedPlatform = platform.trim().isEmpty
        ? 'Android (Live Companion)'
        : platform.trim();

    final response = await sendRelayJsonRequest(
      method: 'POST',
      url: '$effectiveUrl/v1/pairing/complete',
      body: <String, Object?>{
        'pairingCode': parsed.pairingCode,
        'displayName': trimmedName,
        'platform': trimmedPlatform,
      },
      timeout: _httpTimeout,
    );

    if (!response.isSuccess) {
      String detail = response.errorSummary ?? 'HTTP ${response.statusCode}';
      try {
        final errMap = jsonDecode(response.body) as Map<String, Object?>;
        if (errMap['message'] is String) {
          detail = errMap['message'] as String;
        }
      } catch (_) {}
      throw StateError(detail);
    }

    final body = jsonDecode(response.body) as Map<String, Object?>;
    final sessionId = body['pairingSessionId'] as String? ?? '';
    final companionToken = body['companionToken'] as String? ?? '';
    final deviceId = body['deviceId'] as String?;
    final hostDisplayName =
        body['hostDisplayName'] as String? ?? 'WATSafe Laptop';

    if (sessionId.isEmpty || companionToken.isEmpty) {
      throw StateError('Relay did not return a valid companion session token.');
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
      statusMessage:
          'Connected to $hostDisplayName. Live alerts active while WATSafe is open in the foreground.',
    );

    await _persistState();
    await pollCompanionAlertsOnce();
    _startCompanionPollTimerIfNeeded();
    _onStateChanged?.call();
    return _companionSession;
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

    if (response.statusCode == 401) {
      _companionPollTimer?.cancel();
      _companionPollTimer = null;
      _companionToken = null;
      _companionSession = CompanionSessionState(
        isConnected: false,
        pairingSessionId: _companionSession.pairingSessionId,
        hostDisplayName: _companionSession.hostDisplayName,
        phoneDisplayName: _companionSession.phoneDisplayName,
        relayEndpointUrl: url,
        statusMessage:
            'Disconnected — this phone was unpaired or the laptop session ended.',
      );
      await _persistState();
      _onStateChanged?.call();
      return const <CompanionAlertEvent>[];
    }

    if (!response.isSuccess) {
      _companionSession = CompanionSessionState(
        isConnected: true,
        pairingSessionId: _companionSession.pairingSessionId,
        hostDisplayName: _companionSession.hostDisplayName,
        deviceId: _companionSession.deviceId,
        phoneDisplayName: _companionSession.phoneDisplayName,
        relayEndpointUrl: url,
        deliveryMode: _companionSession.deliveryMode,
        statusMessage:
            'Reconnecting to relay (${response.errorSummary ?? "HTTP ${response.statusCode}"})…',
      );
      _onStateChanged?.call();
      return const <CompanionAlertEvent>[];
    }

    final newlyDelivered = <CompanionAlertEvent>[];
    try {
      final decoded = jsonDecode(response.body) as Map<String, Object?>;
      final latestSeq =
          (decoded['latestSeq'] as num?)?.toInt() ?? _companionLastAlertSeq;
      final hostName =
          decoded['hostDisplayName'] as String? ??
          _companionSession.hostDisplayName;
      final rawAlerts =
          decoded['alerts'] as List<Object?>? ?? const <Object?>[];

      for (final item in rawAlerts.whereType<Map<Object?, Object?>>()) {
        final alert = CompanionAlertEvent.fromJson(
          Map<String, Object?>.from(item),
        );
        if (alert.alertSeq > _companionLastAlertSeq) {
          _companionLastAlertSeq = alert.alertSeq;
        }
        // Client-side incidentId deduplication ensures reconnects or cursor
        // replays never produce duplicate phone alerts.
        if (alert.incidentId.isNotEmpty &&
            _seenCompanionIncidentIds.add(alert.incidentId)) {
          newlyDelivered.add(alert);
          _receivedCompanionAlerts = <CompanionAlertEvent>[
            alert,
            ..._receivedCompanionAlerts,
          ];
          if (!_incomingAlertsController.isClosed) {
            _incomingAlertsController.add(alert);
          }
        }
      }

      if (latestSeq > _companionLastAlertSeq) {
        _companionLastAlertSeq = latestSeq;
      }

      _companionSession = CompanionSessionState(
        isConnected: true,
        pairingSessionId: _companionSession.pairingSessionId,
        hostDisplayName: hostName,
        deviceId: _companionSession.deviceId,
        phoneDisplayName: _companionSession.phoneDisplayName,
        relayEndpointUrl: url,
        deliveryMode: _companionSession.deliveryMode,
        statusMessage:
            'Connected to ${hostName ?? "WATSafe Laptop"}. Live foreground alerts active.',
      );

      if (newlyDelivered.isNotEmpty) {
        await _persistState();
      }
      _onStateChanged?.call();
    } catch (_) {
      // Ignore malformed JSON
    }

    return newlyDelivered;
  }

  @override
  Future<void> disconnectCompanionSession() async {
    await _ensureLoaded();
    _companionPollTimer?.cancel();
    _companionPollTimer = null;
    _companionToken = null;
    _companionSession = CompanionSessionState.disconnected;
    await _persistState();
    _onStateChanged?.call();
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
        message: 'Not configured (no paired devices)',
      );
    }

    // If a pairing code was recently issued on this laptop session, sync once
    // before checking `_devices` so a phone that just paired still receives the alert.
    if (hasUrl && _hostToken != null && _devices.isEmpty) {
      await syncPairedDevicesFromRelay();
    }

    if (_devices.isEmpty) {
      return const NotificationDispatchResult(
        delivered: false,
        capabilityStatus: CapabilityStatus.degraded,
        message: 'Not sent (0 paired devices registered)',
      );
    }

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
      'isTest': incident.isTest,
    };

    if (hasUrl) {
      if (_hostToken == null || _hostToken!.isEmpty) {
        await initiateHostPairing();
      }
      final postResult = await sendRelayJsonRequest(
        method: 'POST',
        url: '$_relayEndpointUrl/v1/incidents:report',
        headers: _hostToken != null ? _bearerHeaders(_hostToken!) : null,
        body: payload,
        timeout: _httpTimeout,
      );
      if (postResult.isSuccess) {
        await _appendAlertToLocalOutbox(payload);
        return NotificationDispatchResult(
          delivered: true,
          capabilityStatus: CapabilityStatus.ready,
          message:
              'Delivered via HTTP relay to ${_devices.length} paired device(s)',
        );
      }
      return NotificationDispatchResult(
        delivered: false,
        capabilityStatus: CapabilityStatus.degraded,
        message: 'HTTP relay failed (${postResult.errorSummary})',
      );
    }

    await _appendAlertToLocalOutbox(payload);
    final names = _devices.map((d) => d.displayName).join(', ');
    return NotificationDispatchResult(
      delivered: true,
      capabilityStatus: CapabilityStatus.ready,
      message: 'Dispatched to ${_devices.length} paired device(s): $names',
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
      final invite = _activePairingInvitation;
      if (_hostToken == null || (invite == null && _devices.isEmpty)) {
        _hostSyncTimer?.cancel();
        _hostSyncTimer = null;
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
      if (_hostToken != null &&
          (_activePairingInvitation != null || _devices.isNotEmpty)) {
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
    _companionPollTimer?.cancel();
    _companionPollTimer = null;
    if (!_incomingAlertsController.isClosed) {
      unawaited(_incomingAlertsController.close());
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
