import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../theme/watsafe_theme.dart';

/// Full-focus alarm and PIN disarm screen displayed when `ProtectionState.alarming`
/// is active, showing the trigger reason, timestamp, peak motion score, and
/// PIN entry with lockout feedback.
class ActiveAlarmScreen extends StatefulWidget {
  const ActiveAlarmScreen({super.key, required this.controller});

  final AlarmController controller;

  @override
  State<ActiveAlarmScreen> createState() => _ActiveAlarmScreenState();
}

class _ActiveAlarmScreenState extends State<ActiveAlarmScreen> {
  final TextEditingController _pinController = TextEditingController();
  Timer? _lockoutRefreshTimer;
  String? _feedbackMessage;
  bool _isVerifying = false;

  @override
  void initState() {
    super.initState();
    _lockoutRefreshTimer = Timer.periodic(const Duration(milliseconds: 500), (
      _,
    ) {
      if (mounted && widget.controller.isPinLockedOut) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _lockoutRefreshTimer?.cancel();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _submitDisarm() async {
    if (_isVerifying) {
      return;
    }
    final pin = _pinController.text.trim();
    if (pin.isEmpty) {
      setState(() {
        _feedbackMessage = 'Enter your security PIN to disarm the alarm.';
      });
      return;
    }

    setState(() {
      _isVerifying = true;
    });

    final result = await widget.controller.verifyAndDisarm(pin);
    if (!mounted) {
      return;
    }

    setState(() {
      _isVerifying = false;
      if (!result.verified) {
        _feedbackMessage = result.message;
        _pinController.clear();
      }
    });
  }

  String _formatTimestamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final incident = widget.controller.activeIncident;
    final lockout = widget.controller.remainingPinLockout;
    final isLocked = lockout > Duration.zero;
    final lockoutSec = (lockout.inMilliseconds / 1000).ceil();

    return Container(
      decoration: BoxDecoration(
        color: WatSafeTheme.charcoalDeep,
        border: Border.all(color: WatSafeTheme.alarmCrimson, width: 2),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(
                  color: WatSafeTheme.alarmCrimson,
                  width: 2,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const WatSafeShieldGraphic(
                          accentColor: WatSafeTheme.alarmCrimson,
                          size: 56,
                          isActiveWave: true,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: WatSafeTheme.alarmCrimson,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'ALARM ACTIVE — SIREN SOUNDING',
                                  style: TextStyle(
                                    color: WatSafeTheme.warmOffWhite,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Security Trigger Detected',
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: WatSafeTheme.charcoalElevated,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: WatSafeTheme.charcoalBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          _InfoRow(
                            label: 'Trigger Cause',
                            value:
                                incident?.triggerSummary ??
                                widget.controller.statusMessage,
                          ),
                          const SizedBox(height: 8),
                          _InfoRow(
                            label: 'Timestamp',
                            value: incident != null
                                ? _formatTimestamp(incident.triggeredAt)
                                : _formatTimestamp(DateTime.now()),
                          ),
                          const SizedBox(height: 8),
                          _InfoRow(
                            label: 'Detector',
                            value:
                                incident?.detectorType?.displayName ??
                                widget
                                    .controller
                                    .selectedDetectorType
                                    .displayName,
                          ),
                          if (incident?.peakMotionScore != null) ...<Widget>[
                            const SizedBox(height: 8),
                            _InfoRow(
                              label: 'Peak Motion Score',
                              value: incident!.peakMotionScore!.toStringAsFixed(
                                3,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          _InfoRow(
                            label: 'Remote Push Alert',
                            value:
                                incident?.remoteNotificationStatus ??
                                'Not configured (local-only milestone)',
                          ),
                        ],
                      ),
                    ),
                    if (widget.controller.warningMessage != null) ...<Widget>[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: WatSafeTheme.orangeAccent.withValues(
                            alpha: 0.16,
                          ),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: WatSafeTheme.orangeAccent),
                        ),
                        child: Text(
                          widget.controller.warningMessage!,
                          style: const TextStyle(
                            color: WatSafeTheme.warmOffWhite,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    TextField(
                      key: const Key('alarm_pin_input'),
                      controller: _pinController,
                      autofocus: true,
                      obscureText: true,
                      enabled: !isLocked && !_isVerifying,
                      keyboardType: TextInputType.number,
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(12),
                      ],
                      decoration: InputDecoration(
                        labelText: isLocked
                            ? 'PIN entry locked ($lockoutSec s remaining)'
                            : 'Enter Disarm PIN',
                        hintText: '6–12 digit security PIN',
                        prefixIcon: const Icon(Icons.lock_open_outlined),
                      ),
                      onSubmitted: (_) => _submitDisarm(),
                    ),
                    if (_feedbackMessage != null || isLocked) ...<Widget>[
                      const SizedBox(height: 10),
                      Text(
                        isLocked
                            ? 'Repeated failed attempts. Wait $lockoutSec second${lockoutSec == 1 ? '' : 's'} before retrying.'
                            : _feedbackMessage!,
                        style: const TextStyle(
                          color: WatSafeTheme.amberAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      key: const Key('alarm_disarm_button'),
                      style: FilledButton.styleFrom(
                        backgroundColor: WatSafeTheme.alarmCrimson,
                        foregroundColor: WatSafeTheme.warmOffWhite,
                      ),
                      onPressed: (isLocked || _isVerifying)
                          ? null
                          : _submitDisarm,
                      icon: const Icon(Icons.gpp_good_outlined),
                      label: Text(
                        _isVerifying
                            ? 'Verifying PIN...'
                            : 'Verify PIN & Stop Alarm',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 135,
          child: Text(
            label,
            style: const TextStyle(
              color: WatSafeTheme.warmMuted,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
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

/// Dialog for disarming an armed or paused monitoring session using the user's PIN.
Future<bool> showDisarmPinDialog({
  required BuildContext context,
  required AlarmController controller,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _DisarmPinDialog(controller: controller),
  );
  return result ?? false;
}

class _DisarmPinDialog extends StatefulWidget {
  const _DisarmPinDialog({required this.controller});

  final AlarmController controller;

  @override
  State<_DisarmPinDialog> createState() => _DisarmPinDialogState();
}

class _DisarmPinDialogState extends State<_DisarmPinDialog> {
  final TextEditingController _pinController = TextEditingController();
  String? _errorText;
  bool _isSubmitting = false;

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
      _errorText = null;
    });
    final res = await widget.controller.verifyAndDisarm(
      _pinController.text.trim(),
    );
    if (!mounted) {
      return;
    }
    if (res.verified) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _isSubmitting = false;
      _errorText = res.message ?? 'Incorrect PIN.';
      _pinController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: WatSafeTheme.charcoalSurface,
      title: const Text('Enter PIN to Disarm'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Enter your 6+ digit WATSafe security PIN to stop monitoring and disarm protection.',
              style: TextStyle(color: WatSafeTheme.warmMuted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('disarm_dialog_pin_input'),
              controller: _pinController,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(12),
              ],
              decoration: InputDecoration(
                labelText: 'Security PIN',
                errorText: _errorText,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep Armed'),
        ),
        FilledButton(
          key: const Key('disarm_dialog_submit_button'),
          onPressed: _isSubmitting ? null : _submit,
          child: const Text('Verify & Disarm'),
        ),
      ],
    );
  }
}
