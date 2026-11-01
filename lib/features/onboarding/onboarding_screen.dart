import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/models/detector_models.dart';
import '../theme/watsafe_theme.dart';

/// First-run onboarding screen for setting up the local 6+ digit PIN and
/// inspecting hardware detector capabilities before entering the dashboard.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.controller});

  final AlarmController controller;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _confirmPinController = TextEditingController();
  bool _obscurePin = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  Future<void> _submitPinSetup() async {
    if (_isSubmitting) {
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final result = await widget.controller.setupInitialPin(
      pin: _pinController.text.trim(),
      confirmPin: _confirmPinController.text.trim(),
    );

    if (!mounted) {
      return;
    }
    setState(() {
      _isSubmitting = false;
      if (!result.isValid) {
        _errorMessage = result.errorMessage;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final capability = widget.controller.selectedCapability;
    final capStatus = capability?.status ?? CapabilityStatus.unsupported;
    final capColor = WatSafeTheme.colorForCapabilityStatus(capStatus);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const WatSafeShieldGraphic(
                        accentColor: WatSafeTheme.amberAccent,
                        size: 56,
                        isActiveWave: true,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Welcome to WATSafe',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: WatSafeTheme.warmOffWhite,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'First-run security setup & hardware capability inspection',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: WatSafeTheme.warmMuted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              const Icon(
                                Icons.sensors,
                                color: WatSafeTheme.amberAccent,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '1. Host Capability Check (${widget.controller.selectedDetectorType.displayName})',
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
                                  color: capColor.withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: capColor),
                                ),
                                child: Text(
                                  WatSafeTheme.labelForCapabilityStatus(
                                    capStatus,
                                  ),
                                  style: TextStyle(
                                    color: capColor,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            capability?.summary ??
                                'Inspecting local detector hardware...',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          if (capability?.guidance != null) ...<Widget>[
                            const SizedBox(height: 8),
                            Text(
                              capability!.guidance!,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: WatSafeTheme.warmMuted),
                            ),
                          ],
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: <Widget>[
                              if (capability != null &&
                                  capability.needsPermissionRequest)
                                OutlinedButton.icon(
                                  onPressed: () {
                                    widget.controller
                                        .requestSelectedDetectorPermission();
                                  },
                                  icon: const Icon(
                                    Icons.videocam_outlined,
                                    size: 18,
                                  ),
                                  label: const Text('Grant Camera Permission'),
                                ),
                              OutlinedButton.icon(
                                onPressed:
                                    widget.controller.refreshCapabilities,
                                icon: const Icon(Icons.refresh, size: 18),
                                label: const Text('Refresh Capability Status'),
                              ),
                            ],
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
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              const Icon(
                                Icons.lock_outline,
                                color: WatSafeTheme.amberAccent,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '2. Create Disarm PIN (Minimum 6 Digits)',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Your PIN is required to disarm WATSafe or silence an active alarm. '
                            'It is stored locally as a salted PBKDF2-HMAC-SHA256 hash via '
                            '${widget.controller.pinStorageDescription} and is never logged.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: WatSafeTheme.warmMuted),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            key: const Key('onboarding_pin_input'),
                            controller: _pinController,
                            obscureText: _obscurePin,
                            keyboardType: TextInputType.number,
                            inputFormatters: <TextInputFormatter>[
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(12),
                            ],
                            decoration: InputDecoration(
                              labelText: 'New Security PIN (6–12 digits)',
                              hintText: 'Enter at least 6 digits',
                              suffixIcon: IconButton(
                                onPressed: () {
                                  setState(() {
                                    _obscurePin = !_obscurePin;
                                  });
                                },
                                icon: Icon(
                                  _obscurePin
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                            onSubmitted: (_) => _submitPinSetup(),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: const Key('onboarding_confirm_pin_input'),
                            controller: _confirmPinController,
                            obscureText: _obscurePin,
                            keyboardType: TextInputType.number,
                            inputFormatters: <TextInputFormatter>[
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(12),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Confirm Security PIN',
                              hintText: 'Re-enter the same PIN',
                            ),
                            onSubmitted: (_) => _submitPinSetup(),
                          ),
                          if (_errorMessage != null) ...<Widget>[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: WatSafeTheme.alarmCrimson.withValues(
                                  alpha: 0.15,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: WatSafeTheme.alarmCrimson,
                                ),
                              ),
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(
                                  color: WatSafeTheme.warmOffWhite,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            key: const Key('onboarding_complete_button'),
                            onPressed: _isSubmitting ? null : _submitPinSetup,
                            icon: const Icon(Icons.verified_user_outlined),
                            label: Text(
                              _isSubmitting
                                  ? 'Securing PIN...'
                                  : 'Save PIN & Open Dashboard',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: WatSafeTheme.charcoalElevated,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: WatSafeTheme.charcoalBorder),
                    ),
                    child: Text(
                      'Transparency note: WATSafe is an application-level deterrent and alert tool. '
                      'Its PIN disarm interface is separate from your OS lock screen and cannot '
                      'prevent hardware power-off, OS force-quit, or physical speaker muting.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: WatSafeTheme.warmMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
