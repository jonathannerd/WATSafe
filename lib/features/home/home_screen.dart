import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/alarm/alarm_state.dart';
import '../../core/models/detector_models.dart';
import '../pairing/phone_pairing_sheet.dart';
import '../theme/watsafe_theme.dart';

/// Primary Home screen focused on two things:
/// 1. Clear protection status + one obvious primary action for the current state
/// 2. One simple Phone connection row ("Pair your phone" before pairing; phone
///    name, connection status, and notification status after pairing, with
///    "Send test alert" and "Disconnect phone" inside its details).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});

  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final stateColor = WatSafeTheme.colorForProtectionState(state);
    final capability = controller.selectedCapability;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (controller.warningMessage != null) ...<Widget>[
                _WarningCard(message: controller.warningMessage!),
                const SizedBox(height: 16),
              ],
              _ProtectionHeroCard(
                controller: controller,
                state: state,
                stateColor: stateColor,
                capability: capability,
                onPromptDisarmPin: () => _showDisarmPinDialog(context),
              ),
              const SizedBox(height: 16),
              _PhoneConnectionRow(controller: controller),
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
      backgroundColor: WatSafeTheme.charcoalSurface,
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
    final isActive =
        state == ProtectionState.armed ||
        state == ProtectionState.arming ||
        state == ProtectionState.alarming;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: WatSafeShieldGraphic(
                accentColor: stateColor,
                size: 76,
                isActiveWave: isActive,
              ),
            ),
            const SizedBox(height: 18),
            Center(
              child: Container(
                key: const Key('dashboard_state_badge'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: stateColor.withValues(alpha: 0.55),
                  ),
                ),
                child: Text(
                  state.badgeLabel,
                  style: TextStyle(
                    color: state == ProtectionState.disarmed
                        ? WatSafeTheme.warmOffWhite
                        : stateColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _headlineForState(state),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: WatSafeTheme.warmOffWhite,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _subtitleForState(state, capability),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: WatSafeTheme.warmMuted,
                fontSize: 14.5,
                height: 1.45,
              ),
            ),
            if (state == ProtectionState.arming) ...<Widget>[
              const SizedBox(height: 18),
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
                  backgroundColor: WatSafeTheme.charcoalElevated,
                  color: WatSafeTheme.amberAccent,
                ),
              ),
            ],
            const SizedBox(height: 24),
            _buildPrimaryAction(context),
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

  String _subtitleForState(ProtectionState s, DetectorCapability? cap) {
    final methodLabel =
        controller.selectedDetectorType.userFacingMethodName.toLowerCase();
    switch (s) {
      case ProtectionState.disarmed:
        return 'Arm protection before stepping away. WATSafe will watch for movement using your $methodLabel and sound an alarm if this device is disturbed.';
      case ProtectionState.arming:
        return controller.isCalibrating
            ? 'Calibrating $methodLabel — keep this device still for a moment.'
            : 'Place this device on a steady surface before monitoring begins.';
      case ProtectionState.armed:
        return 'Monitoring for movement with your $methodLabel. Your PIN is required to turn protection off.';
      case ProtectionState.paused:
        return 'Monitoring paused while WATSafe was in the background. Resume monitoring to protect this device again.';
      case ProtectionState.alarming:
        return controller.activeIncident?.triggerSummary ??
            'Movement was detected while protected.';
      case ProtectionState.unavailable:
        if (cap == null) {
          return 'Motion detection is not ready on this device yet.';
        }
        return cap.guidance ?? cap.summary;
    }
  }

  Widget _buildPrimaryAction(BuildContext context) {
    switch (state) {
      case ProtectionState.disarmed:
        return FilledButton.icon(
          key: const Key('arm_protection_button'),
          onPressed: controller.startArming,
          icon: const Icon(Icons.shield_rounded),
          label: const Text('Arm protection'),
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
            backgroundColor: WatSafeTheme.charcoalElevated,
            foregroundColor: WatSafeTheme.warmOffWhite,
            side: const BorderSide(color: WatSafeTheme.charcoalBorder),
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
            backgroundColor: WatSafeTheme.alarmCrimson,
            foregroundColor: WatSafeTheme.warmOffWhite,
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
    final devices = controller.pairedDevices;
    final companion = controller.companionSession;

    // 1. Paired phone row on protected laptop
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
          ? WatSafeTheme.readyEmerald
          : WatSafeTheme.amberAccent;

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
                  child: Icon(
                    Icons.smartphone_rounded,
                    color: accentColor,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        phone.displayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                          color: WatSafeTheme.warmOffWhite,
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
                const Icon(
                  Icons.chevron_right_rounded,
                  color: WatSafeTheme.warmMuted,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 2. Connected companion row when this device is the paired phone
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
                    color: WatSafeTheme.readyEmerald.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.laptop_mac_rounded,
                    color: WatSafeTheme.readyEmerald,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        hostName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15.5,
                          color: WatSafeTheme.warmOffWhite,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Connected • $notifLabel',
                        style: const TextStyle(
                          fontSize: 13,
                          color: WatSafeTheme.readyEmerald,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: WatSafeTheme.warmMuted,
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 3. Before pairing: single clean "Pair your phone" row
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
                  color: WatSafeTheme.amberAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.qr_code_scanner_rounded,
                  color: WatSafeTheme.amberAccent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Pair your phone',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15.5,
                        color: WatSafeTheme.warmOffWhite,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      controller.canManagePairing
                          ? 'Get notified with device location if an alarm triggers'
                          : 'Phone alerts are unavailable right now',
                      style: const TextStyle(
                        fontSize: 13,
                        color: WatSafeTheme.warmMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (controller.canManagePairing)
                const Icon(
                  Icons.chevron_right_rounded,
                  color: WatSafeTheme.warmMuted,
                ),
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
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                'Enter your security PIN to turn protection off.',
                style: TextStyle(color: WatSafeTheme.warmMuted),
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

class _WarningCard extends StatelessWidget {
  const _WarningCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WatSafeTheme.amberAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: WatSafeTheme.amberAccent.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.info_outline_rounded,
            color: WatSafeTheme.amberAccent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: WatSafeTheme.warmOffWhite,
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
