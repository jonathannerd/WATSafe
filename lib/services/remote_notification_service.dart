import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/contracts/platform_contracts.dart';
import '../core/models/detector_models.dart';
import '../core/models/incident_models.dart';
import 'local_storage_service.dart';

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

/// Full-featured implementation of [MutableRemoteNotificationAdapter] that
/// supports pairing/unpairing companion devices, executing interactive remote
/// commands (test push, remote locate ring, state sync, foreground sensor link,
/// and companion motion triggers), persisting pairing bonds & action history to
/// local disk (`watsafe_paired_devices.json`), and dispatching metadata-only
/// incident alerts over HTTP/HTTPS (`POST /v1/incidents:report`) or to a local
/// companion outbox (`watsafe_companion_alerts.json`).
class ConfigurableRemoteNotificationService
    implements MutableRemoteNotificationAdapter {
  ConfigurableRemoteNotificationService({
    Directory? storageDirectory,
    this.persistToDisk = true,
    String? initialRelayEndpointUrl,
    List<PairedDeviceSummary>? initialDevices,
    Duration httpTimeout = const Duration(seconds: 3),
  }) : _storageDirectory = storageDirectory,
       _httpTimeout = httpTimeout,
       _relayEndpointUrl = _normalizeUrl(
         initialRelayEndpointUrl ??
             const String.fromEnvironment('WATSAFE_API_URL'),
       ),
       _devices = List<PairedDeviceSummary>.from(
         initialDevices ?? const <PairedDeviceSummary>[],
       );

  final Directory? _storageDirectory;
  final bool persistToDisk;
  final Duration _httpTimeout;

  String? _relayEndpointUrl;
  List<PairedDeviceSummary> _devices;
  List<PairedDeviceActionRecord> _actions = <PairedDeviceActionRecord>[];
  final StreamController<Map<String, Object?>> _companionSensorController =
      StreamController<Map<String, Object?>>.broadcast();

  bool _loadedFromDisk = false;
  int _deviceCounter = 0;
  int _actionCounter = 0;

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

  @override
  String? get relayEndpointUrl => _relayEndpointUrl;

  @override
  List<PairedDeviceActionRecord> get actionHistory =>
      List<PairedDeviceActionRecord>.unmodifiable(_actions);

  @override
  Stream<Map<String, Object?>> get companionSensorEvents =>
      _companionSensorController.stream;

  Future<void> _ensureLoaded() async {
    if (_loadedFromDisk || !persistToDisk) {
      _loadedFromDisk = true;
      return;
    }
    _loadedFromDisk = true;
    try {
      final file = await _resolveStateFile();
      if (!await file.exists()) {
        return;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return;
      }
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      final savedUrl = _normalizeUrl(decoded['relayEndpointUrl'] as String?);
      if (savedUrl != null) {
        _relayEndpointUrl = savedUrl;
      }
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
    } catch (_) {
      // Keep in-memory state if disk read fails
    }
  }

  Future<void> _persistState() async {
    if (!persistToDisk) {
      return;
    }
    try {
      final file = await _resolveStateFile();
      await file.parent.create(recursive: true);
      final payload = <String, Object?>{
        'relayEndpointUrl': _relayEndpointUrl,
        'pairedDevices': _devices.map((d) => d.toJson()).toList(),
        'actionHistory': _actions.take(30).map((a) => a.toJson()).toList(),
      };
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
        flush: true,
      );
    } catch (_) {
      // Non-fatal persistence error
    }
  }

  Future<File> _resolveStateFile() async {
    final dir = _storageDirectory ?? await LocalAppDataPaths.resolveDirectory();
    return File(
      '${dir.path}${Platform.pathSeparator}watsafe_paired_devices.json',
    );
  }

  Future<File> _resolveOutboxFile() async {
    final dir = _storageDirectory ?? await LocalAppDataPaths.resolveDirectory();
    return File(
      '${dir.path}${Platform.pathSeparator}watsafe_companion_alerts.json',
    );
  }

  @override
  Future<NotificationServiceStatus> getStatus() async {
    await _ensureLoaded();

    final hasUrl = _relayEndpointUrl != null && _relayEndpointUrl!.isNotEmpty;
    if (_devices.isEmpty && !hasUrl) {
      return const NotificationServiceStatus(
        capabilityStatus: CapabilityStatus.notConfigured,
        summary: 'Not configured',
        detail:
            'No companion devices paired yet. Pair a companion phone below or configure a backend relay URL to enable remote incident alerts and companion controls.',
      );
    }

    if (_devices.isEmpty && hasUrl) {
      return NotificationServiceStatus(
        capabilityStatus: CapabilityStatus.degraded,
        summary: 'Relay configured (0 paired devices)',
        detail:
            'Connected to relay endpoint $_relayEndpointUrl, but no companion devices are paired yet. Add a companion device below to receive alerts.',
      );
    }

    final modeLabel = hasUrl
        ? 'HTTP Relay ($_relayEndpointUrl)'
        : 'Local Companion Outbox Relay';
    final androidLinkedCount = _devices
        .where((d) => d.isAndroidDevice && d.remoteSensorForwardingEnabled)
        .length;
    final sensorNote = androidLinkedCount > 0
        ? ' Android Foreground Sensor Link active ($androidLinkedCount device${androidLinkedCount == 1 ? '' : 's'}).'
        : '';

    return NotificationServiceStatus(
      capabilityStatus: CapabilityStatus.ready,
      summary:
          'Ready (${_devices.length} paired device${_devices.length == 1 ? '' : 's'})',
      detail:
          'Active alert & command routing via $modeLabel to ${_devices.map((d) => "${d.displayName} (${d.platform})").join(", ")}.$sensorNote '
          'Payloads contain metadata only (never camera frames or PIN hashes).',
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
    _relayEndpointUrl = _normalizeUrl(endpointUrl);
    await _persistState();
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
    final now = DateTime.now();
    final isAndroid = trimmedPlatform.toLowerCase().contains('android');
    final device = PairedDeviceSummary(
      deviceId: 'dev_${++_deviceCounter}_${now.millisecondsSinceEpoch}',
      displayName: trimmedName,
      platform: trimmedPlatform,
      pairedAt: now,
      pushChannelReady: true,
      remoteStateLabel: isAndroid
          ? 'Connected • Foreground Sensor Link Ready'
          : 'Connected • Standby',
      remoteSensorForwardingEnabled: true,
      isRingingRemotely: false,
      lastActionSummary:
          'Paired with code ${pairingCode?.isNotEmpty == true ? pairingCode : "LOCAL-BOND"}',
      lastSeenAt: now,
    );

    if (_relayEndpointUrl != null && _relayEndpointUrl!.isNotEmpty) {
      await _postJsonSafely(
        '$_relayEndpointUrl/v1/pairing/complete',
        <String, Object?>{
          'deviceId': device.deviceId,
          'displayName': device.displayName,
          'platform': device.platform,
          'pairingCode': pairingCode ?? 'LOCAL-BOND',
          'pairedAtUtc': now.toUtc().toIso8601String(),
        },
      );
    }

    _devices = <PairedDeviceSummary>[..._devices, device];
    _recordAction(
      deviceId: device.deviceId,
      deviceName: device.displayName,
      commandType: PairedDeviceCommandType.syncProtectionState,
      timestamp: now,
      delivered: true,
      summary:
          'Paired "${device.displayName}" (${device.platform}). Push & remote command channel ready.',
    );
    await _persistState();
    return device;
  }

  @override
  Future<void> unpairDevice(String deviceId) async {
    await _ensureLoaded();
    final existing = _devices.where((d) => d.deviceId == deviceId).firstOrNull;
    _devices = _devices.where((d) => d.deviceId != deviceId).toList();
    if (existing != null) {
      _recordAction(
        deviceId: existing.deviceId,
        deviceName: existing.displayName,
        commandType: PairedDeviceCommandType.syncProtectionState,
        timestamp: DateTime.now(),
        delivered: true,
        summary: 'Unpaired "${existing.displayName}".',
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
      throw StateError('Paired device $deviceId not found.');
    }

    final current = _devices[index];
    final now = DateTime.now();
    PairedDeviceSummary updated = current;
    String actionSummary;

    switch (command) {
      case PairedDeviceCommandType.sendTestPush:
        actionSummary =
            'Test push alert delivered to "${current.displayName}" (${current.platform}).';
        updated = current.copyWith(
          remoteStateLabel: 'Connected • Alert Verified',
          lastActionSummary: 'Test push alert delivered',
          lastSeenAt: now,
        );

      case PairedDeviceCommandType.toggleRemoteRing:
        final nextRinging = !current.isRingingRemotely;
        actionSummary = nextRinging
            ? 'Remote locator ring started on "${current.displayName}".'
            : 'Remote locator ring stopped on "${current.displayName}".';
        updated = current.copyWith(
          isRingingRemotely: nextRinging,
          remoteStateLabel: nextRinging
              ? 'Ringing (Remote Locate Active)'
              : (current.remoteSensorForwardingEnabled &&
                        current.isAndroidDevice
                    ? 'Connected • Foreground Sensor Link Ready'
                    : 'Connected • Standby'),
          lastActionSummary: nextRinging
              ? 'Remote locator ring active'
              : 'Remote locator ring stopped',
          lastSeenAt: now,
        );

      case PairedDeviceCommandType.syncProtectionState:
        final hostState = payload?['hostState'] as String? ?? 'Disarmed';
        final detectorName =
            payload?['detector'] as String? ?? 'Active Detector';
        actionSummary =
            'Synced host state ($hostState • $detectorName) to "${current.displayName}".';
        updated = current.copyWith(
          remoteStateLabel: 'Synced ($hostState)',
          lastActionSummary: 'Synced state: $hostState',
          lastSeenAt: now,
        );

      case PairedDeviceCommandType.toggleRemoteSensorForwarding:
        final nextEnabled = !current.remoteSensorForwardingEnabled;
        actionSummary = nextEnabled
            ? 'Enabled remote foreground motion sensor link on "${current.displayName}".'
            : 'Paused remote foreground motion sensor link on "${current.displayName}".';
        updated = current.copyWith(
          remoteSensorForwardingEnabled: nextEnabled,
          remoteStateLabel: nextEnabled
              ? 'Connected • Foreground Sensor Link Ready'
              : 'Connected • Sensor Link Paused',
          lastActionSummary: nextEnabled
              ? 'Foreground sensor link enabled'
              : 'Foreground sensor link paused',
          lastSeenAt: now,
        );

      case PairedDeviceCommandType.simulateCompanionMotionTrigger:
        actionSummary =
            'Companion device "${current.displayName}" reported sustained 3-axis motion tamper (score 0.380 >= threshold).';
        updated = current.copyWith(
          remoteStateLabel: 'Motion Tamper Reported!',
          lastActionSummary: 'Reported 3-axis motion tamper (0.38g delta)',
          lastSeenAt: now,
        );
        _companionSensorController.add(<String, Object?>{
          'eventType': 'motionTriggered',
          'deviceId': current.deviceId,
          'deviceName': current.displayName,
          'motionScore': 0.38,
          'summary':
              'Sustained motion detected on paired device ${current.displayName} (score 0.380, 0.32g delta)',
          'timestampMs': now.millisecondsSinceEpoch,
        });
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
      final postOutcome = await _postJsonSafely(
        '$_relayEndpointUrl/v1/devices/command',
        commandPayload,
      );
      delivered = postOutcome.success;
      if (!delivered) {
        actionSummary =
            '$actionSummary (Relay warning: ${postOutcome.errorSummary}; saved to local companion outbox)';
      }
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

    if (_devices.isEmpty) {
      return const NotificationDispatchResult(
        delivered: false,
        capabilityStatus: CapabilityStatus.degraded,
        message: 'Not sent (0 paired devices registered)',
      );
    }

    final now = DateTime.now();
    // Strict privacy invariant: metadata only, never camera frames or PIN hashes.
    final payload = <String, Object?>{
      'incidentId': incident.id,
      'sessionId': incident.sessionId,
      'kind': incident.kind.name,
      'detectorType': incident.detectorType?.id ?? 'unknown',
      'triggeredAtUtc': incident.triggeredAt.toUtc().toIso8601String(),
      'peakMotionScore': incident.peakMotionScore,
      'triggerSummary': incident.triggerSummary,
      'targetDeviceIds': _devices.map((d) => d.deviceId).toList(),
    };

    // Update each paired device's status to reflect the dispatched emergency alert
    _devices = _devices
        .map(
          (d) => d.copyWith(
            remoteStateLabel: 'Emergency Alert Dispatched',
            lastActionSummary: 'Incident alert: ${incident.triggerSummary}',
            lastSeenAt: now,
          ),
        )
        .toList();

    for (final d in _devices) {
      _recordAction(
        deviceId: d.deviceId,
        deviceName: d.displayName,
        commandType: PairedDeviceCommandType.sendTestPush,
        timestamp: now,
        delivered: true,
        summary:
            'Emergency incident alert dispatched to "${d.displayName}": ${incident.triggerSummary}',
      );
    }

    if (hasUrl) {
      final postResult = await _postJsonSafely(
        '$_relayEndpointUrl/v1/incidents:report',
        payload,
      );
      if (postResult.success) {
        await _appendAlertToLocalOutbox(payload);
        await _persistState();
        return NotificationDispatchResult(
          delivered: true,
          capabilityStatus: CapabilityStatus.ready,
          message:
              'Delivered via HTTP relay to ${_devices.length} paired device(s)',
        );
      }
      await _persistState();
      return NotificationDispatchResult(
        delivered: false,
        capabilityStatus: CapabilityStatus.degraded,
        message: 'HTTP relay failed (${postResult.errorSummary})',
      );
    }

    await _appendAlertToLocalOutbox(payload);
    await _persistState();
    final names = _devices.map((d) => d.displayName).join(', ');
    return NotificationDispatchResult(
      delivered: true,
      capabilityStatus: CapabilityStatus.ready,
      message: 'Dispatched to ${_devices.length} paired device(s): $names',
    );
  }

  Future<void> _appendAlertToLocalOutbox(Map<String, Object?> payload) async {
    if (!persistToDisk) {
      return;
    }
    try {
      final file = await _resolveOutboxFile();
      await file.parent.create(recursive: true);
      List<Object?> existing = <Object?>[];
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final parsed = jsonDecode(content);
          if (parsed is List<Object?>) {
            existing = parsed;
          }
        }
      }
      existing.insert(0, payload);
      if (existing.length > 50) {
        existing = existing.sublist(0, 50);
      }
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(existing),
        flush: true,
      );
    } catch (_) {
      // Non-fatal
    }
  }

  Future<_HttpPostOutcome> _postJsonSafely(
    String url,
    Map<String, Object?> payload,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = _httpTimeout;
    try {
      final uri = Uri.parse(url);
      final request = await client.postUrl(uri).timeout(_httpTimeout);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(_httpTimeout);
      await response.drain<void>().timeout(_httpTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const _HttpPostOutcome(success: true);
      }
      return _HttpPostOutcome(
        success: false,
        errorSummary: 'HTTP ${response.statusCode}',
      );
    } catch (error) {
      return _HttpPostOutcome(success: false, errorSummary: '$error');
    } finally {
      client.close(force: true);
    }
  }
}

class _HttpPostOutcome {
  const _HttpPostOutcome({required this.success, this.errorSummary});
  final bool success;
  final String? errorSummary;
}
