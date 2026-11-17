import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';

/// Browser Notification API implementation of [LocalNotificationAdapter].
class BrowserNotificationService implements LocalNotificationAdapter {
  BrowserNotificationService() {
    final eventParam = Uri.base.queryParameters['event']?.trim();
    if (eventParam != null && eventParam.isNotEmpty) {
      _initialIncidentId = eventParam;
    }
  }

  final StreamController<String> _tapController =
      StreamController<String>.broadcast();
  final Set<String> _displayedIds = <String>{};
  String? _initialIncidentId;

  bool get _hasSecureNotificationApi {
    try {
      return web.window.isSecureContext && globalContext.has('Notification');
    } catch (_) {
      return false;
    }
  }

  @override
  bool get isSupported => _hasSecureNotificationApi;

  @override
  String get channelKind => 'browser';

  @override
  Stream<String> get notificationTaps => _tapController.stream;

  static PermissionStatus _mapBrowserPermission(String raw) {
    switch (raw) {
      case 'granted':
        return PermissionStatus.granted;
      case 'denied':
        return PermissionStatus.denied;
      default:
        return PermissionStatus.notDetermined;
    }
  }

  @override
  Future<PermissionStatus> checkPermission() async {
    if (!_hasSecureNotificationApi) {
      return PermissionStatus.notApplicable;
    }
    try {
      return _mapBrowserPermission(web.Notification.permission);
    } catch (_) {
      return PermissionStatus.notApplicable;
    }
  }

  @override
  Future<PermissionStatus> requestPermission() async {
    if (!_hasSecureNotificationApi) {
      return PermissionStatus.notApplicable;
    }
    try {
      final result = await web.Notification.requestPermission().toDart;
      return _mapBrowserPermission(result.toDart);
    } catch (_) {
      return PermissionStatus.notApplicable;
    }
  }

  @override
  Future<bool> showAlertNotification({
    required String incidentId,
    required String deviceName,
    required String message,
    bool isTest = false,
  }) async {
    if (incidentId.trim().isEmpty || !_displayedIds.add(incidentId)) {
      return false;
    }
    try {
      if (web.Notification.permission != 'granted') {
        return false;
      }
      final notification = web.Notification(
        deviceName,
        web.NotificationOptions(body: message, tag: incidentId),
      );
      notification.onclick = ((web.Event _) {
        web.window.focus();
        notification.close();
        if (!_tapController.isClosed) {
          _tapController.add(incidentId);
        }
      }).toJS;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  String? consumeInitialTappedIncidentId() {
    final val = _initialIncidentId;
    _initialIncidentId = null;
    return val;
  }

  @override
  Future<String?> getPushRegistrationToken() async => null;

  @override
  Future<bool> openExternalUrl(String url) async {
    try {
      web.window.open(url, '_blank', 'noopener,noreferrer');
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    if (!_tapController.isClosed) {
      unawaited(_tapController.close());
    }
  }
}
