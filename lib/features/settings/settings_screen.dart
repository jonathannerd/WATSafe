import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/alarm/alarm_state.dart';
import '../../core/models/detector_models.dart';
import '../../core/models/settings_models.dart';
import '../pairing/phone_pairing_sheet.dart';
import '../testing/guided_protection_test_sheet.dart';
import '../theme/watsafe_theme.dart';

/// Categorized Settings hub with 7 short-labeled categories and dedicated
/// category pages with clear Back navigation:
/// 1. Protection
/// 2. Alarm
/// 3. Devices & notifications
/// 4. Location & privacy
/// 5. PIN & security
/// 6. Appearance
/// 7. Advanced & help
enum SettingsCategory {
  protection,
  alarm,
  devices,
  location,
  pin,
  appearance,
  advanced,
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.initialCategory,
  });

  final AlarmController controller;
  final SettingsCategory? initialCategory;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _deviceNameController;
  late final TextEditingController _permanentRelayUrlController;
  late final TextEditingController _relayUrlController;
  final TextEditingController _currentPinController = TextEditingController();
  final TextEditingController _newPinController = TextEditingController();
  final TextEditingController _confirmPinController = TextEditingController();
  final TextEditingController _customSoundNameController =
      TextEditingController();
  final TextEditingController _customSoundFilePathController =
      TextEditingController();

  SettingsCategory? _activeCategory;
  String? _pinMessage;
  bool _pinSuccess = false;
  bool _isUpdatingPin = false;
  String? _deviceNameSavedNote;
  String? _permanentUrlNote;
  bool _permanentUrlIsError = false;
  String? _advancedNote;
  String? _locationHistoryNote;
  CustomAlarmWavePattern _customWavePattern =
      CustomAlarmWavePattern.alternatingSiren;
  double _customPrimaryFreqHz = 960.0;
  double _customSecondaryFreqHz = 1440.0;
  double _customModulationRateHz = 3.5;
  String? _customSoundFeedback;
  bool _customSoundSuccess = false;

  @override
  void initState() {
    super.initState();
    _activeCategory = widget.initialCategory;
    widget.controller.addListener(_onControllerUpdated);
    _deviceNameController = TextEditingController(
      text: widget.controller.effectiveDeviceName,
    );
    _permanentRelayUrlController = TextEditingController(
      text: widget.controller.isPermanentRelayConfigured
          ? (widget.controller.relayEndpointUrl ?? '')
          : '',
    );
    _relayUrlController = TextEditingController(
      text: widget.controller.relayEndpointUrl ?? '',
    );
  }

  void _onControllerUpdated() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdated);
    _deviceNameController.dispose();
    _permanentRelayUrlController.dispose();
    _relayUrlController.dispose();
    _currentPinController.dispose();
    _newPinController.dispose();
    _confirmPinController.dispose();
    _customSoundNameController.dispose();
    _customSoundFilePathController.dispose();
    super.dispose();
  }

  void _openCategory(SettingsCategory category) {
    setState(() {
      _activeCategory = category;
    });
  }

  void _returnToCategoryList() {
    setState(() {
      _activeCategory = null;
    });
  }

  Future<void> _saveDeviceName() async {
    final trimmed = _deviceNameController.text.trim();
    await widget.controller.updateDeviceDisplayName(trimmed);
    if (!mounted) {
      return;
    }
    setState(() {
      _deviceNameSavedNote = 'Device name saved.';
    });
  }

  Future<void> _handleChangePin() async {
    if (_isUpdatingPin) {
      return;
    }
    setState(() {
      _isUpdatingPin = true;
      _pinMessage = null;
    });

    final result = await widget.controller.changePin(
      currentPin: _currentPinController.text,
      newPin: _newPinController.text,
      confirmNewPin: _confirmPinController.text,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isUpdatingPin = false;
      _pinSuccess = result.isValid;
      _pinMessage = result.isValid
          ? 'Your PIN has been updated.'
          : result.errorMessage;
      if (result.isValid) {
        _currentPinController.clear();
        _newPinController.clear();
        _confirmPinController.clear();
      }
    });
  }

  Future<void> _handleBrowseCustomWav() async {
    final picked = await widget.controller.browseCustomAudioFilePath();
    if (!mounted || picked == null) {
      return;
    }
    setState(() {
      _customSoundFilePathController.text = picked;
      if (_customSoundNameController.text.trim().isEmpty) {
        final normalized = picked.replaceAll('\\', '/');
        final fileName = normalized.split('/').last;
        _customSoundNameController.text = fileName.replaceAll(
          RegExp(r'\.wav$', caseSensitive: false),
          '',
        );
      }
    });
  }

  Future<void> _handleImportCustomWav() async {
    final added = await widget.controller.importCustomWavAlarmSound(
      name: _customSoundNameController.text,
      filePath: _customSoundFilePathController.text,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      if (added != null) {
        _customSoundSuccess = true;
        _customSoundFeedback =
            'Added & selected custom WAV alarm "${added.name}".';
        _customSoundNameController.clear();
        _customSoundFilePathController.clear();
      } else {
        _customSoundSuccess = false;
        _customSoundFeedback =
            widget.controller.warningMessage ??
            'Could not import custom WAV file.';
      }
    });
  }

  Future<void> _handleAddSynthesizedCustomSound() async {
    final name = _customSoundNameController.text.trim().isEmpty
        ? 'Custom ${_customWavePattern.displayName}'
        : _customSoundNameController.text.trim();
    final added = await widget.controller.addCustomSynthesizedAlarmSound(
      name: name,
      pattern: _customWavePattern,
      primaryFrequencyHz: _customPrimaryFreqHz,
      secondaryFrequencyHz: _customSecondaryFreqHz,
      modulationRateHz: _customModulationRateHz,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      if (added != null) {
        _customSoundSuccess = true;
        _customSoundFeedback = 'Added & selected custom alarm "${added.name}".';
        _customSoundNameController.clear();
      } else {
        _customSoundSuccess = false;
        _customSoundFeedback =
            widget.controller.warningMessage ??
            'Could not create custom alarm sound.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    WatSafeTheme.of(context);
    final controller = widget.controller;
    final settings = controller.settings;
    final isLockedByProtection =
        controller.state == ProtectionState.arming ||
        controller.state == ProtectionState.armed ||
        controller.state == ProtectionState.alarming ||
        controller.state == ProtectionState.paused;

    return PopScope(
      canPop: _activeCategory == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _activeCategory != null) {
          _returnToCategoryList();
        }
      },
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: _activeCategory == null
                ? _buildCategoryIndex(context, controller, settings)
                : _buildCategoryDetail(
                    context,
                    _activeCategory!,
                    controller,
                    settings,
                    isLockedByProtection,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryIndex(
    BuildContext context,
    AlarmController controller,
    ProtectionSettings settings,
  ) {
    final methodLabel = controller.selectedDetectorType.userFacingMethodName;
    final pairedPhoneCount = controller.pairedDevices.length;
    final devicesSubtitle = controller.isCompanionMode
        ? 'Connected to ${controller.companionSession.hostDisplayName ?? 'protected computer'}'
        : pairedPhoneCount == 0
        ? '${controller.effectiveDeviceName} · No trusted phones'
        : '${controller.effectiveDeviceName} · $pairedPhoneCount trusted phone${pairedPhoneCount == 1 ? '' : 's'}';
    final locPerm = controller.locationPermissionStatus;
    final shareLocation = settings.shareLocationOnAlarm;
    final locationSubtitle = !shareLocation
        ? 'Off'
        : (locPerm == PermissionStatus.granted
              ? 'On · Every 4 min while open'
              : 'Permission needed');

    return Column(
      key: const Key('settings_category_list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Settings',
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 16),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: <Widget>[
              _SettingsCategoryRow(
                tileKey: const Key('settings_category_protection'),
                icon: Icons.shield_outlined,
                title: 'Protection',
                subtitle:
                    '$methodLabel · ${settings.sensitivityPreset.title} · ${settings.armingCountdownSeconds}s delay',
                onTap: () => _openCategory(SettingsCategory.protection),
              ),
              const Divider(height: 1, indent: 56),
              _SettingsCategoryRow(
                tileKey: const Key('settings_category_alarm'),
                icon: Icons.volume_up_outlined,
                title: 'Alarm',
                subtitle:
                    '${settings.selectedAlarmSoundOption.displayName} · ${(settings.alarmVolume * 100).round()}% volume',
                onTap: () => _openCategory(SettingsCategory.alarm),
              ),
              const Divider(height: 1, indent: 56),
              _SettingsCategoryRow(
                tileKey: const Key('settings_category_devices'),
                icon: Icons.devices_rounded,
                title: 'Devices & notifications',
                subtitle: devicesSubtitle,
                onTap: () => _openCategory(SettingsCategory.devices),
              ),
              const Divider(height: 1, indent: 56),
              _SettingsCategoryRow(
                tileKey: const Key('settings_category_location'),
                icon: Icons.location_on_outlined,
                title: 'Privacy Center',
                subtitle: locationSubtitle,
                onTap: () => _openCategory(SettingsCategory.location),
              ),
              const Divider(height: 1, indent: 56),
              _SettingsCategoryRow(
                tileKey: const Key('settings_category_pin'),
                icon: Icons.lock_outline_rounded,
                title: 'PIN & security',
                subtitle: '6+ digit security PIN',
                onTap: () => _openCategory(SettingsCategory.pin),
              ),
              const Divider(height: 1, indent: 56),
              _SettingsCategoryRow(
                tileKey: const Key('settings_category_appearance'),
                icon: Icons.palette_outlined,
                title: 'Appearance',
                subtitle: settings.colorTheme.displayName,
                onTap: () => _openCategory(SettingsCategory.appearance),
              ),
              const Divider(height: 1, indent: 56),
              _SettingsCategoryRow(
                tileKey: const Key('settings_category_advanced'),
                icon: Icons.tune_rounded,
                title: 'Advanced & help',
                subtitle: 'Diagnostics, service address, and activity reset',
                onTap: () => _openCategory(SettingsCategory.advanced),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryDetail(
    BuildContext context,
    SettingsCategory category,
    AlarmController controller,
    ProtectionSettings settings,
    bool isLockedByProtection,
  ) {
    final categoryTitle = switch (category) {
      SettingsCategory.protection => 'Protection',
      SettingsCategory.alarm => 'Alarm',
      SettingsCategory.devices => 'Devices & notifications',
      SettingsCategory.location => 'Privacy Center',
      SettingsCategory.pin => 'PIN & security',
      SettingsCategory.appearance => 'Appearance',
      SettingsCategory.advanced => 'Advanced & help',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            TextButton.icon(
              key: const Key('settings_category_back_button'),
              onPressed: _returnToCategoryList,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              icon: const Icon(Icons.arrow_back_rounded, size: 19),
              label: const Text('Settings'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          categoryTitle,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 16),
        ...switch (category) {
          SettingsCategory.protection => <Widget>[
            _buildProtectionCategoryCard(
              context,
              controller,
              settings.armingCountdownSeconds,
              isLockedByProtection,
            ),
          ],
          SettingsCategory.alarm => <Widget>[
            _buildSirenVolumeAndTestCard(
              controller,
              settings.alarmVolume,
              isLockedByProtection,
            ),
            const SizedBox(height: 16),
            _buildAlarmSoundsCard(context, controller, settings),
          ],
          SettingsCategory.devices => <Widget>[
            _buildDeviceIdentityCard(context),
            const SizedBox(height: 16),
            _buildPairedDevicesAndNotificationsCard(context, controller),
            if (controller.canManagePairing) ...<Widget>[
              const SizedBox(height: 16),
              _buildPermanentCompanionCard(context, controller),
            ],
          ],
          SettingsCategory.location => <Widget>[
            _buildLocationAndPrivacyCard(context, controller),
            const SizedBox(height: 16),
            _buildSafeZonesCard(context, controller),
          ],
          SettingsCategory.pin => <Widget>[_buildChangePinCard(context)],
          SettingsCategory.appearance => <Widget>[
            _buildColorThemesCard(context, controller, settings),
          ],
          SettingsCategory.advanced => <Widget>[
            _buildAdvancedCategoryCards(
              context,
              controller,
              isLockedByProtection,
            ),
          ],
        },
      ],
    );
  }

  Widget _buildProtectionCategoryCard(
    BuildContext context,
    AlarmController controller,
    int countdownSeconds,
    bool isLockedByProtection,
  ) {
    final palette = WatSafeTheme.of(context);
    final hostOptions = controller.availableHostDetectors;
    final showMethodPicker = hostOptions.length > 1;
    final usesCamera = controller.selectedDetectorType.usesCamera;
    final supportsAcPowerDisconnect =
        controller.selectedDetectorType == DetectorType.macosCameraSceneMotion ||
        controller.selectedDetectorType == DetectorType.windowsCameraSceneMotion;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (showMethodPicker) ...<Widget>[
              const Text(
                'Sensor',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              ...hostOptions.map((type) {
                final cap = controller.capabilities[type];
                final selected = type == controller.selectedDetectorType;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    key: Key('select_detector_${type.name}'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: isLockedByProtection
                        ? null
                        : () => controller.selectDetector(type),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? WatSafeTheme.amberAccent.withValues(alpha: 0.14)
                            : WatSafeTheme.charcoalElevated,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected
                              ? WatSafeTheme.amberAccent
                              : WatSafeTheme.charcoalBorder,
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            type.usesCamera
                                ? Icons.videocam_outlined
                                : Icons.sensors_rounded,
                            color: selected
                                ? WatSafeTheme.amberAccent
                                : WatSafeTheme.warmMuted,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  type.userFacingMethodName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  cap != null && !cap.canArm
                                      ? cap.summary
                                      : type.userFacingDescription,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: WatSafeTheme.warmMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (selected)
                            Icon(
                              Icons.check_circle_rounded,
                              color: WatSafeTheme.amberAccent,
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              const SizedBox(height: 12),
            ],
            const Text(
              'Sensitivity',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ...MotionSensitivityPreset.values.map((preset) {
              final activePreset = controller.settings.sensitivityPreset;
              final isSelected = preset == activePreset;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  key: Key('preset_${preset.name}'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: isLockedByProtection
                      ? null
                      : () => controller.selectSensitivityPreset(preset),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? WatSafeTheme.amberAccent.withValues(alpha: 0.14)
                          : WatSafeTheme.charcoalElevated,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? WatSafeTheme.amberAccent
                            : WatSafeTheme.charcoalBorder,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            isSelected
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_off_rounded,
                            size: 19,
                            color: isSelected
                                ? WatSafeTheme.amberAccent
                                : WatSafeTheme.warmMuted,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                preset.title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                preset.description,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: WatSafeTheme.warmMuted,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
            const SizedBox(height: 12),
            const Text(
              'Arming delay',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <int>[5, 10, 15, 30].map((seconds) {
                final selected = countdownSeconds == seconds;
                return ChoiceChip(
                  label: Text('${seconds}s'),
                  selected: selected,
                  selectedColor: palette.accentPrimary,
                  labelStyle: TextStyle(
                    color: selected
                        ? palette.onAccentColor
                        : palette.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                  onSelected: isLockedByProtection
                      ? null
                      : (_) => controller.updateSettings(
                          armingCountdownSeconds: seconds,
                        ),
                );
              }).toList(),
            ),
            if (!controller.isCompanionMode && usesCamera) ...<Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Divider(height: 1),
              ),
              SwitchListTile(
                key: const Key('alert_on_camera_obstruction_switch'),
                contentPadding: EdgeInsets.zero,
                activeThumbColor: WatSafeTheme.amberAccent,
                title: const Text(
                  'Camera obstruction alarm',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Sounds siren and alerts your phone if the camera is covered while armed.',
                  style: TextStyle(
                    color: WatSafeTheme.warmMuted,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
                value: controller.settings.alertOnCameraObstruction,
                onChanged: isLockedByProtection
                    ? null
                    : controller.updateAlertOnCameraObstruction,
              ),
            ],
            if (!controller.isCompanionMode &&
                controller.isInputInteractionDetectionSupported) ...<Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 1),
              ),
              SwitchListTile(
                key: const Key('alert_on_input_interaction_switch'),
                contentPadding: EdgeInsets.zero,
                activeThumbColor: WatSafeTheme.amberAccent,
                title: const Text(
                  'Keyboard & trackpad alert',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Starts an 8s PIN window when keys or trackpad are used while armed.',
                  style: TextStyle(
                    color: WatSafeTheme.warmMuted,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
                value: controller.settings.alertOnInputInteraction,
                onChanged: isLockedByProtection
                    ? null
                    : controller.updateAlertOnInputInteraction,
              ),
            ],
            if (!controller.isCompanionMode && supportsAcPowerDisconnect) ...<Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 1),
              ),
              SwitchListTile(
                key: const Key('alert_on_ac_power_disconnect_switch'),
                contentPadding: EdgeInsets.zero,
                activeThumbColor: WatSafeTheme.amberAccent,
                title: const Text(
                  'Charger disconnect alert',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Show a local alert if the native detector reports AC power disconnected while protected. Battery percentage monitoring is not available yet.',
                  style: TextStyle(
                    color: WatSafeTheme.warmMuted,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
                value: controller.settings.alertOnAcPowerDisconnect,
                onChanged: isLockedByProtection
                    ? null
                    : controller.updateAlertOnAcPowerDisconnect,
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('settings_guided_test_button'),
                onPressed: isLockedByProtection
                    ? null
                    : () => showGuidedProtectionTestSheet(context, controller),
                icon: const Icon(Icons.verified_user_outlined, size: 18),
                label: const Text('Guided protection test'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSirenVolumeAndTestCard(
    AlarmController controller,
    double alarmVolume,
    bool isLockedByProtection,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Siren volume',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(alarmVolume * 100).round()}%',
                  style: TextStyle(
                    color: WatSafeTheme.amberAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              value: alarmVolume,
              min: 0.1,
              max: 1.0,
              divisions: 18,
              activeColor: WatSafeTheme.amberAccent,
              onChanged: (value) =>
                  controller.updateSettings(alarmVolume: value),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: controller.isTestAlarmRunning
                  ? OutlinedButton.icon(
                      key: const Key('stop_test_alarm_button'),
                      onPressed: controller.stopTestAlarm,
                      icon: const Icon(Icons.stop_rounded),
                      label: const Text('Stop siren test'),
                    )
                  : OutlinedButton.icon(
                      key: const Key('start_test_alarm_button'),
                      onPressed: isLockedByProtection
                          ? null
                          : controller.startTestAlarm,
                      icon: const Icon(Icons.volume_up_rounded),
                      label: const Text('Test siren (5s)'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceIdentityCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Device name',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Shown on the map and in phone alerts.',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('settings_device_name_input'),
                    controller: _deviceNameController,
                    decoration: const InputDecoration(
                      labelText: 'Device name',
                      hintText: 'My MacBook',
                    ),
                    onSubmitted: (_) => _saveDeviceName(),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  key: const Key('save_device_name_button'),
                  onPressed: _saveDeviceName,
                  child: const Text('Save'),
                ),
              ],
            ),
            if (_deviceNameSavedNote != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _deviceNameSavedNote!,
                style: TextStyle(
                  color: WatSafeTheme.readyEmerald,
                  fontSize: 12.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPairedDevicesAndNotificationsCard(
    BuildContext context,
    AlarmController controller,
  ) {
    final pairedPhone = controller.pairedDevices.firstOrNull;
    final notifPerm = controller.localNotificationPermissionStatus;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'Paired phone',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        pairedPhone != null
                            ? '${pairedPhone.displayName} · ${pairedPhone.notificationsEnabled ? "Notifications on" : "Setup needed"}'
                            : 'No phone paired yet',
                        style: TextStyle(
                          color: WatSafeTheme.warmMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (pairedPhone != null)
                  OutlinedButton(
                    key: const Key('settings_manage_paired_phone_button'),
                    onPressed: () =>
                        showConnectedPhoneDetailsSheet(context, controller),
                    child: const Text('Details'),
                  )
                else if (controller.canManagePairing)
                  OutlinedButton(
                    key: const Key('settings_pair_phone_button'),
                    onPressed: () => showPhonePairingSheet(context, controller),
                    child: const Text('Pair phone'),
                  ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(height: 1),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'Local notifications',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _notificationPermissionSummary(
                          isSupported: controller.isLocalNotificationsSupported,
                          status: notifPerm,
                          pushConfigured:
                              controller.companionSession.pushServerConfigured,
                        ),
                        style: TextStyle(
                          color: WatSafeTheme.warmMuted,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                if (controller.isLocalNotificationsSupported &&
                    notifPerm != PermissionStatus.granted) ...<Widget>[
                  const SizedBox(width: 12),
                  OutlinedButton(
                    key: const Key('request_notification_permission_button'),
                    onPressed: controller.requestLocalNotificationPermission,
                    child: const Text('Allow'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationAndPrivacyCard(
    BuildContext context,
    AlarmController controller,
  ) {
    final locPerm = controller.locationPermissionStatus;
    final shareLocation = controller.settings.shareLocationOnAlarm;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (controller.isCompanionMode) ...<Widget>[
              SwitchListTile(
                key: const Key('share_companion_phone_location_switch'),
                contentPadding: EdgeInsets.zero,
                activeThumbColor: WatSafeTheme.amberAccent,
                title: const Text(
                  'Share phone location',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'While app is open',
                  style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 13),
                ),
                value: controller.settings.shareCompanionPhoneLocation,
                onChanged: controller.updateShareCompanionPhoneLocation,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 1),
              ),
            ],
            SwitchListTile(
              key: const Key('share_location_switch'),
              contentPadding: EdgeInsets.zero,
              activeThumbColor: WatSafeTheme.amberAccent,
              title: const Text(
                'Share laptop location',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                _locationPermissionSummary(
                  isSupported: controller.isLocationSupported,
                  status: locPerm,
                  enabled: shareLocation,
                ),
                style: TextStyle(
                  color: WatSafeTheme.warmMuted,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              value: shareLocation,
              onChanged: controller.updateShareLocationOnAlarm,
            ),
            if (shareLocation &&
                controller.isLocationSupported &&
                locPerm != PermissionStatus.granted) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('request_location_permission_button'),
                  onPressed: controller.requestLocationPermission,
                  icon: const Icon(Icons.my_location_rounded, size: 18),
                  label: Text(
                    locPerm == PermissionStatus.denied
                        ? 'Check location access'
                        : 'Enable location',
                  ),
                ),
              ),
            ],
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(height: 1),
            ),
            const Text(
              'Privacy at a glance',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Camera frames are processed on the protected device and are not uploaded. Location sharing is controlled separately above. Safe Zone definitions and radii stay in this installation and are never sent as zones. When laptop location sharing is enabled, current location may still be shared separately. Lock-screen alerts do not include coordinates.',
              style: TextStyle(
                color: WatSafeTheme.warmMuted,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(height: 1),
            ),
            const Text(
              'Stored history',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Shared only inside your paired session and automatically deleted after 7 days.',
              style: TextStyle(
                color: WatSafeTheme.warmMuted,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('delete_location_history_button'),
                onPressed: () async {
                  final ok = await controller.deleteStoredLocationHistory();
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _locationHistoryNote = ok
                        ? 'Stored location history deleted from this device and your relay session.'
                        : 'Local location history deleted. Relay cleanup will sync when back online.';
                  });
                },
                icon: const Icon(Icons.location_disabled_outlined, size: 18),
                label: const Text('Delete history'),
              ),
            ),
            if (_locationHistoryNote != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _locationHistoryNote!,
                key: const Key('location_history_deleted_note'),
                style: TextStyle(
                  color: WatSafeTheme.readyEmerald,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _addSafeZoneFromCurrentLocation(
    BuildContext context,
    AlarmController controller,
  ) async {
    final nameController = TextEditingController();
    var radiusMeters = 500.0;
    try {
      final result = await showDialog<({String name, double radius})>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              final palette = WatSafeTheme.of(dialogContext);
              return AlertDialog(
                title: const Text('Add Safe Zone'),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Text(
                        'Use this device’s current location as the centre. WATSafe will request location access only after you save.',
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const Key('safe_zone_name_input'),
                        controller: nameController,
                        autofocus: true,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Place name',
                          hintText: 'e.g. Home or Campus',
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Radius · ${radiusMeters.round()} m',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Slider(
                        key: const Key('safe_zone_radius_slider'),
                        min: 100,
                        max: 2000,
                        divisions: 19,
                        value: radiusMeters,
                        activeColor: palette.accentPrimary,
                        onChanged: (value) {
                          setDialogState(() => radiusMeters = value);
                        },
                      ),
                    ],
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('safe_zone_save_button'),
                    onPressed: () {
                      final name = nameController.text.trim();
                      if (name.isNotEmpty) {
                        Navigator.of(dialogContext).pop((
                          name: name,
                          radius: radiusMeters,
                        ));
                      }
                    },
                    child: const Text('Save Safe Zone'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (result == null || !mounted) return;
      if (controller.localNotificationPermissionStatus !=
          PermissionStatus.granted) {
        final notificationPermission =
            await controller.requestLocalNotificationPermission();
        if (!mounted) return;
        if (notificationPermission != PermissionStatus.granted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Allow local notifications before creating a Safe Zone.',
              ),
            ),
          );
          return;
        }
      }
      final created = await controller.addSafeZoneFromCurrentLocation(
        name: result.name,
        radiusMeters: result.radius,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            created
                ? 'Safe Zone added on this device.'
                : (controller.warningMessage ??
                    'Could not add a Safe Zone. Check location permission and try again.'),
          ),
        ),
      );
    } finally {
      nameController.dispose();
    }
  }

  Future<void> _restoreSafeZoneMonitoring(
    BuildContext context,
    AlarmController controller,
    String zoneId,
  ) async {
    if (controller.localNotificationPermissionStatus !=
        PermissionStatus.granted) {
      final notificationPermission =
          await controller.requestLocalNotificationPermission();
      if (notificationPermission != PermissionStatus.granted) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Local notification permission is still required.'),
          ),
        );
        return;
      }
    }
    await controller.setSafeZoneEnabled(zoneId, true);
    if (!context.mounted) return;
    if (controller.locationPermissionStatus != PermissionStatus.granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Allow location access to resume Safe Zone checks.'),
        ),
      );
    }
  }

  Widget _buildSafeZonesCard(
    BuildContext context,
    AlarmController controller,
  ) {
    final palette = WatSafeTheme.of(context);
    final zones = controller.settings.safeZones;
    final firstEnabledZone = zones.where((zone) => zone.enabled).firstOrNull;
    final safeZonePermissionsMissing = firstEnabledZone != null &&
        (controller.locationPermissionStatus != PermissionStatus.granted ||
            controller.localNotificationPermissionStatus !=
                PermissionStatus.granted);
    final protectionLocked =
        controller.state == ProtectionState.arming ||
        controller.state == ProtectionState.armed ||
        controller.state == ProtectionState.alarming ||
        controller.state == ProtectionState.paused;
    final canAdd = !controller.isCompanionMode &&
        controller.isLocationSupported &&
        controller.isLocalNotificationsSupported &&
        !protectionLocked;
    return Card(
      key: const Key('safe_zones_card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Safe Zones',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Get a local notification when this protected computer enters or leaves a saved area. Zones are stored on this device only. WATSafe checks while it is running and location access is available; this is not background tracking.',
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
            if (safeZonePermissionsMissing) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                key: const Key('safe_zone_permissions_warning'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: palette.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: palette.borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Safe Zone checks are paused',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Location and local notification permission are needed to resume enter/leave alerts.',
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const Key('safe_zone_restore_permissions_button'),
                      onPressed: controller.isCompanionMode ||
                              !controller.isLocationSupported ||
                              !controller.isLocalNotificationsSupported
                          ? null
                          : () => _restoreSafeZoneMonitoring(
                                context,
                                controller,
                                firstEnabledZone!.id,
                              ),
                      icon: const Icon(Icons.notifications_active_outlined),
                      label: const Text('Resume Safe Zone checks'),
                    ),
                  ],
                ),
              ),
            ],
            if (zones.isEmpty) ...<Widget>[
              const SizedBox(height: 14),
              Text(
                'No Safe Zones yet.',
                style: TextStyle(color: palette.textMuted),
              ),
            ] else ...<Widget>[
              const SizedBox(height: 10),
              for (final zone in zones)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              zone.name,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              'Radius · ${zone.radiusMeters.round()} m',
                              style: TextStyle(
                                color: palette.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        key: Key('safe_zone_enabled_${zone.id}'),
                        value: zone.enabled,
                        onChanged: controller.isCompanionMode || protectionLocked
                            ? null
                            : (enabled) =>
                                controller.setSafeZoneEnabled(zone.id, enabled),
                      ),
                      IconButton(
                        key: Key('safe_zone_remove_${zone.id}'),
                        tooltip: 'Remove Safe Zone',
                        onPressed: controller.isCompanionMode || protectionLocked
                            ? null
                            : () => controller.removeSafeZone(zone.id),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('safe_zone_add_button'),
                onPressed: canAdd
                    ? () => _addSafeZoneFromCurrentLocation(context, controller)
                    : null,
                icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                label: const Text('Add current location'),
              ),
            ),
            if (controller.isCompanionMode)
              Text(
                'Safe Zones are configured from the protected computer, not the companion phone.',
                style: TextStyle(color: palette.textMuted, fontSize: 12),
              )
            else if (!controller.isLocationSupported)
              Text(
                'Location is not supported on this platform.',
                style: TextStyle(color: palette.textMuted, fontSize: 12),
              )
            else if (!controller.isLocalNotificationsSupported)
              Text(
                'Local notifications are not supported on this platform.',
                style: TextStyle(color: palette.textMuted, fontSize: 12),
              )
            else if (protectionLocked)
              Text(
                'Turn protection off before editing Safe Zones.',
                style: TextStyle(color: palette.textMuted, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildColorThemesCard(
    BuildContext context,
    AlarmController controller,
    ProtectionSettings settings,
  ) {
    final activePalette = WatSafeTheme.of(context);
    final activeTheme = settings.colorTheme;
    return Card(
      key: const Key('color_theme_selector_card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Color theme',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Applies immediately across the sidebar, controls, cards, and alerts.',
              style: TextStyle(color: activePalette.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: WatSafeColorTheme.values
                  .map((themeItem) {
                    final palette = WatSafeTheme.paletteFor(themeItem);
                    final isSelected = themeItem == activeTheme;
                    return Semantics(
                      selected: isSelected,
                      button: true,
                      label:
                          '${themeItem.displayName}. ${themeItem.description}',
                      child: InkWell(
                        key: Key('theme_option_${themeItem.id}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => controller.selectColorTheme(themeItem),
                        child: Container(
                          width: 200,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: palette.surfaceElevated,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected
                                  ? palette.accentPrimary
                                  : palette.borderColor,
                              width: isSelected ? 2.0 : 1.0,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  _swatchCircle(
                                    palette.sidebarBackground,
                                    palette.borderColor,
                                  ),
                                  const SizedBox(width: 4),
                                  _swatchCircle(
                                    palette.backgroundDeep,
                                    palette.borderColor,
                                  ),
                                  const SizedBox(width: 4),
                                  _swatchCircle(
                                    palette.accentPrimary,
                                    palette.borderColor,
                                  ),
                                  const SizedBox(width: 4),
                                  _swatchCircle(
                                    palette.readyColor,
                                    palette.borderColor,
                                  ),
                                  const Spacer(),
                                  if (isSelected)
                                    Icon(
                                      Icons.check_circle_rounded,
                                      size: 18,
                                      color: palette.accentPrimary,
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                themeItem.displayName,
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                themeItem.description,
                                style: TextStyle(
                                  color: palette.textMuted,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  })
                  .toList(growable: false),
            ),
          ],
        ),
      ),
    );
  }

  Widget _swatchCircle(Color fill, Color border) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 1),
      ),
    );
  }

  Widget _buildAlarmSoundsCard(
    BuildContext context,
    AlarmController controller,
    ProtectionSettings settings,
  ) {
    final allOptions = settings.allAlarmSoundOptions;
    final selectedOption = settings.selectedAlarmSoundOption;
    return Card(
      key: const Key('alarm_sounds_selector_card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text(
                  'Alarm sound',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                OutlinedButton.icon(
                  key: const Key('preview_alarm_sound_button'),
                  onPressed: controller.isTestAlarmRunning
                      ? controller.stopTestAlarm
                      : controller.previewSelectedAlarmSound,
                  icon: Icon(
                    controller.isTestAlarmRunning
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                    size: 18,
                  ),
                  label: Text(
                    controller.isTestAlarmRunning ? 'Stop Preview' : 'Preview',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...allOptions.map((option) {
              final isSelected = option.id == selectedOption.id;
              return Container(
                key: Key('alarm_sound_option_${option.id}'),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: isSelected
                      ? WatSafeTheme.amberAccent.withValues(alpha: 0.14)
                      : WatSafeTheme.charcoalElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected
                        ? WatSafeTheme.amberAccent
                        : WatSafeTheme.charcoalBorder,
                    width: isSelected ? 1.6 : 1.0,
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 2,
                    ),
                    onTap: () => controller.selectAlarmSound(option.id),
                    leading: Icon(
                      isSelected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      color: isSelected
                          ? WatSafeTheme.amberAccent
                          : WatSafeTheme.warmMuted,
                    ),
                    title: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            option.displayName,
                            style: TextStyle(
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                        if (option.isCustom)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: WatSafeTheme.infoSteel.withValues(
                                alpha: 0.16,
                              ),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'CUSTOM',
                              style: TextStyle(
                                color: WatSafeTheme.infoSteel,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      option.description,
                      style: TextStyle(
                        color: WatSafeTheme.warmMuted,
                        fontSize: 12,
                      ),
                    ),
                    trailing: option.isCustom
                        ? IconButton(
                            key: Key('delete_custom_sound_${option.id}'),
                            tooltip: 'Remove custom sound',
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              color: WatSafeTheme.alarmCrimson,
                              size: 20,
                            ),
                            onPressed: () =>
                                controller.removeCustomAlarmSound(option.id),
                          )
                        : null,
                  ),
                ),
              );
            }),
            const Divider(),
            Text(
              'Custom sound',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('custom_sound_name_input'),
              controller: _customSoundNameController,
              decoration: const InputDecoration(
                labelText: 'Custom Alarm Name',
                hintText: 'e.g. Lab Bench Klaxon',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Import .WAV audio',
              style: TextStyle(
                color: WatSafeTheme.warmOffWhite,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final wavInput = TextField(
                  key: const Key('custom_wav_path_input'),
                  controller: _customSoundFilePathController,
                  decoration: const InputDecoration(
                    labelText: 'Custom .wav file path',
                    hintText: r'C:\Sounds\my_alarm.wav',
                  ),
                );
                final browseBtn = OutlinedButton.icon(
                  key: const Key('browse_custom_wav_button'),
                  onPressed: _handleBrowseCustomWav,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('Browse'),
                );
                final importBtn = FilledButton.icon(
                  key: const Key('import_custom_wav_button'),
                  onPressed: _handleImportCustomWav,
                  icon: const Icon(Icons.file_upload_outlined, size: 18),
                  label: const Text('Add WAV'),
                );
                if (constraints.maxWidth < 460) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      wavInput,
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[browseBtn, importBtn],
                      ),
                    ],
                  );
                }
                return Row(
                  children: <Widget>[
                    Expanded(child: wavInput),
                    const SizedBox(width: 8),
                    browseBtn,
                    const SizedBox(width: 8),
                    importBtn,
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Text(
              'Synthesize tone',
              style: TextStyle(
                color: WatSafeTheme.warmOffWhite,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<CustomAlarmWavePattern>(
              key: const Key('custom_pattern_dropdown'),
              isExpanded: true,
              initialValue: _customWavePattern,
              decoration: const InputDecoration(labelText: 'Waveform Pattern'),
              items: CustomAlarmWavePattern.values
                  .map(
                    (pattern) => DropdownMenuItem<CustomAlarmWavePattern>(
                      value: pattern,
                      child: Text(
                        pattern.displayName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _customWavePattern = value;
                  });
                }
              },
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Expanded(child: Text('Primary frequency')),
                const SizedBox(width: 8),
                Text(
                  '${_customPrimaryFreqHz.round()} Hz',
                  style: TextStyle(
                    color: WatSafeTheme.amberAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              key: const Key('custom_primary_freq_slider'),
              value: _customPrimaryFreqHz,
              min: 200.0,
              max: 3200.0,
              divisions: 60,
              activeColor: WatSafeTheme.amberAccent,
              onChanged: (value) {
                setState(() {
                  _customPrimaryFreqHz = value;
                });
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Expanded(child: Text('Secondary frequency')),
                const SizedBox(width: 8),
                Text(
                  '${_customSecondaryFreqHz.round()} Hz',
                  style: TextStyle(
                    color: WatSafeTheme.amberAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              key: const Key('custom_secondary_freq_slider'),
              value: _customSecondaryFreqHz,
              min: 200.0,
              max: 3200.0,
              divisions: 60,
              activeColor: WatSafeTheme.amberAccent,
              onChanged: (value) {
                setState(() {
                  _customSecondaryFreqHz = value;
                });
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Expanded(child: Text('Pulse speed')),
                const SizedBox(width: 8),
                Text(
                  '${_customModulationRateHz.toStringAsFixed(1)} Hz',
                  style: TextStyle(
                    color: WatSafeTheme.amberAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              key: const Key('custom_mod_rate_slider'),
              value: _customModulationRateHz,
              min: 1.0,
              max: 12.0,
              divisions: 22,
              activeColor: WatSafeTheme.amberAccent,
              onChanged: (value) {
                setState(() {
                  _customModulationRateHz = value;
                });
              },
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('add_custom_synth_sound_button'),
                onPressed: _handleAddSynthesizedCustomSound,
                icon: const Icon(Icons.add_alert_rounded, size: 18),
                label: const Text('Add Custom Synthesized Alarm'),
              ),
            ),
            if (_customSoundFeedback != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                _customSoundFeedback!,
                key: const Key('custom_sound_feedback_text'),
                style: TextStyle(
                  color: _customSoundSuccess
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

  Widget _buildPermanentCompanionCard(
    BuildContext context,
    AlarmController controller,
  ) {
    final currentUrl = controller.relayEndpointUrl ?? '';
    final isPermanent = controller.isPermanentRelayConfigured;
    final isEphemeral = controller.isEphemeralTunnelRelay;

    return Card(
      key: const Key('permanent_companion_settings_card'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Companion address',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (isPermanent
                                ? WatSafeTheme.readyEmerald
                                : WatSafeTheme.amberAccent)
                            .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color:
                          (isPermanent
                                  ? WatSafeTheme.readyEmerald
                                  : WatSafeTheme.amberAccent)
                              .withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    isPermanent ? 'Permanent HTTPS' : 'Temporary / Local',
                    style: TextStyle(
                      color: isPermanent
                          ? WatSafeTheme.readyEmerald
                          : WatSafeTheme.amberAccent,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isPermanent
                  ? 'Active URL: $currentUrl/companion'
                  : (isEphemeral
                        ? 'Using temporary tunnel ($currentUrl). Save a permanent https:// address so your phone pairing survives restarts.'
                        : 'Save a permanent https:// relay address so your phone pairing survives restarts.'),
              style: TextStyle(
                color: WatSafeTheme.warmMuted,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('permanent_relay_url_input'),
                    controller: _permanentRelayUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Permanent HTTPS companion URL',
                      hintText: 'https://<your-render-service>.onrender.com',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  key: const Key('save_permanent_relay_url_button'),
                  onPressed: () async {
                    final ok = await controller.savePermanentRelayEndpoint(
                      _permanentRelayUrlController.text,
                    );
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _permanentUrlIsError = !ok;
                      if (ok) {
                        _relayUrlController.text =
                            controller.relayEndpointUrl ?? '';
                        _permanentUrlNote =
                            _permanentRelayUrlController.text.trim().isEmpty
                            ? 'Cleared permanent URL override.'
                            : 'Permanent HTTPS address saved for all future launches.';
                      } else {
                        _permanentUrlNote =
                            controller.warningMessage ??
                            'Enter a valid permanent https:// domain.';
                      }
                    });
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
            if (_permanentUrlNote != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _permanentUrlNote!,
                style: TextStyle(
                  color: _permanentUrlIsError
                      ? WatSafeTheme.alarmCrimson
                      : WatSafeTheme.readyEmerald,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const Key('iphone_migration_steps_tile'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
                title: const Text(
                  'Migrating from an old Home Screen icon',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
                children: <Widget>[
                  Text(
                    '1. On your iPhone Home Screen, touch and hold an expired tunnel icon and tap Delete Bookmark.\n'
                    '2. Save your permanent https:// URL above, then scan the QR code from Pair your phone once.\n'
                    '3. Add to Home Screen and enable notifications. Future updates migrate automatically.',
                    style: TextStyle(
                      color: WatSafeTheme.warmMuted,
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChangePinCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Change PIN',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Required to disarm protection or silence an alarm.',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('settings_current_pin_input'),
              controller: _currentPinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              decoration: const InputDecoration(labelText: 'Current PIN'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('settings_new_pin_input'),
              controller: _newPinController,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              decoration: const InputDecoration(
                labelText: 'New PIN (6 or more digits)',
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
              ],
              decoration: const InputDecoration(labelText: 'Confirm new PIN'),
            ),
            if (_pinMessage != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _pinMessage!,
                style: TextStyle(
                  color: _pinSuccess
                      ? WatSafeTheme.readyEmerald
                      : WatSafeTheme.alarmCrimson,
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                key: const Key('update_pin_button'),
                onPressed: _isUpdatingPin ? null : _handleChangePin,
                child: Text(_isUpdatingPin ? 'Updating…' : 'Update PIN'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdvancedCategoryCards(
    BuildContext context,
    AlarmController controller,
    bool isLockedByProtection,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Sensitivity threshold',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${_sensitivityLabel(controller.settings.motionSensitivity)} (${(controller.settings.motionSensitivity * 100).round()}%)',
                  style: TextStyle(
                    color: WatSafeTheme.amberAccent,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
            Slider(
              key: const Key('advanced_sensitivity_slider'),
              value: controller.settings.motionSensitivity.clamp(0.1, 0.9),
              min: 0.1,
              max: 0.9,
              divisions: 16,
              activeColor: WatSafeTheme.amberAccent,
              onChanged: isLockedByProtection
                  ? null
                  : (value) =>
                        controller.updateSettings(motionSensitivity: value),
            ),
            const SizedBox(height: 10),
            _CameraDiagnosticsPanel(controller: controller),
            const SizedBox(height: 16),
            if (controller.canManagePairing) ...<Widget>[
              TextField(
                key: const Key('relay_url_input'),
                controller: _relayUrlController,
                decoration: const InputDecoration(
                  labelText: 'Custom alert service address',
                  hintText: 'Configured automatically at build time',
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  key: const Key('save_relay_url_button'),
                  onPressed: () async {
                    await controller.configureRelayEndpoint(
                      _relayUrlController.text,
                    );
                    if (mounted) {
                      setState(() {
                        _advancedNote = 'Alert service address updated.';
                      });
                    }
                  },
                  child: const Text('Save service address'),
                ),
              ),
              if (_advancedNote != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _advancedNote!,
                  style: TextStyle(
                    color: WatSafeTheme.readyEmerald,
                    fontSize: 12.5,
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('clear_activity_history_button'),
                onPressed:
                    (controller.incidents.isEmpty || isLockedByProtection)
                    ? null
                    : controller.clearIncidentHistory,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Clear activity history'),
              ),
            ),
            if (controller.enableDeveloperControls) ...<Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Divider(height: 1),
              ),
              Container(
                key: const Key('developer_demo_testing_section'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: WatSafeTheme.charcoalElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: WatSafeTheme.charcoalBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          Icons.science_outlined,
                          size: 18,
                          color: WatSafeTheme.amberAccent,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'First-use & demo testing',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        OutlinedButton.icon(
                          key: const Key('preview_onboarding_button'),
                          onPressed: controller.startOnboardingPreview,
                          icon: const Icon(Icons.visibility_outlined, size: 18),
                          label: const Text('Preview onboarding'),
                        ),
                        OutlinedButton.icon(
                          key: const Key('reset_demo_button'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: WatSafeTheme.alarmCrimson,
                            side: BorderSide(
                              color: WatSafeTheme.alarmCrimson.withValues(
                                alpha: 0.55,
                              ),
                            ),
                          ),
                          onPressed: () =>
                              _confirmResetDemo(context, controller),
                          icon: const Icon(Icons.restart_alt_rounded, size: 18),
                          label: const Text(
                            'Reset demo and restart onboarding',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmResetDemo(
    BuildContext context,
    AlarmController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final palette = WatSafeTheme.of(dialogContext);
        return AlertDialog(
          key: const Key('reset_demo_confirm_dialog'),
          title: const Text('Reset demo and restart onboarding?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'This development reset affects only this WATSafe installation and its paired session:',
                  style: TextStyle(fontSize: 13.5, height: 1.4),
                ),
                const SizedBox(height: 12),
                Text(
                  '• Stops monitoring and silences any active siren immediately\n'
                  '• Revokes this device’s phone pairing and Web Push registration on the relay\n'
                  '• Clears this installation’s saved security PIN\n'
                  '• Resets device name, motion & siren settings, Activity history, and onboarding state\n'
                  '• Leaves macOS, iOS, Android, and browser permissions unchanged',
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              key: const Key('cancel_reset_demo_button'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm_reset_demo_button'),
              style: FilledButton.styleFrom(
                backgroundColor: palette.alarmColor,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Reset demo'),
            ),
          ],
        );
      },
    );

    if (confirmed == true && mounted) {
      await controller.resetDemoAndRestartOnboarding();
    }
  }

  String _sensitivityLabel(double value) {
    if (value < 0.35) {
      return 'Low';
    }
    if (value < 0.72) {
      return 'Balanced';
    }
    return 'High';
  }

  String _locationPermissionSummary({
    required bool isSupported,
    required PermissionStatus status,
    required bool enabled,
  }) {
    if (!enabled) {
      return 'Off';
    }
    if (!isSupported) {
      return 'Not supported on this device';
    }
    switch (status) {
      case PermissionStatus.granted:
        return 'Updates every 4 min while open and every 15s during alarms';
      case PermissionStatus.denied:
      case PermissionStatus.restricted:
        return 'Blocked in system settings — allow Location for WATSafe';
      case PermissionStatus.notDetermined:
      case PermissionStatus.notApplicable:
        return 'Enable location access to appear on the Devices map';
    }
  }

  String _notificationPermissionSummary({
    required bool isSupported,
    required PermissionStatus status,
    required bool pushConfigured,
  }) {
    if (!isSupported) {
      return 'Alerts appear while WATSafe is open';
    }
    switch (status) {
      case PermissionStatus.granted:
        return pushConfigured
            ? 'Enabled — lock-screen and background alerts active'
            : 'Enabled';
      case PermissionStatus.denied:
      case PermissionStatus.restricted:
        return 'Blocked in system settings';
      case PermissionStatus.notDetermined:
      case PermissionStatus.notApplicable:
        return 'Off';
    }
  }
}

class _SettingsCategoryRow extends StatelessWidget {
  const _SettingsCategoryRow({
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Key tileKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    return InkWell(
      key: tileKey,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: palette.accentPrimary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: palette.accentPrimary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: palette.textMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: palette.textMuted),
          ],
        ),
      ),
    );
  }
}

class _CameraDiagnosticsPanel extends StatelessWidget {
  const _CameraDiagnosticsPanel({required this.controller});

  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final ev = controller.lastTelemetryEvent;
    return Container(
      key: const Key('developer_camera_diagnostics_card'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Live motion diagnostics (numerical only)',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          if (ev == null)
            Text(
              'Idle — start a Guided protection test or arm protection to inspect live scores.',
              style: TextStyle(fontSize: 12, color: palette.textMuted),
            )
          else
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: <Widget>[
                _diagMetric(
                  palette,
                  'Score / Threshold',
                  '${(ev.motionScore ?? 0).toStringAsFixed(3)} / ${(ev.threshold ?? 0).toStringAsFixed(3)}',
                ),
                if (ev.coherentBlocks != null)
                  _diagMetric(palette, 'Rigid blocks', '${ev.coherentBlocks}'),
                if (ev.anchoredBlocks != null)
                  _diagMetric(
                    palette,
                    'Static anchors',
                    '${ev.anchoredBlocks}',
                  ),
                if (ev.slowDriftScore != null)
                  _diagMetric(
                    palette,
                    'Slow drift',
                    ev.slowDriftScore!.toStringAsFixed(3),
                  ),
                if (ev.loomingRejected != null)
                  _diagMetric(
                    palette,
                    'Looming filter',
                    ev.loomingRejected! ? 'Suppressed' : 'Clear',
                  ),
                if (ev.acPowerUnplugged == true)
                  _diagMetric(palette, 'AC power', 'Unplugged'),
                if (ev.averageLuminance != null)
                  _diagMetric(
                    palette,
                    'Luminance',
                    '${(ev.averageLuminance! * 100).round()}%',
                  ),
                if (ev.obstructionKind != null)
                  _diagMetric(palette, 'Obstruction', ev.obstructionKind!),
              ],
            ),
        ],
      ),
    );
  }

  Widget _diagMetric(WatSafePalette palette, String label, String value) {
    return Text(
      '$label: $value',
      style: TextStyle(
        fontSize: 12,
        color: palette.textMuted,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }
}
