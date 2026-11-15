import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';
import '../theme/watsafe_theme.dart';

/// Paired Devices & Remote Notifications screen supporting:
/// 1. Laptop host short-lived pairing code + QR payload generation & session sync
/// 2. Companion phone pairing, foreground live alert polling, and alert feed
/// 3. Direct companion registration & relay endpoint configuration
class PairedDevicesScreen extends StatefulWidget {
  const PairedDevicesScreen({super.key, required this.controller});

  final AlarmController controller;

  @override
  State<PairedDevicesScreen> createState() => _PairedDevicesScreenState();
}

class _PairedDevicesScreenState extends State<PairedDevicesScreen> {
  final TextEditingController _hostNameController = TextEditingController(
    text: 'WATSafe Laptop',
  );
  final TextEditingController _companionCodeController =
      TextEditingController();
  final TextEditingController _companionPhoneNameController =
      TextEditingController(text: 'Companion Phone');

  final TextEditingController _deviceNameController = TextEditingController();
  final TextEditingController _pairingCodeController = TextEditingController(
    text: 'WAT-842',
  );
  late final TextEditingController _endpointController;

  String _selectedPlatform = 'Android (FCM)';
  String? _feedbackMessage;
  bool _isBusy = false;

  static const List<String> _platformOptions = <String>[
    'Android (FCM)',
    'iOS (APNs)',
  ];

  @override
  void initState() {
    super.initState();
    _endpointController = TextEditingController(
      text: widget.controller.relayEndpointUrl ?? '',
    );
  }

  @override
  void dispose() {
    _hostNameController.dispose();
    _companionCodeController.dispose();
    _companionPhoneNameController.dispose();
    _deviceNameController.dispose();
    _pairingCodeController.dispose();
    _endpointController.dispose();
    super.dispose();
  }

  Future<void> _handleSaveEndpoint() async {
    final url = _endpointController.text.trim();
    final updated = await widget.controller.configureRelayEndpoint(
      url.isEmpty ? null : url,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _feedbackMessage = updated
          ? (url.isEmpty
                ? 'Switched to Local Companion Outbox Relay.'
                : 'Configured HTTP relay endpoint: $url')
          : 'Could not update relay endpoint.';
    });
  }

  Future<void> _handleGenerateHostPairingCode() async {
    setState(() {
      _isBusy = true;
      _feedbackMessage = null;
    });
    try {
      final urlText = _endpointController.text.trim();
      if (urlText.isNotEmpty &&
          urlText != (widget.controller.relayEndpointUrl ?? '')) {
        await widget.controller.configureRelayEndpoint(urlText);
      }
      final invite = await widget.controller.initiateHostPairing(
        hostDisplayName: _hostNameController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _feedbackMessage =
            'Generated single-use pairing code ${invite.pairingCode} (valid for 5 minutes).';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _feedbackMessage = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _handleSyncHostDevices() async {
    setState(() {
      _isBusy = true;
    });
    try {
      final synced = await widget.controller.syncPairedDevicesFromRelay();
      if (!mounted) {
        return;
      }
      setState(() {
        _feedbackMessage = synced.isEmpty
            ? 'Checked relay — waiting for phone to complete pairing.'
            : 'Connected to ${synced.length} paired phone(s).';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _handleConnectCompanionPhone() async {
    final codeOrQr = _companionCodeController.text.trim();
    if (codeOrQr.isEmpty) {
      setState(() {
        _feedbackMessage =
            'Enter the 6-character pairing code or paste the watsafe://pair QR link from your laptop.';
      });
      return;
    }
    setState(() {
      _isBusy = true;
      _feedbackMessage = null;
    });
    try {
      final session = await widget.controller.pairAsCompanionPhone(
        pairingCodeOrPayload: codeOrQr,
        displayName: _companionPhoneNameController.text.trim(),
        platform: _selectedPlatform,
        endpointUrlOverride: _endpointController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _companionCodeController.clear();
        _feedbackMessage =
            'Connected to ${session.hostDisplayName ?? "WATSafe Laptop"}! Live foreground alerts enabled.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _feedbackMessage = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _handlePairDevice() async {
    final name = _deviceNameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _feedbackMessage = 'Enter a display name for your companion device.';
      });
      return;
    }
    final paired = await widget.controller.pairCompanionDevice(
      displayName: name,
      platform: _selectedPlatform,
      pairingCode: _pairingCodeController.text.trim(),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      if (paired != null) {
        _deviceNameController.clear();
        _feedbackMessage =
            'Paired "${paired.displayName}" (${paired.platform}).';
      } else {
        _feedbackMessage =
            'Pairing is not enabled on the current notification adapter.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final status = controller.notificationStatus;
    final devices = controller.pairedDevices;
    final invite = controller.activePairingInvitation;
    final companionSession = controller.companionSession;
    final companionAlerts = controller.receivedCompanionAlerts;
    final statusColor = WatSafeTheme.colorForCapabilityStatus(
      status.capabilityStatus,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Paired Devices & Remote Alerts',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: statusColor),
                    ),
                    child: Text(
                      WatSafeTheme.labelForCapabilityStatus(
                        status.capabilityStatus,
                      ),
                      key: const Key('paired_devices_status_badge'),
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            status.capabilityStatus == CapabilityStatus.ready
                                ? Icons.cloud_done_outlined
                                : Icons.cloud_off_outlined,
                            color: statusColor,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Remote Pairing & Push Service: ${status.summary}',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        status.detail,
                        style: const TextStyle(color: WatSafeTheme.warmMuted),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (devices.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 32,
                    ),
                    child: Column(
                      children: <Widget>[
                        const Icon(
                          Icons.phonelink_off_outlined,
                          size: 46,
                          color: WatSafeTheme.warmSubtle,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          status.capabilityStatus ==
                                  CapabilityStatus.notConfigured
                              ? 'No Paired Devices (Service Not Configured)'
                              : 'No Paired Devices Registered',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'WATSafe only displays real local hardware and verified paired devices. '
                          'Generate a short-lived pairing code on your laptop or pair a companion phone below to dispatch metadata-only incident alerts.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: WatSafeTheme.warmMuted),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                'Active Paired Companion Devices (${devices.length})',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (controller.canManagePairing &&
                                (controller.relayEndpointUrl ?? '').isNotEmpty)
                              TextButton.icon(
                                key: const Key('refresh_paired_devices_button'),
                                onPressed: _isBusy
                                    ? null
                                    : _handleSyncHostDevices,
                                icon: const Icon(Icons.sync, size: 16),
                                label: const Text('Sync'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        for (final device in devices)
                          _buildPairedDeviceTile(context, device),
                      ],
                    ),
                  ),
                ),
              if (controller.canManagePairing) ...<Widget>[
                const SizedBox(height: 20),
                _buildLaptopHostCodeAndQrCard(context, invite),
                const SizedBox(height: 20),
                _buildCompanionPhoneReceiverCard(
                  context,
                  companionSession,
                  companionAlerts,
                ),
                const SizedBox(height: 20),
                _buildPairingManagementCard(context),
              ],
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Architecture & Platform Lifecycle Notes',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: WatSafeTheme.amberAccent,
                            ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '• Session isolation: Pairing codes are short-lived (5 minutes) and single-use. Incident alerts are restricted strictly to tokens bound to that paired session.\n'
                        '• Foreground companion alerts: Paired phones receive live alerts immediately while WATSafe is open in the foreground; background wake-up notifications when the app is closed require APNs (.p8) / FCM server credentials on a deployed relay.\n'
                        '• Strict privacy & credential boundary: Camera frames, PINs/PIN hashes, and database credentials never cross the connection. Database URLs (such as Aiven PostgreSQL) live exclusively in backend environment variables.',
                        style: TextStyle(
                          color: WatSafeTheme.warmMuted,
                          height: 1.5,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLaptopHostCodeAndQrCard(
    BuildContext context,
    PairingCodeInvitation? invite,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '1. Protect This Laptop — Generate Pairing Code & QR',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Point both devices at the same WATSafe Relay URL (for example http://<laptop-lan-ip>:8787), then generate a 5-minute single-use code for your phone.',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('host_display_name_input'),
                    controller: _hostNameController,
                    decoration: const InputDecoration(
                      labelText: 'Laptop Display Name',
                      hintText: 'e.g., MacBook Pro — Library Desk',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  key: const Key('generate_pairing_code_button'),
                  onPressed: _isBusy ? null : _handleGenerateHostPairingCode,
                  icon: const Icon(Icons.qr_code_2, size: 18),
                  label: const Text('Generate Code & QR'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const Key('sync_paired_devices_button'),
                  onPressed: _isBusy ? null : _handleSyncHostDevices,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Check Status'),
                ),
              ],
            ),
            if (invite != null) ...<Widget>[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: WatSafeTheme.charcoalElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: WatSafeTheme.amberAccent),
                ),
                child: Wrap(
                  spacing: 20,
                  runSpacing: 16,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Container(
                      width: 132,
                      height: 132,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: CustomPaint(
                        key: const Key('pairing_qr_matrix'),
                        painter: _PairingMatrixPainter(invite.qrPayload),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            'SINGLE-USE PAIRING CODE (5 MIN TTL)',
                            style: TextStyle(
                              color: WatSafeTheme.amberAccent,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            invite.pairingCode,
                            key: const Key('active_pairing_code_label'),
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            invite.qrPayload,
                            style: const TextStyle(
                              color: WatSafeTheme.warmMuted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: invite.qrPayload),
                              );
                              setState(() {
                                _feedbackMessage =
                                    'Copied watsafe://pair link to clipboard.';
                              });
                            },
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('Copy Pairing Link'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCompanionPhoneReceiverCard(
    BuildContext context,
    CompanionSessionState session,
    List<CompanionAlertEvent> alerts,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '2. Companion Phone — Pair with Laptop & Receive Alerts',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (session.isConnected)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: WatSafeTheme.readyEmerald.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: WatSafeTheme.readyEmerald),
                    ),
                    child: const Text(
                      'CONNECTED TO LAPTOP',
                      key: Key('companion_connected_badge'),
                      style: TextStyle(
                        color: WatSafeTheme.readyEmerald,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'On your phone, enter the 6-character code (or paste the watsafe://pair link) shown on your laptop. '
              'Foreground alerts arrive live while WATSafe stays open on screen.',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            if (!session.isConnected) ...<Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    flex: 3,
                    child: TextField(
                      key: const Key('companion_code_or_qr_input'),
                      controller: _companionCodeController,
                      decoration: const InputDecoration(
                        labelText: 'Laptop Pairing Code or watsafe://pair Link',
                        hintText: 'e.g., K7M-4P9 or watsafe://pair?...',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      key: const Key('companion_phone_name_input'),
                      controller: _companionPhoneNameController,
                      decoration: const InputDecoration(
                        labelText: 'This Phone\'s Name',
                        hintText: 'e.g., Pixel 9 / iPhone 16',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const Key('connect_companion_phone_button'),
                  onPressed: _isBusy ? null : _handleConnectCompanionPhone,
                  icon: const Icon(Icons.phonelink_ring, size: 18),
                  label: const Text('Connect Phone to Laptop'),
                ),
              ),
            ] else ...<Widget>[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: WatSafeTheme.charcoalElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: WatSafeTheme.readyEmerald),
                ),
                child: Row(
                  children: <Widget>[
                    const Icon(
                      Icons.laptop_mac,
                      color: WatSafeTheme.readyEmerald,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Paired with ${session.hostDisplayName ?? "WATSafe Laptop"}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            session.statusMessage ??
                                'Session ${session.pairingSessionId} • Foreground live alerts active',
                            style: const TextStyle(
                              color: WatSafeTheme.warmMuted,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton.icon(
                      key: const Key('poll_companion_alerts_button'),
                      onPressed: () {
                        widget.controller.pollCompanionAlertsOnce();
                      },
                      icon: const Icon(Icons.sync, size: 16),
                      label: const Text('Refresh Alerts'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      key: const Key('disconnect_companion_button'),
                      onPressed: () {
                        widget.controller.disconnectCompanionSession();
                      },
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
              ),
            ],
            if (session.statusMessage != null &&
                !session.isConnected) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                session.statusMessage!,
                style: const TextStyle(
                  color: WatSafeTheme.amberAccent,
                  fontSize: 12.5,
                ),
              ),
            ],
            if (alerts.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                'Received Laptop Alarm Alerts (${alerts.length})',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              for (final alert in alerts)
                Container(
                  key: Key('companion_alert_${alert.incidentId}'),
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: WatSafeTheme.alarmCrimson.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: WatSafeTheme.alarmCrimson),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: WatSafeTheme.alarmCrimson,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '${alert.hostDisplayName ?? "Laptop"} — ALARM TRIGGERED',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: WatSafeTheme.warmOffWhite,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              alert.triggerSummary,
                              style: const TextStyle(fontSize: 13),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Incident ${alert.incidentId} • Detector: ${alert.detectorType} • ${alert.triggeredAt.toIso8601String()}',
                              style: const TextStyle(
                                color: WatSafeTheme.warmMuted,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPairedDeviceTile(
    BuildContext context,
    PairedDeviceSummary device,
  ) {
    final isIos = device.platform.toLowerCase().contains('ios');
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WatSafeTheme.charcoalElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: WatSafeTheme.charcoalBorder),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            isIos ? Icons.phone_iphone : Icons.phone_android,
            color: WatSafeTheme.amberAccent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  device.displayName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${device.platform} • ID: ${device.deviceId}',
                  style: const TextStyle(
                    color: WatSafeTheme.warmMuted,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          if (device.connected) ...<Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: WatSafeTheme.readyEmerald.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: WatSafeTheme.readyEmerald),
              ),
              child: const Text(
                'CONNECTED',
                style: TextStyle(
                  color: WatSafeTheme.readyEmerald,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: WatSafeTheme.readyEmerald.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: WatSafeTheme.readyEmerald),
            ),
            child: Text(
              device.pushChannelReady ? 'PUSH READY' : 'PENDING',
              style: const TextStyle(
                color: WatSafeTheme.readyEmerald,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (widget.controller.canManagePairing) ...<Widget>[
            const SizedBox(width: 10),
            IconButton(
              key: Key('unpair_device_${device.deviceId}'),
              tooltip: 'Unpair device',
              icon: const Icon(Icons.link_off, color: WatSafeTheme.warmMuted),
              onPressed: () {
                widget.controller.unpairCompanionDevice(device.deviceId);
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPairingManagementCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Pair Companion Device & Configure Relay',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: const Key('pair_device_name_input'),
                    controller: _deviceNameController,
                    decoration: const InputDecoration(
                      labelText: 'Companion Device Name',
                      hintText: 'e.g., Aidan\'s S24 or iPhone 16',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    key: const Key('pair_device_platform_dropdown'),
                    isExpanded: true,
                    initialValue: _selectedPlatform,
                    decoration: const InputDecoration(
                      labelText: 'Mobile Platform',
                    ),
                    items: _platformOptions
                        .map(
                          (option) => DropdownMenuItem<String>(
                            value: option,
                            child: Text(option),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedPlatform = value;
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: const Key('pair_device_code_input'),
                    controller: _pairingCodeController,
                    decoration: const InputDecoration(
                      labelText: 'Pairing Code',
                      hintText: '6-char code',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const Key('pair_device_submit_button'),
                onPressed: _handlePairDevice,
                icon: const Icon(Icons.phonelink_setup, size: 18),
                label: const Text('Pair Companion Device'),
              ),
            ),
            const Divider(height: 28),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('relay_endpoint_input'),
                    controller: _endpointController,
                    decoration: const InputDecoration(
                      labelText: 'Optional Backend Relay URL (/v1/...)',
                      hintText:
                          'Leave blank for Local Outbox or enter http://127.0.0.1:8787',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  key: const Key('save_relay_endpoint_button'),
                  onPressed: _handleSaveEndpoint,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save Relay URL'),
                ),
              ],
            ),
            if (_feedbackMessage != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _feedbackMessage!,
                key: const Key('pairing_feedback_message'),
                style: const TextStyle(
                  color: WatSafeTheme.amberAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Renders a high-contrast deterministic pairing matrix with finder patterns
/// from [payload] without external third-party UI dependencies.
class _PairingMatrixPainter extends CustomPainter {
  _PairingMatrixPainter(this.payload);

  final String payload;

  static const int _gridSize = 21;

  bool _isFinderModule(int r, int c) {
    bool inFinder(int fr, int fc) {
      final dr = r - fr;
      final dc = c - fc;
      if (dr < 0 || dr > 6 || dc < 0 || dc > 6) {
        return false;
      }
      if (dr == 0 || dr == 6 || dc == 0 || dc == 6) {
        return true;
      }
      if (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4) {
        return true;
      }
      return false;
    }

    return inFinder(0, 0) ||
        inFinder(0, _gridSize - 7) ||
        inFinder(_gridSize - 7, 0);
  }

  bool _isQuietSeparator(int r, int c) {
    return (r <= 7 && c <= 7) ||
        (r <= 7 && c >= _gridSize - 8) ||
        (r >= _gridSize - 8 && c <= 7);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final digest = sha256.convert(utf8.encode(payload)).bytes;
    final cell = size.width / _gridSize;
    final darkPaint = Paint()..color = const Color(0xFF111315);

    var bitIdx = 0;
    for (var r = 0; r < _gridSize; r++) {
      for (var c = 0; c < _gridSize; c++) {
        bool dark = false;
        if (_isFinderModule(r, c)) {
          dark = true;
        } else if (!_isQuietSeparator(r, c)) {
          final byteVal = digest[(bitIdx ~/ 8) % digest.length];
          dark = ((byteVal >> (bitIdx % 8)) & 1) == 1;
          bitIdx += 1;
        }
        if (dark) {
          canvas.drawRect(
            Rect.fromLTWH(c * cell, r * cell, cell + 0.3, cell + 0.3),
            darkPaint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PairingMatrixPainter oldDelegate) {
    return oldDelegate.payload != payload;
  }
}
