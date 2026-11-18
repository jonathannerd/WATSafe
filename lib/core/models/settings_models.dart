import 'package:flutter/foundation.dart';

import 'detector_models.dart';

/// User-facing color themes for WATSafe.
enum WatSafeColorTheme {
  obsidianAmber(
    'obsidian_amber',
    'Obsidian & Amber (Default)',
    'Deep slate charcoal with warm amber security accents',
  ),
  cyberSentinel(
    'cyber_sentinel',
    'Cyber Sentinel (Cobalt & Cyan)',
    'Midnight navy with electric cyan and cobalt highlights',
  ),
  emeraldTactical(
    'emerald_tactical',
    'Emerald Tactical (Matrix Green)',
    'Stealth forest dark with crisp emerald and mint indicators',
  ),
  crimsonNight(
    'crimson_night',
    'Crimson Night (Ruby Alert)',
    'Deep onyx-burgundy with high-urgency ruby and coral accents',
  ),
  royalViolet(
    'royal_violet',
    'Royal Violet (Amethyst)',
    'Cosmic indigo surface with luminous amethyst and lavender accents',
  ),
  arcticDaylight(
    'arctic_daylight',
    'Arctic Daylight (High-Contrast Light)',
    'Clean alabaster daylight surfaces with royal blue and slate contrast',
  );

  const WatSafeColorTheme(this.id, this.displayName, this.description);

  final String id;
  final String displayName;
  final String description;

  static WatSafeColorTheme fromId(String? raw) {
    for (final item in WatSafeColorTheme.values) {
      if (item.id == raw || item.name == raw) {
        return item;
      }
    }
    return WatSafeColorTheme.obsidianAmber;
  }
}

/// Built-in alarm sound profiles bundled/synthesized by WATSafe.
enum BuiltInAlarmSound {
  classicSiren(
    'builtin_classic_siren',
    'Classic Dual-Tone Siren',
    'Alternating 880 Hz / 1320 Hz emergency siren',
  ),
  rapidPulse(
    'builtin_rapid_pulse',
    'Rapid Tactical Pulse',
    'Fast staccato 1150 Hz / 1680 Hz high-urgency pulse',
  ),
  piercingKlaxon(
    'builtin_piercing_klaxon',
    'Piercing High-Pitch Klaxon',
    'Sharp 2100 Hz / 2650 Hz dual-harmonic deterrent alarm',
  ),
  industrialHorn(
    'builtin_industrial_horn',
    'Industrial Foghorn Blast',
    'Deep 440 Hz / 554 Hz / 659 Hz resonant triad horn',
  ),
  temporalBell(
    'builtin_temporal_bell',
    'Temporal-3 Evacuation Bell',
    'ISO/NFPA Temporal-3 rhythmic metallic bell cadence',
  );

  const BuiltInAlarmSound(this.id, this.displayName, this.description);

  final String id;
  final String displayName;
  final String description;

  static BuiltInAlarmSound? tryFromId(String? raw) {
    for (final item in BuiltInAlarmSound.values) {
      if (item.id == raw || item.name == raw) {
        return item;
      }
    }
    return null;
  }
}

/// Waveform patterns available when creating a custom synthesized alarm sound.
enum CustomAlarmWavePattern {
  alternatingSiren('Alternating Two-Tone Siren'),
  sweepingChirp('Frequency-Sweep Chirp'),
  rapidStaccato('Rapid Staccato Beep'),
  harmonicKlaxon('Dual-Harmonic Klaxon');

  const CustomAlarmWavePattern(this.displayName);
  final String displayName;

  static CustomAlarmWavePattern fromName(String? raw) {
    for (final item in CustomAlarmWavePattern.values) {
      if (item.name == raw) {
        return item;
      }
    }
    return CustomAlarmWavePattern.alternatingSiren;
  }
}

/// User-created custom alarm sound option (either an imported `.wav` file path
/// or a custom-configured synthesized tone profile).
@immutable
class CustomAlarmSound {
  const CustomAlarmSound({
    required this.id,
    required this.name,
    this.filePath,
    this.pattern = CustomAlarmWavePattern.alternatingSiren,
    this.primaryFrequencyHz = 960.0,
    this.secondaryFrequencyHz = 1440.0,
    this.modulationRateHz = 3.5,
  });

  final String id;
  final String name;

  /// Optional path to a user-provided `.wav` file on disk. When null or empty,
  /// the custom sound is synthesized from [pattern], [primaryFrequencyHz],
  /// [secondaryFrequencyHz], and [modulationRateHz].
  final String? filePath;
  final CustomAlarmWavePattern pattern;
  final double primaryFrequencyHz;
  final double secondaryFrequencyHz;
  final double modulationRateHz;

  bool get isFileBased => filePath != null && filePath!.trim().isNotEmpty;

  String get subtitle {
    if (isFileBased) {
      final normalized = filePath!.replaceAll('\\', '/');
      final fileName = normalized.split('/').last;
      return 'Custom WAV file ($fileName)';
    }
    return '${pattern.displayName} • ${primaryFrequencyHz.round()} / ${secondaryFrequencyHz.round()} Hz @ ${modulationRateHz.toStringAsFixed(1)} Hz';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'filePath': filePath,
    'pattern': pattern.name,
    'primaryFrequencyHz': primaryFrequencyHz,
    'secondaryFrequencyHz': secondaryFrequencyHz,
    'modulationRateHz': modulationRateHz,
  };

  factory CustomAlarmSound.fromJson(Map<String, Object?> json) {
    return CustomAlarmSound(
      id: (json['id'] as String?) ?? 'custom_alarm',
      name: (json['name'] as String?) ?? 'Custom Alarm',
      filePath: json['filePath'] as String?,
      pattern: CustomAlarmWavePattern.fromName(json['pattern'] as String?),
      primaryFrequencyHz:
          ((json['primaryFrequencyHz'] as num?)?.toDouble() ?? 960.0).clamp(
            200.0,
            3200.0,
          ),
      secondaryFrequencyHz:
          ((json['secondaryFrequencyHz'] as num?)?.toDouble() ?? 1440.0).clamp(
            200.0,
            3200.0,
          ),
      modulationRateHz: ((json['modulationRateHz'] as num?)?.toDouble() ?? 3.5)
          .clamp(0.5, 12.0),
    );
  }
}

/// Unified descriptor for either a built-in or user-added custom alarm sound.
@immutable
class AlarmSoundOption {
  const AlarmSoundOption({
    required this.id,
    required this.displayName,
    required this.description,
    required this.isCustom,
    this.builtIn,
    this.customSound,
  });

  final String id;
  final String displayName;
  final String description;
  final bool isCustom;
  final BuiltInAlarmSound? builtIn;
  final CustomAlarmSound? customSound;
}

/// Simple user-facing sensitivity presets explaining the practical trade-off
/// in plain language without exposing raw optical-flow thresholds.
enum MotionSensitivityPreset {
  fewerFalseAlarms(
    id: 'fewer_false_alarms',
    sensitivityValue: 0.38,
    title: 'Fewer false alarms',
    description: 'Fewer alerts from people walking or leaning nearby. Best for busy libraries, offices, and cafés.',
  ),
  balanced(
    id: 'balanced',
    sensitivityValue: 0.60,
    title: 'Balanced',
    description: 'Recommended. Detects lifting and carrying promptly while ignoring passersby and room lighting changes.',
  ),
  higherSensitivity(
    id: 'higher_sensitivity',
    sensitivityValue: 0.78,
    title: 'Higher sensitivity',
    description: 'Reacts faster to gentle or slow movement of your device. Best for quiet rooms.',
  );

  const MotionSensitivityPreset({
    required this.id,
    required this.sensitivityValue,
    required this.title,
    required this.description,
  });

  final String id;
  final double sensitivityValue;
  final String title;
  final String description;

  static MotionSensitivityPreset fromSensitivity(double sensitivity) {
    if (sensitivity < 0.49) {
      return MotionSensitivityPreset.fewerFalseAlarms;
    }
    if (sensitivity > 0.69) {
      return MotionSensitivityPreset.higherSensitivity;
    }
    return MotionSensitivityPreset.balanced;
  }
}

/// User-configurable protection settings persisted locally.
@immutable
class ProtectionSettings {
  const ProtectionSettings({
    this.selectedDetector = DetectorType.macosCameraSceneMotion,
    this.motionSensitivity = 0.60,
    this.armingCountdownSeconds = 10,
    this.alarmVolume = 0.85,
    this.onboardingCompleted = false,
    this.deviceDisplayName = '',
    this.shareLocationOnAlarm = true,
    this.permanentRelayEndpointUrl = '',
    this.colorTheme = WatSafeColorTheme.obsidianAmber,
    this.selectedAlarmSoundId = 'builtin_classic_siren',
    this.customAlarmSounds = const <CustomAlarmSound>[],
  });

  final DetectorType selectedDetector;

  /// Motion sensitivity in `[0.20, 0.90]`.
  final double motionSensitivity;

  /// Closest simple sensitivity preset for normal user flows.
  MotionSensitivityPreset get sensitivityPreset =>
      MotionSensitivityPreset.fromSensitivity(motionSensitivity);

  /// Arming countdown in seconds (`3`..`30`).
  final int armingCountdownSeconds;

  /// Alarm output volume in `[0.10, 1.00]`.
  final double alarmVolume;

  /// Whether first-run onboarding and PIN creation have been completed.
  final bool onboardingCompleted;

  /// User-facing name for this device (e.g., "Jonathan’s MacBook").
  final String deviceDisplayName;

  /// Whether to share this device's location with the paired phone when an alarm triggers.
  final bool shareLocationOnAlarm;

  /// User-configured permanent HTTPS relay/companion origin persisted across
  /// normal desktop launches.
  final String permanentRelayEndpointUrl;

  /// Selected UI color theme.
  final WatSafeColorTheme colorTheme;

  /// Identifier of the active alarm sound (either a [BuiltInAlarmSound.id] or
  /// a [CustomAlarmSound.id]).
  final String selectedAlarmSoundId;

  /// User-added custom alarm sounds.
  final List<CustomAlarmSound> customAlarmSounds;

  /// Returns all available alarm sound options (built-in + custom).
  List<AlarmSoundOption> get allAlarmSoundOptions {
    return <AlarmSoundOption>[
      for (final builtIn in BuiltInAlarmSound.values)
        AlarmSoundOption(
          id: builtIn.id,
          displayName: builtIn.displayName,
          description: builtIn.description,
          isCustom: false,
          builtIn: builtIn,
        ),
      for (final custom in customAlarmSounds)
        AlarmSoundOption(
          id: custom.id,
          displayName: custom.name,
          description: custom.subtitle,
          isCustom: true,
          customSound: custom,
        ),
    ];
  }

  /// Resolves the currently selected [AlarmSoundOption], falling back to
  /// [BuiltInAlarmSound.classicSiren] if a custom sound was removed.
  AlarmSoundOption get selectedAlarmSoundOption {
    final options = allAlarmSoundOptions;
    for (final option in options) {
      if (option.id == selectedAlarmSoundId) {
        return option;
      }
    }
    return options.first;
  }

  CustomAlarmSound? get selectedCustomAlarmSound =>
      selectedAlarmSoundOption.customSound;

  ProtectionSettings copyWith({
    DetectorType? selectedDetector,
    double? motionSensitivity,
    int? armingCountdownSeconds,
    double? alarmVolume,
    bool? onboardingCompleted,
    String? deviceDisplayName,
    bool? shareLocationOnAlarm,
    String? permanentRelayEndpointUrl,
    WatSafeColorTheme? colorTheme,
    String? selectedAlarmSoundId,
    List<CustomAlarmSound>? customAlarmSounds,
  }) {
    return ProtectionSettings(
      selectedDetector: selectedDetector ?? this.selectedDetector,
      motionSensitivity: (motionSensitivity ?? this.motionSensitivity).clamp(
        0.20,
        0.90,
      ),
      armingCountdownSeconds:
          (armingCountdownSeconds ?? this.armingCountdownSeconds).clamp(3, 30),
      alarmVolume: (alarmVolume ?? this.alarmVolume).clamp(0.10, 1.00),
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
      deviceDisplayName: deviceDisplayName ?? this.deviceDisplayName,
      shareLocationOnAlarm: shareLocationOnAlarm ?? this.shareLocationOnAlarm,
      permanentRelayEndpointUrl:
          permanentRelayEndpointUrl ?? this.permanentRelayEndpointUrl,
      colorTheme: colorTheme ?? this.colorTheme,
      selectedAlarmSoundId: selectedAlarmSoundId ?? this.selectedAlarmSoundId,
      customAlarmSounds: customAlarmSounds ?? this.customAlarmSounds,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'selectedDetector': selectedDetector.id,
      'motionSensitivity': motionSensitivity,
      'armingCountdownSeconds': armingCountdownSeconds,
      'alarmVolume': alarmVolume,
      'onboardingCompleted': onboardingCompleted,
      'deviceDisplayName': deviceDisplayName,
      'shareLocationOnAlarm': shareLocationOnAlarm,
      if (permanentRelayEndpointUrl.trim().isNotEmpty)
        'permanentRelayEndpointUrl': permanentRelayEndpointUrl.trim(),
      'colorTheme': colorTheme.id,
      'selectedAlarmSoundId': selectedAlarmSoundId,
      'customAlarmSounds': customAlarmSounds
          .map((s) => s.toJson())
          .toList(growable: false),
    };
  }

  factory ProtectionSettings.fromJson(Map<String, Object?> json) {
    final detectorId = json['selectedDetector'] as String?;
    final rawCustomList = json['customAlarmSounds'];
    final parsedCustomSounds = <CustomAlarmSound>[];
    if (rawCustomList is List) {
      for (final item in rawCustomList) {
        if (item is Map) {
          parsedCustomSounds.add(
            CustomAlarmSound.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      }
    }
    return ProtectionSettings(
      selectedDetector: detectorId != null
          ? DetectorType.fromId(detectorId)
          : DetectorType.macosCameraSceneMotion,
      motionSensitivity:
          ((json['motionSensitivity'] as num?)?.toDouble() ?? 0.60).clamp(
            0.20,
            0.90,
          ),
      armingCountdownSeconds:
          ((json['armingCountdownSeconds'] as num?)?.toInt() ?? 10).clamp(
            3,
            30,
          ),
      alarmVolume: ((json['alarmVolume'] as num?)?.toDouble() ?? 0.85).clamp(
        0.10,
        1.00,
      ),
      onboardingCompleted: json['onboardingCompleted'] as bool? ?? false,
      deviceDisplayName: json['deviceDisplayName'] as String? ?? '',
      shareLocationOnAlarm: json['shareLocationOnAlarm'] as bool? ?? true,
      permanentRelayEndpointUrl:
          (json['permanentRelayEndpointUrl'] as String? ?? '').trim(),
      colorTheme: WatSafeColorTheme.fromId(json['colorTheme'] as String?),
      selectedAlarmSoundId:
          (json['selectedAlarmSoundId'] as String?) ??
          BuiltInAlarmSound.classicSiren.id,
      customAlarmSounds: parsedCustomSounds,
    );
  }
}
