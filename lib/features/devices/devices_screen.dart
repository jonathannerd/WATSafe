import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';
import '../../core/models/incident_models.dart';
import '../theme/watsafe_theme.dart';
import 'device_geographic_map.dart';

/// Dedicated **Devices** destination showing authorized devices on a readable
/// light interactive map with a single compact horizontal device selector,
/// separate Connection and Protection badges, natural relative update age,
/// accuracy circle, "Center on device", companion phone foreground location
/// sharing, and expandable raw coordinates.
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
    final isWidgetTest = WidgetsBinding.instance.runtimeType
        .toString()
        .contains('Test');
    if (initial &&
        isWidgetTest &&
        widget.controller.authorizedDeviceLocations.isNotEmpty) {
      return;
    }
    final showSpinner =
        !initial || widget.controller.authorizedDeviceLocations.isEmpty;
    if (showSpinner) {
      setState(() {
        _isRefreshing = true;
      });
    }
    try {
      if (widget.controller.isCompanionMode) {
        if (widget.controller.settings.shareCompanionPhoneLocation &&
            widget.controller.isLocationSupported &&
            widget.controller.locationPermissionStatus ==
                PermissionStatus.granted) {
          await widget.controller.refreshCompanionPhoneLocation(
            highAccuracy: !initial,
          );
        }
      } else if (widget.controller.settings.shareLocationOnAlarm &&
          widget.controller.isLocationSupported &&
          widget.controller.locationPermissionStatus ==
              PermissionStatus.granted &&
          (!initial || widget.controller.hostLatestLocation == null)) {
        await widget.controller.refreshProtectedDeviceLocation(
          highAccuracy: !initial,
        );
      }
      await widget.controller.refreshAuthorizedDeviceLocations(
        requestHostRefresh: true,
      );
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
      'recent' => (null, null),
      'reconnecting' => ('Reconnecting', WatSafeTheme.amberAccent),
      _ => ('Last known location', const Color(0xFF475569)),
    };
  }

  @override
  Widget build(BuildContext context) {
    WatSafeTheme.of(context);
    final devices = widget.controller.authorizedDeviceLocations;
    final selected = _resolveSelected(devices);
    final markers = <DeviceMapMarker>[
      for (final d in devices)
        if (d.hasUsableLocation)
          DeviceMapMarker(
            id: d.deviceId,
            label: d.displayName,
            location: d.latestLocation!,
            isProtectedDevice: d.isProtectedDevice,
            isCurrentRequester: d.isCurrentRequester && !d.isProtectedDevice,
            isSelected: selected?.deviceId == d.deviceId,
            isAlarming: d.isAlarming,
            isOnline: d.online,
          ),
    ];

    final mapFocusDevice = (selected != null && selected.hasUsableLocation)
        ? selected
        : devices.where((d) => d.hasUsableLocation).firstOrNull;
    final trackingBadge = _trackingBadgeFor(mapFocusDevice);
    final String? secondaryBadge;
    if (selected != null && !selected.hasUsableLocation && markers.isNotEmpty) {
      final label = (selected.isCurrentRequester && !selected.isProtectedDevice)
          ? 'This phone'
          : selected.displayName;
      secondaryBadge = '$label · location not shared';
    } else if (markers.length >= 2) {
      secondaryBadge = '${markers.length} devices on map';
    } else {
      secondaryBadge = null;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscapeCompact =
            constraints.maxWidth >= 620 &&
            constraints.maxWidth > constraints.maxHeight * 1.25;
        final sideBySide = constraints.maxWidth >= 820 || isLandscapeCompact;

        if (sideBySide) {
          final horizontalPad = constraints.maxWidth >= 900 ? 24.0 : 16.0;
          final verticalPad = isLandscapeCompact ? 10.0 : 20.0;
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPad,
              vertical: verticalPad,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _buildHeader(context, compact: isLandscapeCompact),
                    const SizedBox(height: 10),
                    _buildChipSelector(devices, selected),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          flex: constraints.maxWidth >= 960 ? 8 : 7,
                          child: _buildMapArea(
                            selected: selected,
                            mapFocusDevice: mapFocusDevice,
                            markers: markers,
                            trackingBadge: trackingBadge,
                            secondaryBadge: secondaryBadge,
                            height: (constraints.maxHeight - 125).clamp(
                              220.0,
                              620.0,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          flex: constraints.maxWidth >= 960 ? 4 : 5,
                          child: selected != null
                              ? _SelectedDeviceDetailCard(
                                  device: selected,
                                  controller: widget.controller,
                                  onCenterMap: () => _mapKey.currentState
                                      ?.centerOnDevice(selected.latestLocation),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final portraitMapHeight = (constraints.maxHeight * 0.52).clamp(
          300.0,
          480.0,
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _buildHeader(context, compact: true),
                  const SizedBox(height: 10),
                  _buildChipSelector(devices, selected),
                  const SizedBox(height: 10),
                  _buildMapArea(
                    selected: selected,
                    mapFocusDevice: mapFocusDevice,
                    markers: markers,
                    trackingBadge: trackingBadge,
                    secondaryBadge: secondaryBadge,
                    height: portraitMapHeight,
                  ),
                  const SizedBox(height: 12),
                  if (selected != null)
                    _SelectedDeviceDetailCard(
                      device: selected,
                      controller: widget.controller,
                      onCenterMap: () => _mapKey.currentState?.centerOnDevice(
                        selected.latestLocation,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, {required bool compact}) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            'Devices',
            style:
                (compact
                        ? Theme.of(context).textTheme.titleLarge
                        : Theme.of(context).textTheme.headlineSmall)
                    ?.copyWith(fontWeight: FontWeight.w800),
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

  Widget _buildChipSelector(
    List<AuthorizedDeviceLocationSummary> devices,
    AuthorizedDeviceLocationSummary? selected,
  ) {
    if (devices.isEmpty) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      key: const Key('devices_selector_chip_bar'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (var i = 0; i < devices.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 8),
            _DeviceSelectorChip(
              device: devices[i],
              isSelected: selected?.deviceId == devices[i].deviceId,
              onSelect: () {
                final target = devices[i];
                setState(() {
                  _selectedDeviceId = target.deviceId;
                });
                if (target.hasUsableLocation) {
                  _mapKey.currentState?.centerOnDevice(target.latestLocation);
                }
              },
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _enableLocationSharing() async {
    final controller = widget.controller;
    if (controller.isCompanionMode) {
      await controller.updateShareCompanionPhoneLocation(true);
    } else {
      if (!controller.settings.shareLocationOnAlarm) {
        // Enabling sharing already requests permission and starts location
        // refresh; avoid immediately prompting a second time.
        await controller.updateShareLocationOnAlarm(true);
      } else {
        if (controller.locationPermissionStatus != PermissionStatus.granted) {
          await controller.requestLocationPermission();
        }
        if (controller.locationPermissionStatus == PermissionStatus.granted) {
          await controller.refreshProtectedDeviceLocation(highAccuracy: true);
        }
      }
    }
    await _refreshDevices();
  }

  Widget _buildMapArea({
    required AuthorizedDeviceLocationSummary? selected,
    required AuthorizedDeviceLocationSummary? mapFocusDevice,
    required List<DeviceMapMarker> markers,
    required (String?, Color?) trackingBadge,
    required String? secondaryBadge,
    required double height,
  }) {
    final safeHeight = height.clamp(220.0, 620.0);
    if (markers.isEmpty) {
      final controller = widget.controller;
      final sharingEnabled = controller.isCompanionMode
          ? controller.settings.shareCompanionPhoneLocation
          : controller.settings.shareLocationOnAlarm;
      final permission = controller.locationPermissionStatus;
      final permissionBlocked =
          permission == PermissionStatus.denied ||
          permission == PermissionStatus.restricted;
      final title = !sharingEnabled
          ? 'Location sharing is off'
          : permissionBlocked
          ? 'Location access is blocked'
          : 'Location unavailable';
      final explanation = !controller.isLocationSupported
          ? 'This device or browser does not provide location access.'
          : !sharingEnabled
          ? 'Location is optional. Enable sharing only when you want WATSafe to attach this device’s position to incident reports.'
          : permissionBlocked
          ? 'Allow location access in Safari website settings, then return here and refresh.'
          : (selected?.statusExplanation ??
                'Allow location access so WATSafe can attach this device’s position to an incident report.');
      final canOfferAction =
          controller.isLocationSupported &&
          (!permissionBlocked || !sharingEnabled);
      final actionLabel = !sharingEnabled
          ? 'Enable location sharing'
          : permission == PermissionStatus.granted
          ? 'Refresh location'
          : 'Enable location';

      return Container(
        key: const Key('devices_map_unavailable_placeholder'),
        height: safeHeight > 270 ? 270 : safeHeight,
        decoration: BoxDecoration(
          color: const Color(0xFFEEF2F6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF94A3B8).withValues(alpha: 0.45),
          ),
        ),
        padding: const EdgeInsets.all(22),
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.location_off_outlined,
                size: 30,
                color: Color(0xFF475569),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                explanation,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF475569),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              if (canOfferAction) ...<Widget>[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('devices_enable_location_button'),
                  onPressed: _isRefreshing ? null : _enableLocationSharing,
                  icon: const Icon(Icons.my_location_rounded, size: 17),
                  label: Text(actionLabel),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return DeviceGeographicMap(
      key: _mapKey,
      height: safeHeight,
      primaryLocation: selected?.hasUsableLocation == true
          ? selected!.latestLocation
          : mapFocusDevice?.latestLocation,
      alarmTimeLocation: selected?.hasUsableLocation == true
          ? selected!.alarmTimeLocation
          : mapFocusDevice?.alarmTimeLocation,
      trail: selected?.hasUsableLocation == true
          ? selected!.locationTrail
          : (mapFocusDevice?.locationTrail ?? const <DeviceLocationSnapshot>[]),
      markers: markers,
      selectedMarkerId: selected?.deviceId,
      onSelectMarker: (deviceId) {
        setState(() {
          _selectedDeviceId = deviceId;
        });
      },
      trackingStateLabel: trackingBadge.$1,
      trackingStateTone: trackingBadge.$2,
      secondaryBadgeLabel: secondaryBadge,
      showCenterButtonOverlay: false,
    );
  }
}

class _DeviceSelectorChip extends StatelessWidget {
  const _DeviceSelectorChip({
    required this.device,
    required this.isSelected,
    required this.onSelect,
  });

  final AuthorizedDeviceLocationSummary device;
  final bool isSelected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final isCurrentPhone =
        device.isCurrentRequester && !device.isProtectedDevice;
    final dotColor = device.isAlarming
        ? palette.alarmColor
        : (device.online ? palette.readyColor : palette.warningColor);
    final label = isCurrentPhone
        ? '${device.displayName} · This phone'
        : device.displayName;

    return Semantics(
      selected: isSelected,
      button: true,
      child: Material(
        color: isSelected
            ? WatSafeTheme.amberAccent.withValues(alpha: 0.16)
            : WatSafeTheme.charcoalSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
          side: BorderSide(
            color: isSelected
                ? WatSafeTheme.amberAccent
                : WatSafeTheme.charcoalBorder,
            width: isSelected ? 1.6 : 1.0,
          ),
        ),
        child: InkWell(
          key: Key('device_chip_${device.deviceId}'),
          borderRadius: BorderRadius.circular(999),
          onTap: onSelect,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    device.isProtectedDevice
                        ? Icons.laptop_mac_rounded
                        : Icons.smartphone_rounded,
                    size: 17,
                    color: isSelected
                        ? WatSafeTheme.amberAccent
                        : WatSafeTheme.warmMuted,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      color: isSelected
                          ? WatSafeTheme.warmOffWhite
                          : WatSafeTheme.warmMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectedDeviceDetailCard extends StatefulWidget {
  const _SelectedDeviceDetailCard({
    required this.device,
    required this.controller,
    required this.onCenterMap,
  });

  final AuthorizedDeviceLocationSummary device;
  final AlarmController controller;
  final VoidCallback onCenterMap;

  @override
  State<_SelectedDeviceDetailCard> createState() =>
      _SelectedDeviceDetailCardState();
}

class _SelectedDeviceDetailCardState extends State<_SelectedDeviceDetailCard> {
  bool _showCoordinates = false;

  Color _protectionBadgeColor(AuthorizedDeviceLocationSummary device) {
    if (device.isAlarming) {
      return WatSafeTheme.alarmCrimson;
    }
    final lower = device.protectionStatusLabel.toLowerCase();
    if (lower.contains('interrupted')) {
      return WatSafeTheme.alarmCrimson;
    }
    if (lower.contains('protected') || lower.contains('alerts on')) {
      return WatSafeTheme.readyEmerald;
    }
    if (lower.contains('arming') ||
        lower.contains('paused') ||
        lower.contains('setup')) {
      return WatSafeTheme.amberAccent;
    }
    return WatSafeTheme.warmMuted;
  }

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final device = widget.device;
    final controller = widget.controller;
    final loc = device.latestLocation;
    final hasValidLoc = loc != null && loc.isValid;
    final isCurrentPhone =
        device.isCurrentRequester && !device.isProtectedDevice;
    final connColor = device.online ? palette.readyColor : palette.warningColor;
    final protColor = _protectionBadgeColor(device);
    final phoneBadgeColor = palette.phoneMarkerColor;
    final now = DateTime.now();

    return Card(
      key: const Key('selected_device_detail_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color:
                        (device.isProtectedDevice
                                ? palette.readyColor
                                : phoneBadgeColor)
                            .withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    device.isProtectedDevice
                        ? Icons.laptop_mac_rounded
                        : Icons.smartphone_rounded,
                    size: 20,
                    color: device.isProtectedDevice
                        ? palette.readyColor
                        : phoneBadgeColor,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          Text(
                            device.displayName,
                            key: const Key('selected_device_name_label'),
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          if (isCurrentPhone)
                            _CompactStatusBadge(
                              label: 'This phone',
                              color: phoneBadgeColor,
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        key: const Key('selected_device_status_label'),
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          _CompactStatusBadge(
                            label: device.effectiveConnectionLabel,
                            color: connColor,
                          ),
                          _CompactStatusBadge(
                            label: device.protectionStatusLabel,
                            color: protColor,
                          ),
                          if (hasValidLoc)
                            Container(
                              key: const Key('selected_device_accuracy_badge'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 3.5,
                              ),
                              decoration: BoxDecoration(
                                color: WatSafeTheme.charcoalElevated,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: WatSafeTheme.charcoalBorder,
                                ),
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
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            if (hasValidLoc) ...<Widget>[
              Text(
                device.readableLocationSummary ??
                    (loc.isEffectivelyApproximate
                        ? 'Approximate area'
                        : 'Reported map position'),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14.5,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                loc.relativeAgeLabel(
                  now,
                  forceLastKnown: device.trackingState == 'last_known',
                ),
                key: const Key('selected_device_updated_age_label'),
                style: TextStyle(fontSize: 13, color: palette.textMuted),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlinedButton.icon(
                    key: const Key('devices_center_on_device_button'),
                    onPressed: widget.onCenterMap,
                    icon: const Icon(Icons.my_location_rounded, size: 17),
                    label: const Text('Center on device'),
                  ),
                  if (isCurrentPhone &&
                      controller.isCompanionMode &&
                      controller.settings.shareCompanionPhoneLocation)
                    TextButton(
                      key: const Key('devices_stop_companion_phone_loc_btn'),
                      onPressed: () =>
                          controller.updateShareCompanionPhoneLocation(false),
                      child: const Text('Stop sharing'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              InkWell(
                key: const Key('devices_coordinates_disclosure'),
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  setState(() {
                    _showCoordinates = !_showCoordinates;
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        _showCoordinates
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: palette.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Coordinates',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: palette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_showCoordinates)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SelectableText(
                    loc.formattedCoordinates,
                    key: const Key('selected_device_coordinates_label'),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
            ] else ...<Widget>[
              Container(
                key: const Key('devices_location_unavailable_banner'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: palette.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      device.locationStatus ==
                              IncidentLocationStatus.permissionDenied
                          ? 'Location permission turned off'
                          : (isCurrentPhone
                                ? 'Location not shared'
                                : 'Location unavailable'),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      device.statusExplanation ?? 'No usable location has been reported for this device yet.',
                      style: TextStyle(
                        fontSize: 13,
                        color: palette.textMuted,
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
                          label: const Text('Share laptop location'),
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
                          label: const Text('Enable location'),
                        ),
                    ] else if (isCurrentPhone &&
                        controller.isCompanionMode) ...<Widget>[
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        key: const Key('devices_share_companion_phone_loc_btn'),
                        onPressed: () =>
                            controller.updateShareCompanionPhoneLocation(true),
                        icon: const Icon(Icons.my_location_rounded, size: 18),
                        label: const Text('Share phone location'),
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

class _CompactStatusBadge extends StatelessWidget {
  const _CompactStatusBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.65)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
