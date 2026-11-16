import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';
import '../../core/models/incident_models.dart';

/// Browser Geolocation implementation of [LocationServiceAdapter].
class BrowserLocationService implements LocationServiceAdapter {
  PermissionStatus _lastKnownPermission = PermissionStatus.notDetermined;

  @override
  bool get isSupported => true;

  @override
  Future<PermissionStatus> checkPermission() async {
    try {
      final status = await web.window.navigator.permissions
          .query(<String, Object?>{'name': 'geolocation'}.jsify()! as JSObject)
          .toDart;
      switch (status.state) {
        case 'granted':
          _lastKnownPermission = PermissionStatus.granted;
        case 'denied':
          _lastKnownPermission = PermissionStatus.denied;
        default:
          _lastKnownPermission = PermissionStatus.notDetermined;
      }
      return _lastKnownPermission;
    } catch (_) {
      return _lastKnownPermission;
    }
  }

  @override
  Future<PermissionStatus> requestPermission() async {
    final result = await captureCurrentLocation(
      timeout: const Duration(seconds: 8),
    );
    if (result.status == IncidentLocationStatus.attached) {
      _lastKnownPermission = PermissionStatus.granted;
      return PermissionStatus.granted;
    }
    if (result.status == IncidentLocationStatus.permissionDenied) {
      _lastKnownPermission = PermissionStatus.denied;
      return PermissionStatus.denied;
    }
    return _lastKnownPermission;
  }

  @override
  Future<({DeviceLocationSnapshot? location, IncidentLocationStatus status})>
  captureCurrentLocation({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final completer =
        Completer<
          ({DeviceLocationSnapshot? location, IncidentLocationStatus status})
        >();

    try {
      web.window.navigator.geolocation.getCurrentPosition(
        ((web.GeolocationPosition pos) {
          if (completer.isCompleted) return;
          _lastKnownPermission = PermissionStatus.granted;
          final coords = pos.coords;
          final acc = coords.accuracy;
          completer.complete((
            location: DeviceLocationSnapshot(
              latitude: coords.latitude,
              longitude: coords.longitude,
              accuracyMeters: acc,
              capturedAt: DateTime.fromMillisecondsSinceEpoch(pos.timestamp),
              isApproximate: acc > 100,
              isLastKnown: false,
            ),
            status: IncidentLocationStatus.attached,
          ));
        }).toJS,
        ((web.GeolocationPositionError err) {
          if (completer.isCompleted) return;
          if (err.code == 1) {
            _lastKnownPermission = PermissionStatus.denied;
            completer.complete((
              location: null,
              status: IncidentLocationStatus.permissionDenied,
            ));
          } else {
            completer.complete((
              location: null,
              status: IncidentLocationStatus.unavailable,
            ));
          }
        }).toJS,
        web.PositionOptions(
          enableHighAccuracy: true,
          timeout: timeout.inMilliseconds,
          maximumAge: 60000,
        ),
      );
    } catch (_) {
      if (!completer.isCompleted) {
        completer.complete((
          location: null,
          status: IncidentLocationStatus.unavailable,
        ));
      }
    }

    return completer.future.timeout(
      timeout + const Duration(milliseconds: 500),
      onTimeout: () => (location: null, status: IncidentLocationStatus.unavailable),
    );
  }
}
