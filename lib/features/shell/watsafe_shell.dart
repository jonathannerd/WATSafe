import 'package:flutter/material.dart';

import '../../core/alarm/alarm_controller.dart';
import '../../core/alarm/alarm_state.dart';
import '../alarm/active_alarm_overlay.dart';
import '../dashboard/dashboard_screen.dart';
import '../incidents/incidents_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../paired_devices/paired_devices_screen.dart';
import '../settings/settings_screen.dart';
import '../theme/watsafe_theme.dart';

/// Adaptive Material 3 shell for desktop and mobile layouts.
///
/// Routes to [OnboardingScreen] until the user configures a 6+ digit PIN,
/// elevates [ActiveAlarmScreen] whenever an alarm is active, and provides
/// responsive navigation across Dashboard, Incidents, Paired Devices, and Settings.
class WatSafeShell extends StatefulWidget {
  const WatSafeShell({super.key, required this.controller});

  final AlarmController controller;

  @override
  State<WatSafeShell> createState() => _WatSafeShellState();
}

class _WatSafeShellState extends State<WatSafeShell> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (!widget.controller.isInitialized) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (!widget.controller.hasPinConfigured) {
          return OnboardingScreen(controller: widget.controller);
        }

        if (widget.controller.state == ProtectionState.alarming) {
          return Scaffold(
            body: SafeArea(
              child: ActiveAlarmScreen(controller: widget.controller),
            ),
          );
        }

        final state = widget.controller.state;
        final stateColor = WatSafeTheme.colorForProtectionState(state);

        final pages = <Widget>[
          DashboardScreen(controller: widget.controller),
          IncidentsScreen(controller: widget.controller),
          PairedDevicesScreen(controller: widget.controller),
          SettingsScreen(controller: widget.controller),
        ];

        return LayoutBuilder(
          builder: (context, constraints) {
            final useRail = constraints.maxWidth >= 760;

            return Scaffold(
              appBar: AppBar(
                title: Row(
                  children: <Widget>[
                    WatSafeShieldGraphic(
                      accentColor: stateColor,
                      size: 32,
                      isActiveWave: state.isProtected,
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'WATSafe',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: stateColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: stateColor),
                      ),
                      child: Text(
                        state.badgeLabel,
                        style: TextStyle(
                          color: stateColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
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
                        label: const Text('Stop Test Alarm'),
                      ),
                    ),
                ],
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(1),
                  child: Container(
                    height: 1,
                    color: WatSafeTheme.charcoalBorder,
                  ),
                ),
              ),
              body: Row(
                children: <Widget>[
                  if (useRail) ...<Widget>[
                    NavigationRail(
                      backgroundColor: WatSafeTheme.charcoalDeep,
                      selectedIndex: _selectedIndex,
                      labelType: NavigationRailLabelType.all,
                      indicatorColor: WatSafeTheme.amberAccent.withValues(
                        alpha: 0.22,
                      ),
                      selectedIconTheme: const IconThemeData(
                        color: WatSafeTheme.amberAccent,
                      ),
                      selectedLabelTextStyle: const TextStyle(
                        color: WatSafeTheme.amberAccent,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                      unselectedLabelTextStyle: const TextStyle(
                        color: WatSafeTheme.warmMuted,
                        fontSize: 12,
                      ),
                      onDestinationSelected: (idx) {
                        setState(() {
                          _selectedIndex = idx;
                        });
                      },
                      destinations: const <NavigationRailDestination>[
                        NavigationRailDestination(
                          icon: Icon(Icons.shield_outlined),
                          selectedIcon: Icon(Icons.shield),
                          label: Text('Protection'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.history_outlined),
                          selectedIcon: Icon(Icons.history),
                          label: Text('Incidents'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.devices_other_outlined),
                          selectedIcon: Icon(Icons.devices_other),
                          label: Text('Paired Devices'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings),
                          label: Text('Settings'),
                        ),
                      ],
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                  ],
                  Expanded(child: pages[_selectedIndex]),
                ],
              ),
              bottomNavigationBar: useRail
                  ? null
                  : NavigationBar(
                      backgroundColor: WatSafeTheme.charcoalSurface,
                      indicatorColor: WatSafeTheme.amberAccent.withValues(
                        alpha: 0.22,
                      ),
                      selectedIndex: _selectedIndex,
                      onDestinationSelected: (idx) {
                        setState(() {
                          _selectedIndex = idx;
                        });
                      },
                      destinations: const <NavigationDestination>[
                        NavigationDestination(
                          icon: Icon(Icons.shield_outlined),
                          selectedIcon: Icon(Icons.shield),
                          label: 'Protection',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.history_outlined),
                          selectedIcon: Icon(Icons.history),
                          label: 'Incidents',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.devices_other_outlined),
                          selectedIcon: Icon(Icons.devices_other),
                          label: 'Paired',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings),
                          label: 'Settings',
                        ),
                      ],
                    ),
            );
          },
        );
      },
    );
  }
}
