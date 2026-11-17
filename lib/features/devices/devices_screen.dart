import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';
import '../theme/watsafe_theme.dart';
import 'device_geographic_map.dart';

/// Dedicated **Devices** destination showing authorized devices on an
/// interactive map with clear online/offline badges, relative update age,
/// accuracy circles, "Center on device", "Open in Maps", and actionable
/// "Location unavailable" explanations.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.controller});

  final AlarmController controller;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final GlobalKey<DeviceGeographicMapState> _mapKey =
      GlobalKey<DeviceGeographicMapState>();
  String? _selectedDeviceId;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshDevices(initial: true));
  }

  Future<void> _refreshDevices({bool initial = false}) async {
    if (_isRefreshing) {
      return;
    }
    setState(() {
      _isRefreshing = true;
    });
    try {
      if (widget.controller.settings.shareLocationOnAlarm &&
          widget.controller.isLocationSupported &&
          widget.controller.locationPermissionStatus ==
              PermissionStatus.granted &&
          (!initial || widget.controller.hostLatestLocation == null)) {
        await widget.controller.refreshProtectedDeviceLocation(
          highAccuracy: !initial,
        );
      }
      await widget.controller.refreshAuthorizedDeviceLocations();
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
        });
      }
    }
  }

  AuthorizedDeviceLocationSummary? _resolveSelected(
    List<AuthorizedDeviceLocationSummary> devices,
  ) {
    if (devices.isEmpty) {
      return null;
    }
    if (_selectedDeviceId != null) {
      for (final d in devices) {
        if (d.deviceId == _selectedDeviceId) {
          return d;
        }
      }
    }
    for (final d in devices) {
      if (d.isProtectedDevice) {
        return d;
      }
    }
    return devices.first;
  }

  (String?, Color?) _trackingBadgeFor(AuthorizedDeviceLocationSummary? device) {
    if (device == null || !device.hasUsableLocation) {
      return (null, null);
    }
    return switch (device.trackingState) {
      'live' => ('Live', WatSafeTheme.readyEmerald),
      'reconnecting' => ('Reconnecting', WatSafeTheme.amberAccent),
      _ => ('Last known location', WatSafeTheme.infoSteel),
    };
  }

  @override
  Widget build(BuildContext context) {
    final devices = widget.controller.authorizedDeviceLocations;
    final selected = _resolveSelected(devices);
    final markers = <DeviceMapMarker>[
      for (final d in devices)
        if (d.hasUsableLocation)
          DeviceMapMarker(
            id: d.deviceId,
            label: d.displayName,
            location: d.latestLocation!,
            isSelected: selected?.deviceId == d.deviceId,
            isAlarming: d.isAlarming,
            isOnline: d.online,
          ),
    ];
    final trackingBadge = _trackingBadgeFor(selected);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wideLayout = constraints.maxWidth >= 900;

        if (wideLayout) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _buildHeader(context),
                    const SizedBox(height: 18),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Expanded(
                            flex: 7,
                            child: _buildMapArea(
                              selected: selected,
                              markers: markers,
                              trackingBadge: trackingBadge,
                              height: constraints.maxHeight - 110,
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            flex: 5,
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  if (selected != null) ...<Widget>[
                                    _SelectedDeviceDetailCard(
                                      device: selected,
                                      controller: widget.controller,
                                      onCenterMap: () => _mapKey.currentState
                                          ?.centerOnDevice(),
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                  _buildDeviceRoster(devices, selected),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _buildHeader(context),
                  const SizedBox(height: 16),
                  _buildMapArea(
                    selected: selected,
                    markers: markers,
                    trackingBadge: trackingBadge,
                    height: 248,
                  ),
                  const SizedBox(height: 16),
                  if (selected != null) ...<Widget>[
                    _SelectedDeviceDetailCard(
                      device: selected,
                      controller: widget.controller,
                      onCenterMap: () => _mapKey.currentState?.centerOnDevice(),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _buildDeviceRoster(devices, selected),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Devices',
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                'Protected devices and paired phones on your account.',
                style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 13.5),
              ),
            ],
          ),
        ),
        OutlinedButton.icon(
          key: const Key('refresh_devices_map_button'),
          onPressed: _isRefreshing ? null : () => _refreshDevices(),
          icon: _isRefreshing
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_rounded, size: 18),
          label: Text(_isRefreshing ? 'Updating…' : 'Refresh'),
        ),
      ],
    );
  }

  Widget _buildMapArea({
    required AuthorizedDeviceLocationSummary? selected,
    required List<DeviceMapMarker> markers,
    required (String?, Color?) trackingBadge,
    required double height,
  }) {
    final safeHeight = height.clamp(220.0, 680.0);
    if (markers.isEmpty) {
      return Container(
        key: const Key('devices_map_unavailable_placeholder'),
        height: safeHeight,
        decoration: BoxDecoration(
          color: WatSafeTheme.charcoalSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: WatSafeTheme.charcoalBorder),
        ),
        padding: const EdgeInsets.all(24),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.location_off_outlined,
              size: 36,
              color: WatSafeTheme.amberAccent,
            ),
            const SizedBox(height: 12),
            Text(
              'Location unavailable',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              selected?.statusExplanation ?? 'Allow location access on your protected device so its position can appear here.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: WatSafeTheme.warmMuted,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ],
        ),
      );
    }

    return DeviceGeographicMap(
      key: _mapKey,
      height: safeHeight,
      primaryLocation: selected?.hasUsableLocation == true
          ? selected!.latestLocation
          : null,
      alarmTimeLocation: selected?.alarmTimeLocation,
      trail: selected?.locationTrail ?? const [],
      markers: markers,
      selectedMarkerId: selected?.deviceId,
      onSelectMarker: (deviceId) {
        setState(() {
          _selectedDeviceId = deviceId;
        });
      },
      trackingStateLabel: trackingBadge.$1,
      trackingStateTone: trackingBadge.$2,
      showCenterButtonOverlay: false,
    );
  }

  Widget _buildDeviceRoster(
    List<AuthorizedDeviceLocationSummary> devices,
    AuthorizedDeviceLocationSummary? selected,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text(
          'Authorized devices',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: WatSafeTheme.warmMuted,
          ),
        ),
        const SizedBox(height: 8),
        for (final device in devices)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _DeviceListRow(
              device: device,
              isSelected: selected?.deviceId == device.deviceId,
              onSelect: () {
                setState(() {
                  _selectedDeviceId = device.deviceId;
                });
              },
            ),
          ),
      ],
    );
  }
}

class _SelectedDeviceDetailCard extends StatelessWidget {
  const _SelectedDeviceDetailCard({
    required this.device,
    required this.controller,
    required this.onCenterMap,
  });

  final AuthorizedDeviceLocationSummary device;
  final AlarmController controller;
  final VoidCallback onCenterMap;

  @override
  Widget build(BuildContext context) {
    final loc = device.latestLocation;
    final hasValidLoc = loc != null && loc.isValid;
    final statusColor = device.isAlarming
        ? WatSafeTheme.alarmCrimson
        : (device.online ? WatSafeTheme.readyEmerald : WatSafeTheme.warmMuted);
    final now = DateTime.now();

    return Card(
      key: const Key('selected_device_detail_card'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    device.isProtectedDevice
                        ? Icons.laptop_mac_rounded
                        : Icons.smartphone_rounded,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        device.displayName,
                        key: const Key('selected_device_name_label'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${device.online ? "Online" : "Offline"} • ${device.protectionStatusLabel}',
                        key: const Key('selected_device_status_label'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 14),
            if (hasValidLoc) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      loc.formattedCoordinates,
                      key: const Key('selected_device_coordinates_label'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: WatSafeTheme.warmOffWhite,
                      ),
                    ),
                  ),
                  Container(
                    key: const Key('selected_device_accuracy_badge'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: WatSafeTheme.charcoalElevated,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: WatSafeTheme.charcoalBorder),
                    ),
                    child: Text(
                      loc.accuracyDescription,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: loc.isEffectivelyApproximate
                            ? WatSafeTheme.amberAccent
                            : WatSafeTheme.readyEmerald,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                loc.relativeAgeLabel(now),
                key: const Key('selected_device_updated_age_label'),
                style: const TextStyle(
                  fontSize: 13,
                  color: WatSafeTheme.warmMuted,
                ),
              ),
              if (!device.online) ...<Widget>[
                const SizedBox(height: 6),
                const Text(
                  'Showing last known location. Sleeping, offline, or powered-off devices cannot send live updates until they reconnect.',
                  style: TextStyle(
                    fontSize: 12,
                    color: WatSafeTheme.amberAccent,
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  OutlinedButton.icon(
                    key: const Key('devices_center_on_device_button'),
                    onPressed: onCenterMap,
                    icon: const Icon(Icons.my_location_rounded, size: 18),
                    label: const Text('Center on device'),
                  ),
                  FilledButton.icon(
                    key: const Key('devices_open_in_maps_button'),
                    onPressed: () async {
                      final opened = await controller.openExternalUrl(
                        loc.mapsUrl,
                      );
                      if (!opened && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Maps link: ${loc.mapsUrl}')),
                        );
                      }
                    },
                    icon: const Icon(Icons.map_rounded, size: 18),
                    label: const Text('Open in Maps'),
                  ),
                  if (device.activeIncidentId != null)
                    TextButton.icon(
                      key: const Key('devices_open_active_incident_button'),
                      onPressed: () => controller.openIncidentInActivity(
                        device.activeIncidentId!,
                      ),
                      icon: const Icon(Icons.warning_amber_rounded, size: 18),
                      label: const Text('Follow incident'),
                    ),
                ],
              ),
            ] else ...<Widget>[
              Container(
                key: const Key('devices_location_unavailable_banner'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: WatSafeTheme.charcoalElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: WatSafeTheme.charcoalBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Location unavailable',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: WatSafeTheme.warmOffWhite,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      device.statusExplanation ?? 'No usable location has been reported for this device yet.',
                      style: const TextStyle(
                        fontSize: 13,
                        color: WatSafeTheme.warmMuted,
                        height: 1.35,
                      ),
                    ),
                    if (device.isProtectedDevice &&
                        device.deviceId == 'local_protected_host') ...<Widget>[
                      const SizedBox(height: 10),
                      if (!controller.settings.shareLocationOnAlarm)
                        OutlinedButton.icon(
                          key: const Key('devices_enable_location_sharing_btn'),
                          onPressed: () =>
                              controller.updateShareLocationOnAlarm(true),
                          icon: const Icon(
                            Icons.location_on_outlined,
                            size: 18,
                          ),
                          label: const Text('Turn on location sharing'),
                        )
                      else if (controller.isLocationSupported &&
                          controller.locationPermissionStatus !=
                              PermissionStatus.granted)
                        OutlinedButton.icon(
                          key: const Key('devices_grant_location_perm_btn'),
                          onPressed: () async {
                            final status = await controller
                                .requestLocationPermission();
                            if (status == PermissionStatus.granted) {
                              await controller.refreshProtectedDeviceLocation(
                                highAccuracy: true,
                              );
                            }
                          },
                          icon: const Icon(Icons.my_location_rounded, size: 18),
                          label: const Text('Allow location access'),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DeviceListRow extends StatelessWidget {
  const _DeviceListRow({
    required this.device,
    required this.isSelected,
    required this.onSelect,
  });

  final AuthorizedDeviceLocationSummary device;
  final bool isSelected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final loc = device.latestLocation;
    final now = DateTime.now();
    final String subtitle;
    if (loc != null && loc.isValid) {
      subtitle =
          '${device.online ? "Online" : "Offline"} • ${loc.relativeAgeLabel(now)}';
    } else {
      subtitle =
          '${device.online ? "Online" : "Offline"} • ${device.isProtectedDevice ? "Location unavailable" : device.protectionStatusLabel}';
    }

    final dotColor = device.isAlarming
        ? WatSafeTheme.alarmCrimson
        : (device.online ? WatSafeTheme.readyEmerald : WatSafeTheme.warmMuted);

    return Card(
      key: Key('device_row_${device.deviceId}'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(13),
        side: BorderSide(
          color: isSelected
              ? WatSafeTheme.amberAccent
              : WatSafeTheme.charcoalBorder,
          width: isSelected ? 1.6 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: <Widget>[
              Icon(
                device.isProtectedDevice
                    ? Icons.laptop_mac_rounded
                    : Icons.smartphone_rounded,
                color: isSelected
                    ? WatSafeTheme.amberAccent
                    : WatSafeTheme.warmMuted,
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
                        fontSize: 14.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: WatSafeTheme.warmMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
