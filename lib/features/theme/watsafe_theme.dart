import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/alarm/alarm_state.dart';
import '../../core/models/detector_models.dart';
import '../../core/models/settings_models.dart';

/// Color palette tokens for a [WatSafeColorTheme].
class WatSafePalette {
  const WatSafePalette({
    required this.brightness,
    required this.backgroundDeep,
    required this.surfaceCard,
    required this.surfaceElevated,
    required this.borderColor,
    required this.textPrimary,
    required this.textMuted,
    required this.textSubtle,
    required this.accentPrimary,
    required this.accentSecondary,
    required this.readyColor,
    required this.alarmColor,
    required this.infoColor,
    required this.onAccentColor,
  });

  final Brightness brightness;
  final Color backgroundDeep;
  final Color surfaceCard;
  final Color surfaceElevated;
  final Color borderColor;
  final Color textPrimary;
  final Color textMuted;
  final Color textSubtle;
  final Color accentPrimary;
  final Color accentSecondary;
  final Color readyColor;
  final Color alarmColor;
  final Color infoColor;
  final Color onAccentColor;
}

/// WATSafe color palette and Material 3 theme definition with selectable
/// multi-theme palettes.
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
  static const Color amberSignal = orangeAccent;
  static const Color alarmCrimson = Color(0xFFD6453A);
  static const Color readyEmerald = Color(0xFF2E9B68);
  static const Color infoSteel = Color(0xFF4F86C6);

  static WatSafeColorTheme _activeColorTheme = WatSafeColorTheme.obsidianAmber;

  static WatSafeColorTheme get activeColorTheme => _activeColorTheme;

  static WatSafePalette get activePalette => paletteFor(_activeColorTheme);

  static WatSafePalette paletteFor(WatSafeColorTheme theme) {
    switch (theme) {
      case WatSafeColorTheme.obsidianAmber:
        return const WatSafePalette(
          brightness: Brightness.dark,
          backgroundDeep: charcoalDeep,
          surfaceCard: charcoalSurface,
          surfaceElevated: charcoalElevated,
          borderColor: charcoalBorder,
          textPrimary: warmOffWhite,
          textMuted: warmMuted,
          textSubtle: warmSubtle,
          accentPrimary: amberAccent,
          accentSecondary: orangeAccent,
          readyColor: readyEmerald,
          alarmColor: alarmCrimson,
          infoColor: infoSteel,
          onAccentColor: charcoalDeep,
        );
      case WatSafeColorTheme.cyberSentinel:
        return const WatSafePalette(
          brightness: Brightness.dark,
          backgroundDeep: Color(0xFF070D19),
          surfaceCard: Color(0xFF0F172A),
          surfaceElevated: Color(0xFF1E293B),
          borderColor: Color(0xFF334155),
          textPrimary: Color(0xFFF1F5F9),
          textMuted: Color(0xFF94A3B8),
          textSubtle: Color(0xFF64748B),
          accentPrimary: Color(0xFF06B6D4),
          accentSecondary: Color(0xFF3B82F6),
          readyColor: Color(0xFF10B981),
          alarmColor: Color(0xFFF43F5E),
          infoColor: Color(0xFF60A5FA),
          onAccentColor: Color(0xFF070D19),
        );
      case WatSafeColorTheme.emeraldTactical:
        return const WatSafePalette(
          brightness: Brightness.dark,
          backgroundDeep: Color(0xFF07120D),
          surfaceCard: Color(0xFF0D1F17),
          surfaceElevated: Color(0xFF152E22),
          borderColor: Color(0xFF234735),
          textPrimary: Color(0xFFECFDF5),
          textMuted: Color(0xFF9CA3AF),
          textSubtle: Color(0xFF6B7280),
          accentPrimary: Color(0xFF10B981),
          accentSecondary: Color(0xFF34D399),
          readyColor: Color(0xFF22C55E),
          alarmColor: Color(0xFFEF4444),
          infoColor: Color(0xFF2DD4BF),
          onAccentColor: Color(0xFF07120D),
        );
      case WatSafeColorTheme.crimsonNight:
        return const WatSafePalette(
          brightness: Brightness.dark,
          backgroundDeep: Color(0xFF14090C),
          surfaceCard: Color(0xFF211015),
          surfaceElevated: Color(0xFF2F171E),
          borderColor: Color(0xFF4A2430),
          textPrimary: Color(0xFFFFF1F2),
          textMuted: Color(0xFFD6B4B8),
          textSubtle: Color(0xFF9E7B80),
          accentPrimary: Color(0xFFF43F5E),
          accentSecondary: Color(0xFFFB7185),
          readyColor: Color(0xFF10B981),
          alarmColor: Color(0xFFEF4444),
          infoColor: Color(0xFFFBBF24),
          onAccentColor: Color(0xFFFFFFFF),
        );
      case WatSafeColorTheme.royalViolet:
        return const WatSafePalette(
          brightness: Brightness.dark,
          backgroundDeep: Color(0xFF0D0A1A),
          surfaceCard: Color(0xFF17122B),
          surfaceElevated: Color(0xFF231C3E),
          borderColor: Color(0xFF362C5E),
          textPrimary: Color(0xFFF5F3FF),
          textMuted: Color(0xFFB8B0D4),
          textSubtle: Color(0xFF7E749E),
          accentPrimary: Color(0xFFA855F7),
          accentSecondary: Color(0xFFC084FC),
          readyColor: Color(0xFF10B981),
          alarmColor: Color(0xFFF43F5E),
          infoColor: Color(0xFF38BDF8),
          onAccentColor: Color(0xFFFFFFFF),
        );
      case WatSafeColorTheme.arcticDaylight:
        return const WatSafePalette(
          brightness: Brightness.light,
          backgroundDeep: Color(0xFFF1F5F9),
          surfaceCard: Color(0xFFFFFFFF),
          surfaceElevated: Color(0xFFE2E8F0),
          borderColor: Color(0xFFCBD5E1),
          textPrimary: Color(0xFF0F172A),
          textMuted: Color(0xFF475569),
          textSubtle: Color(0xFF64748B),
          accentPrimary: Color(0xFF2563EB),
          accentSecondary: Color(0xFF0284C7),
          readyColor: Color(0xFF059669),
          alarmColor: Color(0xFFDC2626),
          infoColor: Color(0xFF0284C7),
          onAccentColor: Color(0xFFFFFFFF),
        );
    }
  }

  static ThemeData darkTheme() => themeFor(WatSafeColorTheme.obsidianAmber);

  static ThemeData themeFor(WatSafeColorTheme colorTheme) {
    _activeColorTheme = colorTheme;
    final p = paletteFor(colorTheme);
    final isDark = p.brightness == Brightness.dark;
    final colorScheme =
        (isDark ? const ColorScheme.dark() : const ColorScheme.light())
            .copyWith(
              brightness: p.brightness,
              primary: p.accentPrimary,
              onPrimary: p.onAccentColor,
              secondary: p.accentSecondary,
              onSecondary: p.onAccentColor,
              tertiary: p.readyColor,
              onTertiary: p.onAccentColor,
              error: p.alarmColor,
              onError: Colors.white,
              surface: p.surfaceCard,
              onSurface: p.textPrimary,
              onSurfaceVariant: p.textMuted,
              surfaceContainerHighest: p.surfaceElevated,
              outline: p.borderColor,
            );

    return ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: p.backgroundDeep,
      cardTheme: CardThemeData(
        color: p.surfaceCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: p.borderColor, width: 1),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.backgroundDeep,
        foregroundColor: p.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surfaceElevated,
        labelStyle: TextStyle(color: p.textMuted),
        hintStyle: TextStyle(color: p.textSubtle),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.accentPrimary, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accentPrimary,
          foregroundColor: p.onAccentColor,
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
          foregroundColor: p.textPrimary,
          side: BorderSide(color: p.borderColor),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      dividerTheme: DividerThemeData(color: p.borderColor, thickness: 1),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: p.surfaceCard,
        selectedIconTheme: IconThemeData(color: p.accentPrimary),
        unselectedIconTheme: IconThemeData(color: p.textMuted),
        selectedLabelTextStyle: TextStyle(
          color: p.accentPrimary,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: p.textMuted,
          fontWeight: FontWeight.w500,
          fontSize: 12,
        ),
        indicatorColor: p.accentPrimary.withValues(alpha: 0.16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surfaceCard,
        indicatorColor: p.accentPrimary.withValues(alpha: 0.16),
      ),
    );
  }

  static Color colorForProtectionState(ProtectionState state) {
    final p = activePalette;
    switch (state) {
      case ProtectionState.disarmed:
        return p.textMuted;
      case ProtectionState.arming:
        return p.accentPrimary;
      case ProtectionState.armed:
        return p.readyColor;
      case ProtectionState.alarming:
        return p.alarmColor;
      case ProtectionState.paused:
        return p.accentSecondary;
      case ProtectionState.unavailable:
        return p.textSubtle;
    }
  }

  static Color colorForCapabilityStatus(CapabilityStatus status) {
    final p = activePalette;
    switch (status) {
      case CapabilityStatus.ready:
        return p.readyColor;
      case CapabilityStatus.supported:
        return p.infoColor;
      case CapabilityStatus.permissionRequired:
        return p.accentPrimary;
      case CapabilityStatus.degraded:
        return p.accentSecondary;
      case CapabilityStatus.unsupported:
        return p.alarmColor;
      case CapabilityStatus.notImplemented:
      case CapabilityStatus.notConfigured:
        return p.textSubtle;
    }
  }

  static String labelForCapabilityStatus(CapabilityStatus status) {
    switch (status) {
      case CapabilityStatus.ready:
        return 'Ready';
      case CapabilityStatus.supported:
        return 'Available';
      case CapabilityStatus.permissionRequired:
        return 'Permission needed';
      case CapabilityStatus.degraded:
        return 'Needs attention';
      case CapabilityStatus.unsupported:
        return 'Unavailable';
      case CapabilityStatus.notImplemented:
      case CapabilityStatus.notConfigured:
        return 'Off';
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
