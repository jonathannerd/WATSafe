import 'package:flutter/material.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';
import '../theme/watsafe_theme.dart';

/// Paired Devices & Remote Notifications screen supporting interactive
/// companion device pairing, unpairing, and backend relay configuration while
/// honestly reporting `NOT CONFIGURED` when no devices or relay are set up.
class PairedDevicesScreen extends StatefulWidget {
  const PairedDevicesScreen({super.key, required this.controller});

  final AlarmController controller;

  @override
  State<PairedDevicesScreen> createState() => _PairedDevicesScreenState();
}

class _PairedDevicesScreenState extends State<PairedDevicesScreen> {
  final TextEditingController _deviceNameController = TextEditingController();
  final TextEditingController _pairingCodeController = TextEditingController(
    text: 'WAT-842',
  );
  late final TextEditingController _endpointController;
  String _selectedPlatform = 'Android (FCM)';
  String? _feedbackMessage;

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
    _deviceNameController.dispose();
    _pairingCodeController.dispose();
    _endpointController.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final status = controller.notificationStatus;
    final devices = controller.pairedDevices;
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
                      vertical: 36,
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
                          'Pair a companion phone below to dispatch metadata-only incident alerts when an alarm triggers.',
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
                        Text(
                          'Active Paired Companion Devices (${devices.length})',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
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
                        '• Desktop (macOS / Windows) protects laptops locally and dispatches authenticated incident alerts to paired phones when configured.\n'
                        '• Mobile (iOS / Android) receives push alerts from paired laptops and can monitor its own sensors where OS rules permit.\n'
                        '• iOS lifecycle constraint: iOS suspends background motion capture after screen lock or app backgrounding; backgrounded iOS devices can still receive remote APNs alerts from paired laptops.\n'
                        '• Security boundary: APNs (.p8) and FCM service-account keys must remain strictly on the backend server—never embedded in the Flutter client.',
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
