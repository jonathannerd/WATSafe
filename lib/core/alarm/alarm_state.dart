/// Explicit states of the central WATSafe protection state machine.
enum ProtectionState {
  /// Protection is off; no active countdown, monitoring, or alarm.
  disarmed(displayName: 'Disarmed', badgeLabel: 'DISARMED', isProtected: false),

  /// Countdown and/or initial sensor calibration is in progress.
  arming(displayName: 'Arming', badgeLabel: 'ARMING', isProtected: false),

  /// Active monitoring session is running with a healthy detector.
  armed(displayName: 'Protected', badgeLabel: 'PROTECTED', isProtected: true),

  /// Motion or tamper event triggered the active siren; requires PIN to disarm.
  alarming(
    displayName: 'Alarm Active',
    badgeLabel: 'ALARMING',
    isProtected: true,
  ),

  /// Monitoring was paused by OS lifecycle (sleep, backgrounding, lid closure).
  /// Explicitly NOT showing "Protected".
  paused(
    displayName: 'Monitoring Paused',
    badgeLabel: 'PAUSED',
    isProtected: false,
  ),

  /// Selected detector is unavailable, missing permission, unimplemented, or failed.
  unavailable(
    displayName: 'Unavailable',
    badgeLabel: 'UNAVAILABLE',
    isProtected: false,
  );

  const ProtectionState({
    required this.displayName,
    required this.badgeLabel,
    required this.isProtected,
  });

  final String displayName;
  final String badgeLabel;

  /// True only when monitoring is actively armed or alarming.
  /// Never true when paused, unavailable, arming, or disarmed.
  final bool isProtected;
}
