import 'package:flutter/foundation.dart';

import 'detector_models.dart';

/// Selectable visual color themes for the WATSafe interface.
enum WatSafeColorTheme {
  obsidianAmber(
    id: 'obsidian_amber',
    displayName: 'Obsidian Amber (Default)',
    description:
        'Tactical charcoal surfaces with high-visibility amber & orange accents.',
  ),
  cyberSentinel(
    id: 'cyber_sentinel',
    displayName: 'Cyber Sentinel',
    description:
        'Midnight navy slate with electric cyan and cobalt highlights.',
  ),
  emeraldTactical(
    id: 'emerald_tactical',
    displayName: 'Emerald Tactical',
    description:
        'Stealth forest dark mode with matrix emerald and mint accents.',
  ),
  crimsonNight(
    id: 'crimson_night',
    displayName: 'Crimson Night',
    description: 'Deep onyx-burgundy surfaces with ruby and coral highlights.',
  ),
  royalViolet(
    id: 'royal_violet',
    displayName: 'Royal Violet',
    description:
        'Cosmic indigo surfaces with vibrant amethyst and violet accents.',
  ),
  arcticDaylight(
    id: 'arctic_daylight',
    displayName: 'Arctic Daylight (Light)',
    description:
        'High-contrast daylight alabaster surfaces with royal blue accents.',
  );

  const WatSafeColorTheme({
    required this.id,
    required this.displayName,
    required this.description,
  });

  final String id;
  final String displayName;
  final String description;

  static WatSafeColorTheme fromId(String? raw) {
    if (raw == null) {
      return WatSafeColorTheme.obsidianAmber;
    }
    for (final value in WatSafeColorTheme.values) {
      if (value.id == raw || value.name == raw) {
        return value;
      }
    }
    return WatSafeColorTheme.obsidianAmber;
  }
}

/// Built-in alarm siren and acoustic deterrent noises included with WATSafe.
enum BuiltInAlarmSound {
  classicSiren(
    id: 'classic_siren',
    displayName: 'Classic Dual-Tone Siren',
    description:
        'Alternating 880 / 1320 Hz emergency siren (bundled alarm_siren.wav).',
  ),
  rapidPulse(
    id: 'rapid_pulse',
    displayName: 'Rapid Tactical Pulse',
    description: 'Fast staccato 1100 / 1650 Hz high-urgency pulse pattern.',
  ),
  piercingKlaxon(
    id: 'piercing_klaxon',
    displayName: 'Piercing High-Pitch Klaxon',
    description: 'Intense 2100 / 2650 Hz dual-harmonic acoustic deterrent.',
  ),
  industrialHorn(
    id: 'industrial_horn',
    displayName: 'Industrial Foghorn Blast',
    description:
        'Resonant 440 / 554 / 659 Hz triad horn with rhythmic modulation.',
  ),
  temporalBell(
    id: 'temporal_bell',
    displayName: 'Temporal-3 Evacuation Bell',
    description:
        'Standard Temporal-3 urgent alarm cadence with metallic harmonics.',
  );

  const BuiltInAlarmSound({
    required this.id,
    required this.displayName,
    required this.description,
  });

  final String id;
  final String displayName;
  final String description;

  static BuiltInAlarmSound? tryFromId(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in BuiltInAlarmSound.values) {
      if (value.id == raw || value.name == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Waveform synthesis or import pattern for user-created custom alarm sounds.
enum CustomAlarmWavePattern {
  importedWavFile(id: 'imported_wav', displayName: 'Imported WAV Audio File'),
  alternatingSiren(
    id: 'alternating_siren',
    displayName: 'Alternating Two-Tone Siren',
  ),
  sweepingChirp(id: 'sweeping_chirp', displayName: 'Frequency Sweep Siren'),
  rapidStaccato(id: 'rapid_staccato', displayName: 'Rapid Staccato Pulse'),
  harmonicKlaxon(id: 'harmonic_klaxon', displayName: 'Dual-Harmonic Klaxon');

  const CustomAlarmWavePattern({required this.id, required this.displayName});

  final String id;
  final String displayName;

  static CustomAlarmWavePattern fromId(String? raw) {
    if (raw == null) {
      return CustomAlarmWavePattern.alternatingSiren;
    }
    for (final value in CustomAlarmWavePattern.values) {
      if (value.id == raw || value.name == raw) {
        return value;
      }
    }
    return CustomAlarmWavePattern.alternatingSiren;
  }
}

/// A user-added custom alarm sound (either imported from a `.wav` file on disk
/// or synthesized with custom frequencies and modulation).
@immutable
class CustomAlarmSound {
  const CustomAlarmSound({
    required this.id,
    required this.name,
    required this.pattern,
    this.filePath,
    this.primaryFrequencyHz = 1000.0,
    this.secondaryFrequencyHz = 1600.0,
    this.modulationRateHz = 4.0,
    this.createdAtUtcIso = '',
  });

  final String id;
  final String name;
  final CustomAlarmWavePattern pattern;
  final String? filePath;
  final double primaryFrequencyHz;
  final double secondaryFrequencyHz;
  final double modulationRateHz;
  final String createdAtUtcIso;

  bool get isImportedFile =>
      pattern == CustomAlarmWavePattern.importedWavFile &&
      filePath != null &&
      filePath!.isNotEmpty;

  String get description {
    if (isImportedFile) {
      return 'Custom WAV file: $filePath';
    }
    return '${pattern.displayName} (${primaryFrequencyHz.round()} Hz / '
        '${secondaryFrequencyHz.round()} Hz @ ${modulationRateHz.toStringAsFixed(1)} Hz)';
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'pattern': pattern.id,
      'filePath': filePath,
      'primaryFrequencyHz': primaryFrequencyHz,
      'secondaryFrequencyHz': secondaryFrequencyHz,
      'modulationRateHz': modulationRateHz,
      'createdAtUtcIso': createdAtUtcIso,
    };
  }

  factory CustomAlarmSound.fromJson(Map<String, Object?> json) {
    return CustomAlarmSound(
      id: json['id'] as String? ?? 'custom_unknown',
      name: json['name'] as String? ?? 'Custom Alarm Sound',
      pattern: CustomAlarmWavePattern.fromId(json['pattern'] as String?),
      filePath: json['filePath'] as String?,
      primaryFrequencyHz:
          ((json['primaryFrequencyHz'] as num?)?.toDouble() ?? 1000.0).clamp(
            200.0,
            3600.0,
          ),
      secondaryFrequencyHz:
          ((json['secondaryFrequencyHz'] as num?)?.toDouble() ?? 1600.0).clamp(
            200.0,
            3600.0,
          ),
      modulationRateHz: ((json['modulationRateHz'] as num?)?.toDouble() ?? 4.0)
          .clamp(0.5, 16.0),
      createdAtUtcIso: json['createdAtUtcIso'] as String? ?? '',
    );
  }
}

/// Unified descriptor for a built-in or user-added alarm sound option.
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

/// User-configurable protection settings persisted locally.
@immutable
class ProtectionSettings {
  const ProtectionSettings({
    this.selectedDetector = DetectorType.macosCameraSceneMotion,
    this.motionSensitivity = 0.60,
    this.armingCountdownSeconds = 10,
    this.alarmVolume = 0.85,
    this.onboardingCompleted = false,
    this.colorTheme = WatSafeColorTheme.obsidianAmber,
    this.selectedAlarmSoundId = 'classic_siren',
    this.customAlarmSounds = const <CustomAlarmSound>[],
  });

  final DetectorType selectedDetector;

  /// Motion sensitivity in `[0.20, 0.90]`.
  final double motionSensitivity;

  /// Arming countdown in seconds (`3`..`30`).
  final int armingCountdownSeconds;

  /// Alarm output volume in `[0.10, 1.00]`.
  final double alarmVolume;

  /// Whether first-run onboarding and PIN creation have been completed.
  final bool onboardingCompleted;

  /// Active visual color theme for the application.
  final WatSafeColorTheme colorTheme;

  /// ID of the active alarm sound (either a [BuiltInAlarmSound.id] or a [CustomAlarmSound.id]).
  final String selectedAlarmSoundId;

  /// User-added custom alarm sounds persisted alongside built-in noises.
  final List<CustomAlarmSound> customAlarmSounds;

  /// Returns all built-in alarm noises followed by all user-added custom alarm sounds.
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
          description: custom.description,
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
      colorTheme: colorTheme ?? this.colorTheme,
      selectedAlarmSoundId: selectedAlarmSoundId ?? this.selectedAlarmSoundId,
      customAlarmSounds: customAlarmSounds != null
          ? List<CustomAlarmSound>.unmodifiable(customAlarmSounds)
          : this.customAlarmSounds,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'selectedDetector': selectedDetector.id,
      'motionSensitivity': motionSensitivity,
      'armingCountdownSeconds': armingCountdownSeconds,
      'alarmVolume': alarmVolume,
      'onboardingCompleted': onboardingCompleted,
      'colorTheme': colorTheme.id,
      'selectedAlarmSoundId': selectedAlarmSoundId,
      'customAlarmSounds': customAlarmSounds
          .map((item) => item.toJson())
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
            CustomAlarmSound.fromJson(Map<String, Object?>.from(item)),
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
      colorTheme: WatSafeColorTheme.fromId(json['colorTheme'] as String?),
      selectedAlarmSoundId:
          json['selectedAlarmSoundId'] as String? ??
          BuiltInAlarmSound.classicSiren.id,
      customAlarmSounds: List<CustomAlarmSound>.unmodifiable(
        parsedCustomSounds,
      ),
    );
  }
}
