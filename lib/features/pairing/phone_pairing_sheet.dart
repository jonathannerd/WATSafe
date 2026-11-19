import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/contracts/platform_contracts.dart';
import '../../core/models/detector_models.dart';
import '../theme/watsafe_theme.dart';
import 'qr_code_widget.dart';

/// Opens the end-to-end phone pairing flow.
///
/// - On a laptop (`initialPhonePairingPayload == null`), immediately generates
///   and shows a scannable QR code + short one-time code, watches for the phone
///   to connect, and transitions automatically to **Phone connected** with
///   **Send test alert**.
/// - When opened from a scanned QR link (`initialPhonePairingPayload != null`)
///   or switched to phone code entry, looks up the host and asks
///   `"Connect to <Host Name>?"` with one **Connect** button, then asks for
///   notification permission after explaining what alerts the phone receives.
Future<void> showPhonePairingSheet(
  BuildContext context,
  AlarmController controller, {
  String? initialPhonePairingPayload,
}) {
  final palette = WatSafeTheme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: palette.surfaceCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: _PhonePairingSheetBody(
          controller: controller,
          initialPhonePairingPayload: initialPhonePairingPayload,
        ),
      );
    },
  );
}

/// Opens the details sheet for the Phone connection row on Home when a phone
/// (or companion session) is already paired.
Future<void> showConnectedPhoneDetailsSheet(
  BuildContext context,
  AlarmController controller,
) {
  final palette = WatSafeTheme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: palette.surfaceCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return _ConnectedPhoneDetailsBody(controller: controller);
    },
  );
}

enum _PairingStep {
  hostQrDisplay,
  phoneEnterCode,
  phoneConfirmHost,
  phoneNotificationPrompt,
}

class _PhonePairingSheetBody extends StatefulWidget {
  const _PhonePairingSheetBody({
    required this.controller,
    this.initialPhonePairingPayload,
  });

  final AlarmController controller;
  final String? initialPhonePairingPayload;

  @override
  State<_PhonePairingSheetBody> createState() => _PhonePairingSheetBodyState();
}

class _PhonePairingSheetBodyState extends State<_PhonePairingSheetBody> {
  late _PairingStep _step;
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _permanentUrlController = TextEditingController();
  late final TextEditingController _phoneNameController;

  bool _isBusy = false;
  bool _showPermanentUrlEditor = false;
  String? _errorMessage;
  String? _infoMessage;

  PairingLookupPreview? _lookupPreview;
  String? _pendingPayloadOrCode;
  int _initialPairedCount = 0;
  bool _hostJustConnected = false;

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _initialPairedCount = widget.controller.pairedDevices.length;
    _phoneNameController = TextEditingController(text: _defaultPhoneLabel());
    if (widget.controller.isPermanentRelayConfigured) {
      _permanentUrlController.text = widget.controller.relayEndpointUrl ?? '';
    }
    widget.controller.addListener(_onControllerChanged);

    final initialPayload = widget.initialPhonePairingPayload?.trim();
    if (initialPayload != null && initialPayload.isNotEmpty) {
      _step = _PairingStep.phoneEnterCode;
      _codeController.text = initialPayload;
      unawaited(_lookupPhoneCode(initialPayload));
    } else {
      _step = _PairingStep.hostQrDisplay;
      unawaited(_ensureHostInvitation());
    }
  }

  String _defaultPhoneLabel() {
    final custom = widget.controller.settings.deviceDisplayName.trim();
    if (custom.isNotEmpty) {
      return custom;
    }
    if (kIsWeb) {
      return 'My Phone';
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'My iPhone';
      case TargetPlatform.android:
        return 'My Android Phone';
      default:
        return 'My Phone';
    }
  }

  String _currentPlatformLabel() {
    if (kIsWeb) {
      return 'Mobile Web';
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'iOS';
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.windows:
        return 'Windows';
      default:
        return 'Phone';
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    _codeController.dispose();
    _permanentUrlController.dispose();
    _phoneNameController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) {
      return;
    }
    if (_step == _PairingStep.hostQrDisplay &&
        widget.controller.pairedDevices.length > _initialPairedCount) {
      _hostJustConnected = true;
    }
    if ((_step == _PairingStep.phoneEnterCode ||
            _step == _PairingStep.phoneConfirmHost) &&
        widget.controller.companionSession.isConnected) {
      _step = _PairingStep.phoneNotificationPrompt;
    }
    setState(() {});
  }

  void _startHostPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      if (_step == _PairingStep.hostQrDisplay && !_hostJustConnected) {
        unawaited(widget.controller.syncPairedDevicesFromRelay());
      }
      // Refresh countdown display
      setState(() {});
    });
  }

  Future<void> _ensureHostInvitation({bool forceRefresh = false}) async {
    final existing = widget.controller.activePairingInvitation;
    if (!forceRefresh &&
        existing != null &&
        !existing.isExpiredAt(DateTime.now())) {
      _startHostPolling();
      return;
    }

    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      await widget.controller.initiateHostPairing(
        hostDisplayName: widget.controller.effectiveDeviceName,
      );
      if (mounted) {
        _startHostPolling();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = _cleanErrorMessage(error);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _lookupPhoneCode(String rawInput) async {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _errorMessage = 'Enter the 6-character code shown on your laptop.';
      });
      return;
    }

    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      final preview = await widget.controller.lookupPairingInvitation(trimmed);
      if (!mounted) {
        return;
      }
      setState(() {
        _lookupPreview = preview;
        _pendingPayloadOrCode = trimmed;
        _step = _PairingStep.phoneConfirmHost;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = _cleanErrorMessage(error);
        _step = _PairingStep.phoneEnterCode;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _confirmPhoneConnect() async {
    final payload = _pendingPayloadOrCode ?? _codeController.text.trim();
    if (payload.isEmpty) {
      return;
    }
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      await widget.controller.pairAsCompanionPhone(
        pairingCodeOrPayload: payload,
        displayName: _phoneNameController.text.trim().isEmpty
            ? 'My Phone'
            : _phoneNameController.text.trim(),
        platform: _currentPlatformLabel(),
      );
      if (!mounted) {
        return;
      }
      final alreadyGranted =
          widget.controller.localNotificationPermissionStatus ==
          PermissionStatus.granted;
      if (alreadyGranted) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          _step = _PairingStep.phoneNotificationPrompt;
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = _cleanErrorMessage(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _requestNotificationsAfterPairing() async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    final status = await widget.controller.requestLocalNotificationPermission();
    if (!mounted) {
      return;
    }
    setState(() {
      _isBusy = false;
    });
    if (status == PermissionStatus.granted) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _infoMessage = 'Notifications are off in your device settings. You will still see alerts while WATSafe is open, and you can enable system notifications anytime in Settings.';
      });
    }
  }

  Future<void> _sendImmediateTestAlert() async {
    setState(() {
      _isBusy = true;
      _errorMessage = null;
      _infoMessage = null;
    });
    final res = await widget.controller.sendTestAlertToPairedPhone();
    if (!mounted) {
      return;
    }
    setState(() {
      _isBusy = false;
      if (res.delivered) {
        _infoMessage = res.message;
      } else {
        _errorMessage = res.message.isNotEmpty ? res.message : 'Could not deliver the test alert right now. Check your connection and try again.';
      }
    });
  }

  String _cleanErrorMessage(Object error) {
    final raw = '$error';
    if (raw.startsWith('Bad state: ')) {
      return raw.substring('Bad state: '.length);
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: palette.borderColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_hostJustConnected)
                _buildHostConnectedView(context)
              else
                switch (_step) {
                  _PairingStep.hostQrDisplay => _buildHostQrView(context),
                  _PairingStep.phoneEnterCode => _buildPhoneCodeEntryView(
                    context,
                  ),
                  _PairingStep.phoneConfirmHost => _buildPhoneConfirmHostView(
                    context,
                  ),
                  _PairingStep.phoneNotificationPrompt =>
                    _buildPhoneNotificationPromptView(context),
                },
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHostConnectedView(BuildContext context) {
    final latestPhone = widget.controller.pairedDevices.last;
    return Column(
      key: const Key('pairing_connected_confirmation'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Icon(
          Icons.check_circle_rounded,
          color: WatSafeTheme.readyEmerald,
          size: 52,
        ),
        const SizedBox(height: 12),
        Text(
          'Phone connected',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          '${latestPhone.displayName} is now paired with ${widget.controller.effectiveDeviceName}.',
          textAlign: TextAlign.center,
          style: TextStyle(color: WatSafeTheme.warmMuted, height: 1.4),
        ),
        if (_infoMessage != null) ...<Widget>[
          const SizedBox(height: 14),
          _StatusNotice(
            message: _infoMessage!,
            color: WatSafeTheme.readyEmerald,
            icon: Icons.mark_chat_read_rounded,
          ),
        ],
        if (_errorMessage != null) ...<Widget>[
          const SizedBox(height: 14),
          _StatusNotice(
            message: _errorMessage!,
            color: WatSafeTheme.alarmCrimson,
            icon: Icons.error_outline_rounded,
          ),
        ],
        const SizedBox(height: 22),
        FilledButton.icon(
          key: const Key('pairing_send_test_alert_button'),
          onPressed: _isBusy ? null : _sendImmediateTestAlert,
          icon: const Icon(Icons.notifications_active_rounded),
          label: Text(_isBusy ? 'Sending…' : 'Send test alert'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _buildHostQrView(BuildContext context) {
    final invite = widget.controller.activePairingInvitation;
    final now = DateTime.now();
    final isExpired = invite != null && invite.isExpiredAt(now);
    final remainingSeconds = invite?.remainingSecondsAt(now) ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Pair your phone',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Scan this with your phone’s camera.',
          style: TextStyle(
            color: WatSafeTheme.warmOffWhite,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        _buildCompanionAddressBanner(context),
        const SizedBox(height: 16),
        if (_isBusy && invite == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 44),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_errorMessage != null && invite == null) ...<Widget>[
          _StatusNotice(
            message: _errorMessage!,
            color: WatSafeTheme.alarmCrimson,
            icon: Icons.wifi_off_rounded,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('retry_pairing_button'),
            onPressed: _isBusy
                ? null
                : () => _ensureHostInvitation(forceRefresh: true),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ] else if (invite != null && isExpired) ...<Widget>[
          _StatusNotice(
            message: 'This pairing code expired for your security. Generate a fresh code to continue.',
            color: WatSafeTheme.amberAccent,
            icon: Icons.timer_off_outlined,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('refresh_pairing_code_button'),
            onPressed: _isBusy
                ? null
                : () => _ensureHostInvitation(forceRefresh: true),
            icon: const Icon(Icons.qr_code_2_rounded),
            label: const Text('Get new code'),
          ),
        ] else if (invite != null) ...<Widget>[
          Center(child: QrCodeWidget(data: invite.effectiveScanUrl, size: 216)),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: WatSafeTheme.charcoalElevated,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: WatSafeTheme.charcoalBorder),
            ),
            child: Column(
              children: <Widget>[
                Text(
                  'One-time pairing code',
                  style: TextStyle(
                    color: WatSafeTheme.warmMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    SelectableText(
                      invite.pairingCode,
                      key: const Key('active_pairing_code_label'),
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3,
                        color: WatSafeTheme.amberAccent,
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Copy code',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: invite.pairingCode),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Pairing code copied')),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                    ),
                  ],
                ),
                Text(
                  'Expires in ${_formatRemaining(remainingSeconds)}',
                  style: TextStyle(
                    color: WatSafeTheme.warmSubtle,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Can’t scan the QR code? Open WATSafe on your phone, tap Pair your phone, choose Enter code instead, and enter this code.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: WatSafeTheme.warmMuted,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        TextButton.icon(
          key: const Key('switch_to_phone_code_entry_button'),
          onPressed: _isBusy
              ? null
              : () {
                  setState(() {
                    _errorMessage = null;
                    _step = _PairingStep.phoneEnterCode;
                  });
                },
          icon: const Icon(Icons.smartphone_rounded, size: 18),
          label: const Text('Enter code instead (pair this phone)'),
        ),
      ],
    );
  }

  Widget _buildPhoneCodeEntryView(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Connect to your laptop',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Enter the 6-character code shown below the QR code on your laptop.',
          style: TextStyle(color: WatSafeTheme.warmMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('companion_code_or_qr_input'),
          controller: _codeController,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'One-time code',
            hintText: 'K7M-4P9',
          ),
          onSubmitted: _lookupPhoneCode,
        ),
        if (_errorMessage != null) ...<Widget>[
          const SizedBox(height: 12),
          _StatusNotice(
            message: _errorMessage!,
            color: WatSafeTheme.alarmCrimson,
            icon: Icons.error_outline_rounded,
          ),
        ],
        const SizedBox(height: 18),
        FilledButton(
          key: const Key('lookup_pairing_code_button'),
          onPressed: _isBusy
              ? null
              : () => _lookupPhoneCode(_codeController.text),
          child: Text(_isBusy ? 'Checking code…' : 'Continue'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _isBusy
              ? null
              : () {
                  setState(() {
                    _errorMessage = null;
                    _step = _PairingStep.hostQrDisplay;
                  });
                  unawaited(_ensureHostInvitation());
                },
          child: const Text('Show QR code for another phone instead'),
        ),
      ],
    );
  }

  Widget _buildPhoneConfirmHostView(BuildContext context) {
    final hostName = _lookupPreview?.hostDisplayName ?? 'your laptop';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Icon(
          Icons.laptop_mac_rounded,
          color: WatSafeTheme.amberAccent,
          size: 44,
        ),
        const SizedBox(height: 12),
        Text(
          'Connect to $hostName?',
          key: const Key('connect_to_host_title'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          'This phone will receive alerts and device location if $hostName triggers an alarm.',
          textAlign: TextAlign.center,
          style: TextStyle(color: WatSafeTheme.warmMuted, height: 1.4),
        ),
        const SizedBox(height: 18),
        TextField(
          key: const Key('companion_phone_name_input'),
          controller: _phoneNameController,
          decoration: const InputDecoration(
            labelText: 'This phone’s name',
            hintText: 'My iPhone',
          ),
        ),
        if (_errorMessage != null) ...<Widget>[
          const SizedBox(height: 12),
          _StatusNotice(
            message: _errorMessage!,
            color: WatSafeTheme.alarmCrimson,
            icon: Icons.error_outline_rounded,
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('confirm_connect_phone_button'),
          onPressed: _isBusy ? null : _confirmPhoneConnect,
          child: Text(_isBusy ? 'Connecting…' : 'Connect'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _isBusy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildPhoneNotificationPromptView(BuildContext context) {
    final hostName =
        widget.controller.companionSession.hostDisplayName ??
        _lookupPreview?.hostDisplayName ??
        'your laptop';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Icon(
          Icons.notifications_active_rounded,
          color: WatSafeTheme.readyEmerald,
          size: 48,
        ),
        const SizedBox(height: 12),
        Text(
          'Connected to $hostName',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          'Allow notifications so this phone can alert you right away when $hostName detects motion — and take you straight to the event and map when tapped.',
          textAlign: TextAlign.center,
          style: TextStyle(color: WatSafeTheme.warmMuted, height: 1.4),
        ),
        if (_infoMessage != null) ...<Widget>[
          const SizedBox(height: 14),
          _StatusNotice(
            message: _infoMessage!,
            color: WatSafeTheme.amberAccent,
            icon: Icons.info_outline_rounded,
          ),
        ],
        const SizedBox(height: 20),
        if (_infoMessage == null)
          FilledButton.icon(
            key: const Key('enable_phone_notifications_button'),
            onPressed: _isBusy ? null : _requestNotificationsAfterPairing,
            icon: const Icon(Icons.notifications_rounded),
            label: Text(_isBusy ? 'Requesting…' : 'Turn on notifications'),
          ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('finish_phone_pairing_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_infoMessage == null ? 'Not now' : 'Done'),
        ),
      ],
    );
  }

  Future<void> _savePermanentUrlFromSheet() async {
    final trimmed = _permanentUrlController.text.trim();
    setState(() {
      _isBusy = true;
      _errorMessage = null;
      _infoMessage = null;
    });
    final ok = await widget.controller.savePermanentRelayEndpoint(trimmed);
    if (!mounted) {
      return;
    }
    if (!ok) {
      setState(() {
        _isBusy = false;
        _errorMessage =
            widget.controller.warningMessage ??
            'Enter a permanent https:// address (not a temporary tunnel).';
      });
      return;
    }
    setState(() {
      _showPermanentUrlEditor = false;
      _infoMessage = 'Permanent companion address saved. Scan this new QR code once in Safari and replace any old Home Screen icon.';
    });
    await _ensureHostInvitation(forceRefresh: true);
  }

  Widget _buildCompanionAddressBanner(BuildContext context) {
    final currentUrl = widget.controller.relayEndpointUrl ?? '';
    final isPermanent = widget.controller.isPermanentRelayConfigured;
    final isEphemeral = widget.controller.isEphemeralTunnelRelay;

    if (isPermanent) {
      return Container(
        key: const Key('companion_address_status_banner'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: WatSafeTheme.readyEmerald.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: WatSafeTheme.readyEmerald.withValues(alpha: 0.45),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.verified_rounded,
              color: WatSafeTheme.readyEmerald,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Permanent HTTPS companion ($currentUrl/companion) — one-time Home Screen install and pairing survive restarts.',
                style: TextStyle(
                  color: WatSafeTheme.warmOffWhite,
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final headline = isEphemeral
        ? 'Temporary tunnel address — one-time cloud deploy needed for permanent Home Screen icon'
        : 'Local address — deploy or set a permanent HTTPS address for iPhone Home Screen install';
    final detail = isEphemeral
        ? 'Temporary *.trycloudflare.com tunnels expire when restarted, causing an old Home Screen bookmark to open a white error page. Deploy the permanent relay with Aiven PostgreSQL (render.yaml + AIVEN_DATABASE_URL secret, or a Named Cloudflare Tunnel), save its https:// address below, remove the old iPhone bookmark, and pair one final time.'
        : 'iPhone Home Screen notifications require a permanent HTTPS domain. Deploy render.yaml with AIVEN_DATABASE_URL in Render secrets (or a Named Cloudflare Tunnel), then save its https:// address here.';

    return Container(
      key: const Key('companion_address_status_banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: WatSafeTheme.amberAccent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: WatSafeTheme.amberAccent.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.cloud_queue_rounded,
                color: WatSafeTheme.amberAccent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline,
                  style: TextStyle(
                    color: WatSafeTheme.amberAccent,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: TextStyle(
              color: WatSafeTheme.warmMuted,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('toggle_permanent_url_editor_button'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              onPressed: _isBusy
                  ? null
                  : () {
                      setState(() {
                        _showPermanentUrlEditor = !_showPermanentUrlEditor;
                      });
                    },
              icon: Icon(
                _showPermanentUrlEditor
                    ? Icons.expand_less_rounded
                    : Icons.link_rounded,
                size: 16,
              ),
              label: Text(
                _showPermanentUrlEditor
                    ? 'Hide permanent address setup'
                    : 'Set permanent HTTPS address',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          ),
          if (_showPermanentUrlEditor) ...<Widget>[
            const SizedBox(height: 8),
            TextField(
              key: const Key('pairing_permanent_url_input'),
              controller: _permanentUrlController,
              decoration: const InputDecoration(
                labelText: 'Permanent HTTPS address',
                hintText: 'https://<your-render-service>.onrender.com',
                isDense: true,
              ),
              onSubmitted: (_) => _savePermanentUrlFromSheet(),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const Key('pairing_save_permanent_url_button'),
              onPressed: _isBusy ? null : _savePermanentUrlFromSheet,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save permanent address & refresh QR'),
            ),
          ],
        ],
      ),
    );
  }

  String _formatRemaining(int totalSeconds) {
    final mins = totalSeconds ~/ 60;
    final secs = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }
}

class _ConnectedPhoneDetailsBody extends StatefulWidget {
  const _ConnectedPhoneDetailsBody({required this.controller});

  final AlarmController controller;

  @override
  State<_ConnectedPhoneDetailsBody> createState() =>
      _ConnectedPhoneDetailsBodyState();
}

class _ConnectedPhoneDetailsBodyState
    extends State<_ConnectedPhoneDetailsBody> {
  bool _isBusy = false;
  String? _feedbackMessage;
  bool _feedbackIsError = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    unawaited(widget.controller.syncPairedDevicesFromRelay());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _handleSendTestAlert() async {
    setState(() {
      _isBusy = true;
      _feedbackMessage = null;
    });
    final res = await widget.controller.sendTestAlertToPairedPhone();
    if (!mounted) {
      return;
    }
    setState(() {
      _isBusy = false;
      _feedbackIsError = !res.delivered;
      _feedbackMessage = res.message.isNotEmpty
          ? res.message
          : (res.delivered
                ? 'Push service accepted test alert — awaiting phone receipt.'
                : 'Could not reach your phone right now. Check your connection and try again.');
    });
  }

  Future<void> _handleDisconnectHostPhone(PairedDeviceSummary phone) async {
    setState(() {
      _isBusy = true;
    });
    await widget.controller.unpairCompanionDevice(phone.deviceId);
    if (!mounted) {
      return;
    }
    if (widget.controller.pairedDevices.isEmpty) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _isBusy = false;
      });
    }
  }

  Future<void> _handleDisconnectCompanion() async {
    setState(() {
      _isBusy = true;
    });
    await widget.controller.disconnectCompanionSession();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final devices = widget.controller.pairedDevices;
    final companion = widget.controller.companionSession;

    if (devices.isEmpty && companion.isConnected) {
      return _buildCompanionModeDetails(context, companion);
    }

    if (devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('No phone is connected right now.'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }

    final primaryPhone = devices.first;
    final isConnected = primaryPhone.connected;
    final notifEnabled = primaryPhone.notificationsEnabled;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: palette.borderColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Icon(
                    Icons.smartphone_rounded,
                    color: isConnected
                        ? WatSafeTheme.readyEmerald
                        : WatSafeTheme.warmMuted,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          primaryPhone.displayName,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          isConnected ? 'Phone connected' : 'Disconnected',
                          style: TextStyle(
                            color: isConnected
                                ? WatSafeTheme.readyEmerald
                                : WatSafeTheme.amberAccent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: WatSafeTheme.charcoalElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: WatSafeTheme.charcoalBorder),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      notifEnabled
                          ? Icons.notifications_active_rounded
                          : Icons.notifications_paused_rounded,
                      color: notifEnabled
                          ? WatSafeTheme.readyEmerald
                          : WatSafeTheme.amberAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        notifEnabled
                            ? 'Notifications are enabled on ${primaryPhone.displayName}.'
                            : switch (primaryPhone.notificationChannel) {
                                'needs_https' =>
                                  '${primaryPhone.displayName} is paired over plain HTTP. Open WATSafe over HTTPS on your phone to enable lock-screen notifications.',
                                'needs_home_screen' =>
                                  '${primaryPhone.displayName} is paired in Safari. On iPhone, tap Share → Add to Home Screen, open the WATSafe icon, and tap Enable notifications.',
                                'pending_permission' || 'pending_setup' =>
                                  '${primaryPhone.displayName} is paired. Tap Enable notifications on your phone to finish lock-screen push setup.',
                                _ =>
                                  'System notifications are off on ${primaryPhone.displayName}. Alerts still appear when WATSafe is open; turn on notifications on your phone for lock-screen alerts.',
                              },
                        style: TextStyle(
                          color: WatSafeTheme.warmOffWhite,
                          fontSize: 13.5,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_feedbackMessage != null) ...<Widget>[
                const SizedBox(height: 14),
                _StatusNotice(
                  message: _feedbackMessage!,
                  color: _feedbackIsError
                      ? WatSafeTheme.alarmCrimson
                      : WatSafeTheme.readyEmerald,
                  icon: _feedbackIsError
                      ? Icons.error_outline_rounded
                      : Icons.check_circle_outline_rounded,
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('send_test_alert_button'),
                onPressed: (_isBusy || !isConnected)
                    ? null
                    : _handleSendTestAlert,
                icon: const Icon(Icons.send_rounded),
                label: Text(_isBusy ? 'Sending…' : 'Send test alert'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const Key('disconnect_phone_button'),
                onPressed: _isBusy
                    ? null
                    : () => _handleDisconnectHostPhone(primaryPhone),
                style: OutlinedButton.styleFrom(
                  foregroundColor: WatSafeTheme.alarmCrimson,
                ),
                icon: const Icon(Icons.link_off_rounded),
                label: const Text('Disconnect phone'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompanionModeDetails(
    BuildContext context,
    CompanionSessionState companion,
  ) {
    final perm = widget.controller.localNotificationPermissionStatus;
    final notifOn =
        perm == PermissionStatus.granted || companion.notificationsEnabled;
    final hostLabel = companion.hostDisplayName ?? 'your laptop';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: WatSafeTheme.charcoalBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Paired with $hostLabel',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                companion.statusMessage ?? 'Connected',
                style: TextStyle(color: WatSafeTheme.readyEmerald),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: WatSafeTheme.charcoalElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: WatSafeTheme.charcoalBorder),
                ),
                child: Text(
                  notifOn
                      ? (companion.pushServerConfigured
                            ? 'Lock-screen and background notifications are enabled.'
                            : 'System notifications are enabled while WATSafe is active.')
                      : (perm == PermissionStatus.denied
                            ? 'Notifications are blocked in your phone or browser settings. Open system Settings > Notifications to re-enable lock-screen alerts. Foreground alerts remain active while WATSafe is open.'
                            : (perm == PermissionStatus.notApplicable
                                  ? 'Open WATSafe over HTTPS and, on iPhone, add WATSafe to your Home Screen and open its icon to enable lock-screen notifications.'
                                  : 'Foreground alerts are active while WATSafe is open. Turn on notifications below to receive system alerts.')),
                  style: TextStyle(
                    color: WatSafeTheme.warmOffWhite,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (!notifOn &&
                  perm != PermissionStatus.denied &&
                  perm != PermissionStatus.notApplicable) ...<Widget>[
                FilledButton.icon(
                  onPressed: _isBusy
                      ? null
                      : () async {
                          setState(() => _isBusy = true);
                          await widget.controller
                              .requestLocalNotificationPermission();
                          if (mounted) {
                            setState(() => _isBusy = false);
                          }
                        },
                  icon: const Icon(Icons.notifications_active_rounded),
                  label: const Text('Turn on notifications'),
                ),
                const SizedBox(height: 10),
              ],
              OutlinedButton.icon(
                key: const Key('disconnect_companion_button'),
                onPressed: _isBusy ? null : _handleDisconnectCompanion,
                style: OutlinedButton.styleFrom(
                  foregroundColor: WatSafeTheme.alarmCrimson,
                ),
                icon: const Icon(Icons.link_off_rounded),
                label: const Text('Disconnect phone'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusNotice extends StatelessWidget {
  const _StatusNotice({
    required this.message,
    required this.color,
    required this.icon,
  });

  final String message;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: color, size: 19),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
