import 'package:flutter/material.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/alarm/alarm_state.dart';
import '../../core/models/detector_models.dart';
import '../alarm/active_alarm_overlay.dart';
import '../theme/watsafe_theme.dart';

/// Main Protection Dashboard displaying real detector availability, health,
/// arming countdown, live telemetry, test alarm controls, and detector selector.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.controller});

  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final stateColor = WatSafeTheme.colorForProtectionState(state);
    final selectedCapability = controller.selectedCapability;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (controller.warningMessage != null) ...<Widget>[
                _WarningBanner(message: controller.warningMessage!),
                const SizedBox(height: 16),
              ],
              _ProtectionHeroCard(
                controller: controller,
                state: state,
                stateColor: stateColor,
                capability: selectedCapability,
              ),
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 720;
                  if (isWide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          flex: 6,
                          child: _DetectorSelectorCard(controller: controller),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          flex: 5,
                          child: _TelemetryAndTestAlarmColumn(
                            controller: controller,
                          ),
                        ),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _TelemetryAndTestAlarmColumn(controller: controller),
                      const SizedBox(height: 20),
                      _DetectorSelectorCard(controller: controller),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: WatSafeTheme.orangeAccent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: WatSafeTheme.orangeAccent),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.warning_amber_rounded,
            color: WatSafeTheme.amberAccent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: WatSafeTheme.warmOffWhite,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
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
  });

  final AlarmController controller;
  final ProtectionState state;
  final Color stateColor;
  final DetectorCapability? capability;

  @override
  Widget build(BuildContext context) {
    final canArm = capability?.canArm ?? false;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: state.isProtected ? stateColor : WatSafeTheme.charcoalBorder,
          width: state.isProtected ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 16,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    WatSafeShieldGraphic(
                      accentColor: stateColor,
                      size: 68,
                      isActiveWave:
                          state == ProtectionState.armed ||
                          state == ProtectionState.arming ||
                          state == ProtectionState.alarming,
                    ),
                    const SizedBox(width: 18),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: stateColor.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: stateColor),
                            ),
                            child: Text(
                              state.badgeLabel,
                              key: const Key('dashboard_state_badge'),
                              style: TextStyle(
                                color: stateColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            state.displayName,
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: WatSafeTheme.warmOffWhite,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            controller.statusMessage,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: WatSafeTheme.warmMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                _buildPrimaryActionButtons(context, canArm),
              ],
            ),
            if (state == ProtectionState.arming) ...<Widget>[
              const SizedBox(height: 20),
              _ArmingCountdownBar(controller: controller),
            ],
            if (state == ProtectionState.unavailable ||
                state == ProtectionState.paused) ...<Widget>[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: WatSafeTheme.charcoalElevated,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: WatSafeTheme.charcoalBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      state == ProtectionState.paused
                          ? 'Protection Paused — Not Actively Monitoring'
                          : 'Detector Readiness & Permission Guidance',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: WatSafeTheme.amberAccent,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      capability?.guidance ??
                          capability?.statusDetail ??
                          'Ensure the selected detector hardware is connected and OS permissions are granted.',
                      style: const TextStyle(
                        color: WatSafeTheme.warmMuted,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: <Widget>[
                        if (capability != null &&
                            capability!.needsPermissionRequest)
                          FilledButton.tonalIcon(
                            onPressed:
                                controller.requestSelectedDetectorPermission,
                            icon: Icon(
                              capability!.type.usesCamera
                                  ? Icons.videocam_outlined
                                  : Icons.sensors,
                              size: 18,
                            ),
                            label: Text(
                              capability!.type.usesCamera
                                  ? 'Grant Camera Permission'
                                  : 'Grant Motion Sensor Permission',
                            ),
                          ),
                        OutlinedButton.icon(
                          onPressed: controller.refreshCapabilities,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Refresh Readiness'),
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

  Widget _buildPrimaryActionButtons(BuildContext context, bool canArm) {
    switch (state) {
      case ProtectionState.disarmed:
      case ProtectionState.unavailable:
        return Wrap(
          spacing: 12,
          runSpacing: 10,
          children: <Widget>[
            FilledButton.icon(
              key: const Key('arm_protection_button'),
              onPressed: canArm ? controller.startArming : null,
              icon: const Icon(Icons.shield_outlined),
              label: Text(
                canArm
                    ? 'Arm Protection (${controller.settings.armingCountdownSeconds}s)'
                    : 'Cannot Arm (Detector Unavailable)',
              ),
            ),
          ],
        );

      case ProtectionState.arming:
        return Wrap(
          spacing: 12,
          runSpacing: 10,
          children: <Widget>[
            OutlinedButton.icon(
              key: const Key('cancel_arming_button'),
              onPressed: controller.cancelArming,
              icon: const Icon(Icons.close),
              label: const Text('Cancel Arming'),
            ),
          ],
        );

      case ProtectionState.armed:
      case ProtectionState.paused:
        return FilledButton.icon(
          key: const Key('disarm_protection_button'),
          style: FilledButton.styleFrom(
            backgroundColor: WatSafeTheme.orangeAccent,
            foregroundColor: WatSafeTheme.charcoalDeep,
          ),
          onPressed: () {
            showDisarmPinDialog(context: context, controller: controller);
          },
          icon: const Icon(Icons.lock_open_outlined),
          label: const Text('Disarm with PIN'),
        );

      case ProtectionState.alarming:
        return FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: WatSafeTheme.alarmCrimson,
            foregroundColor: WatSafeTheme.warmOffWhite,
          ),
          onPressed: () {
            showDisarmPinDialog(context: context, controller: controller);
          },
          icon: const Icon(Icons.notification_important_outlined),
          label: const Text('Enter PIN to Stop Siren'),
        );
    }
  }
}

class _ArmingCountdownBar extends StatelessWidget {
  const _ArmingCountdownBar({required this.controller});

  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    final total = controller.settings.armingCountdownSeconds;
    final remaining = controller.remainingCountdownSeconds;
    final progress = total > 0
        ? ((total - remaining) / total).clamp(0.0, 1.0)
        : 1.0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: WatSafeTheme.charcoalElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: WatSafeTheme.amberAccent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                controller.isCalibrating
                    ? 'Calibrating baseline scene...'
                    : 'Arming Countdown in Progress',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: WatSafeTheme.warmOffWhite,
                ),
              ),
              Text(
                controller.isCalibrating ? 'CALIBRATING' : '${remaining}s',
                key: const Key('countdown_seconds_label'),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: WatSafeTheme.amberAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: controller.isCalibrating ? null : progress,
            minHeight: 8,
            backgroundColor: WatSafeTheme.charcoalDeep,
            color: WatSafeTheme.amberAccent,
            borderRadius: BorderRadius.circular(4),
          ),
        ],
      ),
    );
  }
}

class _TelemetryAndTestAlarmColumn extends StatelessWidget {
  const _TelemetryAndTestAlarmColumn({required this.controller});

  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    final telemetry = controller.lastTelemetryEvent;
    final threshold = MonitorConfig(
      sessionId: 'preview',
      sensitivity: controller.settings.motionSensitivity,
    ).motionScoreThreshold;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(
                      Icons.analytics_outlined,
                      color: WatSafeTheme.amberAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Live Sensor & Scene-Motion Telemetry',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _TelemetryMetricRow(
                  label: 'Selected Modality',
                  value: controller.selectedDetectorType.modalityLabel,
                ),
                const SizedBox(height: 8),
                _TelemetryMetricRow(
                  label: 'Active Trigger Threshold',
                  value:
                      '${threshold.toStringAsFixed(3)} (Sensitivity ${(controller.settings.motionSensitivity * 100).round()}%)',
                ),
                const SizedBox(height: 8),
                _TelemetryMetricRow(
                  label: 'Latest Scene Motion Score',
                  value: telemetry?.motionScore != null
                      ? telemetry!.motionScore!.toStringAsFixed(3)
                      : (controller.state == ProtectionState.armed
                            ? 'Calibrating / 0.000'
                            : 'Idle (disarmed)'),
                ),
                const SizedBox(height: 8),
                _TelemetryMetricRow(
                  label: 'Frame Luminance',
                  value: telemetry?.averageLuminance != null
                      ? '${(telemetry!.averageLuminance! * 100).round()}%'
                      : '—',
                ),
                const SizedBox(height: 12),
                Text(
                  controller.selectedDetectorType.limitationNote,
                  style: const TextStyle(
                    color: WatSafeTheme.warmMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(
                      Icons.volume_up_outlined,
                      color: WatSafeTheme.amberAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Independent Local Test Alarm (Max 5s)',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Verifies local siren playback and incident logging independently of camera hardware. '
                  'Automatically stops after at most 5 seconds and records a clearly marked TEST incident.',
                  style: TextStyle(
                    color: WatSafeTheme.warmMuted,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 14),
                if (controller.isTestAlarmRunning)
                  FilledButton.icon(
                    key: const Key('stop_test_alarm_button'),
                    style: FilledButton.styleFrom(
                      backgroundColor: WatSafeTheme.alarmCrimson,
                      foregroundColor: WatSafeTheme.warmOffWhite,
                    ),
                    onPressed: controller.stopTestAlarm,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Stop Test Alarm Immediately'),
                  )
                else
                  OutlinedButton.icon(
                    key: const Key('start_test_alarm_button'),
                    onPressed:
                        (controller.state == ProtectionState.disarmed ||
                            controller.state == ProtectionState.unavailable)
                        ? controller.startTestAlarm
                        : null,
                    icon: const Icon(Icons.play_arrow_outlined),
                    label: Text(
                      'Run 5-Second Test Alarm (${(controller.settings.alarmVolume * 100).round()}% Vol)',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TelemetryMetricRow extends StatelessWidget {
  const _TelemetryMetricRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(color: WatSafeTheme.warmMuted, fontSize: 13),
        ),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: WatSafeTheme.warmOffWhite,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}

class _DetectorSelectorCard extends StatelessWidget {
  const _DetectorSelectorCard({required this.controller});

  final AlarmController controller;

  @override
  Widget build(BuildContext context) {
    final capabilities = controller.capabilities;
    final selectedType = controller.selectedDetectorType;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Expanded(
                  child: Row(
                    children: <Widget>[
                      const Icon(
                        Icons.tune_outlined,
                        color: WatSafeTheme.amberAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Platform Detector Selector & Status',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh detector capabilities',
                  onPressed: controller.refreshCapabilities,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Select a detector to inspect its hardware readiness, OS permission state, and platform implementation status.',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            ...DetectorType.values.map((type) {
              final cap = capabilities[type];
              final status = cap?.status ?? CapabilityStatus.unsupported;
              final statusColor = WatSafeTheme.colorForCapabilityStatus(status);
              final isSelected = type == selectedType;

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => controller.selectDetector(type),
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
                        width: isSelected ? 1.6 : 1.0,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
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
                              child: Text(
                                type.displayName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: WatSafeTheme.warmOffWhite,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(color: statusColor),
                              ),
                              child: Text(
                                WatSafeTheme.labelForCapabilityStatus(status),
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.only(left: 28),
                          child: Text(
                            cap?.summary ?? type.limitationNote,
                            style: const TextStyle(
                              color: WatSafeTheme.warmMuted,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
