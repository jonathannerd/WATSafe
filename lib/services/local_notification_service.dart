import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/contracts/platform_contracts.dart';
import '../core/models/detector_models.dart';

/// Record of a displayed local notification (used by tests and diagnostics).
@immutable
class DisplayedAlertNotification {
  const DisplayedAlertNotification({
    required this.incidentId,
    required this.deviceName,
    required this.message,
    required this.isTest,
  });

  final String incidentId;
  final String deviceName;
  final String message;
  final bool isTest;
}

/// Safe default notification adapter when OS notifications are not wired.
class NoOpLocalNotificationService implements LocalNotificationAdapter {
  NoOpLocalNotificationService();

  final StreamController<String> _tapController =
      StreamController<String>.broadcast();

  @override
  bool get isSupported => false;

  @override
  String get channelKind => 'none';

  @override
  Future<PermissionStatus> checkPermission() async =>
      PermissionStatus.notApplicable;

  @override
  Future<PermissionStatus> requestPermission() async =>
      PermissionStatus.notApplicable;

  @override
  Future<bool> showAlertNotification({
    required String incidentId,
    required String deviceName,
    required String message,
    bool isTest = false,
  }) async => false;

  @override
  Stream<String> get notificationTaps => _tapController.stream;

  @override
  String? consumeInitialTappedIncidentId() => null;

  @override
  Future<String?> getPushRegistrationToken() async => null;

  @override
  Future<bool> openExternalUrl(String url) async => false;

  @override
  void dispose() {
    if (!_tapController.isClosed) {
      unawaited(_tapController.close());
    }
  }
}

/// Native platform channel implementation of [LocalNotificationAdapter]
/// (`UNUserNotificationCenter` on iOS/macOS, `NotificationManager` on Android).
class PlatformLocalNotificationService implements LocalNotificationAdapter {
  PlatformLocalNotificationService({
    MethodChannel? channel,
    this._onDeepLinkReceived,
  }) : _channel =
           channel ?? const MethodChannel('dev.watsafe/local_notifications') {
    _channel.setMethodCallHandler(_handleNativeCallback);
  }

  final MethodChannel _channel;
  final void Function(String deepLink)? _onDeepLinkReceived;
  final StreamController<String> _tapController =
      StreamController<String>.broadcast();
  final Set<String> _displayedIncidentIds = <String>{};
  String? _initialIncidentId;
  bool _checkedInitial = false;
  bool _supported = true;

  @override
  bool get isSupported => _supported;

  @override
  String get channelKind => _supported ? 'os' : 'none';

  @override
  Stream<String> get notificationTaps => _tapController.stream;

  Future<Object?> _handleNativeCallback(MethodCall call) async {
    final args = call.arguments;
    if (call.method == 'onNotificationTapped' && args is Map) {
      final incidentId = (args['incidentId'] as String? ?? '').trim();
      if (incidentId.isNotEmpty && !_tapController.isClosed) {
        _tapController.add(incidentId);
      }
    } else if (call.method == 'onDeepLinkOpened' && args is Map) {
      final url = (args['url'] as String? ?? '').trim();
      if (url.isNotEmpty) {
        _onDeepLinkReceived?.call(url);
      }
    }
    return null;
  }

  static PermissionStatus _parsePermission(String? raw) {
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
      if (!_checkedInitial) {
        _checkedInitial = true;
        final initial = await _channel.invokeMethod<String>(
          'consumeInitialNotificationIncidentId',
        );
        if (initial != null && initial.trim().isNotEmpty) {
          _initialIncidentId = initial.trim();
        }
      }
      final raw = await _channel.invokeMethod<String>('checkPermission');
      if (raw == 'unsupported' || raw == 'notApplicable') {
        _supported = false;
      }
      return _parsePermission(raw);
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
      return _parsePermission(raw);
    } on MissingPluginException {
      _supported = false;
      return PermissionStatus.notApplicable;
    } catch (_) {
      return PermissionStatus.denied;
    }
  }

  @override
  Future<bool> showAlertNotification({
    required String incidentId,
    required String deviceName,
    required String message,
    bool isTest = false,
  }) async {
    if (kIsWeb || !_supported || incidentId.trim().isEmpty) {
      return false;
    }
    if (!_displayedIncidentIds.add(incidentId)) {
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>(
        'showAlertNotification',
        <String, Object?>{
          'incidentId': incidentId,
          'title': deviceName,
          'body': message,
          'isTest': isTest,
        },
      );
      return ok ?? false;
    } on MissingPluginException {
      _supported = false;
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  String? consumeInitialTappedIncidentId() {
    final value = _initialIncidentId;
    _initialIncidentId = null;
    return value;
  }

  @override
  Future<String?> getPushRegistrationToken() async {
    if (kIsWeb || !_supported) {
      return null;
    }
    try {
      final token = await _channel.invokeMethod<String>('getPushToken');
      return (token != null && token.trim().isNotEmpty) ? token.trim() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> openExternalUrl(String url) async {
    if (kIsWeb || url.trim().isEmpty) {
      return false;
    }
    try {
      final opened = await _channel.invokeMethod<bool>(
        'openExternalUrl',
        <String, Object?>{'url': url.trim()},
      );
      return opened ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    if (!_tapController.isClosed) {
      unawaited(_tapController.close());
    }
  }
}

/// Programmable in-memory notification service for end-to-end tests.
class FakeLocalNotificationService implements LocalNotificationAdapter {
  FakeLocalNotificationService({
    this.supported = true,
    this.permission = PermissionStatus.notDetermined,
    this.pushToken,
    String? initialTappedIncidentId,
  }) : _initialIncidentId = initialTappedIncidentId;

  bool supported;
  PermissionStatus permission;
  String? pushToken;
  String? _initialIncidentId;
  int requestPermissionCount = 0;
  final List<String> openedUrls = <String>[];
  final Set<String> _displayedIds = <String>{};
  final List<DisplayedAlertNotification> displayedNotifications =
      <DisplayedAlertNotification>[];
  final StreamController<String> _tapController =
      StreamController<String>.broadcast();

  @override
  bool get isSupported => supported;

  @override
  String get channelKind => supported ? 'os' : 'none';

  @override
  Stream<String> get notificationTaps => _tapController.stream;

  void simulateTap(String incidentId) {
    if (!_tapController.isClosed) {
      _tapController.add(incidentId);
    }
  }

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
  Future<bool> showAlertNotification({
    required String incidentId,
    required String deviceName,
    required String message,
    bool isTest = false,
  }) async {
    if (!supported || permission != PermissionStatus.granted) {
      return false;
    }
    if (!_displayedIds.add(incidentId)) {
      return false;
    }
    displayedNotifications.add(
      DisplayedAlertNotification(
        incidentId: incidentId,
        deviceName: deviceName,
        message: message,
        isTest: isTest,
      ),
    );
    return true;
  }

  @override
  String? consumeInitialTappedIncidentId() {
    final val = _initialIncidentId;
    _initialIncidentId = null;
    return val;
  }

  @override
  Future<String?> getPushRegistrationToken() async => pushToken;

  @override
  Future<bool> openExternalUrl(String url) async {
    openedUrls.add(url);
    return true;
  }

  @override
  void dispose() {
    if (!_tapController.isClosed) {
      unawaited(_tapController.close());
    }
  }
}
