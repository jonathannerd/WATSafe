import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/alarm/alarm_controller.dart';
import '../theme/watsafe_theme.dart';

/// Opens the silent, safe Guided Protection Test bottom sheet so users can
/// check passerby rejection and gentle pickup detection on their own device
/// without sounding the siren or sending phone panic alerts.
Future<void> showGuidedProtectionTestSheet(
  BuildContext context,
  AlarmController controller,
) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: WatSafeTheme.charcoalSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _GuidedProtectionTestSheet(controller: controller),
    );
  } finally {
    await controller.stopGuidedProtectionTest();
  }
}

class _GuidedProtectionTestSheet extends StatefulWidget {
  const _GuidedProtectionTestSheet({required this.controller});

  final AlarmController controller;

  @override
  State<_GuidedProtectionTestSheet> createState() =>
      _GuidedProtectionTestSheetState();
}

class _GuidedProtectionTestSheetState
    extends State<_GuidedProtectionTestSheet> {
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  Future<void> _begin() async {
    await widget.controller.startGuidedProtectionTest();
    if (mounted) {
      setState(() {
        _starting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final phase = widget.controller.guidedTestPhase;
        final falseCount = widget.controller.guidedTestFalseTriggers;
        final pickupDetected = widget.controller.guidedTestPickupDetected;
        final latency = widget.controller.guidedTestPickupLatency;
        final telemetry = widget.controller.lastTelemetryEvent;
        final preset = widget.controller.settings.sensitivityPreset;

        return Padding(
          key: const Key('guided_protection_test_sheet'),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(
                        Icons.verified_user_outlined,
                        color: WatSafeTheme.amberAccent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Guided protection test',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        key: const Key('close_guided_test_button'),
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Silent check (${preset.title} preset) — no siren will sound and no phone alert will be sent.',
                    style: const TextStyle(
                      color: WatSafeTheme.warmMuted,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (_starting || phase == 'calibrating')
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Column(
                        children: <Widget>[
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          Text(
                            'Calibrating baseline — keep your device still for a moment…',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: WatSafeTheme.warmMuted),
                          ),
                        ],
                      ),
                    )
                  else if (phase == 'failed')
                    _buildFailedCard(context)
                  else if (phase == 'completed' || pickupDetected)
                    _buildCompletedCard(context, falseCount, latency)
                  else if (phase == 'lift_check')
                    _buildLiftStepCard(context, telemetry?.motionScore)
                  else
                    _buildPasserbyStepCard(
                      context,
                      falseCount,
                      telemetry?.motionScore,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPasserbyStepCard(
    BuildContext context,
    int falseCount,
    double? liveScore,
  ) {
    final passedCleanly = falseCount == 0;
    return Container(
      key: const Key('guided_test_passerby_card'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WatSafeTheme.charcoalElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: WatSafeTheme.charcoalBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'Step 1 of 2 • Everyday scene activity',
            style: TextStyle(
              color: WatSafeTheme.amberAccent,
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Leave this device resting still on your desk. Walk behind it, lean toward the screen, or wave a hand briefly in front of the camera.',
            style: TextStyle(
              color: WatSafeTheme.warmOffWhite,
              fontSize: 14.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color:
                  (passedCleanly
                          ? WatSafeTheme.readyEmerald
                          : WatSafeTheme.amberAccent)
                      .withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  passedCleanly
                      ? Icons.check_circle_rounded
                      : Icons.info_outline_rounded,
                  color: passedCleanly
                      ? WatSafeTheme.readyEmerald
                      : WatSafeTheme.amberAccent,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    passedCleanly
                        ? 'No false alarms triggered so far'
                        : '$falseCount trigger${falseCount == 1 ? '' : 's'} detected — consider switching sensitivity to "Fewer false alarms" in Settings if the device stayed still.',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (liveScore != null) ...<Widget>[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: (liveScore * 3.0).clamp(0.0, 1.0),
                backgroundColor: WatSafeTheme.charcoalDeep,
                color: WatSafeTheme.readyEmerald,
              ),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const Key('guided_test_next_step_button'),
            onPressed: widget.controller.advanceGuidedTestToLiftStep,
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('Next: Test gentle lift'),
          ),
        ],
      ),
    );
  }

  Widget _buildLiftStepCard(BuildContext context, double? liveScore) {
    return Container(
      key: const Key('guided_test_lift_card'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WatSafeTheme.charcoalElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: WatSafeTheme.amberAccent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'Step 2 of 2 • Pickup & tilt check',
            style: TextStyle(
              color: WatSafeTheme.amberAccent,
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Now gently lift, tilt, or slide this device across the table as if someone were picking it up.',
            style: TextStyle(
              color: WatSafeTheme.warmOffWhite,
              fontSize: 14.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 7,
              value: liveScore != null
                  ? (liveScore * 3.5).clamp(0.05, 1.0)
                  : null,
              backgroundColor: WatSafeTheme.charcoalDeep,
              color: WatSafeTheme.amberAccent,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Waiting for device movement…',
            style: TextStyle(fontSize: 13, color: WatSafeTheme.warmMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletedCard(
    BuildContext context,
    int falseCount,
    Duration? latency,
  ) {
    final secs = latency != null
        ? (latency.inMilliseconds / 1000.0).toStringAsFixed(1)
        : null;
    return Container(
      key: const Key('guided_test_completed_card'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: WatSafeTheme.readyEmerald.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: WatSafeTheme.readyEmerald.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(
                Icons.check_circle_rounded,
                color: WatSafeTheme.readyEmerald,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Pickup detected cleanly',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: WatSafeTheme.warmOffWhite,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${secs != null ? "Device movement was recognized in ${secs}s. " : ""}'
            '${falseCount == 0 ? "Everyday scene motion triggered 0 false alarms." : "Scene check recorded $falseCount trigger${falseCount == 1 ? '' : 's'}."}',
            style: const TextStyle(
              color: WatSafeTheme.warmOffWhite,
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              OutlinedButton(
                key: const Key('guided_test_restart_button'),
                onPressed: () {
                  setState(() {
                    _starting = true;
                  });
                  unawaited(_begin());
                },
                child: const Text('Run again'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  key: const Key('guided_test_done_button'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFailedCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: WatSafeTheme.charcoalElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: WatSafeTheme.charcoalBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            widget.controller.warningMessage ??
                'Could not start motion detection for the guided test.',
            style: const TextStyle(color: WatSafeTheme.warmOffWhite),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
