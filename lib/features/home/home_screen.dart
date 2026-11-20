import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/alarm/alarm_state.dart';
import '../../core/models/detector_models.dart';
import '../pairing/phone_pairing_sheet.dart';
import '../testing/guided_protection_test_sheet.dart';
import '../theme/watsafe_theme.dart';

/// Primary Home screen focused on two things:
/// 1. Clear protection status + one obvious primary action for the current state
/// 2. One simple Phone connection row ("Pair your phone" before pairing; phone
///    name, connection status, and notification status after pairing, with
///    "Send test alert" and "Disconnect phone" inside its details).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});

  final AlarmController controller;

  String? _resolveActionableWarning() {
    final explicit = controller.warningMessage?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    if (!controller.isCompanionMode &&
        controller.state == ProtectionState.armed &&
        controller.pairedDevices.isNotEmpty) {
      final phone = controller.pairedDevices.first;
      if (!phone.connected) {
        return 'Phone connection interrupted — local siren remains active.';
      }
      if (!phone.notificationsEnabled) {
        return 'Phone notifications are off — open WATSafe on your phone to enable alerts.';
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final state = controller.state;
    final stateColor = WatSafeTheme.colorForProtectionState(state, palette);
    final capability = controller.selectedCapability;
    final actionableWarning = _resolveActionableWarning();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (actionableWarning != null) ...<Widget>[
                _WarningCard(message: actionableWarning),
                const SizedBox(height: 14),
              ],
              if (state == ProtectionState.unavailable) ...<Widget>[
                _SetupReadinessCard(controller: controller),
                const SizedBox(height: 12),
              ],
              _ProtectionHeroCard(
                controller: controller,
                state: state,
                stateColor: stateColor,
                capability: capability,
                onPromptDisarmPin: () => _showDisarmPinDialog(context),
              ),
              const SizedBox(height: 12),
              _PhoneConnectionRow(controller: controller),
              if (controller.selectedDetectorType ==
                  DetectorType.browserCameraSceneMotion) ...<Widget>[
                const SizedBox(height: 10),
                const _BrowserMonitoringLimitsCard(),
              ],
              if (!controller.isCompanionMode) ...<Widget>[
                const SizedBox(height: 10),
                _ProtectionDetailsCard(controller: controller),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDisarmPinDialog(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: WatSafeTheme.of(context).surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: _DisarmPinSheet(controller: controller),
        );
      },
    );
  }
}


class _SetupReadinessCard extends StatelessWidget {
  const _SetupReadinessCard({required this.controller});

  final AlarmController controller;

  Future<void> _enableLocationSharing() async {
    if (controller.isCompanionMode) {
      await controller.updateShareCompanionPhoneLocation(true);
      return;
    }

    if (!controller.settings.shareLocationOnAlarm) {
      await controller.updateSettings(shareLocationOnAlarm: true);
    }
    if (controller.locationPermissionStatus != PermissionStatus.granted) {
      await controller.requestLocationPermission();
    }
    if (controller.locationPermissionStatus == PermissionStatus.granted) {
      await controller.refreshProtectedDeviceLocation(highAccuracy: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final capability = controller.selectedCapability;
    final detectorReady = capability?.canArm ?? false;
    final locationSharingEnabled = controller.isCompanionMode
        ? controller.settings.shareCompanionPhoneLocation
        : controller.settings.shareLocationOnAlarm;
    final locationGranted =
        controller.locationPermissionStatus == PermissionStatus.granted;
    final phoneConnected =
        controller.companionSession.isConnected ||
        controller.pairedDevices.any((device) => device.connected);

    final cameraStatus = detectorReady
        ? 'Ready'
        : capability?.status == CapabilityStatus.permissionRequired
        ? 'Permission needed'
        : 'Needs attention';
    final locationStatus = !controller.isLocationSupported
        ? 'Not available'
        : (locationSharingEnabled && locationGranted)
        ? 'Enabled'
        : (locationSharingEnabled ? 'Optional' : 'Off');
    final phoneStatus = phoneConnected ? 'Connected' : 'Optional';

    final locationNeedsAction =
        controller.isLocationSupported &&
        !locationGranted &&
        locationSharingEnabled &&
        controller.locationPermissionStatus != PermissionStatus.denied &&
        controller.locationPermissionStatus != PermissionStatus.restricted;
    final sharingCanBeEnabled =
        controller.isLocationSupported && !locationSharingEnabled;

    return Card(
      key: const Key('home_setup_readiness_card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.checklist_rounded, color: palette.accentPrimary),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Setup checklist',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                ),
                Text(
                  'Before arming',
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SetupReadinessLine(
              icon: controller.selectedDetectorType.usesCamera
                  ? Icons.videocam_outlined
                  : Icons.sensors_rounded,
              title: controller.selectedDetectorType.usesCamera
                  ? 'Camera access · Required'
                  : 'Motion sensor · Required',
              detail: capability?.summary ?? 'Checking detector readiness…',
              status: cameraStatus,
              isReady: detectorReady,
            ),
            if (controller.isLocationSupported) ...<Widget>[
              const SizedBox(height: 10),
              _SetupReadinessLine(
                icon: Icons.location_on_outlined,
                title: 'Location sharing · Optional',
                detail: !locationSharingEnabled
                    ? 'Off until you choose to share this device’s location.'
                    : locationGranted
                    ? 'Location permission is enabled for incident reporting.'
                    : controller.locationPermissionStatus ==
                              PermissionStatus.denied ||
                          controller.locationPermissionStatus ==
                              PermissionStatus.restricted
                    ? 'Blocked in browser or system settings.'
                    : 'Can attach this device’s position to an incident alert.',
                status: locationStatus,
                isReady: locationSharingEnabled && locationGranted,
                isOptional: true,
              ),
              if (locationNeedsAction || sharingCanBeEnabled) ...<Widget>[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('home_enable_location_button'),
                    onPressed: _enableLocationSharing,
                    icon: const Icon(Icons.location_searching_rounded, size: 17),
                    label: Text(
                      sharingCanBeEnabled
                          ? 'Enable location sharing'
                          : 'Allow location',
                    ),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 10),
            _SetupReadinessLine(
              icon: Icons.smartphone_rounded,
              title: 'Phone pairing · Optional',
              detail: phoneConnected
                  ? 'A companion phone is connected.'
                  : 'Pair a phone to receive remote incident alerts.',
              status: phoneStatus,
              isReady: phoneConnected,
              isOptional: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupReadinessLine extends StatelessWidget {
  const _SetupReadinessLine({
    required this.icon,
    required this.title,
    required this.detail,
    required this.status,
    required this.isReady,
    this.isOptional = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String status;
  final bool isReady;
  final bool isOptional;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final tone = isReady
        ? palette.readyColor
        : isOptional
        ? palette.textMuted
        : palette.warningColor;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 18, color: tone),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    status,
                    style: TextStyle(
                      color: tone,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 11.5,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BrowserMonitoringLimitsCard extends StatelessWidget {
  const _BrowserMonitoringLimitsCard();

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    return Card(
      key: const Key('browser_monitoring_limitations'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.visibility_outlined, color: palette.warningColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Browser monitoring limits',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Camera monitoring pauses when this tab is hidden or the browser suspends it. Keep Safari open, this tab visible, and the device awake. Check that WATSafe says “Protected” before leaving it unattended.',
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 12.5,
                      height: 1.4,
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
}

class _ProtectionHeroCard extends StatelessWidget {
  const _ProtectionHeroCard({
    required this.controller,
    required this.state,
    required this.stateColor,
    required this.capability,
    required this.onPromptDisarmPin,
  });

  final AlarmController controller;
  final ProtectionState state;
  final Color stateColor;
  final DetectorCapability? capability;
  final VoidCallback onPromptDisarmPin;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final isActive =
        state == ProtectionState.armed ||
        state == ProtectionState.arming ||
        state == ProtectionState.alarming;
    final subtitle = _subtitleForState(state, capability);
    final shieldAccent = state == ProtectionState.disarmed
        ? palette.accentPrimary
        : stateColor;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: WatSafeShieldGraphic(
                accentColor: shieldAccent,
                size: 68,
                isActiveWave: isActive,
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: Container(
                key: const Key('dashboard_state_badge'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: stateColor.withValues(alpha: 0.55)),
                ),
                child: Text(
                  state.badgeLabel,
                  style: TextStyle(
                    color: state == ProtectionState.disarmed
                        ? palette.textPrimary
                        : stateColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _headlineForState(state),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: palette.textPrimary,
              ),
            ),
            if (subtitle != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 13.5,
                  height: 1.4,
                ),
              ),
            ],
            if (state == ProtectionState.armed &&
                controller.isConfirmingMovement) ...<Widget>[
              const SizedBox(height: 14),
              Container(
                key: const Key('movement_confirmation_banner'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: palette.warningColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: palette.warningColor.withValues(alpha: 0.65),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: palette.warningColor,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        'Movement detected — checking…',
                        style: TextStyle(
                          color: palette.warningColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (state == ProtectionState.armed &&
                controller.isInputInteractionGraceActive) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                key: const Key('input_interaction_grace_banner'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: palette.warningColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: palette.warningColor.withValues(alpha: 0.65),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      Icons.keyboard_alt_outlined,
                      size: 16,
                      color: palette.warningColor,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Keyboard or trackpad input detected — enter your PIN within 8s to disarm.',
                        style: TextStyle(
                          color: palette.warningColor,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (state == ProtectionState.arming) ...<Widget>[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  minHeight: 8,
                  value: controller.isCalibrating
                      ? 1.0
                      : (1.0 -
                                (controller.remainingCountdownSeconds /
                                    controller.settings.armingCountdownSeconds))
                            .clamp(0.05, 1.0),
                  backgroundColor: palette.surfaceElevated,
                  color: palette.accentPrimary,
                ),
              ),
            ],
            const SizedBox(height: 20),
            _buildPrimaryAction(context, palette),
          ],
        ),
      ),
    );
  }

  String _headlineForState(ProtectionState s) {
    switch (s) {
      case ProtectionState.disarmed:
        return 'Protection is off';
      case ProtectionState.arming:
        return controller.isCalibrating
            ? 'Finishing setup…'
            : 'Arming in ${controller.remainingCountdownSeconds}s';
      case ProtectionState.armed:
        return 'Protected';
      case ProtectionState.paused:
        return 'Monitoring paused';
      case ProtectionState.alarming:
        return 'Alarm triggered';
      case ProtectionState.unavailable:
        return capability?.status == CapabilityStatus.permissionRequired
            ? 'Permission needed'
            : 'Motion sensor unavailable';
    }
  }

  String? _subtitleForState(ProtectionState s, DetectorCapability? cap) {
    final methodLabel = controller.selectedDetectorType.userFacingMethodName
        .toLowerCase();
    switch (s) {
      case ProtectionState.disarmed:
        return null;
      case ProtectionState.arming:
        return controller.isCalibrating
            ? 'Calibrating $methodLabel — keep device still.'
            : 'Place on a steady surface.';
      case ProtectionState.armed:
        return 'Monitoring with $methodLabel · PIN required to disarm';
      case ProtectionState.paused:
        return 'Resume monitoring to protect this device.';
      case ProtectionState.alarming:
        return controller.activeIncident?.triggerSummary ??
            'Movement was detected while protected.';
      case ProtectionState.unavailable:
        if (cap == null) {
          return 'Motion detection is not ready yet.';
        }
        return cap.guidance ?? cap.summary;
    }
  }

  Widget _buildPrimaryAction(BuildContext context, WatSafePalette palette) {
    switch (state) {
      case ProtectionState.disarmed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FilledButton.icon(
              key: const Key('arm_protection_button'),
              onPressed: controller.startArming,
              icon: const Icon(Icons.shield_rounded),
              label: const Text('Arm protection'),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton.icon(
                key: const Key('home_guided_test_button'),
                onPressed: () =>
                    showGuidedProtectionTestSheet(context, controller),
                icon: const Icon(Icons.verified_user_outlined, size: 17),
                label: const Text('Guided protection test'),
              ),
            ),
          ],
        );

      case ProtectionState.arming:
        return OutlinedButton.icon(
          key: const Key('cancel_arming_button'),
          onPressed: controller.cancelArming,
          icon: const Icon(Icons.close_rounded),
          label: const Text('Cancel'),
        );

      case ProtectionState.armed:
        return FilledButton.icon(
          key: const Key('disarm_protected_button'),
          onPressed: onPromptDisarmPin,
          style: FilledButton.styleFrom(
            backgroundColor: palette.surfaceElevated,
            foregroundColor: palette.textPrimary,
            side: BorderSide(color: palette.borderColor),
          ),
          icon: const Icon(Icons.lock_open_rounded),
          label: const Text('Enter PIN to disarm'),
        );

      case ProtectionState.paused:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FilledButton.icon(
              key: const Key('resume_monitoring_button'),
              onPressed: () => controller.resumePausedMonitoring(
                reason: 'Resumed from Home',
                userInitiated: true,
              ),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Resume monitoring'),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('disarm_paused_button'),
              onPressed: onPromptDisarmPin,
              child: const Text('Enter PIN to disarm'),
            ),
          ],
        );

      case ProtectionState.alarming:
        return FilledButton.icon(
          key: const Key('disarm_alarming_button'),
          onPressed: onPromptDisarmPin,
          style: FilledButton.styleFrom(
            backgroundColor: palette.alarmColor,
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.lock_open_rounded),
          label: const Text('Enter PIN to disarm'),
        );

      case ProtectionState.unavailable:
        final needsPermission =
            capability?.status == CapabilityStatus.permissionRequired;
        final usesCamera = controller.selectedDetectorType.usesCamera;
        if (needsPermission) {
          return FilledButton.icon(
            key: const Key('grant_permission_button'),
            onPressed: controller.requestSelectedDetectorPermission,
            icon: Icon(
              usesCamera ? Icons.videocam_rounded : Icons.sensors_rounded,
            ),
            label: Text(
              usesCamera
                  ? 'Grant Camera Permission'
                  : 'Grant Motion Sensor Permission',
            ),
          );
        }
        return OutlinedButton.icon(
          key: const Key('retry_detector_button'),
          onPressed: controller.retrySelectedDetectorSetup,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try again'),
        );
    }
  }
}

class _PhoneConnectionRow extends StatelessWidget {
  const _PhoneConnectionRow({required this.controller});

  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final devices = controller.pairedDevices;
    final companion = controller.companionSession;

    if (devices.isNotEmpty) {
      final phone = devices.first;
      final isConnected = phone.connected;
      final isFullyReady = isConnected && phone.notificationsEnabled;
      final String notifText;
      if (phone.notificationsEnabled) {
        notifText = 'Notifications on';
      } else if (phone.notificationChannel == 'needs_https') {
        notifText = 'HTTPS setup needed on phone';
      } else if (phone.notificationChannel == 'needs_home_screen') {
        notifText = 'Add to Home Screen on phone';
      } else if (phone.notificationChannel == 'pending_permission' ||
          phone.notificationChannel == 'pending_setup') {
        notifText = 'Finish notification setup on phone';
      } else {
        notifText = 'Notifications off';
      }
      final statusText = isConnected ? 'Phone connected' : 'Disconnected';
      final accentColor = isFullyReady
          ? palette.readyColor
          : palette.warningColor;

      return Card(
        key: const Key('home_phone_connection_row'),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('paired_phone_details_trigger'),
          onTap: () => showConnectedPhoneDetailsSheet(context, controller),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: <Widget>[
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.smartphone_rounded, color: accentColor),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        phone.displayName,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                          color: palette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$statusText • $notifText',
                        style: TextStyle(
                          fontSize: 13,
                          color: accentColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: palette.textMuted),
              ],
            ),
          ),
        ),
      );
    }

    if (companion.isConnected) {
      final hostName = companion.hostDisplayName ?? 'Your Laptop';
      final perm = controller.localNotificationPermissionStatus;
      final notifEnabled =
          perm == PermissionStatus.granted || companion.notificationsEnabled;
      final notifLabel = notifEnabled
          ? 'Notifications on'
          : 'In-app alerts only';

      return Card(
        key: const Key('companion_connected_badge'),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showConnectedPhoneDetailsSheet(context, controller),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(
              children: <Widget>[
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: palette.readyColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.laptop_mac_rounded,
                    color: palette.readyColor,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        hostName,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                          color: palette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Connected • $notifLabel',
                        style: TextStyle(
                          fontSize: 13,
                          color: palette.readyColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: palette.textMuted),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      key: const Key('home_phone_connection_row'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('pair_your_phone_row'),
        onTap: controller.canManagePairing
            ? () => showPhonePairingSheet(context, controller)
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: palette.accentPrimary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.qr_code_scanner_rounded,
                  color: palette.accentPrimary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Pair your phone',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15.5,
                        color: palette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      controller.canManagePairing
                          ? 'Get notified with device location if an alarm triggers'
                          : 'Phone alerts are unavailable right now',
                      style: TextStyle(fontSize: 13, color: palette.textMuted),
                    ),
                  ],
                ),
              ),
              if (controller.canManagePairing)
                Icon(Icons.chevron_right_rounded, color: palette.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _DisarmPinSheet extends StatefulWidget {
  const _DisarmPinSheet({required this.controller});

  final AlarmController controller;

  @override
  State<_DisarmPinSheet> createState() => _DisarmPinSheetState();
}

class _DisarmPinSheetState extends State<_DisarmPinSheet> {
  final TextEditingController _pinController = TextEditingController();
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) {
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    final res = await widget.controller.verifyAndDisarm(_pinController.text);
    if (!mounted) {
      return;
    }
    if (res.verified) {
      Navigator.of(context).pop();
    } else {
      _pinController.clear();
      setState(() {
        _isSubmitting = false;
        _errorMessage = res.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Enter PIN to disarm',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Enter your security PIN to turn protection off.',
                style: TextStyle(color: palette.textMuted),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('disarm_pin_input'),
                controller: _pinController,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: InputDecoration(
                  labelText: 'Security PIN',
                  errorText: _errorMessage,
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 18),
              FilledButton(
                key: const Key('disarm_submit_button'),
                onPressed: _isSubmitting ? null : _submit,
                child: Text(_isSubmitting ? 'Checking…' : 'Disarm'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProtectionDetailsCard extends StatelessWidget {
  const _ProtectionDetailsCard({required this.controller});

  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final methodName = controller.selectedDetectorType.userFacingMethodName;
    final usesCamera = controller.selectedDetectorType.usesCamera;
    final presetTitle = controller.settings.sensitivityPreset.title;
    final soundTitle = controller.settings.selectedAlarmSoundOption.displayName;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('home_protection_details_tile'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          leading: Icon(
            Icons.shield_outlined,
            size: 20,
            color: palette.textMuted,
          ),
          title: Text(
            'Protection details',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: palette.textPrimary,
            ),
          ),
          subtitle: Text(
            '$methodName · $presetTitle · $soundTitle',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: palette.textMuted),
          ),
          children: <Widget>[
            _detailLine(
              palette: palette,
              icon: usesCamera
                  ? Icons.videocam_outlined
                  : Icons.sensors_rounded,
              text: usesCamera
                  ? 'Watches background scene shifts for physical movement and sounds an immediate tamper alarm if the camera is covered.'
                  : 'Monitors built-in device motion sensors and triggers an alarm when disturbed.',
            ),
            const SizedBox(height: 8),
            _detailLine(
              palette: palette,
              icon: Icons.laptop_mac_rounded,
              text: 'Keep your laptop lid open while armed. Closing the lid alerts your phone before sleep, and the cloud relay warns you within ~30–35s if an armed laptop goes offline.',
            ),
            const SizedBox(height: 8),
            _detailLine(
              palette: palette,
              icon: Icons.lock_outline_rounded,
              text: 'Your security PIN is always required to disarm protection or silence an active siren.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailLine({
    required WatSafePalette palette,
    required IconData icon,
    required String text,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 15, color: palette.textSubtle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: palette.textMuted,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.warningColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.warningColor.withValues(alpha: 0.55)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.info_outline_rounded,
            color: palette.warningColor,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
