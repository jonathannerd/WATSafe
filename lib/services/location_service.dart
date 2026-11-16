import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/contracts/platform_contracts.dart';
import '../core/models/detector_models.dart';
import '../core/models/incident_models.dart';

/// Default no-op location adapter used when location services are not wired.
class UnconfiguredLocationService implements LocationServiceAdapter {
  const UnconfiguredLocationService();

  @override
  bool get isSupported => false;

  @override
  Future<PermissionStatus> checkPermission() async =>
      PermissionStatus.notApplicable;

  @override
  Future<PermissionStatus> requestPermission() async =>
      PermissionStatus.notApplicable;

  @override
  Future<({DeviceLocationSnapshot? location, IncidentLocationStatus status})>
  captureCurrentLocation({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    return (location: null, status: IncidentLocationStatus.unavailable);
  }
}

/// Native platform channel implementation of [LocationServiceAdapter]
/// (`CoreLocation` on macOS/iOS, `LocationManager` on Android, graceful
/// fallback when unsupported).
class PlatformLocationService implements LocationServiceAdapter {
  PlatformLocationService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.watsafe/location');

  final MethodChannel _channel;
  bool _supported = true;

  @override
  bool get isSupported => _supported;

  static PermissionStatus parsePermissionStatus(String? raw) {
    switch (raw) {
      case 'granted':
        return PermissionStatus.granted;
      case 'denied':
        return PermissionStatus.denied;
      case 'restricted':
        return PermissionStatus.restricted;
      case 'notApplicable':
      case 'unsupported':
        return PermissionStatus.notApplicable;
      default:
        return PermissionStatus.notDetermined;
    }
  }

  @override
  Future<PermissionStatus> checkPermission() async {
    if (kIsWeb) {
      return PermissionStatus.notApplicable;
    }
    try {
      final raw = await _channel.invokeMethod<String>('checkPermission');
      if (raw == 'unsupported' || raw == 'notApplicable') {
        _supported = false;
      }
      return parsePermissionStatus(raw);
    } on MissingPluginException {
      _supported = false;
      return PermissionStatus.notApplicable;
    } catch (_) {
      return PermissionStatus.notDetermined;
    }
  }

  @override
  Future<PermissionStatus> requestPermission() async {
    if (kIsWeb) {
      return PermissionStatus.notApplicable;
    }
    try {
      final raw = await _channel.invokeMethod<String>('requestPermission');
      if (raw == 'unsupported' || raw == 'notApplicable') {
        _supported = false;
      }
      return parsePermissionStatus(raw);
    } on MissingPluginException {
      _supported = false;
      return PermissionStatus.notApplicable;
    } catch (_) {
      return PermissionStatus.denied;
    }
  }

  @override
  Future<({DeviceLocationSnapshot? location, IncidentLocationStatus status})>
  captureCurrentLocation({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (kIsWeb || !_supported) {
      return (location: null, status: IncidentLocationStatus.unavailable);
    }
    try {
      final raw = await _channel
          .invokeMapMethod<String, Object?>(
            'captureLocation',
            <String, Object?>{'timeoutMs': timeout.inMilliseconds},
          )
          .timeout(
            timeout + const Duration(milliseconds: 500),
            onTimeout: () => <String, Object?>{'status': 'unavailable'},
          );
      if (raw == null) {
        return (location: null, status: IncidentLocationStatus.unavailable);
      }
      final statusRaw = raw['status'] as String? ?? 'unavailable';
      if (statusRaw == 'permissionDenied') {
        return (
          location: null,
          status: IncidentLocationStatus.permissionDenied,
        );
      }
      final lat = (raw['latitude'] as num?)?.toDouble();
      final lon = (raw['longitude'] as num?)?.toDouble();
      if (lat == null || lon == null) {
        return (location: null, status: IncidentLocationStatus.unavailable);
      }
      final capturedMs = (raw['capturedAtMs'] as num?)?.toInt();
      final capturedAt = capturedMs != null
          ? DateTime.fromMillisecondsSinceEpoch(capturedMs)
          : DateTime.now();
      final accuracy = (raw['accuracyMeters'] as num?)?.toDouble();
      final isApproximate =
          (raw['isApproximate'] as bool? ?? false) ||
          (accuracy != null && accuracy > 100);
      final isLastKnown = raw['isLastKnown'] as bool? ?? false;

      return (
        location: DeviceLocationSnapshot(
          latitude: lat,
          longitude: lon,
          accuracyMeters: accuracy,
          capturedAt: capturedAt,
          isApproximate: isApproximate,
          isLastKnown: isLastKnown,
        ),
        status: IncidentLocationStatus.attached,
      );
    } on MissingPluginException {
      _supported = false;
      return (location: null, status: IncidentLocationStatus.unavailable);
    } catch (_) {
      return (location: null, status: IncidentLocationStatus.unavailable);
    }
  }
}

/// Programmable in-memory location service for deterministic tests.
class FakeLocationService implements LocationServiceAdapter {
  FakeLocationService({
    this.supported = true,
    this.permission = PermissionStatus.granted,
    this.nextLocation,
    this.captureCompleter,
  });

  bool supported;
  PermissionStatus permission;
  DeviceLocationSnapshot? nextLocation;
  Completer<DeviceLocationSnapshot?>? captureCompleter;
  int requestPermissionCount = 0;
  int captureCount = 0;

  @override
  bool get isSupported => supported;

  @override
  Future<PermissionStatus> checkPermission() async =>
      supported ? permission : PermissionStatus.notApplicable;

  @override
  Future<PermissionStatus> requestPermission() async {
    requestPermissionCount += 1;
    if (!supported) {
      return PermissionStatus.notApplicable;
    }
    if (permission == PermissionStatus.notDetermined) {
      permission = PermissionStatus.granted;
    }
    return permission;
  }

  @override
  Future<({DeviceLocationSnapshot? location, IncidentLocationStatus status})>
  captureCurrentLocation({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    captureCount += 1;
    if (!supported) {
      return (location: null, status: IncidentLocationStatus.unavailable);
    }
    if (permission == PermissionStatus.denied ||
        permission == PermissionStatus.restricted ||
        permission == PermissionStatus.notDetermined) {
      return (location: null, status: IncidentLocationStatus.permissionDenied);
    }
    if (captureCompleter != null) {
      final resolved = await captureCompleter!.future;
      if (resolved == null) {
        return (location: null, status: IncidentLocationStatus.unavailable);
      }
      return (location: resolved, status: IncidentLocationStatus.attached);
    }
    if (nextLocation == null) {
      return (location: null, status: IncidentLocationStatus.unavailable);
    }
    return (location: nextLocation, status: IncidentLocationStatus.attached);
  }
}
