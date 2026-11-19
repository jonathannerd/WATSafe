import 'package:flutter/material.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/contracts/platform_contracts.dart';
import '../../core/models/incident_models.dart';
import '../devices/device_geographic_map.dart';
import '../theme/watsafe_theme.dart';

/// Unified chronological Activity feed showing alarm and test events across
/// both this device and any paired laptop, with an interactive incident map,
/// alarm-time vs latest location comparison, filtered movement trail, and
/// **Center on device**.
class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key, required this.controller});

  final AlarmController controller;

  List<_ActivityEntry> _buildMergedEntries() {
    final byId = <String, _ActivityEntry>{};

    for (final inc in controller.incidents) {
      byId[inc.id] = _ActivityEntry.fromIncident(
        inc,
        fallbackDeviceName: controller.effectiveDeviceName,
      );
    }

    for (final alert in controller.receivedCompanionAlerts) {
      final existing = byId[alert.incidentId];
      final fromAlert = _ActivityEntry.fromCompanionAlert(alert);
      if (existing == null) {
        byId[alert.incidentId] = fromAlert;
      } else {
        final nextLocation = fromAlert.location ?? existing.location;
        final nextAlarmLocation =
            existing.alarmTimeLocation ?? fromAlert.alarmTimeLocation;
        final nextTrail =
            fromAlert.locationTrail.length > existing.locationTrail.length
            ? fromAlert.locationTrail
            : existing.locationTrail;
        final nextStatus = nextLocation != null
            ? IncidentLocationStatus.attached
            : (existing.locationStatus == IncidentLocationStatus.pending &&
                      fromAlert.locationStatus != IncidentLocationStatus.pending
                  ? fromAlert.locationStatus
                  : existing.locationStatus);
        byId[alert.incidentId] = existing.copyWithLocationData(
          nextLocation: nextLocation,
          nextAlarmLocation: nextAlarmLocation,
          nextTrail: nextTrail,
          nextStatus: nextStatus,
          nextTrackingState: fromAlert.locationTrackingState,
        );
      }
    }

    final list = byId.values.toList()
      ..sort((a, b) => b.triggeredAt.compareTo(a.triggeredAt));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _buildMergedEntries();
    final palette = WatSafeTheme.of(context);
    final selectedId = controller.selectedActivityIncidentId;
    final selectedEntry = selectedId == null
        ? null
        : entries.where((e) => e.id == selectedId).firstOrNull;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Activity',
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                'Recent alarms and test alerts from your protected devices.',
                style: TextStyle(color: palette.textMuted),
              ),
              const SizedBox(height: 20),
              if (selectedEntry != null) ...<Widget>[
                _SelectedEventDetailCard(
                  entry: selectedEntry,
                  controller: controller,
                ),
                const SizedBox(height: 20),
              ],
              if (entries.isEmpty)
                const _EmptyActivityCard()
              else
                ...entries.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _ActivityEventRow(
                      entry: entry,
                      isSelected: entry.id == selectedId,
                      onSelect: () =>
                          controller.openIncidentInActivity(entry.id),
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

@immutable
class _ActivityEntry {
  const _ActivityEntry({
    required this.id,
    required this.deviceName,
    required this.title,
    required this.summary,
    required this.triggeredAt,
    required this.isTest,
    required this.isFailure,
    required this.location,
    required this.alarmTimeLocation,
    required this.locationTrail,
    required this.locationStatus,
    required this.locationTrackingState,
    this.resolutionSummary,
  });

  final String id;
  final String deviceName;
  final String title;
  final String summary;
  final DateTime triggeredAt;
  final bool isTest;
  final bool isFailure;
  final DeviceLocationSnapshot? location;
  final DeviceLocationSnapshot? alarmTimeLocation;
  final List<DeviceLocationSnapshot> locationTrail;
  final IncidentLocationStatus locationStatus;
  final String locationTrackingState;
  final String? resolutionSummary;

  bool get hasDistinctLatestLocation =>
      location != null &&
      alarmTimeLocation != null &&
      location!.differsMeaningfullyFrom(alarmTimeLocation!);

  static bool _isCameraObstructionSummary(String raw) {
    final lower = raw.toLowerCase();
    return lower.contains('camera') &&
        (lower.contains('block') ||
            lower.contains('cover') ||
            lower.contains('obstruct'));
  }

  factory _ActivityEntry.fromIncident(
    IncidentRecord inc, {
    required String fallbackDeviceName,
  }) {
    final String title = switch (inc.kind) {
      IncidentKind.realDetectorTrigger => 'Alarm triggered',
      IncidentKind.manualTestAlarm => 'Test alert',
      IncidentKind.detectorFailureDuringMonitoring => 'Monitoring stopped',
      IncidentKind.protectionInterrupted =>
        _isCameraObstructionSummary(inc.triggerSummary)
            ? 'Camera blocked'
            : 'Protection interrupted',
    };
    return _ActivityEntry(
      id: inc.id,
      deviceName: (inc.deviceName != null && inc.deviceName!.trim().isNotEmpty)
          ? inc.deviceName!.trim()
          : fallbackDeviceName,
      title: title,
      summary: inc.triggerSummary,
      triggeredAt: inc.triggeredAt,
      isTest: inc.kind == IncidentKind.manualTestAlarm,
      isFailure:
          inc.kind == IncidentKind.detectorFailureDuringMonitoring ||
          inc.kind == IncidentKind.protectionInterrupted,
      location: inc.location,
      alarmTimeLocation: inc.effectiveAlarmLocation,
      locationTrail: inc.locationTrail,
      locationStatus: inc.locationStatus,
      locationTrackingState: inc.locationTrackingState,
      resolutionSummary: inc.resolutionSummary,
    );
  }

  factory _ActivityEntry.fromCompanionAlert(CompanionAlertEvent alert) {
    final isInterrupted = alert.kind == 'protectionInterrupted';
    final isFailure =
        alert.kind == 'detectorFailureDuringMonitoring' || isInterrupted;
    final title = alert.isTest
        ? 'Test alert'
        : (isInterrupted
              ? (_isCameraObstructionSummary(alert.triggerSummary)
                    ? 'Camera blocked'
                    : 'Protection interrupted')
              : (isFailure ? 'Monitoring stopped' : 'Alarm triggered'));
    return _ActivityEntry(
      id: alert.incidentId,
      deviceName:
          (alert.hostDisplayName != null &&
              alert.hostDisplayName!.trim().isNotEmpty)
          ? alert.hostDisplayName!.trim()
          : 'Protected Laptop',
      title: title,
      summary: alert.triggerSummary,
      triggeredAt: alert.triggeredAt,
      isTest: alert.isTest,
      isFailure: isFailure,
      location: alert.location,
      alarmTimeLocation: alert.effectiveAlarmLocation,
      locationTrail: alert.locationTrail,
      locationStatus: alert.locationStatus,
      locationTrackingState: alert.locationTrackingState,
    );
  }

  _ActivityEntry copyWithLocationData({
    required DeviceLocationSnapshot? nextLocation,
    required DeviceLocationSnapshot? nextAlarmLocation,
    required List<DeviceLocationSnapshot> nextTrail,
    required IncidentLocationStatus nextStatus,
    required String nextTrackingState,
  }) {
    return _ActivityEntry(
      id: id,
      deviceName: deviceName,
      title: title,
      summary: summary,
      triggeredAt: triggeredAt,
      isTest: isTest,
      isFailure: isFailure,
      location: nextLocation,
      alarmTimeLocation: nextAlarmLocation,
      locationTrail: nextTrail,
      locationStatus: nextStatus,
      locationTrackingState: nextTrackingState,
      resolutionSummary: resolutionSummary,
    );
  }
}

class _ActivityEventRow extends StatelessWidget {
  const _ActivityEventRow({
    required this.entry,
    required this.isSelected,
    required this.onSelect,
  });

  final _ActivityEntry entry;
  final bool isSelected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final accent = entry.isTest
        ? WatSafeTheme.infoSteel
        : (entry.isFailure
              ? WatSafeTheme.amberAccent
              : WatSafeTheme.alarmCrimson);

    return Card(
      key: Key('activity_row_${entry.id}'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isSelected ? accent : WatSafeTheme.charcoalBorder,
          width: isSelected ? 1.8 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  entry.isTest
                      ? Icons.notifications_active_outlined
                      : (entry.isFailure
                            ? Icons.pause_circle_outline_rounded
                            : Icons.warning_amber_rounded),
                  color: accent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      entry.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15.5,
                        color: WatSafeTheme.of(context).textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${entry.deviceName} • ${_formatEventTime(entry.triggeredAt)}',
                      style: TextStyle(
                        fontSize: 13,
                        color: WatSafeTheme.of(context).textMuted,
                      ),
                    ),
                    if (entry.locationStatus ==
                        IncidentLocationStatus.pending) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        'Getting device location…',
                        style: TextStyle(
                          fontSize: 12,
                          color: WatSafeTheme.of(context).warningColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (entry.location != null) ...<Widget>[
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  key: Key('view_location_${entry.id}'),
                  onPressed: onSelect,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  icon: const Icon(Icons.location_on_outlined, size: 17),
                  label: const Text('View location'),
                ),
              ] else
                Icon(
                  Icons.chevron_right_rounded,
                  color: WatSafeTheme.of(context).textMuted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectedEventDetailCard extends StatelessWidget {
  const _SelectedEventDetailCard({
    required this.entry,
    required this.controller,
  });

  final _ActivityEntry entry;
  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final accent = entry.isTest
        ? palette.infoColor
        : (entry.isFailure ? palette.warningColor : palette.alarmColor);
    final loc = entry.location;

    return Card(
      key: const Key('activity_selected_event_card'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: accent.withValues(alpha: 0.7), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        entry.title,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${entry.deviceName} • ${_formatEventTime(entry.triggeredAt)}',
                        style: TextStyle(
                          color: palette.textMuted,
                          fontSize: 13.5,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close details',
                  onPressed: controller.clearSelectedActivityIncident,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              entry.summary,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 14.5,
                height: 1.4,
              ),
            ),
            if (entry.resolutionSummary != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                entry.resolutionSummary!,
                style: TextStyle(color: palette.textSubtle, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 18),
            const Divider(height: 1),
            const SizedBox(height: 16),
            if (loc != null && loc.isValid)
              _LocationPreviewSection(entry: entry, location: loc)
            else
              _UnavailableLocationNotice(status: entry.locationStatus),
          ],
        ),
      ),
    );
  }
}

class _LocationPreviewSection extends StatefulWidget {
  const _LocationPreviewSection({required this.entry, required this.location});

  final _ActivityEntry entry;
  final DeviceLocationSnapshot location;

  @override
  State<_LocationPreviewSection> createState() =>
      _LocationPreviewSectionState();
}

class _LocationPreviewSectionState extends State<_LocationPreviewSection> {
  final GlobalKey<DeviceGeographicMapState> _mapKey =
      GlobalKey<DeviceGeographicMapState>();

  (String?, Color?) _trackingBadge() {
    final state = widget.entry.locationTrackingState;
    if (state == 'live') {
      return ('Live', WatSafeTheme.readyEmerald);
    }
    if (state == 'recent') {
      return (null, null);
    }
    if (state == 'reconnecting') {
      return ('Reconnecting', WatSafeTheme.amberAccent);
    }
    return ('Last known location', WatSafeTheme.infoSteel);
  }

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final location = widget.location;
    final entry = widget.entry;
    final badge = _trackingBadge();
    final now = DateTime.now();

    return Column(
      key: const Key('event_location_card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(
              Icons.location_on_rounded,
              color: palette.accentPrimary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${entry.deviceName} location',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            Container(
              key: const Key('location_precision_badge'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: palette.borderColor),
              ),
              child: Text(
                location.precisionLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color:
                      (location.isEffectivelyApproximate ||
                          location.isLastKnown)
                      ? palette.warningColor
                      : palette.readyColor,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        DeviceGeographicMap(
          key: _mapKey,
          height: 210,
          primaryLocation: location,
          alarmTimeLocation: entry.alarmTimeLocation,
          trail: entry.locationTrail,
          trackingStateLabel: badge.$1,
          trackingStateTone: badge.$2,
          showCenterButtonOverlay: false,
        ),
        const SizedBox(height: 12),
        if (entry.hasDistinctLatestLocation &&
            entry.alarmTimeLocation != null) ...<Widget>[
          Container(
            key: const Key('alarm_vs_latest_location_card'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.surfaceElevated,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _CoordinateComparisonRow(
                  dotColor: palette.warningColor,
                  label: 'Alarm-time location',
                  value:
                      '${entry.alarmTimeLocation!.formattedCoordinates} (${_formatShortTime(entry.alarmTimeLocation!.capturedAt)})',
                ),
                const SizedBox(height: 8),
                _CoordinateComparisonRow(
                  dotColor: palette.alarmColor,
                  label: 'Latest known location',
                  value:
                      '${location.formattedCoordinates} • ${location.accuracyDescription}',
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ] else ...<Widget>[
          Text(
            '${location.formattedCoordinates} • ${location.accuracyDescription}',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
        ],
        if (entry.locationTrail.length >= 2) ...<Widget>[
          Text(
            '${entry.locationTrail.length} verified location updates (${_formatShortTime(entry.locationTrail.first.capturedAt)} → ${_formatShortTime(entry.locationTrail.last.capturedAt)})',
            key: const Key('incident_trail_summary'),
            style: TextStyle(
              fontSize: 12.5,
              color: palette.accentPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
        ],
        Text(
          'Recorded ${_formatEventTime(location.capturedAt)} • ${location.relativeAgeLabel(now, forceLastKnown: entry.locationTrackingState == 'last_known')}',
          key: const Key('location_recorded_time_label'),
          style: TextStyle(fontSize: 12.5, color: palette.textMuted),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('incident_center_on_device_button'),
            onPressed: () => _mapKey.currentState?.centerOnDevice(),
            icon: const Icon(Icons.my_location_rounded, size: 18),
            label: const Text('Center on device'),
          ),
        ),
      ],
    );
  }
}

class _CoordinateComparisonRow extends StatelessWidget {
  const _CoordinateComparisonRow({
    required this.dotColor,
    required this.label,
    required this.value,
  });

  final Color dotColor;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: WatSafeTheme.of(context).textMuted,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: WatSafeTheme.of(context).textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UnavailableLocationNotice extends StatelessWidget {
  const _UnavailableLocationNotice({required this.status});

  final IncidentLocationStatus status;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final String message = switch (status) {
      IncidentLocationStatus.pending => 'Getting device location… This map will update automatically as soon as coordinates arrive.',
      IncidentLocationStatus.permissionDenied => 'Location unavailable — location permission was turned off on the protected device when this alarm triggered.',
      IncidentLocationStatus.notRequested => 'Location unavailable — location sharing on alarm was turned off in Settings.',
      IncidentLocationStatus.unavailable || IncidentLocationStatus.attached => 'Location unavailable — the protected device could not determine its location when this alarm triggered.',
    };

    return Container(
      key: const Key('location_unavailable_notice'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (status == IncidentLocationStatus.pending)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: palette.accentPrimary,
                ),
              ),
            )
          else
            Icon(
              Icons.location_off_outlined,
              color: palette.textMuted,
              size: 20,
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyActivityCard extends StatelessWidget {
  const _EmptyActivityCard();

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
        child: Column(
          children: <Widget>[
            Icon(
              Icons.check_circle_outline_rounded,
              size: 44,
              color: palette.readyColor,
            ),
            const SizedBox(height: 12),
            Text(
              'No alarm events yet',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'When an alarm or test alert happens on your protected device, it will appear here with the time and location.',
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.textMuted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatEventTime(DateTime dt) {
  final local = dt.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  final ss = local.second.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm:$ss';
}

String _formatShortTime(DateTime dt) {
  final local = dt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  final ss = local.second.toString().padLeft(2, '0');
  return '$hh:$mm:$ss';
}
