import 'dart:async';

import 'package:flutter/services.dart';

import '../core/contracts/platform_contracts.dart';

/// Platform audio adapter that plays the bundled local looping WAV asset
/// (`assets/audio/alarm_siren.wav`) via native platform audio bridges on
/// macOS (`AVAudioPlayer`), Windows (`WinMM PlaySoundW`), Android (`AudioTrack`
/// with `USAGE_ALARM`), and iOS (`AVAudioPlayer` with `AVAudioSession`),
/// providing a system-alert fallback when native audio channels are absent.
///
/// Uses a monotonic `_playbackGeneration` token across every asynchronous boundary
/// so that calling [stopAlarm] while [startLoopingAlarm] or [startTestAlarm] is
/// still loading assets or awaiting native channel startup immediately cancels
/// playback and prevents late siren startup.
class PlatformAudioAlarmService implements AudioAlarmAdapter {
  PlatformAudioAlarmService({MethodChannel? channel, this._assetLoader})
    : _channel = channel ?? const MethodChannel('dev.watsafe/audio_alarm');

  final MethodChannel _channel;
  final Future<Uint8List?> Function()? _assetLoader;
  Uint8List? _cachedWavBytes;
  bool _isPlaying = false;
  int _playbackGeneration = 0;
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
    if (_assetLoader != null) {
      _cachedWavBytes = await _assetLoader();
      return _cachedWavBytes;
    }
    try {
      final byteData = await rootBundle.load('assets/audio/alarm_siren.wav');
      _cachedWavBytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      return _cachedWavBytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> prepareForAlarm() async {
    await _loadAlarmAssetBytes();
  }

  @override
  Future<void> startLoopingAlarm({required double volume}) async {
    _cancelTimers();
    final generation = ++_playbackGeneration;
    _isPlaying = true;
    final clampedVolume = volume.clamp(0.10, 1.00);
    final wavBytes = await _loadAlarmAssetBytes();

    if (!_isPlaying || generation != _playbackGeneration) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('startLoopingAlarm', <String, Object?>{
        'volume': clampedVolume,
        'wavBytes': wavBytes,
      });
      if (!_isPlaying || generation != _playbackGeneration) {
        await _invokeStopChannelSafely();
      }
      return;
    } on MissingPluginException {
      if (_isPlaying && generation == _playbackGeneration) {
        _startFallbackSystemBeepLoop(generation);
      }
    } on PlatformException {
      if (_isPlaying && generation == _playbackGeneration) {
        _startFallbackSystemBeepLoop(generation);
      }
    }
  }

  @override
  Future<void> startTestAlarm({
    required double volume,
    required Duration maxDuration,
  }) async {
    _cancelTimers();
    final generation = ++_playbackGeneration;
    _isPlaying = true;
    final clampedVolume = volume.clamp(0.10, 1.00);
    final wavBytes = await _loadAlarmAssetBytes();

    if (!_isPlaying || generation != _playbackGeneration) {
      return;
    }

    final effectiveDuration = maxDuration > const Duration(seconds: 5)
        ? const Duration(seconds: 5)
        : maxDuration;

    _autoStopTimer = Timer(effectiveDuration, () {
      if (generation == _playbackGeneration) {
        unawaited(stopAlarm());
      }
    });

    try {
      await _channel.invokeMethod<void>('startTestAlarm', <String, Object?>{
        'volume': clampedVolume,
        'maxDurationMs': effectiveDuration.inMilliseconds,
        'wavBytes': wavBytes,
      });
      if (!_isPlaying || generation != _playbackGeneration) {
        await _invokeStopChannelSafely();
      }
      return;
    } on MissingPluginException {
      if (_isPlaying && generation == _playbackGeneration) {
        _startFallbackSystemBeepLoop(generation);
      }
    } on PlatformException {
      if (_isPlaying && generation == _playbackGeneration) {
        _startFallbackSystemBeepLoop(generation);
      }
    }
  }

  @override
  Future<void> stopAlarm() async {
    ++_playbackGeneration;
    _cancelTimers();
    _isPlaying = false;
    await _invokeStopChannelSafely();
  }

  Future<void> _invokeStopChannelSafely() async {
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

  void _startFallbackSystemBeepLoop(int generation) {
    if (!_isPlaying || generation != _playbackGeneration) {
      return;
    }
    unawaited(SystemSound.play(SystemSoundType.alert));
    _fallbackLoopTimer = Timer.periodic(const Duration(milliseconds: 900), (
      timer,
    ) {
      if (!_isPlaying || generation != _playbackGeneration) {
        timer.cancel();
        return;
      }
      unawaited(SystemSound.play(SystemSoundType.alert));
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
  int _playbackGeneration = 0;
  int prepareCount = 0;
  int loopingStartCount = 0;
  int testStartCount = 0;
  int stopCount = 0;
  double lastVolume = 0.85;
  bool shouldThrowOnStart = false;
  bool shouldThrowOnPrepare = false;

  /// Optional completer allowing tests to hold [startLoopingAlarm] pending
  /// while exercising concurrent PIN disarm operations.
  Completer<void>? pendingStartCompleter;

  /// Ordered log of adapter operations (`prepare`, `startLooping`,
  /// `startLoopingCompleted`, `startTest`, `stop`, `setVolume`).
  final List<String> callLog = <String>[];

  @override
  bool get isPlaying => _isPlaying;

  @override
  String get audioLimitationsNote =>
      'Test audio adapter (local siren simulation).';

  @override
  Future<void> prepareForAlarm() async {
    prepareCount += 1;
    callLog.add('prepare');
    if (shouldThrowOnPrepare) {
      throw StateError('Simulated audio prepare error');
    }
  }

  @override
  Future<void> startLoopingAlarm({required double volume}) async {
    loopingStartCount += 1;
    lastVolume = volume;
    callLog.add('startLooping');
    if (shouldThrowOnStart) {
      throw StateError('Simulated audio output error');
    }

    final generation = ++_playbackGeneration;
    _isPlaying = true;

    final pending = pendingStartCompleter;
    if (pending != null) {
      await pending.future;
      if (generation != _playbackGeneration) {
        callLog.add('startLoopingAbortedAfterStop');
        return;
      }
    }
    callLog.add('startLoopingCompleted');
  }

  @override
  Future<void> startTestAlarm({
    required double volume,
    required Duration maxDuration,
  }) async {
    testStartCount += 1;
    lastVolume = volume;
    callLog.add('startTest');
    if (shouldThrowOnStart) {
      throw StateError('Simulated test audio error');
    }
    ++_playbackGeneration;
    _isPlaying = true;
  }

  @override
  Future<void> stopAlarm() async {
    ++_playbackGeneration;
    _isPlaying = false;
    stopCount += 1;
    callLog.add('stop');
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
    callLog.add('setVolume');
  }
}
