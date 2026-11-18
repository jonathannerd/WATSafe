import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Supported native desktop lifecycle, power, lid-switch, termination, and
/// non-invasive user-input interaction signals.
enum SystemLifecycleEventType {
  /// Hardware clamshell / lid-switch API explicitly reported lid closure.
  lidClosed,

  /// Hardware clamshell / lid-switch API explicitly reported lid open.
  lidOpened,

  /// OS reported impending system sleep (`IORegisterForSystemPower` /
  /// `NSWorkspace.willSleepNotification` / `PBT_APMSUSPEND`) without a
  /// separate confirmed clamshell-closed state.
  systemWillSleep,

  /// OS resumed from sleep (`kIOMessageSystemHasPoweredOn` /
  /// `NSWorkspace.didWakeNotification` / `PBT_APMRESUMEAUTOMATIC`).
  systemDidWake,

  /// Display slept while the system remained awake (`screensDidSleepNotification`).
  screensDidSleep,

  /// System shutdown or restart requested (`willPowerOffNotification` /
  /// `WM_QUERYENDSESSION`).
  systemWillPowerOff,

  /// User session logging out or switching away (`sessionDidResignActiveNotification`).
  sessionResignedActive,

  /// Application quit or window close attempted while protection is armed.
  appWillTerminate,

  /// Non-invasive HID idle counter reset indicating keyboard, trackpad, or
  /// mouse interaction while armed (`CGEventSource` / `GetLastInputInfo`).
  userInputDetected;

  static SystemLifecycleEventType? tryFromName(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    for (final value in SystemLifecycleEventType.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Event emitted by the native desktop lifecycle & power bridge.
@immutable
class SystemLifecycleEvent {
  const SystemLifecycleEvent({
    required this.type,
    required this.timestamp,
    required this.summary,
    this.clamshellClosed,
    this.flushToken,
  });

  final SystemLifecycleEventType type;
  final DateTime timestamp;
  final String summary;

  /// Non-null only when the OS hardware clamshell/lid API explicitly reported
  /// the lid state (`true` = closed, `false` = open).
  final bool? clamshellClosed;

  /// Optional short-lived native power/termination hold token. When present,
  /// [SystemLifecycleAdapter.completeUrgentFlush] releases the native hold as
  /// soon as the best-effort pre-interruption alert request finishes (bounded
  /// natively to ~1.6s max so WATSafe never blocks OS sleep indefinitely).
  final String? flushToken;

  factory SystemLifecycleEvent.fromMap(Map<Object?, Object?> map) {
    final parsedType =
        SystemLifecycleEventType.tryFromName(map['type'] as String?) ??
        SystemLifecycleEventType.systemWillSleep;
    final tsMs = (map['timestampMs'] as num?)?.toInt();
    return SystemLifecycleEvent(
      type: parsedType,
      timestamp: tsMs != null
          ? DateTime.fromMillisecondsSinceEpoch(tsMs)
          : DateTime.now(),
      summary: map['summary'] as String? ?? parsedType.name,
      clamshellClosed: map['clamshellClosed'] as bool?,
      flushToken: map['flushToken'] as String?,
    );
  }
}

/// Capabilities of the host's native lifecycle and tamper-observation bridge.
@immutable
class SystemLifecycleCapabilities {
  const SystemLifecycleCapabilities({
    required this.isSupported,
    required this.supportsClamshellDetection,
    required this.supportsSleepWakeNotifications,
    required this.supportsShutdownLogoutNotifications,
    required this.supportsQuitInterception,
    required this.supportsInputInteractionDetection,
    this.platformLabel = 'Unsupported',
  });

  const SystemLifecycleCapabilities.unsupported()
    : isSupported = false,
      supportsClamshellDetection = false,
      supportsSleepWakeNotifications = false,
      supportsShutdownLogoutNotifications = false,
      supportsQuitInterception = false,
      supportsInputInteractionDetection = false,
      platformLabel = 'Unsupported';

  final bool isSupported;
  final bool supportsClamshellDetection;
  final bool supportsSleepWakeNotifications;
  final bool supportsShutdownLogoutNotifications;
  final bool supportsQuitInterception;
  final bool supportsInputInteractionDetection;
  final String platformLabel;

  factory SystemLifecycleCapabilities.fromMap(Map<Object?, Object?> map) {
    return SystemLifecycleCapabilities(
      isSupported: map['isSupported'] as bool? ?? true,
      supportsClamshellDetection:
          map['supportsClamshellDetection'] as bool? ?? false,
      supportsSleepWakeNotifications:
          map['supportsSleepWakeNotifications'] as bool? ?? false,
      supportsShutdownLogoutNotifications:
          map['supportsShutdownLogoutNotifications'] as bool? ?? false,
      supportsQuitInterception:
          map['supportsQuitInterception'] as bool? ?? false,
      supportsInputInteractionDetection:
          map['supportsInputInteractionDetection'] as bool? ?? false,
      platformLabel: map['platformLabel'] as String? ?? 'Desktop',
    );
  }
}

/// Contract for observing native lid-close, impending sleep, shutdown/logout,
/// app termination, and optional non-invasive input activity on desktop hosts.
abstract class SystemLifecycleAdapter {
  bool get isSupported;

  SystemLifecycleCapabilities get capabilities;

  Stream<SystemLifecycleEvent> get events;

  Future<SystemLifecycleCapabilities> initialize();

  Future<void> syncProtectionState({
    required bool armed,
    required bool monitorInputInteraction,
  });

  Future<void> completeUrgentFlush(String flushToken);

  Future<void> dispose();
}

/// Platform-channel implementation backed by `MacOSSystemLifecycleBridge` on
/// macOS and `WindowsSystemLifecycleBridge` on Windows.
class PlatformSystemLifecycleService implements SystemLifecycleAdapter {
  PlatformSystemLifecycleService({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool? isDesktopOverride,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel('dev.watsafe/system_lifecycle'),
       _eventChannel =
           eventChannel ??
           const EventChannel('dev.watsafe/system_lifecycle_events'),
       _isSupported =
           isDesktopOverride ??
           (!kIsWeb &&
               (defaultTargetPlatform == TargetPlatform.macOS ||
                   defaultTargetPlatform == TargetPlatform.windows));

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final bool _isSupported;

  final StreamController<SystemLifecycleEvent> _eventsController =
      StreamController<SystemLifecycleEvent>.broadcast();
  StreamSubscription<Object?>? _nativeSubscription;
  SystemLifecycleCapabilities _capabilities =
      const SystemLifecycleCapabilities.unsupported();
  bool _initialized = false;

  @override
  bool get isSupported => _isSupported;

  @override
  SystemLifecycleCapabilities get capabilities => _capabilities;

  @override
  Stream<SystemLifecycleEvent> get events => _eventsController.stream;

  @override
  Future<SystemLifecycleCapabilities> initialize() async {
    if (!_isSupported) {
      return _capabilities;
    }
    if (!_initialized) {
      _initialized = true;
      _nativeSubscription = _eventChannel.receiveBroadcastStream().listen((
        raw,
      ) {
        if (raw is Map && !_eventsController.isClosed) {
          _eventsController.add(SystemLifecycleEvent.fromMap(raw));
        }
      }, onError: (_) {});
    }
    try {
      final raw = await _methodChannel.invokeMapMethod<Object?, Object?>(
        'getCapabilities',
      );
      if (raw != null) {
        _capabilities = SystemLifecycleCapabilities.fromMap(raw);
      } else {
        _capabilities = SystemLifecycleCapabilities(
          isSupported: true,
          supportsClamshellDetection: true,
          supportsSleepWakeNotifications: true,
          supportsShutdownLogoutNotifications: true,
          supportsQuitInterception: true,
          supportsInputInteractionDetection: true,
          platformLabel: defaultTargetPlatform == TargetPlatform.macOS
              ? 'macOS'
              : 'Windows',
        );
      }
    } on MissingPluginException {
      _capabilities = const SystemLifecycleCapabilities.unsupported();
    } on PlatformException {
      _capabilities = const SystemLifecycleCapabilities.unsupported();
    }
    return _capabilities;
  }

  @override
  Future<void> syncProtectionState({
    required bool armed,
    required bool monitorInputInteraction,
  }) async {
    if (!_isSupported) {
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>(
        'syncProtectionState',
        <String, Object?>{
          'armed': armed,
          'monitorInputInteraction': armed && monitorInputInteraction,
        },
      );
    } on MissingPluginException {
      // Safe no-op in headless unit tests without registered platform channels.
    } on PlatformException {
      // Non-fatal.
    }
  }

  @override
  Future<void> completeUrgentFlush(String flushToken) async {
    if (!_isSupported || flushToken.isEmpty) {
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>(
        'completeUrgentFlush',
        <String, Object?>{'flushToken': flushToken},
      );
    } on MissingPluginException {
      // Safe no-op.
    } on PlatformException {
      // Non-fatal.
    }
  }

  @override
  Future<void> dispose() async {
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
    if (!_eventsController.isClosed) {
      await _eventsController.close();
    }
  }
}

/// Safe no-op implementation used on web, mobile, and tests that do not inject
/// a fake desktop lifecycle bridge.
class NoOpSystemLifecycleService implements SystemLifecycleAdapter {
  const NoOpSystemLifecycleService();

  @override
  bool get isSupported => false;

  @override
  SystemLifecycleCapabilities get capabilities =>
      const SystemLifecycleCapabilities.unsupported();

  @override
  Stream<SystemLifecycleEvent> get events =>
      const Stream<SystemLifecycleEvent>.empty();

  @override
  Future<SystemLifecycleCapabilities> initialize() async => capabilities;

  @override
  Future<void> syncProtectionState({
    required bool armed,
    required bool monitorInputInteraction,
  }) async {}

  @override
  Future<void> completeUrgentFlush(String flushToken) async {}

  @override
  Future<void> dispose() async {}
}

/// Deterministic in-memory lifecycle bridge for automated tests.
class FakeSystemLifecycleService implements SystemLifecycleAdapter {
  FakeSystemLifecycleService({SystemLifecycleCapabilities? capabilities})
    : _capabilities =
          capabilities ??
          const SystemLifecycleCapabilities(
            isSupported: true,
            supportsClamshellDetection: true,
            supportsSleepWakeNotifications: true,
            supportsShutdownLogoutNotifications: true,
            supportsQuitInterception: true,
            supportsInputInteractionDetection: true,
            platformLabel: 'macOS (simulated)',
          );

  final SystemLifecycleCapabilities _capabilities;
  final StreamController<SystemLifecycleEvent> _controller =
      StreamController<SystemLifecycleEvent>.broadcast();

  bool lastSyncedArmed = false;
  bool lastSyncedMonitorInput = false;
  final List<String> completedFlushTokens = <String>[];

  @override
  bool get isSupported => _capabilities.isSupported;

  @override
  SystemLifecycleCapabilities get capabilities => _capabilities;

  @override
  Stream<SystemLifecycleEvent> get events => _controller.stream;

  void emit(SystemLifecycleEvent event) {
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  @override
  Future<SystemLifecycleCapabilities> initialize() async => _capabilities;

  @override
  Future<void> syncProtectionState({
    required bool armed,
    required bool monitorInputInteraction,
  }) async {
    lastSyncedArmed = armed;
    lastSyncedMonitorInput = monitorInputInteraction;
  }

  @override
  Future<void> completeUrgentFlush(String flushToken) async {
    completedFlushTokens.add(flushToken);
  }

  @override
  Future<void> dispose() async {
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}
