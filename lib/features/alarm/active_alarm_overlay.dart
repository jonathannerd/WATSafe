import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../theme/watsafe_theme.dart';

/// Focused triggered-alarm screen showing only what happened and the PIN entry
/// needed to disarm and silence the siren immediately.
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
        _feedbackMessage = 'Enter your PIN to disarm.';
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
    final local = dt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final incident = widget.controller.activeIncident;
    final lockout = widget.controller.remainingPinLockout;
    final isLocked = lockout > Duration.zero;
    final lockoutSec = (lockout.inMilliseconds / 1000).ceil();

    return Container(
      color: WatSafeTheme.charcoalDeep,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: const BorderSide(
                  color: WatSafeTheme.alarmCrimson,
                  width: 2,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(26),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Center(
                      child: WatSafeShieldGraphic(
                        accentColor: WatSafeTheme.alarmCrimson,
                        size: 64,
                        isActiveWave: true,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Container(
                        key: const Key('active_alarm_badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: WatSafeTheme.alarmCrimson,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'Alarm triggered',
                          style: TextStyle(
                            color: WatSafeTheme.warmOffWhite,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      incident?.triggerSummary ??
                          'Movement was detected while protected.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: WatSafeTheme.warmOffWhite,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      incident != null
                          ? '${incident.deviceName ?? widget.controller.effectiveDeviceName} • ${_formatTimestamp(incident.triggeredAt)}'
                          : widget.controller.effectiveDeviceName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: WatSafeTheme.warmMuted,
                        fontSize: 13.5,
                      ),
                    ),
                    if (!widget.controller.isAudioPlaying &&
                        widget
                            .controller
                            .wasAlarmInterruptedByLifecycle) ...<Widget>[
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        key: const Key('resume_alarm_audio_button'),
                        onPressed:
                            widget.controller.resumeInterruptedAlarmAudio,
                        icon: const Icon(Icons.volume_up_rounded, size: 18),
                        label: const Text('Resume siren audio'),
                      ),
                    ],
                    const SizedBox(height: 24),
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
                            ? 'Wait ${lockoutSec}s to try again'
                            : 'Security PIN',
                        hintText: 'Enter your PIN',
                        prefixIcon: const Icon(Icons.lock_open_rounded),
                      ),
                      onSubmitted: (_) => _submitDisarm(),
                    ),
                    if (_feedbackMessage != null || isLocked) ...<Widget>[
                      const SizedBox(height: 10),
                      Text(
                        isLocked
                            ? 'Too many incorrect attempts. Try again in $lockoutSec second${lockoutSec == 1 ? '' : 's'}.'
                            : _feedbackMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: WatSafeTheme.amberAccent,
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      key: const Key('alarm_disarm_button'),
                      style: FilledButton.styleFrom(
                        backgroundColor: WatSafeTheme.alarmCrimson,
                        foregroundColor: WatSafeTheme.warmOffWhite,
                      ),
                      onPressed: (isLocked || _isVerifying)
                          ? null
                          : _submitDisarm,
                      icon: const Icon(Icons.check_circle_outline_rounded),
                      label: Text(
                        _isVerifying ? 'Checking PIN…' : 'Enter PIN to disarm',
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
