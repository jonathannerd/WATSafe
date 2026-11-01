import 'package:flutter/material.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/alarm/alarm_state.dart';
import '../../core/models/incident_models.dart';
import '../theme/watsafe_theme.dart';

/// Incident history screen displaying real detector triggers, manual test
/// incidents (clearly labeled), and detector failures, with an honest empty state.
class IncidentsScreen extends StatelessWidget {
  const IncidentsScreen({super.key, required this.controller});

  final AlarmController controller;

  String _formatDateTime(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final incidents = controller.incidents;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Local Incident History',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Privacy guarantee: Incident logs contain timestamps and motion telemetry only—never camera frames or PIN data.',
                          style: TextStyle(
                            color: WatSafeTheme.warmMuted,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (incidents.isNotEmpty &&
                      controller.state != ProtectionState.alarming) ...<Widget>[
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      key: const Key('clear_incidents_button'),
                      onPressed: controller.clearIncidentHistory,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Clear History'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 20),
              if (incidents.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 48,
                    ),
                    child: Column(
                      children: <Widget>[
                        const Icon(
                          Icons.history_toggle_off_outlined,
                          size: 48,
                          color: WatSafeTheme.warmSubtle,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'No Local Incidents Recorded',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Real detector triggers and manual Test Alarm runs on this device will appear here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: WatSafeTheme.warmMuted),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...incidents.map((incident) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _IncidentCard(
                      incident: incident,
                      formatDateTime: _formatDateTime,
                    ),
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }
}

class _IncidentCard extends StatelessWidget {
  const _IncidentCard({required this.incident, required this.formatDateTime});

  final IncidentRecord incident;
  final String Function(DateTime) formatDateTime;

  @override
  Widget build(BuildContext context) {
    final Color badgeColor;
    final String badgeText;

    switch (incident.kind) {
      case IncidentKind.realDetectorTrigger:
        badgeColor = WatSafeTheme.alarmCrimson;
        badgeText = 'REAL DETECTOR TRIGGER';
      case IncidentKind.manualTestAlarm:
        badgeColor = WatSafeTheme.amberAccent;
        badgeText = 'TEST EVENT (SIMULATED)';
      case IncidentKind.detectorFailureDuringMonitoring:
        badgeColor = WatSafeTheme.orangeAccent;
        badgeText = 'DETECTOR FAILURE';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: badgeColor),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
                Text(
                  formatDateTime(incident.triggeredAt),
                  style: const TextStyle(
                    color: WatSafeTheme.warmMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              incident.triggerSummary,
              style: const TextStyle(
                color: WatSafeTheme.warmOffWhite,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 20,
              runSpacing: 6,
              children: <Widget>[
                if (incident.detectorType != null)
                  Text(
                    'Detector: ${incident.detectorType!.displayName}',
                    style: const TextStyle(
                      color: WatSafeTheme.warmMuted,
                      fontSize: 12.5,
                    ),
                  ),
                if (incident.peakMotionScore != null)
                  Text(
                    'Peak Motion Score: ${incident.peakMotionScore!.toStringAsFixed(3)}',
                    style: const TextStyle(
                      color: WatSafeTheme.warmMuted,
                      fontSize: 12.5,
                    ),
                  ),
                Text(
                  'Resolution: ${incident.resolutionSummary}',
                  style: const TextStyle(
                    color: WatSafeTheme.warmMuted,
                    fontSize: 12.5,
                  ),
                ),
                if (incident.resolvedAt != null)
                  Text(
                    'Resolved At: ${formatDateTime(incident.resolvedAt!)}',
                    style: const TextStyle(
                      color: WatSafeTheme.warmMuted,
                      fontSize: 12.5,
                    ),
                  ),
                Text(
                  'Remote Alert: ${incident.remoteNotificationStatus}',
                  style: const TextStyle(
                    color: WatSafeTheme.warmSubtle,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
