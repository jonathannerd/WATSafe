import 'package:flutter/material.dart';

import '../../core/alarm/alarm_controller.dart';
import '../theme/watsafe_theme.dart';

/// Paired Devices & Remote Notifications screen showing an honest unconfigured
/// and empty state until the Backend & Notifications teammate connects real
/// authenticated pairing and APNs/FCM push services.
class PairedDevicesScreen extends StatelessWidget {
  const PairedDevicesScreen({super.key, required this.controller});

  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
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
                          const Icon(
                            Icons.cloud_off_outlined,
                            color: WatSafeTheme.amberAccent,
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
                      vertical: 44,
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
                          'No Paired Devices (Service Not Configured)',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'WATSafe only displays real local hardware and verified paired devices. '
                          'Device pairing, ownership verification, and remote push dispatch (APNs/FCM) '
                          'will appear here once the backend relay service is connected.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: WatSafeTheme.warmMuted),
                        ),
                      ],
                    ),
                  ),
                ),
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
}
