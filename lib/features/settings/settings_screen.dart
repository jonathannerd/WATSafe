import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/alarm/alarm_state.dart';
import '../../core/models/detector_models.dart';
import '../../core/models/settings_models.dart';
import '../testing/guided_protection_test_sheet.dart';
import '../theme/watsafe_theme.dart';

/// Clean user-facing Settings screen for:
/// - Device name (used during phone pairing & alerts)
/// - Motion detection method (where multiple are supported), sensitivity, arming delay, & siren volume
/// - Notification and location permissions & location-on-alarm sharing
/// - Changing the security PIN
/// - Collapsed Advanced disclosure for technical service overrides & history clearing
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final AlarmController controller;

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

  String? _pinMessage;
  bool _pinSuccess = false;
  bool _isUpdatingPin = false;
  String? _deviceNameSavedNote;
  String? _permanentUrlNote;
  bool _permanentUrlIsError = false;
  String? _advancedNote;
  String? _locationHistoryNote;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final settings = controller.settings;
    final isLockedByProtection =
        controller.state == ProtectionState.arming ||
        controller.state == ProtectionState.armed ||
        controller.state == ProtectionState.alarming ||
        controller.state == ProtectionState.paused;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Settings',
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                'Manage how WATSafe protects this device, shares location, and verifies your PIN.',
                style: TextStyle(color: WatSafeTheme.warmMuted),
              ),
              const SizedBox(height: 20),

              // 1. Device Identity
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        'This device',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Shown when pairing your phone and in alarm notifications.',
                        style: TextStyle(
                          color: WatSafeTheme.warmMuted,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              key: const Key('settings_device_name_input'),
                              controller: _deviceNameController,
                              decoration: const InputDecoration(
                                labelText: 'Device name',
                                hintText: 'Jonathan’s MacBook',
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
                          style: const TextStyle(
                            color: WatSafeTheme.readyEmerald,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 2. Motion Detection & Siren
              _buildMotionAndSirenCard(
                context,
                controller,
                settings.motionSensitivity,
                settings.armingCountdownSeconds,
                settings.alarmVolume,
                isLockedByProtection,
              ),
              const SizedBox(height: 16),

              // 3. Notifications & Location Permissions
              _buildPermissionsCard(context, controller),
              const SizedBox(height: 16),

              // 4. Permanent Phone Companion Address & One-Time Migration
              if (controller.canManagePairing) ...<Widget>[
                _buildPermanentCompanionCard(context, controller),
                const SizedBox(height: 16),
              ],

              // 5. Change PIN
              _buildChangePinCard(context),
              const SizedBox(height: 16),

              // 6. Collapsed Advanced Section (relay override & clear history out of normal flow)
              _buildAdvancedSection(context, controller, isLockedByProtection),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMotionAndSirenCard(
    BuildContext context,
    AlarmController controller,
    double sensitivity,
    int countdownSeconds,
    double alarmVolume,
    bool isLockedByProtection,
  ) {
    final hostOptions = controller.availableHostDetectors;
    // Deduplicate options that share the same plain-language method label if needed,
    // while keeping every distinct selectable method on this host.
    final showMethodPicker = hostOptions.length > 1;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Motion detection & siren',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            if (showMethodPicker) ...<Widget>[
              const Text(
                'Detection method',
                style: TextStyle(fontWeight: FontWeight.w600),
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
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: WatSafeTheme.warmMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (selected)
                            const Icon(
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
              style: TextStyle(fontWeight: FontWeight.w600),
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
                      vertical: 12,
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
                            size: 20,
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
                                  fontSize: 14.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                preset.description,
                                style: const TextStyle(
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
            if (controller.selectedDetectorType.usesCamera) ...<Widget>[
              const SizedBox(height: 4),
              const Text(
                'Camera protection infers device movement from shifts across the background scene rather than built-in motion sensors. Keep the camera uncovered in a lit room so passersby can be separated from someone lifting your device.',
                style: TextStyle(
                  fontSize: 12,
                  color: WatSafeTheme.warmSubtle,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 14),
            const Text(
              'Arming delay',
              style: TextStyle(fontWeight: FontWeight.w600),
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
                  selectedColor: WatSafeTheme.amberAccent,
                  labelStyle: TextStyle(
                    color: selected
                        ? WatSafeTheme.charcoalDeep
                        : WatSafeTheme.warmOffWhite,
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
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Siren volume',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(alarmVolume * 100).round()}%',
                  style: const TextStyle(
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
            if (!controller.isCompanionMode &&
                controller.isInputInteractionDetectionSupported) ...<Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Divider(height: 1),
              ),
              SwitchListTile(
                key: const Key('alert_on_input_interaction_switch'),
                contentPadding: EdgeInsets.zero,
                activeThumbColor: WatSafeTheme.amberAccent,
                title: const Text(
                  'Alert on keyboard or trackpad interaction while armed',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Optional: starts an 8-second PIN grace window when keys or the trackpad are used, then triggers an alarm if not disarmed. Standard laptop hardware cannot detect touching the outer case without movement or key/trackpad input.',
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
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                controller.isTestAlarmRunning
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
                OutlinedButton.icon(
                  key: const Key('settings_guided_test_button'),
                  onPressed: isLockedByProtection
                      ? null
                      : () =>
                            showGuidedProtectionTestSheet(context, controller),
                  icon: const Icon(Icons.verified_user_outlined, size: 18),
                  label: const Text('Guided protection test'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionsCard(
    BuildContext context,
    AlarmController controller,
  ) {
    final locPerm = controller.locationPermissionStatus;
    final notifPerm = controller.localNotificationPermissionStatus;
    final shareLocation = controller.settings.shareLocationOnAlarm;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Permissions & location sharing',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),

            if (controller.isCompanionMode) ...<Widget>[
              SwitchListTile(
                key: const Key('share_companion_phone_location_switch'),
                contentPadding: EdgeInsets.zero,
                activeThumbColor: WatSafeTheme.amberAccent,
                title: const Text(
                  'Share this phone’s location',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Off by default. Shares this phone’s location on the Devices map only while WATSafe is open in the foreground, and pauses in the background while keeping last-known coordinates labeled with their timestamp.',
                  style: TextStyle(
                    color: WatSafeTheme.warmMuted,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                value: controller.settings.shareCompanionPhoneLocation,
                onChanged: controller.updateShareCompanionPhoneLocation,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(height: 1),
              ),
            ],

            // Location sharing toggle + permission status
            SwitchListTile(
              key: const Key('share_location_switch'),
              contentPadding: EdgeInsets.zero,
              activeThumbColor: WatSafeTheme.amberAccent,
              title: const Text(
                'Share device location when an alarm triggers',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                _locationPermissionSummary(
                  isSupported: controller.isLocationSupported,
                  status: locPerm,
                  enabled: shareLocation,
                ),
                style: const TextStyle(
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
                        ? 'Check location access again'
                        : 'Allow location access',
                  ),
                ),
              ),
            ],
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1),
            ),

            // Notifications permission status
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'Alert notifications',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _notificationPermissionSummary(
                          isSupported: controller.isLocalNotificationsSupported,
                          status: notifPerm,
                          pushConfigured:
                              controller.companionSession.pushServerConfigured,
                        ),
                        style: const TextStyle(
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
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1),
            ),
            const Text(
              'Location privacy & 7-day retention',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              'Protected-device location is shared only with your paired session while armed and for up to 15 minutes after an alarm, stopping immediately on PIN disarm. Companion phone location is off by default and updates only in the foreground when explicitly enabled. Laptop Wi-Fi positioning may be approximate, and sleeping or offline devices cannot report new updates. Stored location history is automatically deleted after 7 days.',
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
                label: const Text('Delete stored location history'),
              ),
            ),
            if (_locationHistoryNote != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _locationHistoryNote!,
                key: const Key('location_history_deleted_note'),
                style: const TextStyle(
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
                    'Phone companion address & migration',
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
                  ? 'Active companion URL: $currentUrl/companion. Both WATSafe on this laptop and your installed iPhone Home Screen app reconnect automatically on startup.'
                  : (isEphemeral
                        ? 'Currently using a temporary tunnel ($currentUrl). Temporary tunnels generate a new domain after restarts, causing old Home Screen bookmarks to open white tunnel error pages. Deploy the permanent relay with Aiven PostgreSQL (render.yaml + AIVEN_DATABASE_URL secret, or a Named Cloudflare Tunnel) and save its https:// address below.'
                        : 'Deploy the permanent HTTPS relay with Aiven PostgreSQL (render.yaml + AIVEN_DATABASE_URL secret, or a Named Cloudflare Tunnel) and save its https:// address below so your iPhone Home Screen icon and pairing survive every restart.'),
              style: const TextStyle(
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
            const SizedBox(height: 12),
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const Key('iphone_migration_steps_tile'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
                title: const Text(
                  'Migrating from an old Home Screen icon (one-time steps)',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
                children: const <Widget>[
                  Text(
                    'Why one final install is required: iOS isolates Home Screen web apps, Service Workers, saved credentials, and Web Push subscriptions strictly by domain. Moving off an expired *.trycloudflare.com domain to your permanent https:// address requires replacing the bookmark once:\n\n'
                    '1. On your iPhone Home Screen, touch and hold the old WATSafe icon and tap Delete Bookmark.\n'
                    '2. Save your permanent https:// URL above, then open Pair your phone on Home and scan the QR code once in Safari.\n'
                    '3. Follow the guided Add to Home Screen + Enable notifications steps one final time. After that, closing/reopening WATSafe or restarting either device reconnects automatically.',
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
            const SizedBox(height: 6),
            const Text(
              'Your PIN is required to disarm protection or silence a triggered alarm.',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 13.5),
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

  Widget _buildAdvancedSection(
    BuildContext context,
    AlarmController controller,
    bool isLockedByProtection,
  ) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('advanced_settings_tile'),
          title: const Text(
            'Advanced',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            controller.enableDeveloperControls
                ? 'First-use demo reset, activity cleanup, and custom alert server settings'
                : 'Activity history cleanup and custom alert server settings',
            style: const TextStyle(
              color: WatSafeTheme.warmMuted,
              fontSize: 12.5,
            ),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Fine-tune sensitivity threshold',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${_sensitivityLabel(controller.settings.motionSensitivity)} (${(controller.settings.motionSensitivity * 100).round()}%)',
                  style: const TextStyle(
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
                  style: const TextStyle(
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
                    const Row(
                      children: <Widget>[
                        Icon(
                          Icons.science_outlined,
                          size: 18,
                          color: WatSafeTheme.amberAccent,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'First-use & demo testing (Development only)',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Relaunching or hot restarting WATSafe keeps your saved PIN, paired phone, settings, and Activity history. Use Preview onboarding to inspect the welcome flow safely, or Reset demo to test a clean first launch. OS and browser permissions stay managed by system settings.',
                      style: TextStyle(
                        color: WatSafeTheme.warmMuted,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
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
      builder: (dialogContext) => AlertDialog(
        key: const Key('reset_demo_confirm_dialog'),
        title: const Text('Reset demo and restart onboarding?'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'This development reset affects only this WATSafe installation and its paired session:',
                style: TextStyle(fontSize: 13.5, height: 1.4),
              ),
              SizedBox(height: 12),
              Text(
                '• Stops monitoring and silences any active siren immediately\n'
                '• Revokes this device’s phone pairing and Web Push registration on the relay\n'
                '• Clears this installation’s saved security PIN\n'
                '• Resets device name, motion & siren settings, Activity history, and onboarding state\n'
                '• Leaves macOS, iOS, Android, and browser permissions unchanged (reset Camera, Location, or Notifications in system settings if testing OS permission prompts)',
                style: TextStyle(
                  color: WatSafeTheme.warmMuted,
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
              backgroundColor: WatSafeTheme.alarmCrimson,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset demo'),
          ),
        ],
      ),
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
      return 'Location will not be included when an alarm triggers.';
    }
    if (!isSupported) {
      return 'Location lookup is not available on this device.';
    }
    switch (status) {
      case PermissionStatus.granted:
        return 'Allowed — shared only with your paired phone when an alarm triggers.';
      case PermissionStatus.denied:
      case PermissionStatus.restricted:
        return 'Location access is blocked in your system or browser settings. Enable Location for WATSafe in system settings to share location on alarm.';
      case PermissionStatus.notDetermined:
      case PermissionStatus.notApplicable:
        return 'Allow location access so your paired phone can see where this device is if an alarm triggers.';
    }
  }

  String _notificationPermissionSummary({
    required bool isSupported,
    required PermissionStatus status,
    required bool pushConfigured,
  }) {
    if (!isSupported) {
      return 'Alerts appear inside WATSafe while the app is open.';
    }
    switch (status) {
      case PermissionStatus.granted:
        return pushConfigured
            ? 'Enabled — lock-screen and background alerts are active.'
            : 'Enabled — system notifications appear when WATSafe receives an alert.';
      case PermissionStatus.denied:
      case PermissionStatus.restricted:
        return 'Blocked in system or browser settings. Open system Settings > Notifications to turn alerts back on. Foreground alerts still appear while WATSafe is open.';
      case PermissionStatus.notDetermined:
      case PermissionStatus.notApplicable:
        return 'Off — allow notifications to receive system alerts when a paired device triggers an alarm.';
    }
  }
}

class _CameraDiagnosticsPanel extends StatelessWidget {
  const _CameraDiagnosticsPanel({required this.controller});

  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    final ev = controller.lastTelemetryEvent;
    return Container(
      key: const Key('developer_camera_diagnostics_card'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: WatSafeTheme.charcoalElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: WatSafeTheme.charcoalBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Live motion diagnostics (numerical only — camera frames are never saved)',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          if (ev == null)
            const Text(
              'Idle — start a Guided protection test or arm protection to inspect live ego-motion scores.',
              style: TextStyle(fontSize: 12, color: WatSafeTheme.warmMuted),
            )
          else
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: <Widget>[
                _diagMetric(
                  'Score / Threshold',
                  '${(ev.motionScore ?? 0).toStringAsFixed(3)} / ${(ev.threshold ?? 0).toStringAsFixed(3)}',
                ),
                if (ev.coherentBlocks != null)
                  _diagMetric('Rigid blocks', '${ev.coherentBlocks}'),
                if (ev.anchoredBlocks != null)
                  _diagMetric('Static anchors', '${ev.anchoredBlocks}'),
                if (ev.slowDriftScore != null)
                  _diagMetric(
                    'Slow drift',
                    ev.slowDriftScore!.toStringAsFixed(3),
                  ),
                if (ev.loomingRejected != null)
                  _diagMetric(
                    'Looming filter',
                    ev.loomingRejected! ? 'Suppressed' : 'Clear',
                  ),
                if (ev.acPowerUnplugged == true)
                  _diagMetric('AC power', 'Unplugged'),
                if (ev.averageLuminance != null)
                  _diagMetric(
                    'Luminance',
                    '${(ev.averageLuminance! * 100).round()}%',
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _diagMetric(String label, String value) {
    return Text(
      '$label: $value',
      style: const TextStyle(
        fontSize: 12,
        color: WatSafeTheme.warmMuted,
        fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }
}
