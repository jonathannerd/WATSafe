import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models/incident_models.dart';
import '../theme/watsafe_theme.dart';

const String _defaultTileUrlTemplate = String.fromEnvironment(
  'WATSAFE_TILE_URL_TEMPLATE',
  defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
);

/// Marker model rendered on [DeviceGeographicMap].
@immutable
class DeviceMapMarker {
  const DeviceMapMarker({
    required this.id,
    required this.label,
    required this.location,
    this.isProtectedDevice = true,
    this.isCurrentRequester = false,
    this.isSelected = false,
    this.isAlarming = false,
    this.isOnline = true,
  });

  final String id;
  final String label;
  final DeviceLocationSnapshot location;
  final bool isProtectedDevice;
  final bool isCurrentRequester;
  final bool isSelected;
  final bool isAlarming;
  final bool isOnline;

  String get effectiveLabel {
    if (isCurrentRequester && !label.toLowerCase().contains('this phone')) {
      return '$label · This phone';
    }
    return label;
  }
}

class _MarkerPixelOffset {
  const _MarkerPixelOffset({required this.offset, required this.coLocated});

  final Offset offset;
  final bool coLocated;
}

List<_MarkerPixelOffset> _computeMarkerPixelOffsets(
  List<DeviceMapMarker> markers, {
  double zoom = 15.6,
}) {
  final assigned = List<bool>.filled(markers.length, false);
  final result = List<_MarkerPixelOffset>.filled(
    markers.length,
    const _MarkerPixelOffset(offset: Offset.zero, coLocated: false),
  );

  for (var i = 0; i < markers.length; i++) {
    if (assigned[i]) {
      continue;
    }
    final refLatRad = markers[i].location.latitude * math.pi / 180.0;
    final metersPerPixel = math.max(
      0.05,
      (156543.03 * math.cos(refLatRad)) / math.pow(2.0, zoom),
    );
    final group = <int>[i];
    for (var j = i + 1; j < markers.length; j++) {
      final distM = markers[i].location.distanceMetersTo(markers[j].location);
      if (distM < 28.0 || (distM / metersPerPixel) < 44.0) {
        group.add(j);
      }
    }
    if (group.length >= 2) {
      final radius = group.length == 2 ? 22.0 : 26.0;
      for (var k = 0; k < group.length; k++) {
        final idx = group[k];
        final angle = -math.pi / 6.0 + (k * 2.0 * math.pi) / group.length;
        result[idx] = _MarkerPixelOffset(
          offset: Offset(
            math.cos(angle) * radius,
            math.sin(angle) * radius * 0.65,
          ),
          coLocated: true,
        );
        assigned[idx] = true;
      }
    } else {
      assigned[i] = true;
    }
  }
  return result;
}

/// Interactive Web Mercator geographic map widget for viewing authorized
/// devices, accuracy circles, alarm-time vs latest markers, and filtered
/// post-alarm location trails.
///
/// Uses license-compliant natural light OpenStreetMap interactive tiles (`$0`,
/// max zoom 18, explicit `User-Agent` header, visible
/// `© OpenStreetMap contributors` attribution) and degrades gracefully to a
/// crisp light street-styled Web Mercator coordinate basemap + meter scale bar
/// when offline or in widget tests. Never plots missing or invalid `(0, 0)`
/// coordinates.
class DeviceGeographicMap extends StatefulWidget {
  const DeviceGeographicMap({
    super.key,
    this.primaryLocation,
    this.alarmTimeLocation,
    this.trail = const <DeviceLocationSnapshot>[],
    this.markers = const <DeviceMapMarker>[],
    this.selectedMarkerId,
    this.onSelectMarker,
    this.trackingStateLabel,
    this.trackingStateTone,
    this.secondaryBadgeLabel,
    this.height = 280,
    this.enableNetworkTiles,
    this.centerButtonKey = const Key('center_on_device_button'),
    this.showCenterButtonOverlay = true,
  });

  final DeviceLocationSnapshot? primaryLocation;
  final DeviceLocationSnapshot? alarmTimeLocation;
  final List<DeviceLocationSnapshot> trail;
  final List<DeviceMapMarker> markers;
  final String? selectedMarkerId;
  final ValueChanged<String>? onSelectMarker;
  final String? trackingStateLabel;
  final Color? trackingStateTone;
  final String? secondaryBadgeLabel;
  final double height;
  final bool? enableNetworkTiles;
  final Key centerButtonKey;
  final bool showCenterButtonOverlay;

  @override
  State<DeviceGeographicMap> createState() => DeviceGeographicMapState();
}

class DeviceGeographicMapState extends State<DeviceGeographicMap> {
  late double _centerLat;
  late double _centerLon;
  late double _zoom;
  Offset? _lastFocalPoint;
  bool _userMovedViewport = false;
  String _lastMarkerSignature = '';

  List<DeviceMapMarker> get _validMarkers =>
      widget.markers.where((m) => m.location.isValid).toList(growable: false);

  DeviceLocationSnapshot? get _focusLocation {
    if (widget.primaryLocation != null && widget.primaryLocation!.isValid) {
      return widget.primaryLocation;
    }
    for (final marker in widget.markers) {
      if (marker.id == widget.selectedMarkerId && marker.location.isValid) {
        return marker.location;
      }
    }
    for (final marker in widget.markers) {
      if (marker.isSelected && marker.location.isValid) {
        return marker.location;
      }
    }
    for (final marker in widget.markers) {
      if (marker.location.isValid) {
        return marker.location;
      }
    }
    if (widget.alarmTimeLocation != null && widget.alarmTimeLocation!.isValid) {
      return widget.alarmTimeLocation;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _applyInitialOrMultiDeviceBounds();
  }

  void _applyInitialOrMultiDeviceBounds() {
    final valid = _validMarkers;
    _lastMarkerSignature = valid.map((m) => m.id).join('|');
    if (valid.length >= 2) {
      var minLat = 90.0;
      var maxLat = -90.0;
      var minLon = 180.0;
      var maxLon = -180.0;
      for (final m in valid) {
        minLat = math.min(minLat, m.location.latitude);
        maxLat = math.max(maxLat, m.location.latitude);
        minLon = math.min(minLon, m.location.longitude);
        maxLon = math.max(maxLon, m.location.longitude);
      }
      _centerLat = (minLat + maxLat) / 2.0;
      _centerLon = (minLon + maxLon) / 2.0;
      final spanMeters =
          DeviceLocationSnapshot(
            latitude: minLat,
            longitude: minLon,
            capturedAt: valid.first.location.capturedAt,
          ).distanceMetersTo(
            DeviceLocationSnapshot(
              latitude: maxLat,
              longitude: maxLon,
              capturedAt: valid.first.location.capturedAt,
            ),
          );
      if (spanMeters < 60) {
        _zoom = 16.0;
      } else if (spanMeters < 350) {
        _zoom = 15.0;
      } else if (spanMeters < 1500) {
        _zoom = 13.6;
      } else if (spanMeters < 8000) {
        _zoom = 11.8;
      } else {
        _zoom = 9.8;
      }
      return;
    }

    final initial = _focusLocation;
    _centerLat = initial?.latitude ?? 43.4723;
    _centerLon = initial?.longitude ?? -80.5449;
    _zoom = _initialZoomFor(initial);
  }

  @override
  void didUpdateWidget(covariant DeviceGeographicMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextSig = _validMarkers.map((m) => m.id).join('|');
    if (oldWidget.selectedMarkerId != widget.selectedMarkerId) {
      final selectedTarget = _focusLocation;
      if (selectedTarget != null) {
        _centerLat = selectedTarget.latitude;
        _centerLon = selectedTarget.longitude;
        _zoom = math.max(_zoom, _initialZoomFor(selectedTarget));
      }
      _lastMarkerSignature = nextSig;
      return;
    }

    if (!_userMovedViewport && nextSig != _lastMarkerSignature) {
      _applyInitialOrMultiDeviceBounds();
      return;
    }

    if (!_userMovedViewport && widget.markers.isEmpty) {
      final oldFocus = oldWidget.primaryLocation;
      final nextFocus = _focusLocation;
      if (nextFocus != null &&
          (oldFocus == null || nextFocus.differsMeaningfullyFrom(oldFocus))) {
        _centerLat = nextFocus.latitude;
        _centerLon = nextFocus.longitude;
        _zoom = _initialZoomFor(nextFocus);
      }
    }
  }

  double _initialZoomFor(DeviceLocationSnapshot? loc) {
    if (loc == null) {
      return 14.0;
    }
    final acc = loc.accuracyMeters ?? (loc.isApproximate ? 180.0 : 25.0);
    if (acc >= 800) {
      return 12.8;
    }
    if (acc >= 250) {
      return 14.2;
    }
    if (acc >= 80) {
      return 15.2;
    }
    return 16.0;
  }

  /// Re-centers the map viewport onto the selected or primary device location.
  void centerOnDevice([DeviceLocationSnapshot? explicitTarget]) {
    final target = (explicitTarget != null && explicitTarget.isValid)
        ? explicitTarget
        : _focusLocation;
    if (target == null) {
      return;
    }
    setState(() {
      _userMovedViewport = false;
      _centerLat = target.latitude;
      _centerLon = target.longitude;
      _zoom = _initialZoomFor(target);
    });
  }

  void _adjustZoom(double delta) {
    setState(() {
      _userMovedViewport = true;
      _zoom = (_zoom + delta).clamp(3.0, 18.0);
    });
  }

  bool get _shouldLoadTiles {
    if (widget.enableNetworkTiles != null) {
      return widget.enableNetworkTiles!;
    }
    final bindingName = WidgetsBinding.instance.runtimeType.toString();
    if (bindingName.contains('Test')) {
      return false;
    }
    return _defaultTileUrlTemplate.startsWith('https://');
  }

  void _handlePanDelta(Offset delta) {
    if (delta.distanceSquared < 0.25) {
      return;
    }
    final scale = 256.0 * math.pow(2.0, _zoom);
    final centerWorld = _WebMercator.project(_centerLat, _centerLon, scale);
    final nextWorld = Offset(
      (centerWorld.dx - delta.dx) % scale,
      (centerWorld.dy - delta.dy).clamp(0.0, scale),
    );
    final unprojected = _WebMercator.unproject(nextWorld, scale);
    setState(() {
      _userMovedViewport = true;
      _centerLat = unprojected.$1.clamp(-85.0, 85.0);
      _centerLon = unprojected.$2;
    });
  }

  @override
  Widget build(BuildContext context) {
    final focus = _focusLocation;
    if (focus == null) {
      return Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: const Color(0xFFEEF2F6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFF94A3B8).withValues(alpha: 0.45),
          ),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.location_off_outlined,
              color: Color(0xFF475569),
              size: 28,
            ),
            SizedBox(height: 8),
            Text(
              'Location unavailable',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
              ),
            ),
            SizedBox(height: 4),
            Text(
              'No valid coordinates have been reported for this device yet.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: Color(0xFF475569)),
            ),
          ],
        ),
      );
    }

    final validTrail = widget.trail.where((p) => p.isValid).toList();
    final validAlarmLoc =
        (widget.alarmTimeLocation != null && widget.alarmTimeLocation!.isValid)
        ? widget.alarmTimeLocation
        : null;
    final hasDistinctAlarmOrigin =
        validAlarmLoc != null &&
        widget.primaryLocation != null &&
        widget.primaryLocation!.isValid &&
        widget.primaryLocation!.differsMeaningfullyFrom(validAlarmLoc);

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        key: const Key('device_geographic_map'),
        height: widget.height,
        decoration: BoxDecoration(
          color: const Color(0xFFEEF2F6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFF94A3B8).withValues(alpha: 0.45),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewport = Size(constraints.maxWidth, constraints.maxHeight);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (details) {
                _lastFocalPoint = details.localFocalPoint;
              },
              onScaleUpdate: (details) {
                final prev = _lastFocalPoint;
                _lastFocalPoint = details.localFocalPoint;
                if (prev != null) {
                  _handlePanDelta(details.localFocalPoint - prev);
                }
                if ((details.scale - 1.0).abs() > 0.04) {
                  _adjustZoom(details.scale > 1.0 ? 0.08 : -0.08);
                }
              },
              onTapUp: widget.onSelectMarker == null
                  ? null
                  : (details) =>
                        _handleMarkerTap(details.localPosition, viewport),
              child: Stack(
                children: <Widget>[
                  // 1. Offline-ready crisp light street-grid basemap
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _MercatorGraticulePainter(
                        centerLat: _centerLat,
                        centerLon: _centerLon,
                        zoom: _zoom,
                      ),
                    ),
                  ),

                  // 2. Natural light OpenStreetMap tile layer when online
                  if (_shouldLoadTiles)
                    Positioned.fill(
                      child: Opacity(
                        opacity: 0.96,
                        child: _OsmTileLayer(
                          centerLat: _centerLat,
                          centerLon: _centerLon,
                          zoom: _zoom.round().clamp(3, 18),
                          viewport: viewport,
                        ),
                      ),
                    ),

                  // 3. Vector overlay: accuracy circle, filtered trail, laptop & phone pins
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _DeviceOverlayPainter(
                        centerLat: _centerLat,
                        centerLon: _centerLon,
                        zoom: _zoom,
                        primaryLocation: widget.primaryLocation,
                        alarmTimeLocation: hasDistinctAlarmOrigin
                            ? validAlarmLoc
                            : null,
                        trail: validTrail,
                        markers: _validMarkers,
                        selectedMarkerId: widget.selectedMarkerId,
                        selectedRingColor: WatSafeTheme.of(context)
                            .accentPrimary,
                      ),
                    ),
                  ),

                  // 4. Top-left tracking status & legend pills
                  Positioned(
                    top: 10,
                    left: 10,
                    right: 58,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        if (widget.trackingStateLabel != null)
                          _MapBadge(
                            badgeKey: const Key('map_tracking_state_badge'),
                            label: widget.trackingStateLabel!,
                            dotColor:
                                widget.trackingStateTone ??
                                WatSafeTheme.of(context).accentPrimary,
                          ),
                        if (widget.secondaryBadgeLabel != null &&
                            widget.secondaryBadgeLabel!.trim().isNotEmpty)
                          _MapBadge(
                            badgeKey: const Key('map_secondary_badge'),
                            label: widget.secondaryBadgeLabel!,
                            dotColor: const Color(0xFF2563EB),
                          ),
                        if (hasDistinctAlarmOrigin)
                          _MapBadge(
                            badgeKey: const Key(
                              'map_alarm_origin_marker_legend',
                            ),
                            label: 'Start → Latest shown',
                            dotColor: WatSafeTheme.of(context).warningColor,
                          ),
                      ],
                    ),
                  ),

                  // 5. Top-right accessible zoom & recenter controls
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _MapIconButton(
                          buttonKey: const Key('map_zoom_in_button'),
                          icon: Icons.add_rounded,
                          tooltip: 'Zoom in',
                          onPressed: () => _adjustZoom(1.0),
                        ),
                        const SizedBox(height: 6),
                        _MapIconButton(
                          buttonKey: const Key('map_zoom_out_button'),
                          icon: Icons.remove_rounded,
                          tooltip: 'Zoom out',
                          onPressed: () => _adjustZoom(-1.0),
                        ),
                        if (widget.showCenterButtonOverlay) ...<Widget>[
                          const SizedBox(height: 6),
                          _MapIconButton(
                            buttonKey: widget.centerButtonKey,
                            icon: Icons.my_location_rounded,
                            tooltip: 'Center on device',
                            onPressed: centerOnDevice,
                          ),
                        ],
                      ],
                    ),
                  ),

                  // 6. Bottom-left real-meter scale bar
                  Positioned(
                    bottom: 8,
                    left: 10,
                    child: _ScaleBarLabel(latitude: _centerLat, zoom: _zoom),
                  ),

                  // 7. Bottom-right required OpenStreetMap attribution (compact micro-credit)
                  Positioned(
                    bottom: 6,
                    right: 8,
                    child: Container(
                      key: const Key('map_attribution_badge'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        '© OpenStreetMap contributors',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF475569),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Resolves the screen-space center of each valid marker (including automatic
  /// co-located marker fan-out) for hit-testing and automated verification.
  @visibleForTesting
  Map<String, Offset> computeMarkerScreenPositions(Size viewport) {
    final valid = _validMarkers;
    final offsets = _computeMarkerPixelOffsets(valid, zoom: _zoom);
    final scale = 256.0 * math.pow(2.0, _zoom);
    final centerWorld = _WebMercator.project(_centerLat, _centerLon, scale);
    final out = <String, Offset>{};
    for (var i = 0; i < valid.length; i++) {
      final marker = valid[i];
      final markerWorld = _WebMercator.project(
        marker.location.latitude,
        marker.location.longitude,
        scale,
      );
      final basePos = Offset(
        viewport.width / 2.0 + (markerWorld.dx - centerWorld.dx),
        viewport.height / 2.0 + (markerWorld.dy - centerWorld.dy),
      );
      out[marker.id] = basePos + offsets[i].offset;
    }
    return out;
  }

  void _handleMarkerTap(Offset localPos, Size viewport) {
    final positions = computeMarkerScreenPositions(viewport);
    String? bestId;
    var bestDist = 28.0;
    positions.forEach((id, screenPos) {
      final dist = (screenPos - localPos).distance;
      if (dist <= bestDist) {
        bestDist = dist;
        bestId = id;
      }
    });
    if (bestId != null) {
      widget.onSelectMarker?.call(bestId!);
    }
  }
}

class _WebMercator {
  static Offset project(double lat, double lon, double worldSize) {
    final clampedLat = lat.clamp(-85.05112878, 85.05112878);
    final sinLat = math.sin(clampedLat * math.pi / 180.0);
    final x = ((lon + 180.0) / 360.0) * worldSize;
    final y =
        (0.5 - math.log((1.0 + sinLat) / (1.0 - sinLat)) / (4.0 * math.pi)) *
        worldSize;
    return Offset(x, y);
  }

  static (double, double) unproject(Offset world, double worldSize) {
    final lon = (world.dx / worldSize) * 360.0 - 180.0;
    final n = math.pi - (2.0 * math.pi * world.dy) / worldSize;
    final lat =
        (180.0 / math.pi) * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
    final wrappedLon = ((lon + 180.0) % 360.0 + 360.0) % 360.0 - 180.0;
    return (lat, wrappedLon);
  }

  static double metersPerPixel(double lat, double zoom) {
    final latRad = lat.clamp(-85.0, 85.0) * math.pi / 180.0;
    return (156543.03392 * math.cos(latRad)) / math.pow(2.0, zoom);
  }
}

class _OsmTileLayer extends StatelessWidget {
  const _OsmTileLayer({
    required this.centerLat,
    required this.centerLon,
    required this.zoom,
    required this.viewport,
  });

  final double centerLat;
  final double centerLon;
  final int zoom;
  final Size viewport;

  @override
  Widget build(BuildContext context) {
    final tileCount = 1 << zoom;
    final worldSize = 256.0 * tileCount;
    final centerWorld = _WebMercator.project(centerLat, centerLon, worldSize);
    final topLeftWorld = Offset(
      centerWorld.dx - viewport.width / 2.0,
      centerWorld.dy - viewport.height / 2.0,
    );

    final startTileX = (topLeftWorld.dx / 256.0).floor();
    final endTileX = ((topLeftWorld.dx + viewport.width) / 256.0).floor();
    final startTileY = (topLeftWorld.dy / 256.0).floor();
    final endTileY = ((topLeftWorld.dy + viewport.height) / 256.0).floor();

    final tiles = <Widget>[];
    for (var tx = startTileX; tx <= endTileX; tx++) {
      for (var ty = startTileY; ty <= endTileY; ty++) {
        if (ty < 0 || ty >= tileCount) {
          continue;
        }
        final wrappedX = ((tx % tileCount) + tileCount) % tileCount;
        final url = _defaultTileUrlTemplate
            .replaceAll('{z}', '$zoom')
            .replaceAll('{x}', '$wrappedX')
            .replaceAll('{y}', '$ty');
        final left = tx * 256.0 - topLeftWorld.dx;
        final top = ty * 256.0 - topLeftWorld.dy;

        tiles.add(
          Positioned(
            left: left,
            top: top,
            width: 256,
            height: 256,
            child: Image.network(
              url,
              headers: const <String, String>{
                'User-Agent':
                    'WATSafe/1.0 (+https://github.com/jonathannerd/WATSafe)',
              },
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        );
      }
    }

    return Stack(children: tiles);
  }
}

class _MercatorGraticulePainter extends CustomPainter {
  const _MercatorGraticulePainter({
    required this.centerLat,
    required this.centerLon,
    required this.zoom,
  });

  final double centerLat;
  final double centerLon;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFEEF2F6),
    );

    final scale = 256.0 * math.pow(2.0, zoom);
    final centerWorld = _WebMercator.project(centerLat, centerLon, scale);
    const stepPx = 48.0;
    final startX = -((centerWorld.dx % stepPx) + stepPx) % stepPx;
    final startY = -((centerWorld.dy % stepPx) + stepPx) % stepPx;

    final parkPaint = Paint()..color = const Color(0xFFE2F1E8);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          startX + stepPx * 0.14,
          startY + stepPx * 0.14,
          stepPx * 1.72,
          stepPx * 1.2,
        ),
        const Radius.circular(6),
      ),
      parkPaint,
    );
    if (size.width > 180 && size.height > 150) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            size.width - stepPx * 2.1,
            size.height - stepPx * 1.75,
            stepPx * 1.45,
            stepPx * 1.05,
          ),
          const Radius.circular(6),
        ),
        parkPaint,
      );
    }

    final localRoadPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.4;
    final arterialPaint = Paint()
      ..color = const Color(0xFFCBD5E1)
      ..strokeWidth = 4.2;

    var idx = 0;
    for (var x = startX; x < size.width + stepPx; x += stepPx) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        idx % 3 == 0 ? arterialPaint : localRoadPaint,
      );
      idx++;
    }
    idx = 0;
    for (var y = startY; y < size.height + stepPx; y += stepPx) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        idx % 3 == 0 ? arterialPaint : localRoadPaint,
      );
      idx++;
    }
  }

  @override
  bool shouldRepaint(covariant _MercatorGraticulePainter oldDelegate) {
    return oldDelegate.centerLat != centerLat ||
        oldDelegate.centerLon != centerLon ||
        oldDelegate.zoom != zoom;
  }
}

class _DeviceOverlayPainter extends CustomPainter {
  const _DeviceOverlayPainter({
    required this.centerLat,
    required this.centerLon,
    required this.zoom,
    required this.primaryLocation,
    required this.alarmTimeLocation,
    required this.trail,
    required this.markers,
    required this.selectedMarkerId,
    required this.selectedRingColor,
  });

  final double centerLat;
  final double centerLon;
  final double zoom;
  final DeviceLocationSnapshot? primaryLocation;
  final DeviceLocationSnapshot? alarmTimeLocation;
  final List<DeviceLocationSnapshot> trail;
  final List<DeviceMapMarker> markers;
  final String? selectedMarkerId;
  final Color selectedRingColor;

  Offset _toScreen(
    DeviceLocationSnapshot loc,
    Size size,
    double scale,
    Offset centerWorld,
  ) {
    final w = _WebMercator.project(loc.latitude, loc.longitude, scale);
    return Offset(
      size.width / 2.0 + (w.dx - centerWorld.dx),
      size.height / 2.0 + (w.dy - centerWorld.dy),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = 256.0 * math.pow(2.0, zoom);
    final centerWorld = _WebMercator.project(centerLat, centerLon, scale);

    // 1. Draw filtered post-alarm movement trail when >= 2 reliable points exist.
    if (trail.length >= 2) {
      final path = Path();
      final screenPts = trail
          .map((pt) => _toScreen(pt, size, scale, centerWorld))
          .toList(growable: false);
      path.moveTo(screenPts.first.dx, screenPts.first.dy);
      for (var i = 1; i < screenPts.length; i++) {
        path.lineTo(screenPts[i].dx, screenPts[i].dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFFD97706)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      for (var i = 1; i < screenPts.length - 1; i++) {
        canvas.drawCircle(screenPts[i], 3.8, Paint()..color = Colors.white);
      }
    }

    // 2. Draw distinct alarm-time start marker if present.
    if (alarmTimeLocation != null && alarmTimeLocation!.isValid) {
      final alarmPos = _toScreen(alarmTimeLocation!, size, scale, centerWorld);
      canvas.drawCircle(
        alarmPos,
        9.5,
        Paint()..color = const Color(0xFFD97706).withValues(alpha: 0.24),
      );
      canvas.drawCircle(
        alarmPos,
        6.5,
        Paint()..color = const Color(0xFFD97706),
      );
      canvas.drawCircle(
        alarmPos,
        6.5,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }

    // 3. Draw multi-device markers (with distinct laptop vs phone icons + co-located fan-out).
    if (markers.isNotEmpty) {
      final offsets = _computeMarkerPixelOffsets(markers, zoom: zoom);
      for (var i = 0; i < markers.length; i++) {
        final marker = markers[i];
        final isSelected = marker.id == selectedMarkerId || marker.isSelected;
        final accent = marker.isAlarming
            ? WatSafeTheme.alarmCrimson
            : (marker.isProtectedDevice
                  ? const Color(0xFF1E8254)
                  : const Color(0xFF2563EB));
        _paintDeviceMarker(
          canvas,
          size,
          scale,
          centerWorld,
          marker.location,
          pixelOffset: offsets[i],
          accent: accent,
          isProtectedDevice: marker.isProtectedDevice,
          label: marker.effectiveLabel,
          drawAccuracyCircle: isSelected,
          emphasize: isSelected,
        );
      }
    } else if (primaryLocation != null && primaryLocation!.isValid) {
      _paintDeviceMarker(
        canvas,
        size,
        scale,
        centerWorld,
        primaryLocation!,
        pixelOffset: const _MarkerPixelOffset(
          offset: Offset.zero,
          coLocated: false,
        ),
        accent: WatSafeTheme.alarmCrimson,
        isProtectedDevice: true,
        label: null,
        drawAccuracyCircle: true,
        emphasize: true,
      );
    }
  }

  void _paintDeviceMarker(
    Canvas canvas,
    Size size,
    double scale,
    Offset centerWorld,
    DeviceLocationSnapshot loc, {
    required _MarkerPixelOffset pixelOffset,
    required Color accent,
    required bool isProtectedDevice,
    required String? label,
    required bool drawAccuracyCircle,
    required bool emphasize,
  }) {
    final basePos = _toScreen(loc, size, scale, centerWorld);
    final pinPos = basePos + pixelOffset.offset;

    if (drawAccuracyCircle) {
      final meters = loc.accuracyMeters ?? (loc.isApproximate ? 150.0 : 25.0);
      final mpp = _WebMercator.metersPerPixel(loc.latitude, zoom);
      final radiusPx = (meters / math.max(0.05, mpp)).clamp(18.0, 92.0);
      canvas.drawCircle(
        basePos,
        radiusPx,
        Paint()..color = accent.withValues(alpha: 0.14),
      );
      canvas.drawCircle(
        basePos,
        radiusPx,
        Paint()
          ..color = accent.withValues(alpha: 0.52)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    if (pixelOffset.coLocated) {
      canvas.drawLine(
        basePos,
        pinPos,
        Paint()
          ..color = const Color(0xFF0F172A).withValues(alpha: 0.35)
          ..strokeWidth = 1.5,
      );
      canvas.drawCircle(basePos, 3.0, Paint()..color = const Color(0xFF334155));
    }

    if (emphasize) {
      canvas.drawCircle(
        pinPos,
        19.5,
        Paint()..color = selectedRingColor.withValues(alpha: 0.42),
      );
    }

    final outerRadius = emphasize ? 15.5 : 14.0;
    final innerRadius = emphasize ? 13.0 : 11.5;
    canvas.drawCircle(
      pinPos + const Offset(0, 2),
      outerRadius,
      Paint()..color = const Color(0xFF0F172A).withValues(alpha: 0.22),
    );
    canvas.drawCircle(pinPos, outerRadius, Paint()..color = Colors.white);
    canvas.drawCircle(pinPos, innerRadius, Paint()..color = accent);

    // Distinct vector glyph for laptop vs phone inside the marker pin
    final glyphPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (isProtectedDevice) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: pinPos.translate(0, -1.0),
            width: 11.0,
            height: 7.2,
          ),
          const Radius.circular(1.4),
        ),
        glyphPaint,
      );
      canvas.drawLine(
        pinPos.translate(-7.2, 4.4),
        pinPos.translate(7.2, 4.4),
        glyphPaint,
      );
    } else {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: pinPos, width: 7.8, height: 12.2),
          const Radius.circular(1.8),
        ),
        glyphPaint,
      );
      canvas.drawCircle(
        pinPos.translate(0, 3.8),
        0.9,
        Paint()..color = Colors.white,
      );
    }

    if (label != null && label.trim().isNotEmpty) {
      final trimmed = label.length > 22 ? '${label.substring(0, 21)}…' : label;
      final tp = TextPainter(
        text: TextSpan(
          text: trimmed,
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: Color(0xFF0F172A),
          ),
        ),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 148);
      final labelAbove = pixelOffset.coLocated && pixelOffset.offset.dy < -4.0;
      final labelCenterY = labelAbove
          ? pinPos.dy - (outerRadius + 11.0)
          : pinPos.dy + outerRadius + 11.0;
      final pillRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(pinPos.dx, labelCenterY),
          width: tp.width + 12.0,
          height: tp.height + 5.0,
        ),
        const Radius.circular(999),
      );
      canvas.drawRRect(
        pillRect,
        Paint()..color = Colors.white.withValues(alpha: 0.95),
      );
      canvas.drawRRect(
        pillRect,
        Paint()
          ..color = const Color(0xFF0F172A).withValues(alpha: 0.16)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
      tp.paint(
        canvas,
        Offset(pinPos.dx - tp.width / 2.0, labelCenterY - tp.height / 2.0),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DeviceOverlayPainter oldDelegate) {
    return oldDelegate.centerLat != centerLat ||
        oldDelegate.centerLon != centerLon ||
        oldDelegate.zoom != zoom ||
        oldDelegate.primaryLocation != primaryLocation ||
        oldDelegate.alarmTimeLocation != alarmTimeLocation ||
        oldDelegate.selectedMarkerId != selectedMarkerId ||
        oldDelegate.selectedRingColor != selectedRingColor ||
        oldDelegate.trail.length != trail.length ||
        oldDelegate.markers != markers;
  }
}

class _MapBadge extends StatelessWidget {
  const _MapBadge({
    required this.badgeKey,
    required this.label,
    required this.dotColor,
  });

  final Key badgeKey;
  final String label;
  final Color dotColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: badgeKey,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0xFF0F172A).withValues(alpha: 0.16),
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.1),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7.5,
            height: 7.5,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapIconButton extends StatelessWidget {
  const _MapIconButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    return Material(
      color: Colors.white.withValues(alpha: 0.96),
      elevation: 2,
      shadowColor: const Color(0xFF0F172A).withValues(alpha: 0.2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: palette.accentPrimary.withValues(alpha: 0.32)),
      ),
      child: InkWell(
        key: buttonKey,
        borderRadius: BorderRadius.circular(10),
        hoverColor: palette.accentPrimary.withValues(alpha: 0.14),
        focusColor: palette.accentPrimary.withValues(alpha: 0.20),
        splashColor: palette.accentPrimary.withValues(alpha: 0.22),
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 19, color: const Color(0xFF0F172A)),
          ),
        ),
      ),
    );
  }
}

class _ScaleBarLabel extends StatelessWidget {
  const _ScaleBarLabel({required this.latitude, required this.zoom});

  final double latitude;
  final double zoom;

  @override
  Widget build(BuildContext context) {
    final mpp = _WebMercator.metersPerPixel(latitude, zoom);
    final rawMeters = mpp * 64.0;
    final String label;
    if (rawMeters >= 1000) {
      label = '${(rawMeters / 1000.0).toStringAsFixed(1)} km';
    } else {
      label = '${math.max(10, (rawMeters / 10.0).round() * 10)} m';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: const Color(0xFF0F172A).withValues(alpha: 0.12),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: Color(0xFF0F172A),
        ),
      ),
    );
  }
}
