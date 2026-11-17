import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../core/contracts/platform_contracts.dart';
import '../core/models/settings_models.dart';

/// Synthesizes 16-bit mono little-endian PCM `.wav` buffers for built-in
/// alarm tones and user-created custom alarm sounds.
class AlarmWaveformSynthesizer {
  static const int sampleRate = 22050;

  /// Synthesizes a 2.0-second seamless looping 16-bit PCM WAV buffer for [sound].
  static Uint8List synthesizeBuiltIn(BuiltInAlarmSound sound) {
    switch (sound) {
      case BuiltInAlarmSound.classicSiren:
        return _buildWav(
          durationSeconds: 2.0,
          sampleGenerator: (double t) {
            final freq = ((t * 2.0).floor() % 2 == 0) ? 880.0 : 1320.0;
            return 0.85 * math.sin(2.0 * math.pi * freq * t);
          },
        );

      case BuiltInAlarmSound.rapidPulse:
        return _buildWav(
          durationSeconds: 1.6,
          sampleGenerator: (double t) {
            final slot = (t * 8.0).floor() % 4;
            if (slot == 3) {
              return 0.0;
            }
            final freq = (slot % 2 == 0) ? 1150.0 : 1680.0;
            final fundamental = math.sin(2.0 * math.pi * freq * t);
            final thirdHarmonic =
                0.30 * math.sin(2.0 * math.pi * (freq * 3) * t);
            return 0.72 * (fundamental + thirdHarmonic);
          },
        );

      case BuiltInAlarmSound.piercingKlaxon:
        return _buildWav(
          durationSeconds: 1.6,
          sampleGenerator: (double t) {
            final lfo = 0.5 + 0.5 * math.sin(2.0 * math.pi * 6.0 * t);
            final f1 = 2100.0 + (180.0 * lfo);
            final f2 = 2650.0 - (140.0 * lfo);
            final wave =
                0.55 * math.sin(2.0 * math.pi * f1 * t) +
                0.45 * math.sin(2.0 * math.pi * f2 * t);
            return 0.88 * wave;
          },
        );

      case BuiltInAlarmSound.industrialHorn:
        return _buildWav(
          durationSeconds: 2.0,
          sampleGenerator: (double t) {
            final cycle = t % 1.0;
            final envelope = cycle < 0.78 ? 1.0 : 0.15;
            final w1 = math.sin(2.0 * math.pi * 440.0 * t);
            final w2 = 0.75 * math.sin(2.0 * math.pi * 554.37 * t);
            final w3 = 0.60 * math.sin(2.0 * math.pi * 659.25 * t);
            final sub = 0.45 * math.sin(2.0 * math.pi * 220.0 * t);
            return (0.85 * envelope * (w1 + w2 + w3 + sub)) / 2.8;
          },
        );

      case BuiltInAlarmSound.temporalBell:
        return _buildWav(
          durationSeconds: 2.4,
          sampleGenerator: (double t) {
            // Temporal-3 pattern: three 0.45s pulses separated by 0.15s gaps, then 0.6s pause
            final phase = t % 2.4;
            final isOn =
                (phase >= 0.0 && phase < 0.45) ||
                (phase >= 0.60 && phase < 1.05) ||
                (phase >= 1.20 && phase < 1.65);
            if (!isOn) {
              return 0.0;
            }
            final ringMod = 0.75 + 0.25 * math.sin(2.0 * math.pi * 28.0 * t);
            final bell1 = math.sin(2.0 * math.pi * 1480.0 * t);
            final bell2 = 0.50 * math.sin(2.0 * math.pi * 2960.0 * t);
            return 0.65 * ringMod * (bell1 + bell2);
          },
        );
    }
  }

  /// Synthesizes a 2.0-second seamless looping 16-bit PCM WAV buffer for a
  /// user-created [CustomAlarmSound].
  static Uint8List synthesizeCustom(CustomAlarmSound custom) {
    final f1 = custom.primaryFrequencyHz.clamp(200.0, 3600.0);
    final f2 = custom.secondaryFrequencyHz.clamp(200.0, 3600.0);
    final rate = custom.modulationRateHz.clamp(0.5, 16.0);

    switch (custom.pattern) {
      case CustomAlarmWavePattern.importedWavFile:
      case CustomAlarmWavePattern.alternatingSiren:
        return _buildWav(
          durationSeconds: 2.0,
          sampleGenerator: (double t) {
            final useSecond = ((t * rate * 2.0).floor() % 2) == 1;
            final freq = useSecond ? f2 : f1;
            return 0.85 * math.sin(2.0 * math.pi * freq * t);
          },
        );

      case CustomAlarmWavePattern.sweepingChirp:
        return _buildWav(
          durationSeconds: 2.0,
          sampleGenerator: (double t) {
            // Continuous phase-integrated frequency sweep between f1 and f2
            final centerFreq = 0.5 * (f1 + f2);
            final deviation = 0.5 * (f2 - f1);
            final instantPhase =
                (2.0 * math.pi * centerFreq * t) -
                ((deviation / rate) * math.cos(2.0 * math.pi * rate * t));
            return 0.85 * math.sin(instantPhase);
          },
        );

      case CustomAlarmWavePattern.rapidStaccato:
        return _buildWav(
          durationSeconds: 2.0,
          sampleGenerator: (double t) {
            final slot = (t * rate * 4.0).floor() % 4;
            if (slot == 3) {
              return 0.0;
            }
            final freq = (slot % 2 == 0) ? f1 : f2;
            final base = math.sin(2.0 * math.pi * freq * t);
            final harmonic = 0.25 * math.sin(2.0 * math.pi * (freq * 2.0) * t);
            return 0.75 * (base + harmonic);
          },
        );

      case CustomAlarmWavePattern.harmonicKlaxon:
        return _buildWav(
          durationSeconds: 2.0,
          sampleGenerator: (double t) {
            final env = 0.65 + 0.35 * math.sin(2.0 * math.pi * rate * t);
            final w1 = math.sin(2.0 * math.pi * f1 * t);
            final w2 = math.sin(2.0 * math.pi * f2 * t);
            return 0.45 * env * (w1 + w2);
          },
        );
    }
  }

  static Uint8List _buildWav({
    required double durationSeconds,
    required double Function(double timeSeconds) sampleGenerator,
  }) {
    final numSamples = (sampleRate * durationSeconds).round();
    final dataBytes = numSamples * 2;
    final totalBytes = 44 + dataBytes;
    final buffer = ByteData(totalBytes);

    // RIFF header
    buffer.setUint8(0, 0x52); // 'R'
    buffer.setUint8(1, 0x49); // 'I'
    buffer.setUint8(2, 0x46); // 'F'
    buffer.setUint8(3, 0x46); // 'F'
    buffer.setUint32(4, totalBytes - 8, Endian.little);
    buffer.setUint8(8, 0x57); // 'W'
    buffer.setUint8(9, 0x41); // 'A'
    buffer.setUint8(10, 0x56); // 'V'
    buffer.setUint8(11, 0x45); // 'E'

    // fmt subchunk (16-bit mono PCM)
    buffer.setUint8(12, 0x66); // 'f'
    buffer.setUint8(13, 0x6D); // 'm'
    buffer.setUint8(14, 0x74); // 't'
    buffer.setUint8(15, 0x20); // ' '
    buffer.setUint32(16, 16, Endian.little); // PCM chunk size
    buffer.setUint16(20, 1, Endian.little); // AudioFormat = 1 (PCM)
    buffer.setUint16(22, 1, Endian.little); // NumChannels = 1
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little); // ByteRate
    buffer.setUint16(32, 2, Endian.little); // BlockAlign
    buffer.setUint16(34, 16, Endian.little); // BitsPerSample

    // data subchunk
    buffer.setUint8(36, 0x64); // 'd'
    buffer.setUint8(37, 0x61); // 'a'
    buffer.setUint8(38, 0x74); // 't'
    buffer.setUint8(39, 0x61); // 'a'
    buffer.setUint32(40, dataBytes, Endian.little);

    for (var i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final raw = sampleGenerator(t).clamp(-1.0, 1.0);
      final pcm = (raw * 32760.0).round().clamp(-32768, 32767);
      buffer.setInt16(44 + (i * 2), pcm, Endian.little);
    }

    return buffer.buffer.asUint8List();
  }

  /// Validates that [bytes] begins with a valid RIFF/WAVE header.
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

/// Platform audio adapter that plays built-in and custom alarm sounds via
/// native platform audio bridges on macOS (`AVAudioPlayer`), Windows (`WinMM PlaySoundW`),
/// Android (`AudioTrack` with `USAGE_ALARM`), and iOS (`AVAudioPlayer`),
/// providing a system-alert fallback when native audio channels are absent.
class PlatformAudioAlarmService implements AudioAlarmAdapter {
  PlatformAudioAlarmService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.watsafe/audio_alarm');

  final MethodChannel _channel;
  final Map<String, Uint8List> _cachedSoundBytes = <String, Uint8List>{};
  String _selectedSoundId = BuiltInAlarmSound.classicSiren.id;
  CustomAlarmSound? _selectedCustomSound;
  bool _isPlaying = false;
  Timer? _fallbackLoopTimer;
  Timer? _autoStopTimer;

  @override
  bool get isPlaying => _isPlaying;

  @override
  String get audioLimitationsNote =>
      'Alarm plays the selected built-in or custom WAV sound through the active '
      'OS audio output device at the chosen volume. WATSafe cannot override '
      'hardware mute switches, muted OS master volume, disconnected headphones, '
      'force-quit actions, or system shutdown.';

  @override
  Future<void> configureAlarmSound({
    required String soundId,
    CustomAlarmSound? customSound,
  }) async {
    _selectedSoundId = soundId;
    _selectedCustomSound = customSound;
  }

  @override
  Future<String?> pickCustomAudioFilePath() async {
    try {
      final selectedPath = await _channel.invokeMethod<String>(
        'pickCustomAudioFile',
      );
      if (selectedPath != null && selectedPath.trim().isNotEmpty) {
        return selectedPath.trim();
      }
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<Uint8List?> _loadActiveAlarmWavBytes() async {
    final custom = _selectedCustomSound;
    if (custom != null) {
      if (custom.isImportedFile && custom.filePath != null) {
        try {
          final file = File(custom.filePath!);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            if (AlarmWaveformSynthesizer.isValidWavBytes(bytes)) {
              return bytes;
            }
          }
        } catch (_) {
          // Fall back to synthesized custom sound if file cannot be read
        }
      }
      final cacheKey =
          'custom_${custom.id}_${custom.pattern.id}_'
          '${custom.primaryFrequencyHz}_${custom.secondaryFrequencyHz}_'
          '${custom.modulationRateHz}';
      final cached = _cachedSoundBytes[cacheKey];
      if (cached != null) {
        return cached;
      }
      final synthesized = AlarmWaveformSynthesizer.synthesizeCustom(custom);
      _cachedSoundBytes[cacheKey] = synthesized;
      return synthesized;
    }

    final builtIn =
        BuiltInAlarmSound.tryFromId(_selectedSoundId) ??
        BuiltInAlarmSound.classicSiren;
    final cached = _cachedSoundBytes[builtIn.id];
    if (cached != null) {
      return cached;
    }

    if (builtIn == BuiltInAlarmSound.classicSiren) {
      try {
        final byteData = await rootBundle.load('assets/audio/alarm_siren.wav');
        final bytes = byteData.buffer.asUint8List();
        if (bytes.length > 44) {
          _cachedSoundBytes[builtIn.id] = bytes;
          return bytes;
        }
      } catch (_) {
        // Fall through to synthesized classic siren
      }
    }

    final synthesized = AlarmWaveformSynthesizer.synthesizeBuiltIn(builtIn);
    _cachedSoundBytes[builtIn.id] = synthesized;
    return synthesized;
  }

  @override
  Future<void> startLoopingAlarm({required double volume}) async {
    _cancelTimers();
    _isPlaying = true;
    final clampedVolume = volume.clamp(0.10, 1.00);
    final wavBytes = await _loadActiveAlarmWavBytes();

    try {
      await _channel.invokeMethod<void>('startLoopingAlarm', <String, Object?>{
        'volume': clampedVolume,
        'wavBytes': wavBytes,
        'soundId': _selectedSoundId,
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
    final wavBytes = await _loadActiveAlarmWavBytes();

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
        'soundId': _selectedSoundId,
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
  String activeSoundId = BuiltInAlarmSound.classicSiren.id;
  CustomAlarmSound? activeCustomSound;
  String? mockPickedFilePath;
  bool shouldThrowOnStart = false;

  @override
  bool get isPlaying => _isPlaying;

  @override
  String get audioLimitationsNote =>
      'Test audio adapter (local siren simulation).';

  @override
  Future<void> configureAlarmSound({
    required String soundId,
    CustomAlarmSound? customSound,
  }) async {
    activeSoundId = soundId;
    activeCustomSound = customSound;
  }

  @override
  Future<String?> pickCustomAudioFilePath() async => mockPickedFilePath;

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
