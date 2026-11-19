import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/alarm/alarm_state.dart';
import '../activity/activity_screen.dart';
import '../alarm/active_alarm_overlay.dart';
import '../devices/devices_screen.dart';
import '../home/home_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../pairing/phone_pairing_sheet.dart';
import '../settings/settings_screen.dart';
import '../theme/watsafe_theme.dart';

/// Adaptive Material 3 shell around WATSafe's four primary destinations:
/// **Home**, **Devices**, **Activity**, and **Settings**.
class WatSafeShell extends StatefulWidget {
  const WatSafeShell({
    super.key,
    required this.controller,
    this.initialPairingPayload,
  });

  final AlarmController controller;
  final String? initialPairingPayload;

  @override
  State<WatSafeShell> createState() => _WatSafeShellState();
}

class _WatSafeShellState extends State<WatSafeShell>
    with WidgetsBindingObserver {
  int _selectedIndex = 0;
  int _lastHandledOpenActivityNonce = 0;
  bool _handledInitialPairingLink = false;
  StreamSubscription<String>? _openIncidentSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindController();
  }

  @override
  void didUpdateWidget(covariant WatSafeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.initialPairingPayload != widget.initialPairingPayload) {
      unawaited(_openIncidentSub?.cancel());
      _handledInitialPairingLink = false;
      _bindController();
    }
  }

  static const int _activityTabIndex = 2;

  void _bindController() {
    _lastHandledOpenActivityNonce = widget.controller.openActivityNonce;
    if (widget.controller.selectedActivityIncidentId != null) {
      _selectedIndex = _activityTabIndex;
    }
    _openIncidentSub = widget.controller.onOpenActivityIncident.listen((_) {
      if (mounted && _selectedIndex != _activityTabIndex) {
        setState(() {
          _selectedIndex = _activityTabIndex;
        });
      }
    });
  }

  @override
  void dispose() {
    unawaited(_openIncidentSub?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(widget.controller.handleAppLifecycleState(state));
  }

  void _maybeOpenInitialPairingSheet() {
    if (_handledInitialPairingLink) {
      return;
    }
    final payload = widget.initialPairingPayload?.trim();
    if (payload == null || payload.isEmpty) {
      return;
    }
    if (!widget.controller.isInitialized) {
      return;
    }
    _handledInitialPairingLink = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        showPhonePairingSheet(
          context,
          widget.controller,
          initialPhonePairingPayload: payload,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final palette = WatSafeTheme.of(context);

        if (!widget.controller.isInitialized) {
          return Scaffold(
            backgroundColor: palette.backgroundDeep,
            body: Center(
              child: CircularProgressIndicator(color: palette.accentPrimary),
            ),
          );
        }

        _maybeOpenInitialPairingSheet();

        if (widget.controller.openActivityNonce !=
            _lastHandledOpenActivityNonce) {
          _lastHandledOpenActivityNonce = widget.controller.openActivityNonce;
          _selectedIndex = _activityTabIndex;
        }

        final hasIncomingPairingLink =
            widget.initialPairingPayload?.trim().isNotEmpty == true;
        if (widget.controller.isPreviewingOnboarding) {
          return OnboardingScreen(
            controller: widget.controller,
            isPreviewMode: true,
          );
        }
        if (!widget.controller.hasPinConfigured &&
            !widget.controller.companionSession.isConnected &&
            !hasIncomingPairingLink) {
          _selectedIndex = 0;
          return OnboardingScreen(controller: widget.controller);
        }

        if (widget.controller.state == ProtectionState.alarming) {
          return Scaffold(
            backgroundColor: palette.backgroundDeep,
            body: SafeArea(
              child: ActiveAlarmScreen(controller: widget.controller),
            ),
          );
        }

        final state = widget.controller.state;
        final stateColor = WatSafeTheme.colorForProtectionState(state, palette);

        final pages = <Widget>[
          HomeScreen(controller: widget.controller),
          DevicesScreen(controller: widget.controller),
          ActivityScreen(controller: widget.controller),
          SettingsScreen(controller: widget.controller),
        ];

        final safeIndex = _selectedIndex.clamp(0, pages.length - 1);

        return LayoutBuilder(
          builder: (context, constraints) {
            final useRail = constraints.maxWidth >= 760;

            return Scaffold(
              backgroundColor: palette.backgroundDeep,
              appBar: AppBar(
                backgroundColor: palette.sidebarBackground,
                foregroundColor: palette.textPrimary,
                title: Row(
                  children: <Widget>[
                    WatSafeShieldGraphic(
                      accentColor: state == ProtectionState.disarmed
                          ? palette.accentPrimary
                          : stateColor,
                      size: 30,
                      isActiveWave: state.isProtected,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'WATSafe',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
                actions: <Widget>[
                  if (widget.controller.isTestAlarmRunning)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: FilledButton.tonalIcon(
                        onPressed: widget.controller.stopTestAlarm,
                        icon: const Icon(Icons.stop_circle_outlined, size: 18),
                        label: const Text('Stop siren test'),
                      ),
                    ),
                ],
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(1),
                  child: Container(
                    key: const Key('app_header_divider'),
                    height: 1,
                    color: palette.sidebarBorder,
                  ),
                ),
              ),
              body: Row(
                children: <Widget>[
                  if (useRail) ...<Widget>[
                    NavigationRail(
                      key: const Key('desktop_navigation_rail'),
                      backgroundColor: palette.sidebarBackground,
                      selectedIndex: safeIndex,
                      labelType: NavigationRailLabelType.all,
                      useIndicator: true,
                      indicatorColor: palette.sidebarIndicator,
                      indicatorShape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: palette.accentPrimary.withValues(
                            alpha: palette.isDark ? 0.50 : 0.38,
                          ),
                          width: 1,
                        ),
                      ),
                      selectedIconTheme: IconThemeData(
                        color: palette.accentPrimary,
                        size: 23,
                      ),
                      unselectedIconTheme: IconThemeData(
                        color: palette.textMuted,
                        size: 22,
                      ),
                      selectedLabelTextStyle: TextStyle(
                        color: palette.accentPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                      unselectedLabelTextStyle: TextStyle(
                        color: palette.textMuted,
                        fontWeight: FontWeight.w500,
                        fontSize: 12.5,
                      ),
                      onDestinationSelected: (idx) {
                        setState(() {
                          _selectedIndex = idx;
                        });
                      },
                      destinations: const <NavigationRailDestination>[
                        NavigationRailDestination(
                          icon: Icon(Icons.shield_outlined),
                          selectedIcon: Icon(Icons.shield_rounded),
                          label: Text('Home'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.map_outlined),
                          selectedIcon: Icon(Icons.map_rounded),
                          label: Text('Devices'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.notifications_none_rounded),
                          selectedIcon: Icon(Icons.notifications_rounded),
                          label: Text('Activity'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings_rounded),
                          label: Text('Settings'),
                        ),
                      ],
                    ),
                    VerticalDivider(
                      key: const Key('desktop_sidebar_divider'),
                      width: 1,
                      thickness: 1,
                      color: palette.sidebarBorder,
                    ),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (widget
                                .controller
                                .latestUnacknowledgedCompanionAlert !=
                            null)
                          _ForegroundCompanionBanner(
                            controller: widget.controller,
                            onViewEvent: (incidentId) {
                              setState(() {
                                _selectedIndex = _activityTabIndex;
                              });
                              widget.controller.openIncidentInActivity(
                                incidentId,
                              );
                            },
                          ),
                        Expanded(child: pages[safeIndex]),
                      ],
                    ),
                  ),
                ],
              ),
              bottomNavigationBar: useRail
                  ? null
                  : Container(
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(color: palette.sidebarBorder),
                        ),
                      ),
                      child: NavigationBar(
                        key: const Key('compact_navigation_bar'),
                        backgroundColor: palette.sidebarBackground,
                        indicatorColor: palette.sidebarIndicator,
                        selectedIndex: safeIndex,
                        onDestinationSelected: (idx) {
                          setState(() {
                            _selectedIndex = idx;
                          });
                        },
                        destinations: const <NavigationDestination>[
                          NavigationDestination(
                            icon: Icon(Icons.shield_outlined),
                            selectedIcon: Icon(Icons.shield_rounded),
                            label: 'Home',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.map_outlined),
                            selectedIcon: Icon(Icons.map_rounded),
                            label: 'Devices',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.notifications_none_rounded),
                            selectedIcon: Icon(Icons.notifications_rounded),
                            label: 'Activity',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.settings_outlined),
                            selectedIcon: Icon(Icons.settings_rounded),
                            label: 'Settings',
                          ),
                        ],
                      ),
                    ),
            );
          },
        );
      },
    );
  }
}

class _ForegroundCompanionBanner extends StatelessWidget {
  const _ForegroundCompanionBanner({
    required this.controller,
    required this.onViewEvent,
  });

  final AlarmController controller;
  final ValueChanged<String> onViewEvent;

  @override
  Widget build(BuildContext context) {
    final palette = WatSafeTheme.of(context);
    final alert = controller.latestUnacknowledgedCompanionAlert!;
    final deviceName = alert.hostDisplayName ?? 'Your Laptop';
    final bannerColor = alert.isTest ? palette.infoColor : palette.alarmColor;

    return Material(
      color: bannerColor,
      child: InkWell(
        key: const Key('remote_laptop_alarm_banner'),
        onTap: () => onViewEvent(alert.incidentId),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: <Widget>[
              Icon(
                alert.isTest
                    ? Icons.notifications_active_rounded
                    : Icons.warning_amber_rounded,
                color: Colors.white,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      alert.isTest
                          ? '$deviceName • Test alert'
                          : '$deviceName • Alarm triggered',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      alert.triggerSummary,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                key: const Key('view_alert_in_activity_button'),
                onPressed: () => onViewEvent(alert.incidentId),
                child: const Text(
                  'View event',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                key: const Key('dismiss_remote_alarm_banner_button'),
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: controller.dismissCompanionAlertBanner,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
