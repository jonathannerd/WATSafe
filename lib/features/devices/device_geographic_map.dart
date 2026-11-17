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
    this.isSelected = false,
    this.isAlarming = false,
    this.isOnline = true,
  });

  final String id;
  final String label;
  final DeviceLocationSnapshot location;
  final bool isSelected;
  final bool isAlarming;
  final bool isOnline;
}

/// Interactive Web Mercator geographic map widget for viewing authorized
/// devices, accuracy circles, alarm-time vs latest markers, and filtered
/// post-alarm location trails.
///
/// Uses license-compliant OpenStreetMap interactive tiles (`$0`, max zoom 18,
/// explicit `User-Agent` header, visible `© OpenStreetMap contributors`
/// attribution) and degrades gracefully to a projected Web Mercator coordinate
/// graticule + meter scale bar when offline or in widget tests. Never plots
/// missing or invalid `(0, 0)` coordinates.
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
    this.height = 260,
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
    final initial = _focusLocation;
    _centerLat = initial?.latitude ?? 43.4723;
    _centerLon = initial?.longitude ?? -80.5449;
    _zoom = _initialZoomFor(initial);
  }

  @override
  void didUpdateWidget(covariant DeviceGeographicMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldFocus =
        oldWidget.primaryLocation ??
        oldWidget.markers
            .where((m) => m.id == oldWidget.selectedMarkerId)
            .map((m) => m.location)
            .firstOrNull;
    final nextFocus = _focusLocation;
    if (nextFocus != null &&
        (oldFocus == null ||
            oldWidget.selectedMarkerId != widget.selectedMarkerId ||
            nextFocus.differsMeaningfullyFrom(oldFocus))) {
      _centerLat = nextFocus.latitude;
      _centerLon = nextFocus.longitude;
      _zoom = _initialZoomFor(nextFocus);
    }
  }

  double _initialZoomFor(DeviceLocationSnapshot? loc) {
    if (loc == null) {
      return 14.0;
    }
    final acc = loc.accuracyMeters ?? (loc.isApproximate ? 180.0 : 25.0);
    if (acc >= 800) {
      return 12.5;
    }
    if (acc >= 250) {
      return 14.0;
    }
    if (acc >= 80) {
      return 15.0;
    }
    return 16.0;
  }

  /// Re-centers the map viewport onto the selected or primary device location.
  void centerOnDevice() {
    final target = _focusLocation;
    if (target == null) {
      return;
    }
    setState(() {
      _centerLat = target.latitude;
      _centerLon = target.longitude;
      _zoom = _initialZoomFor(target);
    });
  }

  void _adjustZoom(double delta) {
    setState(() {
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
    final scale = 256.0 * math.pow(2.0, _zoom);
    final centerWorld = _WebMercator.project(_centerLat, _centerLon, scale);
    final nextWorld = Offset(
      (centerWorld.dx - delta.dx) % scale,
      (centerWorld.dy - delta.dy).clamp(0.0, scale),
    );
    final unprojected = _WebMercator.unproject(nextWorld, scale);
    setState(() {
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
          color: WatSafeTheme.charcoalElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: WatSafeTheme.charcoalBorder),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.location_off_outlined,
              color: WatSafeTheme.warmMuted,
              size: 28,
            ),
            SizedBox(height: 8),
            Text(
              'Location unavailable',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: WatSafeTheme.warmOffWhite,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'No valid coordinates have been reported for this device yet.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: WatSafeTheme.warmMuted),
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
          color: const Color(0xFF151E27),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: WatSafeTheme.charcoalBorder),
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
                  // 1. Offline-ready Web Mercator graticule basemap
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _MercatorGraticulePainter(
                        centerLat: _centerLat,
                        centerLon: _centerLon,
                        zoom: _zoom,
                      ),
                    ),
                  ),

                  // 2. Interactive OpenStreetMap tile layer when online
                  if (_shouldLoadTiles)
                    Positioned.fill(
                      child: Opacity(
                        opacity: 0.78,
                        child: _OsmTileLayer(
                          centerLat: _centerLat,
                          centerLon: _centerLon,
                          zoom: _zoom.round().clamp(3, 18),
                          viewport: viewport,
                        ),
                      ),
                    ),

                  // 3. Vector overlay: accuracy circle, filtered trail, alarm-time & latest pins
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
                        markers: widget.markers,
                        selectedMarkerId: widget.selectedMarkerId,
                      ),
                    ),
                  ),

                  // 4. Top-left tracking status & legend pills
                  Positioned(
                    top: 10,
                    left: 10,
                    right: 56,
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
                                WatSafeTheme.amberAccent,
                          ),
                        if (hasDistinctAlarmOrigin)
                          const _MapBadge(
                            badgeKey: Key('map_alarm_origin_marker_legend'),
                            label: 'Start → Latest shown',
                            dotColor: WatSafeTheme.amberAccent,
                          ),
                      ],
                    ),
                  ),

                  // 5. Top-right compact zoom & recenter controls (non-crowded)
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

                  // 7. Bottom-right required OpenStreetMap attribution
                  Positioned(
                    bottom: 8,
                    right: 10,
                    child: Container(
                      key: const Key('map_attribution_badge'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: WatSafeTheme.charcoalDeep.withValues(
                          alpha: 0.84,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '© OpenStreetMap contributors',
                        style: TextStyle(
                          fontSize: 10,
                          color: WatSafeTheme.warmMuted,
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

  void _handleMarkerTap(Offset localPos, Size viewport) {
    final scale = 256.0 * math.pow(2.0, _zoom);
    final centerWorld = _WebMercator.project(_centerLat, _centerLon, scale);
    for (final marker in widget.markers) {
      if (!marker.location.isValid) {
        continue;
      }
      final markerWorld = _WebMercator.project(
        marker.location.latitude,
        marker.location.longitude,
        scale,
      );
      final screenPos = Offset(
        viewport.width / 2.0 + (markerWorld.dx - centerWorld.dx),
        viewport.height / 2.0 + (markerWorld.dy - centerWorld.dy),
      );
      if ((screenPos - localPos).distance <= 24.0) {
        widget.onSelectMarker?.call(marker.id);
        return;
      }
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
            child: ColorFiltered(
              colorFilter: const ColorFilter.matrix(<double>[
                -0.75,
                0,
                0,
                0,
                195,
                0,
                -0.72,
                0,
                0,
                195,
                0,
                0,
                -0.65,
                0,
                205,
                0,
                0,
                0,
                1,
                0,
              ]),
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
      Paint()..color = const Color(0xFF16202B),
    );

    final gridPaint = Paint()
      ..color = const Color(0xFF233242)
      ..strokeWidth = 1.0;
    final majorPaint = Paint()
      ..color = const Color(0xFF2C3F53)
      ..strokeWidth = 1.4;

    final scale = 256.0 * math.pow(2.0, zoom);
    final centerWorld = _WebMercator.project(centerLat, centerLon, scale);
    const stepPx = 48.0;
    final startX = -(centerWorld.dx % stepPx);
    final startY = -(centerWorld.dy % stepPx);

    var idx = 0;
    for (var x = startX; x < size.width; x += stepPx) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        idx % 3 == 0 ? majorPaint : gridPaint,
      );
      idx++;
    }
    idx = 0;
    for (var y = startY; y < size.height; y += stepPx) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        idx % 3 == 0 ? majorPaint : gridPaint,
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
  });

  final double centerLat;
  final double centerLon;
  final double zoom;
  final DeviceLocationSnapshot? primaryLocation;
  final DeviceLocationSnapshot? alarmTimeLocation;
  final List<DeviceLocationSnapshot> trail;
  final List<DeviceMapMarker> markers;
  final String? selectedMarkerId;

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
          ..color = WatSafeTheme.amberAccent.withValues(alpha: 0.88)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      for (var i = 1; i < screenPts.length - 1; i++) {
        canvas.drawCircle(
          screenPts[i],
          3.6,
          Paint()..color = WatSafeTheme.warmOffWhite,
        );
      }
    }

    // 2. Draw distinct alarm-time start marker if present.
    if (alarmTimeLocation != null && alarmTimeLocation!.isValid) {
      final alarmPos = _toScreen(alarmTimeLocation!, size, scale, centerWorld);
      canvas.drawCircle(
        alarmPos,
        9,
        Paint()..color = WatSafeTheme.amberAccent.withValues(alpha: 0.26),
      );
      canvas.drawCircle(alarmPos, 6, Paint()..color = WatSafeTheme.amberAccent);
      canvas.drawCircle(
        alarmPos,
        6,
        Paint()
          ..color = WatSafeTheme.warmOffWhite
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );
    }

    // 3. Draw multi-device markers if supplied, else primaryLocation.
    if (markers.isNotEmpty) {
      for (final marker in markers) {
        if (!marker.location.isValid) {
          continue;
        }
        final isSelected = marker.id == selectedMarkerId || marker.isSelected;
        _paintLocationPin(
          canvas,
          size,
          scale,
          centerWorld,
          marker.location,
          accent: marker.isAlarming
              ? WatSafeTheme.alarmCrimson
              : (marker.isOnline
                    ? WatSafeTheme.readyEmerald
                    : WatSafeTheme.amberAccent),
          drawAccuracyCircle: isSelected,
          emphasize: isSelected,
        );
      }
    } else if (primaryLocation != null && primaryLocation!.isValid) {
      _paintLocationPin(
        canvas,
        size,
        scale,
        centerWorld,
        primaryLocation!,
        accent: WatSafeTheme.alarmCrimson,
        drawAccuracyCircle: true,
        emphasize: true,
      );
    }
  }

  void _paintLocationPin(
    Canvas canvas,
    Size size,
    double scale,
    Offset centerWorld,
    DeviceLocationSnapshot loc, {
    required Color accent,
    required bool drawAccuracyCircle,
    required bool emphasize,
  }) {
    final pos = _toScreen(loc, size, scale, centerWorld);
    if (drawAccuracyCircle) {
      final meters = loc.accuracyMeters ?? (loc.isApproximate ? 150.0 : 25.0);
      final mpp = _WebMercator.metersPerPixel(loc.latitude, zoom);
      final radiusPx = (meters / math.max(0.05, mpp)).clamp(14.0, 96.0);
      canvas.drawCircle(
        pos,
        radiusPx,
        Paint()..color = accent.withValues(alpha: 0.16),
      );
      canvas.drawCircle(
        pos,
        radiusPx,
        Paint()
          ..color = accent.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    final outerRadius = emphasize ? 9.5 : 7.5;
    final innerRadius = emphasize ? 6.5 : 5.0;
    canvas.drawCircle(
      pos,
      outerRadius,
      Paint()..color = WatSafeTheme.warmOffWhite,
    );
    canvas.drawCircle(pos, innerRadius, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(covariant _DeviceOverlayPainter oldDelegate) {
    return oldDelegate.centerLat != centerLat ||
        oldDelegate.centerLon != centerLon ||
        oldDelegate.zoom != zoom ||
        oldDelegate.primaryLocation != primaryLocation ||
        oldDelegate.alarmTimeLocation != alarmTimeLocation ||
        oldDelegate.selectedMarkerId != selectedMarkerId ||
        oldDelegate.trail.length != trail.length ||
        oldDelegate.markers.length != markers.length;
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
        color: WatSafeTheme.charcoalDeep.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: WatSafeTheme.charcoalBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
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
                color: WatSafeTheme.warmOffWhite,
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
    return Material(
      color: WatSafeTheme.charcoalDeep.withValues(alpha: 0.9),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: WatSafeTheme.charcoalBorder),
      ),
      child: InkWell(
        key: buttonKey,
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(icon, size: 18, color: WatSafeTheme.warmOffWhite),
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
      label = '${(rawMeters / 10.0).round() * 10} m';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: WatSafeTheme.charcoalDeep.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: WatSafeTheme.charcoalBorder),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: WatSafeTheme.warmOffWhite,
        ),
      ),
    );
  }
}
