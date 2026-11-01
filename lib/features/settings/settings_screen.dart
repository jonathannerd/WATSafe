import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/models/detector_models.dart';
import '../theme/watsafe_theme.dart';

/// Settings screen for configuring motion sensitivity, arming countdown,
/// alarm volume, and changing the security PIN (requiring the current PIN).
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
  String? _pinChangeFeedback;
  bool _pinChangeSuccess = false;
  bool _isUpdatingPin = false;

  @override
  void dispose() {
    _currentPinController.dispose();
    _newPinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
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
                'Protection Settings & Security PIN',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Detection & Countdown Parameters',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
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
                            style: const TextStyle(
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
                          widget.controller.updateSettings(
                            motionSensitivity: value,
                          );
                        },
                      ),
                      const Text(
                        'Higher sensitivity lowers the required scene-motion score threshold. '
                        'Requires 3 consecutive frames above threshold after calibration.',
                        style: TextStyle(
                          color: WatSafeTheme.warmMuted,
                          fontSize: 12.5,
                        ),
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
                            style: const TextStyle(
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
                      const Text(
                        'Time provided after clicking Arm Protection to step back and stabilize the laptop before sensor calibration completes.',
                        style: TextStyle(
                          color: WatSafeTheme.warmMuted,
                          fontSize: 12.5,
                        ),
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
                            style: const TextStyle(
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
                        style: const TextStyle(
                          color: WatSafeTheme.warmMuted,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        'Change Disarm PIN (Requires Current PIN)',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: WatSafeTheme.amberAccent,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Storage adapter: ${widget.controller.pinStorageDescription}',
                        style: const TextStyle(
                          color: WatSafeTheme.warmMuted,
                          fontSize: 12.5,
                        ),
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
                            style: const TextStyle(
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}
