import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/models/detector_models.dart';
import '../../core/models/settings_models.dart';
import '../theme/watsafe_theme.dart';

/// Settings screen for configuring color themes, built-in and custom alarm
/// noises, motion sensitivity, arming countdown, alarm volume, and changing
/// the security PIN (requiring the current PIN).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final AlarmController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _currentPinController = TextEditingController();
  final TextEditingController _newPinController = TextEditingController();
  final TextEditingController _confirmPinController = TextEditingController();

  final TextEditingController _customSoundNameController =
      TextEditingController();
  final TextEditingController _customWavPathController =
      TextEditingController();

  CustomAlarmWavePattern _selectedCustomPattern =
      CustomAlarmWavePattern.alternatingSiren;
  double _primaryFreqHz = 960.0;
  double _secondaryFreqHz = 1540.0;
  double _modulationRateHz = 4.0;
  String? _soundFeedbackMessage;
  bool _soundFeedbackSuccess = true;

  String? _pinChangeFeedback;
  bool _pinChangeSuccess = false;
  bool _isUpdatingPin = false;

  @override
  void dispose() {
    _currentPinController.dispose();
    _newPinController.dispose();
    _confirmPinController.dispose();
    _customSoundNameController.dispose();
    _customWavPathController.dispose();
    super.dispose();
  }

  Future<void> _handleBrowseWavFile() async {
    final picked = await widget.controller.browseCustomAudioFilePath();
    if (!mounted || picked == null) {
      return;
    }
    setState(() {
      _customWavPathController.text = picked;
      if (_customSoundNameController.text.trim().isEmpty) {
        final fileName = picked
            .split(RegExp(r'[/\\]'))
            .where((s) => s.isNotEmpty)
            .lastOrNull;
        if (fileName != null) {
          _customSoundNameController.text = fileName.replaceAll(
            RegExp(r'\.wav$', caseSensitive: false),
            '',
          );
        }
      }
    });
  }

  Future<void> _handleImportWavSound() async {
    final path = _customWavPathController.text.trim();
    if (path.isEmpty) {
      setState(() {
        _soundFeedbackSuccess = false;
        _soundFeedbackMessage =
            'Enter or browse to a valid .wav audio file path to import.';
      });
      return;
    }
    final imported = await widget.controller.importCustomWavAlarmSound(
      filePath: path,
      customName: _customSoundNameController.text.trim(),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      if (imported != null) {
        _soundFeedbackSuccess = true;
        _soundFeedbackMessage =
            'Added and selected custom WAV sound "${imported.name}".';
        _customWavPathController.clear();
        _customSoundNameController.clear();
      } else {
        _soundFeedbackSuccess = false;
        _soundFeedbackMessage =
            'Could not import WAV file. Ensure the file exists and has a valid RIFF/WAVE header.';
      }
    });
  }

  Future<void> _handleAddSynthesizedCustomSound() async {
    final rawName = _customSoundNameController.text.trim();
    final effectiveName = rawName.isEmpty
        ? 'Custom ${_selectedCustomPattern.displayName} (${_primaryFreqHz.round()}/${_secondaryFreqHz.round()} Hz)'
        : rawName;

    final created = await widget.controller.addCustomSynthesizedAlarmSound(
      name: effectiveName,
      pattern: _selectedCustomPattern,
      primaryFrequencyHz: _primaryFreqHz,
      secondaryFrequencyHz: _secondaryFreqHz,
      modulationRateHz: _modulationRateHz,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      if (created != null) {
        _soundFeedbackSuccess = true;
        _soundFeedbackMessage =
            'Added and selected custom alarm sound "${created.name}".';
        _customSoundNameController.clear();
      } else {
        _soundFeedbackSuccess = false;
        _soundFeedbackMessage = 'Could not create custom alarm sound.';
      }
    });
  }

  Future<void> _submitPinChange() async {
    if (_isUpdatingPin) {
      return;
    }
    setState(() {
      _isUpdatingPin = true;
      _pinChangeFeedback = null;
      _pinChangeSuccess = false;
    });

    final result = await widget.controller.changePin(
      currentPin: _currentPinController.text.trim(),
      newPin: _newPinController.text.trim(),
      confirmNewPin: _confirmPinController.text.trim(),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isUpdatingPin = false;
      _pinChangeSuccess = result.isValid;
      _pinChangeFeedback = result.isValid
          ? 'Security PIN updated and re-salted with PBKDF2-HMAC-SHA256.'
          : (result.errorMessage ?? 'Failed to change PIN.');
      if (result.isValid) {
        _currentPinController.clear();
        _newPinController.clear();
        _confirmPinController.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.controller.settings;
    final threshold = MonitorConfig(
      sessionId: 'settings_preview',
      sensitivity: settings.motionSensitivity,
    ).motionScoreThreshold;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Protection Settings, Themes & Alarm Sounds',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 20),
              _buildColorThemeCard(context, settings),
              const SizedBox(height: 20),
              _buildAlarmSoundsCard(context, settings),
              const SizedBox(height: 20),
              _buildDetectionParametersCard(context, settings, threshold),
              const SizedBox(height: 20),
              _buildPinChangeCard(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColorThemeCard(
    BuildContext context,
    ProtectionSettings settings,
  ) {
    return Card(
      key: const Key('color_theme_selector_card'),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.palette_outlined,
                  color: WatSafeTheme.amberAccent,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Appearance & Color Themes',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: WatSafeTheme.amberAccent,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Select a color theme for the WATSafe interface. Your selection applies immediately across all screens and persists locally.',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: WatSafeColorTheme.values.map((theme) {
                final palette = WatSafeTheme.paletteFor(theme);
                final isSelected = settings.colorTheme == theme;

                return SizedBox(
                  width: 260,
                  child: InkWell(
                    key: Key('theme_option_${theme.id}'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => widget.controller.selectColorTheme(theme),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? WatSafeTheme.charcoalElevated
                            : WatSafeTheme.charcoalDeep,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSelected
                              ? WatSafeTheme.amberAccent
                              : WatSafeTheme.charcoalBorder,
                          width: isSelected ? 2.0 : 1.0,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              _ThemeColorSwatchRow(palette: palette),
                              const Spacer(),
                              Icon(
                                isSelected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                size: 18,
                                color: isSelected
                                    ? WatSafeTheme.amberAccent
                                    : WatSafeTheme.warmSubtle,
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            theme.displayName,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: WatSafeTheme.warmOffWhite,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            theme.description,
                            style: TextStyle(
                              color: WatSafeTheme.warmMuted,
                              fontSize: 11.5,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlarmSoundsCard(
    BuildContext context,
    ProtectionSettings settings,
  ) {
    final allOptions = settings.allAlarmSoundOptions;
    final activeOption = settings.selectedAlarmSoundOption;
    final synthPatterns = CustomAlarmWavePattern.values
        .where((p) => p != CustomAlarmWavePattern.importedWavFile)
        .toList(growable: false);

    return Card(
      key: const Key('alarm_sounds_selector_card'),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.campaign_outlined,
                      color: WatSafeTheme.amberAccent,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Alarm Noises & Custom Alarm Sounds',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: WatSafeTheme.amberAccent,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    if (widget.controller.isAudioPlaying)
                      FilledButton.tonalIcon(
                        key: const Key('stop_preview_alarm_sound_button'),
                        onPressed: widget.controller.stopTestAlarm,
                        icon: const Icon(Icons.stop_circle_outlined, size: 16),
                        label: const Text('Stop Audio'),
                      )
                    else
                      OutlinedButton.icon(
                        key: const Key('preview_alarm_sound_button'),
                        onPressed: widget.controller.previewSelectedAlarmSound,
                        icon: const Icon(Icons.volume_up_outlined, size: 16),
                        label: Text('Preview "${activeOption.displayName}"'),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Choose from 5 built-in acoustic alarm noises or add your own custom alarm sounds below (via custom .WAV file import or custom waveform synthesis).',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            ...allOptions.map((option) {
              final isSelected = option.id == activeOption.id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  key: Key('alarm_sound_option_${option.id}'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => widget.controller.selectAlarmSound(option.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? WatSafeTheme.charcoalElevated
                          : WatSafeTheme.charcoalDeep,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? WatSafeTheme.amberAccent
                            : WatSafeTheme.charcoalBorder,
                        width: isSelected ? 1.6 : 1.0,
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          isSelected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          size: 18,
                          color: isSelected
                              ? WatSafeTheme.amberAccent
                              : WatSafeTheme.warmSubtle,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Flexible(
                                    child: Text(
                                      option.displayName,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: WatSafeTheme.warmOffWhite,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          (option.isCustom
                                                  ? WatSafeTheme.amberAccent
                                                  : WatSafeTheme.infoSteel)
                                              .withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(
                                        color: option.isCustom
                                            ? WatSafeTheme.amberAccent
                                            : WatSafeTheme.infoSteel,
                                      ),
                                    ),
                                    child: Text(
                                      option.isCustom ? 'CUSTOM' : 'BUILT-IN',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w800,
                                        color: option.isCustom
                                            ? WatSafeTheme.amberAccent
                                            : WatSafeTheme.infoSteel,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                option.description,
                                style: TextStyle(
                                  color: WatSafeTheme.warmMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (option.isCustom)
                          IconButton(
                            key: Key('delete_custom_sound_${option.id}'),
                            tooltip: 'Remove custom sound',
                            icon: Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: WatSafeTheme.warmMuted,
                            ),
                            onPressed: () {
                              widget.controller.removeCustomAlarmSound(
                                option.id,
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }),
            const Divider(height: 32),
            Text(
              'Add Custom Alarm Sound to Existing Options',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: WatSafeTheme.amberAccent,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('custom_sound_name_input'),
              controller: _customSoundNameController,
              decoration: const InputDecoration(
                labelText: 'Custom Alarm Sound Name',
                hintText: 'e.g., Lab Security Klaxon or Custom Siren',
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: WatSafeTheme.charcoalDeep,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: WatSafeTheme.charcoalBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Option A — Import Custom .WAV Audio File from Disk',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: WatSafeTheme.warmOffWhite,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          key: const Key('custom_wav_path_input'),
                          controller: _customWavPathController,
                          decoration: const InputDecoration(
                            labelText: 'Path to .WAV File',
                            hintText: r'C:\Sounds\my_custom_alarm.wav',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        key: const Key('browse_custom_wav_button'),
                        onPressed: _handleBrowseWavFile,
                        icon: const Icon(Icons.folder_open_outlined, size: 18),
                        label: const Text('Browse...'),
                      ),
                      const SizedBox(width: 10),
                      FilledButton.tonalIcon(
                        key: const Key('import_custom_wav_button'),
                        onPressed: _handleImportWavSound,
                        icon: const Icon(Icons.file_upload_outlined, size: 18),
                        label: const Text('Import WAV'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: WatSafeTheme.charcoalDeep,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: WatSafeTheme.charcoalBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Option B — Synthesize Custom Alarm Tone Generator',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: WatSafeTheme.warmOffWhite,
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<CustomAlarmWavePattern>(
                    key: const Key('custom_pattern_dropdown'),
                    isExpanded: true,
                    initialValue: _selectedCustomPattern,
                    decoration: const InputDecoration(
                      labelText: 'Waveform Modulation Pattern',
                    ),
                    items: synthPatterns
                        .map(
                          (p) => DropdownMenuItem<CustomAlarmWavePattern>(
                            value: p,
                            child: Text(p.displayName),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedCustomPattern = value;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      const Text(
                        'Primary Tone Frequency',
                        style: TextStyle(fontSize: 12.5),
                      ),
                      Text(
                        '${_primaryFreqHz.round()} Hz',
                        style: TextStyle(
                          color: WatSafeTheme.amberAccent,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    key: const Key('custom_primary_freq_slider'),
                    value: _primaryFreqHz,
                    min: 200.0,
                    max: 3200.0,
                    divisions: 60,
                    onChanged: (val) {
                      setState(() {
                        _primaryFreqHz = val;
                      });
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      const Text(
                        'Secondary Tone Frequency',
                        style: TextStyle(fontSize: 12.5),
                      ),
                      Text(
                        '${_secondaryFreqHz.round()} Hz',
                        style: TextStyle(
                          color: WatSafeTheme.amberAccent,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    key: const Key('custom_secondary_freq_slider'),
                    value: _secondaryFreqHz,
                    min: 200.0,
                    max: 3200.0,
                    divisions: 60,
                    onChanged: (val) {
                      setState(() {
                        _secondaryFreqHz = val;
                      });
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      const Text(
                        'Modulation / Pulse Rate',
                        style: TextStyle(fontSize: 12.5),
                      ),
                      Text(
                        '${_modulationRateHz.toStringAsFixed(1)} Hz',
                        style: TextStyle(
                          color: WatSafeTheme.amberAccent,
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    key: const Key('custom_mod_rate_slider'),
                    value: _modulationRateHz,
                    min: 1.0,
                    max: 12.0,
                    divisions: 22,
                    onChanged: (val) {
                      setState(() {
                        _modulationRateHz = val;
                      });
                    },
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      key: const Key('add_custom_synth_sound_button'),
                      onPressed: _handleAddSynthesizedCustomSound,
                      icon: const Icon(Icons.add_alert_outlined, size: 18),
                      label: const Text('Add Custom Tone to Alarm Options'),
                    ),
                  ),
                ],
              ),
            ),
            if (_soundFeedbackMessage != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _soundFeedbackMessage!,
                key: const Key('custom_sound_feedback_message'),
                style: TextStyle(
                  color: _soundFeedbackSuccess
                      ? WatSafeTheme.readyEmerald
                      : WatSafeTheme.alarmCrimson,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDetectionParametersCard(
    BuildContext context,
    ProtectionSettings settings,
    double threshold,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Detection & Countdown Parameters',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: WatSafeTheme.amberAccent,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                const Text(
                  'Scene-Motion Sensitivity',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${(settings.motionSensitivity * 100).round()}% (Trigger threshold: ${threshold.toStringAsFixed(3)})',
                  style: TextStyle(
                    color: WatSafeTheme.amberAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              key: const Key('sensitivity_slider'),
              value: settings.motionSensitivity,
              min: 0.20,
              max: 0.90,
              divisions: 14,
              onChanged: (value) {
                widget.controller.updateSettings(motionSensitivity: value);
              },
            ),
            Text(
              'Higher sensitivity lowers the required scene-motion score threshold. '
              'Requires 3 consecutive frames above threshold after calibration.',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 12.5),
            ),
            const Divider(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Text(
                  'Arming Countdown Duration',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${settings.armingCountdownSeconds} seconds',
                  style: TextStyle(
                    color: WatSafeTheme.amberAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              key: const Key('countdown_slider'),
              value: settings.armingCountdownSeconds.toDouble(),
              min: 3,
              max: 30,
              divisions: 27,
              onChanged: (value) {
                widget.controller.updateSettings(
                  armingCountdownSeconds: value.round(),
                );
              },
            ),
            Text(
              'Time provided after clicking Arm Protection to step back and stabilize the laptop before sensor calibration completes.',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 12.5),
            ),
            const Divider(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Text(
                  'Local Siren Volume',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${(settings.alarmVolume * 100).round()}%',
                  style: TextStyle(
                    color: WatSafeTheme.amberAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              key: const Key('volume_slider'),
              value: settings.alarmVolume,
              min: 0.10,
              max: 1.00,
              divisions: 18,
              onChanged: (value) {
                widget.controller.updateSettings(alarmVolume: value);
              },
            ),
            Text(
              widget.controller.audioLimitationsNote,
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPinChangeCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Change Disarm PIN (Requires Current PIN)',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: WatSafeTheme.amberAccent,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Storage adapter: ${widget.controller.pinStorageDescription}',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('settings_current_pin_input'),
              controller: _currentPinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(12),
              ],
              decoration: const InputDecoration(
                labelText: 'Current Security PIN',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('settings_new_pin_input'),
              controller: _newPinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(12),
              ],
              decoration: const InputDecoration(
                labelText: 'New Security PIN (6–12 digits)',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('settings_confirm_pin_input'),
              controller: _confirmPinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(12),
              ],
              decoration: const InputDecoration(
                labelText: 'Confirm New Security PIN',
              ),
              onSubmitted: (_) => _submitPinChange(),
            ),
            if (_pinChangeFeedback != null) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color:
                      (_pinChangeSuccess
                              ? WatSafeTheme.readyEmerald
                              : WatSafeTheme.alarmCrimson)
                          .withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _pinChangeSuccess
                        ? WatSafeTheme.readyEmerald
                        : WatSafeTheme.alarmCrimson,
                  ),
                ),
                child: Text(
                  _pinChangeFeedback!,
                  style: TextStyle(
                    color: WatSafeTheme.warmOffWhite,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('settings_change_pin_button'),
                onPressed: _isUpdatingPin ? null : _submitPinChange,
                icon: const Icon(Icons.password_outlined),
                label: const Text('Update Security PIN'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeColorSwatchRow extends StatelessWidget {
  const _ThemeColorSwatchRow({required this.palette});

  final WatSafePalette palette;

  @override
  Widget build(BuildContext context) {
    final colors = <Color>[
      palette.backgroundDeep,
      palette.surfaceElevated,
      palette.primaryAccent,
      palette.secondaryAccent,
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: colors
          .map(
            (c) => Container(
              width: 18,
              height: 18,
              margin: const EdgeInsets.only(right: 5),
              decoration: BoxDecoration(
                color: c,
                shape: BoxShape.circle,
                border: Border.all(color: palette.border, width: 1),
              ),
            ),
          )
          .toList(),
    );
  }
}
