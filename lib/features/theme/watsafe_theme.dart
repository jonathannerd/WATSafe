import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../core/alarm/alarm_state.dart';
import '../../core/models/detector_models.dart';

/// WATSafe color palette and Material 3 theme definition.
/// Uses charcoal surfaces, warm off-white text/cards, and restrained amber/orange accents.
class WatSafeTheme {
  static const Color charcoalDeep = Color(0xFF141619);
  static const Color charcoalSurface = Color(0xFF1D2025);
  static const Color charcoalElevated = Color(0xFF262A31);
  static const Color charcoalBorder = Color(0xFF363C46);

  static const Color warmOffWhite = Color(0xFFF5F2EB);
  static const Color warmMuted = Color(0xFFC8C2B6);
  static const Color warmSubtle = Color(0xFF948E83);

  static const Color amberAccent = Color(0xFFE58E26);
  static const Color orangeAccent = Color(0xFFD96B27);
  static const Color alarmCrimson = Color(0xFFD6453A);
  static const Color readyEmerald = Color(0xFF2E9B68);
  static const Color infoSteel = Color(0xFF4F86C6);

  static ThemeData darkTheme() {
    const colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: amberAccent,
      onPrimary: charcoalDeep,
      primaryContainer: Color(0xFF4A3010),
      onPrimaryContainer: warmOffWhite,
      secondary: orangeAccent,
      onSecondary: charcoalDeep,
      secondaryContainer: Color(0xFF462614),
      onSecondaryContainer: warmOffWhite,
      tertiary: readyEmerald,
      onTertiary: charcoalDeep,
      error: alarmCrimson,
      onError: warmOffWhite,
      surface: charcoalSurface,
      onSurface: warmOffWhite,
      onSurfaceVariant: warmMuted,
      outline: charcoalBorder,
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: kIsWeb ? 'Roboto' : null,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: charcoalDeep,
      cardTheme: CardThemeData(
        color: charcoalSurface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: charcoalBorder, width: 1),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: charcoalDeep,
        foregroundColor: warmOffWhite,
        elevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: charcoalElevated,
        labelStyle: const TextStyle(color: warmMuted),
        hintStyle: const TextStyle(color: warmSubtle),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: charcoalBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: charcoalBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: amberAccent, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: amberAccent,
          foregroundColor: charcoalDeep,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: warmOffWhite,
          side: const BorderSide(color: charcoalBorder),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      dividerTheme: const DividerThemeData(color: charcoalBorder, thickness: 1),
    );
  }

  static Color colorForProtectionState(ProtectionState state) {
    switch (state) {
      case ProtectionState.disarmed:
        return warmMuted;
      case ProtectionState.arming:
        return amberAccent;
      case ProtectionState.armed:
        return readyEmerald;
      case ProtectionState.alarming:
        return alarmCrimson;
      case ProtectionState.paused:
        return orangeAccent;
      case ProtectionState.unavailable:
        return warmSubtle;
    }
  }

  static Color colorForCapabilityStatus(CapabilityStatus status) {
    switch (status) {
      case CapabilityStatus.ready:
        return readyEmerald;
      case CapabilityStatus.supported:
        return infoSteel;
      case CapabilityStatus.permissionRequired:
        return amberAccent;
      case CapabilityStatus.degraded:
        return orangeAccent;
      case CapabilityStatus.unsupported:
        return alarmCrimson;
      case CapabilityStatus.notImplemented:
      case CapabilityStatus.notConfigured:
        return warmSubtle;
    }
  }

  static String labelForCapabilityStatus(CapabilityStatus status) {
    switch (status) {
      case CapabilityStatus.ready:
        return 'READY';
      case CapabilityStatus.supported:
        return 'SUPPORTED';
      case CapabilityStatus.permissionRequired:
        return 'PERMISSION REQUIRED';
      case CapabilityStatus.degraded:
        return 'DEGRADED INPUT';
      case CapabilityStatus.unsupported:
        return 'UNSUPPORTED';
      case CapabilityStatus.notImplemented:
        return 'NOT IMPLEMENTED';
      case CapabilityStatus.notConfigured:
        return 'NOT CONFIGURED';
    }
  }
}

/// Original custom-painted WATSafe shield and sensor wave emblem.
class WatSafeShieldGraphic extends StatelessWidget {
  const WatSafeShieldGraphic({
    super.key,
    required this.accentColor,
    this.size = 64,
    this.isActiveWave = false,
  });

  final Color accentColor;
  final double size;
  final bool isActiveWave;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _WatSafeShieldPainter(
          accentColor: accentColor,
          isActiveWave: isActiveWave,
        ),
      ),
    );
  }
}

class _WatSafeShieldPainter extends CustomPainter {
  _WatSafeShieldPainter({
    required this.accentColor,
    required this.isActiveWave,
  });

  final Color accentColor;
  final bool isActiveWave;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Outer subtle ring
    final ringPaint = Paint()
      ..color = accentColor.withValues(alpha: isActiveWave ? 0.25 : 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, radius - 2, ringPaint);

    if (isActiveWave) {
      final arcPaint = Paint()
        ..color = accentColor.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 7),
        -math.pi * 0.75,
        math.pi * 0.5,
        false,
        arcPaint,
      );
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 7),
        math.pi * 0.25,
        math.pi * 0.5,
        false,
        arcPaint,
      );
    }

    // Shield path
    final w = size.width * 0.52;
    final h = size.height * 0.58;
    final top = center.dy - h * 0.48;
    final bottom = center.dy + h * 0.52;
    final left = center.dx - w * 0.5;
    final right = center.dx + w * 0.5;

    final shield = Path()
      ..moveTo(center.dx, top)
      ..lineTo(right, top + h * 0.18)
      ..lineTo(right, top + h * 0.52)
      ..quadraticBezierTo(right, bottom - h * 0.12, center.dx, bottom)
      ..quadraticBezierTo(left, bottom - h * 0.12, left, top + h * 0.52)
      ..lineTo(left, top + h * 0.18)
      ..close();

    final fillPaint = Paint()
      ..color = accentColor.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    canvas.drawPath(shield, fillPaint);

    final borderPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(shield, borderPaint);

    // Inner sensor core dot
    final corePaint = Paint()
      ..color = WatSafeTheme.warmOffWhite
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(center.dx, center.dy + h * 0.02),
      size.width * 0.06,
      corePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _WatSafeShieldPainter oldDelegate) {
    return oldDelegate.accentColor != accentColor ||
        oldDelegate.isActiveWave != isActiveWave;
  }
}
