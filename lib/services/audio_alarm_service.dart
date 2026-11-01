import 'dart:async';

import 'package:flutter/services.dart';

import '../core/contracts/platform_contracts.dart';

/// Platform audio adapter that plays the bundled local looping WAV asset
/// (`assets/audio/alarm_siren.wav`) via native `AVAudioPlayer` on macOS and
/// provides a system-alert fallback when native audio channels are absent.
class PlatformAudioAlarmService implements AudioAlarmAdapter {
  PlatformAudioAlarmService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.watsafe/audio_alarm');

  final MethodChannel _channel;
  Uint8List? _cachedWavBytes;
  bool _isPlaying = false;
  Timer? _fallbackLoopTimer;
  Timer? _autoStopTimer;

  @override
  bool get isPlaying => _isPlaying;

  @override
  String get audioLimitationsNote =>
      'Alarm siren plays using the local bundled WAV asset (`assets/audio/alarm_siren.wav`) '
      'through the active OS audio output device at the chosen volume. '
      'WATSafe cannot override hardware mute switches, muted OS master volume, '
      'disconnected headphones, force-quit actions, or system shutdown.';

  Future<Uint8List?> _loadAlarmAssetBytes() async {
    if (_cachedWavBytes != null) {
      return _cachedWavBytes;
    }
    try {
      final byteData = await rootBundle.load('assets/audio/alarm_siren.wav');
      _cachedWavBytes = byteData.buffer.asUint8List();
      return _cachedWavBytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> startLoopingAlarm({required double volume}) async {
    _cancelTimers();
    _isPlaying = true;
    final clampedVolume = volume.clamp(0.10, 1.00);
    final wavBytes = await _loadAlarmAssetBytes();

    try {
      await _channel.invokeMethod<void>('startLoopingAlarm', <String, Object?>{
        'volume': clampedVolume,
        'wavBytes': wavBytes,
      });
      return;
    } on MissingPluginException {
      _startFallbackSystemBeepLoop();
    } on PlatformException {
      _startFallbackSystemBeepLoop();
    }
  }

  @override
  Future<void> startTestAlarm({
    required double volume,
    required Duration maxDuration,
  }) async {
    _cancelTimers();
    _isPlaying = true;
    final clampedVolume = volume.clamp(0.10, 1.00);
    final wavBytes = await _loadAlarmAssetBytes();

    final effectiveDuration = maxDuration > const Duration(seconds: 5)
        ? const Duration(seconds: 5)
        : maxDuration;

    _autoStopTimer = Timer(effectiveDuration, () {
      unawaited(stopAlarm());
    });

    try {
      await _channel.invokeMethod<void>('startTestAlarm', <String, Object?>{
        'volume': clampedVolume,
        'maxDurationMs': effectiveDuration.inMilliseconds,
        'wavBytes': wavBytes,
      });
      return;
    } on MissingPluginException {
      _startFallbackSystemBeepLoop();
    } on PlatformException {
      _startFallbackSystemBeepLoop();
    }
  }

  @override
  Future<void> stopAlarm() async {
    _cancelTimers();
    _isPlaying = false;
    try {
      await _channel.invokeMethod<void>('stopAlarm');
    } on MissingPluginException {
      // Ignore on fallback targets
    } on PlatformException {
      // Ignore
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    final clampedVolume = volume.clamp(0.10, 1.00);
    try {
      await _channel.invokeMethod<void>('setVolume', <String, Object?>{
        'volume': clampedVolume,
      });
    } on MissingPluginException {
      // Ignore on fallback targets
    } on PlatformException {
      // Ignore
    }
  }

  void _startFallbackSystemBeepLoop() {
    unawaited(SystemSound.play(SystemSoundType.alert));
    _fallbackLoopTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (_isPlaying) {
        unawaited(SystemSound.play(SystemSoundType.alert));
      }
    });
  }

  void _cancelTimers() {
    _fallbackLoopTimer?.cancel();
    _fallbackLoopTimer = null;
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
  }
}

/// Test double for [AudioAlarmAdapter] used in automated unit and widget tests.
class FakeAudioAlarmAdapter implements AudioAlarmAdapter {
  bool _isPlaying = false;
  int loopingStartCount = 0;
  int testStartCount = 0;
  int stopCount = 0;
  double lastVolume = 0.85;
  bool shouldThrowOnStart = false;

  @override
  bool get isPlaying => _isPlaying;

  @override
  String get audioLimitationsNote =>
      'Test audio adapter (local siren simulation).';

  @override
  Future<void> startLoopingAlarm({required double volume}) async {
    if (shouldThrowOnStart) {
      throw StateError('Simulated audio output error');
    }
    _isPlaying = true;
    loopingStartCount += 1;
    lastVolume = volume;
  }

  @override
  Future<void> startTestAlarm({
    required double volume,
    required Duration maxDuration,
  }) async {
    if (shouldThrowOnStart) {
      throw StateError('Simulated test audio error');
    }
    _isPlaying = true;
    testStartCount += 1;
    lastVolume = volume;
  }

  @override
  Future<void> stopAlarm() async {
    _isPlaying = false;
    stopCount += 1;
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
  }
}
