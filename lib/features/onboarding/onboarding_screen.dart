import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/models/detector_models.dart';
import '../pairing/phone_pairing_sheet.dart';
import '../theme/watsafe_theme.dart';

/// Friendly plain-language first-run setup for naming this device, choosing a
/// 6+ digit security PIN, and understanding location sharing on alarm.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.controller,
    this.isPreviewMode = false,
  });

  final AlarmController controller;
  final bool isPreviewMode;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final TextEditingController _deviceNameController;
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _confirmPinController = TextEditingController();
  bool _obscurePin = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _deviceNameController = TextEditingController(
      text: widget.controller.effectiveDeviceName,
    );
  }

  @override
  void dispose() {
    _deviceNameController.dispose();
    _pinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  Future<void> _submitPinSetup() async {
    if (widget.isPreviewMode) {
      widget.controller.exitOnboardingPreview();
      return;
    }
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
      deviceDisplayName: _deviceNameController.text.trim(),
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
    final palette = WatSafeTheme.of(context);
    final locPerm = widget.controller.locationPermissionStatus;
    final locGranted = locPerm == PermissionStatus.granted;

    return Scaffold(
      backgroundColor: palette.backgroundDeep,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (widget.isPreviewMode) ...<Widget>[
                    Container(
                      key: const Key('onboarding_preview_banner'),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: palette.accentPrimary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: palette.accentPrimary),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.visibility_rounded,
                            color: palette.accentPrimary,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Previewing onboarding — your saved PIN, phone pairing, settings, and Activity history remain untouched.',
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            key: const Key('exit_onboarding_preview_button'),
                            onPressed: widget.controller.exitOnboardingPreview,
                            child: const Text('Exit preview'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  Center(
                    child: WatSafeShieldGraphic(
                      accentColor: palette.accentPrimary,
                      size: 64,
                      isActiveWave: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Welcome to WATSafe',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: palette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Name this device and create a PIN so only you can turn protection off.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 14.5,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          TextField(
                            key: const Key('onboarding_device_name_input'),
                            controller: _deviceNameController,
                            decoration: const InputDecoration(
                              labelText: 'Device name',
                              hintText: 'Jonathan’s MacBook',
                            ),
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
                              labelText: 'Create PIN (6 or more digits)',
                              hintText: 'At least 6 digits',
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
                              labelText: 'Confirm PIN',
                              hintText: 'Re-enter the same PIN',
                            ),
                            onSubmitted: (_) => _submitPinSetup(),
                          ),
                          if (widget
                              .controller
                              .isLocationSupported) ...<Widget>[
                            const SizedBox(height: 18),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: palette.surfaceElevated,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: palette.borderColor),
                              ),
                              child: Row(
                                children: <Widget>[
                                  Icon(
                                    locGranted
                                        ? Icons.check_circle_rounded
                                        : Icons.location_on_outlined,
                                    color: locGranted
                                        ? palette.readyColor
                                        : palette.accentPrimary,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Allow location access so WATSafe can share where this device is with your paired phone if an alarm triggers.',
                                      style: TextStyle(
                                        color: palette.textMuted,
                                        fontSize: 12.5,
                                        height: 1.35,
                                      ),
                                    ),
                                  ),
                                  if (!locGranted) ...<Widget>[
                                    const SizedBox(width: 8),
                                    TextButton(
                                      key: const Key(
                                        'onboarding_allow_location_button',
                                      ),
                                      onPressed: widget
                                          .controller
                                          .requestLocationPermission,
                                      child: const Text('Allow'),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                          if (_errorMessage != null) ...<Widget>[
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: palette.alarmColor.withValues(
                                  alpha: 0.15,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: palette.alarmColor),
                              ),
                              child: Text(
                                _errorMessage!,
                                style: TextStyle(
                                  color: palette.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          FilledButton(
                            key: const Key('onboarding_complete_button'),
                            onPressed: _isSubmitting ? null : _submitPinSetup,
                            child: Text(
                              widget.isPreviewMode
                                  ? 'Exit preview'
                                  : (_isSubmitting
                                        ? 'Saving…'
                                        : 'Finish setup'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (widget.controller.canManagePairing) ...<Widget>[
                    const SizedBox(height: 12),
                    TextButton.icon(
                      key: const Key('onboarding_pair_phone_instead_button'),
                      onPressed: () => showPhonePairingSheet(
                        context,
                        widget.controller,
                        initialPhonePairingPayload: null,
                      ),
                      icon: const Icon(Icons.smartphone_rounded, size: 18),
                      label: const Text(
                        'Setting up your phone? Pair with your laptop',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
