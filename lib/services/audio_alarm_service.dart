import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../core/contracts/platform_contracts.dart';
import '../core/models/settings_models.dart';

/// Synthesizes 16-bit mono PCM RIFF/WAVE buffers for built-in and custom
/// alarm sound profiles.
class AlarmWaveformSynthesizer {
  AlarmWaveformSynthesizer._();

  static const int sampleRate = 22050;

  /// Generates a complete RIFF/WAVE byte buffer for [builtIn].
  static Uint8List generateBuiltInWav(BuiltInAlarmSound builtIn) {
    switch (builtIn) {
      case BuiltInAlarmSound.classicSiren:
        return generateSynthesizedWav(
          pattern: CustomAlarmWavePattern.alternatingSiren,
          primaryFrequencyHz: 880.0,
          secondaryFrequencyHz: 1320.0,
          modulationRateHz: 2.0,
          durationSeconds: 2.0,
        );
      case BuiltInAlarmSound.rapidPulse:
        return generateSynthesizedWav(
          pattern: CustomAlarmWavePattern.rapidStaccato,
          primaryFrequencyHz: 1150.0,
          secondaryFrequencyHz: 1680.0,
          modulationRateHz: 6.0,
          durationSeconds: 2.0,
        );
      case BuiltInAlarmSound.piercingKlaxon:
        return generateSynthesizedWav(
          pattern: CustomAlarmWavePattern.harmonicKlaxon,
          primaryFrequencyHz: 2100.0,
          secondaryFrequencyHz: 2650.0,
          modulationRateHz: 4.0,
          durationSeconds: 2.0,
        );
      case BuiltInAlarmSound.industrialHorn:
        return _generateIndustrialHornWav();
      case BuiltInAlarmSound.temporalBell:
        return _generateTemporalBellWav();
    }
  }

  /// Generates a complete RIFF/WAVE byte buffer for a custom synthesized sound.
  static Uint8List generateCustomWav(CustomAlarmSound custom) {
    return generateSynthesizedWav(
      pattern: custom.pattern,
      primaryFrequencyHz: custom.primaryFrequencyHz,
      secondaryFrequencyHz: custom.secondaryFrequencyHz,
      modulationRateHz: custom.modulationRateHz,
      durationSeconds: 2.4,
    );
  }

  static Uint8List generateSynthesizedWav({
    required CustomAlarmWavePattern pattern,
    required double primaryFrequencyHz,
    required double secondaryFrequencyHz,
    required double modulationRateHz,
    double durationSeconds = 2.0,
  }) {
    final totalSamples = (sampleRate * durationSeconds).round();
    final samples = Int16List(totalSamples);
    final f1 = primaryFrequencyHz.clamp(200.0, 3200.0);
    final f2 = secondaryFrequencyHz.clamp(200.0, 3200.0);
    final modHz = modulationRateHz.clamp(0.5, 12.0);

    var phase1 = 0.0;
    var phase2 = 0.0;

    for (var i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      final modPhase = (t * modHz) % 1.0;
      var sample = 0.0;

      switch (pattern) {
        case CustomAlarmWavePattern.alternatingSiren:
          final freq = modPhase < 0.5 ? f1 : f2;
          phase1 += (2.0 * math.pi * freq) / sampleRate;
          sample = 0.75 * math.sin(phase1) + 0.25 * math.sin(phase1 * 2.0);
          break;
        case CustomAlarmWavePattern.sweepingChirp:
          final sweep = 0.5 * (1.0 - math.cos(2.0 * math.pi * modPhase));
          final freq = f1 + (f2 - f1) * sweep;
          phase1 += (2.0 * math.pi * freq) / sampleRate;
          sample = 0.80 * math.sin(phase1) + 0.20 * math.sin(phase1 * 3.0);
          break;
        case CustomAlarmWavePattern.rapidStaccato:
          final gateOn = modPhase < 0.62;
          final useHigh = ((t * modHz).floor().isOdd);
          final freq = useHigh ? f2 : f1;
          phase1 += (2.0 * math.pi * freq) / sampleRate;
          if (gateOn) {
            final raw = math.sin(phase1);
            sample = raw >= 0 ? 0.72 : -0.72;
          } else {
            sample = 0.0;
          }
          break;
        case CustomAlarmWavePattern.harmonicKlaxon:
          final pulse = modPhase < 0.78 ? 1.0 : 0.18;
          phase1 += (2.0 * math.pi * f1) / sampleRate;
          phase2 += (2.0 * math.pi * f2) / sampleRate;
          sample =
              pulse *
              (0.52 * math.sin(phase1) +
                  0.38 * math.sin(phase2) +
                  0.10 * math.sin((phase1 + phase2) * 0.5));
          break;
      }

      final scaled = (sample * 28000.0).round().clamp(-32767, 32767);
      samples[i] = scaled;
    }

    return _encodePcm16MonoWav(samples);
  }

  static Uint8List _generateIndustrialHornWav() {
    const durationSeconds = 2.4;
    final totalSamples = (sampleRate * durationSeconds).round();
    final samples = Int16List(totalSamples);

    var p1 = 0.0;
    var p2 = 0.0;
    var p3 = 0.0;

    for (var i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      final cycle = t % 1.2;
      final env = cycle < 0.92 ? 1.0 : 0.12;
      final vibrato = 1.0 + 0.008 * math.sin(2.0 * math.pi * 5.5 * t);

      p1 += (2.0 * math.pi * 440.0 * vibrato) / sampleRate;
      p2 += (2.0 * math.pi * 554.37 * vibrato) / sampleRate;
      p3 += (2.0 * math.pi * 659.25 * vibrato) / sampleRate;

      final wave =
          0.45 * math.sin(p1) + 0.32 * math.sin(p2) + 0.23 * math.sin(p3);
      samples[i] = (env * wave * 28500.0).round().clamp(-32767, 32767);
    }

    return _encodePcm16MonoWav(samples);
  }

  static Uint8List _generateTemporalBellWav() {
    const durationSeconds = 3.2;
    final totalSamples = (sampleRate * durationSeconds).round();
    final samples = Int16List(totalSamples);

    var p1 = 0.0;
    var p2 = 0.0;

    for (var i = 0; i < totalSamples; i++) {
      final t = i / sampleRate;
      var pulseStart = -1.0;
      if (t >= 0.0 && t < 0.5) {
        pulseStart = 0.0;
      } else if (t >= 0.7 && t < 1.2) {
        pulseStart = 0.7;
      } else if (t >= 1.4 && t < 1.9) {
        pulseStart = 1.4;
      }

      p1 += (2.0 * math.pi * 1568.0) / sampleRate;
      p2 += (2.0 * math.pi * 2349.3) / sampleRate;

      if (pulseStart >= 0.0) {
        final localT = t - pulseStart;
        final ringMod = 0.65 + 0.35 * math.sin(2.0 * math.pi * 18.0 * localT);
        final decay = math.exp(-localT * 2.2);
        final wave =
            ringMod * decay * (0.68 * math.sin(p1) + 0.32 * math.sin(p2));
        samples[i] = (wave * 29000.0).round().clamp(-32767, 32767);
      } else {
        samples[i] = 0;
      }
    }

    return _encodePcm16MonoWav(samples);
  }

  static Uint8List _encodePcm16MonoWav(Int16List samples) {
    final dataByteLength = samples.length * 2;
    final totalByteLength = 44 + dataByteLength;
    final byteData = ByteData(totalByteLength);

    // "RIFF"
    byteData.setUint8(0, 0x52);
    byteData.setUint8(1, 0x49);
    byteData.setUint8(2, 0x46);
    byteData.setUint8(3, 0x46);
    byteData.setUint32(4, 36 + dataByteLength, Endian.little);
    // "WAVE"
    byteData.setUint8(8, 0x57);
    byteData.setUint8(9, 0x41);
    byteData.setUint8(10, 0x56);
    byteData.setUint8(11, 0x45);
    // "fmt "
    byteData.setUint8(12, 0x66);
    byteData.setUint8(13, 0x6D);
    byteData.setUint8(14, 0x74);
    byteData.setUint8(15, 0x20);
    byteData.setUint32(16, 16, Endian.little); // PCM header size
    byteData.setUint16(20, 1, Endian.little); // AudioFormat = 1 (PCM)
    byteData.setUint16(22, 1, Endian.little); // NumChannels = 1
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, sampleRate * 2, Endian.little); // ByteRate
    byteData.setUint16(32, 2, Endian.little); // BlockAlign
    byteData.setUint16(34, 16, Endian.little); // BitsPerSample
    // "data"
    byteData.setUint8(36, 0x64);
    byteData.setUint8(37, 0x61);
    byteData.setUint8(38, 0x74);
    byteData.setUint8(39, 0x61);
    byteData.setUint32(40, dataByteLength, Endian.little);

    var offset = 44;
    for (var i = 0; i < samples.length; i++) {
      byteData.setInt16(offset, samples[i], Endian.little);
      offset += 2;
    }

    return byteData.buffer.asUint8List();
  }

  /// Validates whether [bytes] has a valid RIFF/WAVE header.
  static bool isValidWavBytes(Uint8List bytes) {
    if (bytes.length < 44) {
      return false;
    }
    final isRiff =
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46;
    final isWave =
        bytes[8] == 0x57 &&
        bytes[9] == 0x41 &&
        bytes[10] == 0x56 &&
        bytes[11] == 0x45;
    return isRiff && isWave;
  }
}

/// Platform audio adapter that plays the bundled local looping WAV asset
/// (`assets/audio/alarm_siren.wav`) or a user-selected built-in/custom WAV
/// profile via native platform audio bridges on macOS, Windows, Android, and iOS.
class PlatformAudioAlarmService implements AudioAlarmAdapter {
  PlatformAudioAlarmService({
    MethodChannel? channel,
    MethodChannel? methodChannel,
    this._assetLoader,
  }) : _channel =
           channel ??
           methodChannel ??
           const MethodChannel('dev.watsafe/audio_alarm');

  final MethodChannel _channel;
  final Future<Uint8List?> Function()? _assetLoader;
  Uint8List? _cachedWavBytes;
  Uint8List? _activeWavBytes;
  bool _isPlaying = false;
  int _playbackGeneration = 0;
  Timer? _fallbackLoopTimer;
  Timer? _autoStopTimer;
  String _selectedSoundId = BuiltInAlarmSound.classicSiren.id;
  CustomAlarmSound? _selectedCustomSound;

  @override
  bool get isPlaying => _isPlaying;

  String get selectedSoundId => _selectedSoundId;

  @override
  String get audioLimitationsNote =>
      'Alarm siren plays using the local bundled WAV asset (`assets/audio/alarm_siren.wav`) '
      'through the active OS audio output device at the chosen volume. '
      'WATSafe cannot override hardware mute switches, muted OS master volume, '
      'disconnected headphones, force-quit actions, or system shutdown.';

  Future<Uint8List?> _loadAlarmAssetBytes() async {
    if (_activeWavBytes != null) {
      return _activeWavBytes;
    }

    if (_selectedCustomSound != null) {
      final custom = _selectedCustomSound!;
      if (custom.isFileBased) {
        try {
          final file = File(custom.filePath!.trim());
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            if (AlarmWaveformSynthesizer.isValidWavBytes(bytes)) {
              _activeWavBytes = bytes;
              return _activeWavBytes;
            }
          }
        } catch (_) {
          // Fall through to synthesized custom tone if file cannot be read
        }
      }
      _activeWavBytes = AlarmWaveformSynthesizer.generateCustomWav(custom);
      return _activeWavBytes;
    }

    final builtIn =
        BuiltInAlarmSound.tryFromId(_selectedSoundId) ??
        BuiltInAlarmSound.classicSiren;
    if (builtIn == BuiltInAlarmSound.classicSiren) {
      if (_cachedWavBytes != null) {
        _activeWavBytes = _cachedWavBytes;
        return _activeWavBytes;
      }
      if (_assetLoader != null) {
        _cachedWavBytes = await _assetLoader();
        _activeWavBytes = _cachedWavBytes;
        return _activeWavBytes;
      }
      try {
        final data = await rootBundle.load('assets/audio/alarm_siren.wav');
        _cachedWavBytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        _activeWavBytes = _cachedWavBytes;
        return _activeWavBytes;
      } catch (_) {
        return null;
      }
    }

    _activeWavBytes = AlarmWaveformSynthesizer.generateBuiltInWav(builtIn);
    return _activeWavBytes;
  }

  @override
  Future<void> configureAlarmSound({
    required String soundId,
    CustomAlarmSound? customSound,
  }) async {
    _selectedSoundId = soundId;
    _selectedCustomSound = customSound;
    _activeWavBytes = null;
    await _loadAlarmAssetBytes();
  }

  @override
  Future<String?> pickCustomAudioFilePath() async {
    try {
      final selectedPath = await _channel.invokeMethod<String>(
        'pickCustomAudioFile',
      );
      if (selectedPath == null || selectedPath.trim().isEmpty) {
        return null;
      }
      return selectedPath.trim();
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
        'soundId': _selectedSoundId,
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
        'soundId': _selectedSoundId,
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
  String selectedSoundId = BuiltInAlarmSound.classicSiren.id;
  CustomAlarmSound? selectedCustomSound;
  String? mockPickedFilePath;

  int get startLoopingCalls => loopingStartCount;
  int get startTestCalls => testStartCount;
  int get stopCalls => stopCount;

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
  Future<void> configureAlarmSound({
    required String soundId,
    CustomAlarmSound? customSound,
  }) async {
    selectedSoundId = soundId;
    selectedCustomSound = customSound;
  }

  @override
  Future<String?> pickCustomAudioFilePath() async => mockPickedFilePath;

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
