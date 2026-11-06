import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import '../../core/contracts/platform_contracts.dart';

/// Decodes the existing siren asset when the user taps Arm or Test Alarm.
class BrowserAlarmAudio implements AudioAlarmAdapter {
  web.AudioContext? _context;
  web.AudioBuffer? _siren;
  web.AudioBufferSourceNode? _source;
  web.GainNode? _gain;
  int _playbackRequest = 0;

  @override
  String get audioLimitationsNote =>
      'Alarm audio uses the current browser audio output. Keep the tab '
      'unmuted and check the system volume with Test Alarm.';

  @override
  bool get isPlaying => _source != null;

  @override
  Future<void> prepareForAlarm() async {
    final context = _context ??= web.AudioContext();
    if (context.state != 'running') {
      await context.resume().toDart.timeout(const Duration(seconds: 4));
    }
    if (_siren == null) {
      final data = await rootBundle.load('assets/audio/alarm_siren.wav');
      final bytes = Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      _siren = await context.decodeAudioData(bytes.buffer.toJS).toDart;
    }
  }

  @override
  Future<void> startLoopingAlarm({required double volume}) async {
    _playbackRequest++;
    _play(volume);
  }

  @override
  Future<void> startTestAlarm({
    required double volume,
    required Duration maxDuration,
  }) async {
    final request = ++_playbackRequest;
    await prepareForAlarm();
    if (request != _playbackRequest) {
      return;
    }
    final source = _play(volume);
    final seconds = (maxDuration.inMilliseconds / 1000).clamp(0.0, 5.0);
    // Schedule the cap on the audio clock even if browser timers are throttled.
    source.stop(_context!.currentTime + seconds);
  }

  web.AudioBufferSourceNode _play(double volume) {
    final context = _context;
    final siren = _siren;
    if (context == null || siren == null || context.state != 'running') {
      throw StateError('Tap Arm or Test Alarm to enable sound.');
    }
    _stopSource();
    final gain = _gain ??= context.createGain()..connect(context.destination);
    gain.gain.value = volume.clamp(0.0, 1.0);
    final source = context.createBufferSource()
      ..buffer = siren
      ..loop = true
      ..connect(gain);
    source.onended = ((web.Event _) {
      if (identical(_source, source)) {
        _source = null;
        source.disconnect();
      }
    }).toJS;
    source.start();
    _source = source;
    return source;
  }

  @override
  Future<void> stopAlarm() async {
    _playbackRequest++;
    _stopSource();
  }

  void _stopSource() {
    final source = _source;
    _source = null;
    source?.stop();
    source?.disconnect();
  }

  @override
  Future<void> setVolume(double volume) async {
    _gain?.gain.value = volume.clamp(0.0, 1.0);
  }
}
