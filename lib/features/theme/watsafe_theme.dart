import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/alarm/alarm_state.dart';
import '../../core/models/detector_models.dart';
import '../../core/models/theme_palette_catalog.dart';

/// Resolved Flutter color palette and [ThemeExtension] for a [WatSafeColorTheme].
class WatSafePalette extends ThemeExtension<WatSafePalette> {
  const WatSafePalette({
    required this.theme,
    required this.brightness,
    required this.backgroundDeep,
    required this.sidebarBackground,
    required this.surfaceCard,
    required this.surfaceElevated,
    required this.borderColor,
    required this.sidebarBorder,
    required this.textPrimary,
    required this.textMuted,
    required this.textSubtle,
    required this.accentPrimary,
    required this.accentSecondary,
    required this.readyColor,
    required this.warningColor,
    required this.alarmColor,
    required this.infoColor,
    required this.phoneMarkerColor,
    required this.onAccentColor,
  });

  factory WatSafePalette.fromSpec(WatSafePaletteSpec spec) {
    return WatSafePalette(
      theme: spec.theme,
      brightness: spec.isDark ? Brightness.dark : Brightness.light,
      backgroundDeep: Color(spec.backgroundDeep),
      sidebarBackground: Color(spec.sidebarBackground),
      surfaceCard: Color(spec.surfaceCard),
      surfaceElevated: Color(spec.surfaceElevated),
      borderColor: Color(spec.borderColor),
      sidebarBorder: Color(spec.sidebarBorder),
      textPrimary: Color(spec.textPrimary),
      textMuted: Color(spec.textMuted),
      textSubtle: Color(spec.textSubtle),
      accentPrimary: Color(spec.accentPrimary),
      accentSecondary: Color(spec.accentSecondary),
      readyColor: Color(spec.readyColor),
      warningColor: Color(spec.warningColor),
      alarmColor: Color(spec.alarmColor),
      infoColor: Color(spec.infoColor),
      phoneMarkerColor: Color(spec.phoneMarkerColor),
      onAccentColor: Color(spec.onAccentColor),
    );
  }

  final WatSafeColorTheme theme;
  final Brightness brightness;
  final Color backgroundDeep;
  final Color sidebarBackground;
  final Color surfaceCard;
  final Color surfaceElevated;
  final Color borderColor;
  final Color sidebarBorder;
  final Color textPrimary;
  final Color textMuted;
  final Color textSubtle;
  final Color accentPrimary;
  final Color accentSecondary;
  final Color readyColor;
  final Color warningColor;
  final Color alarmColor;
  final Color infoColor;
  final Color phoneMarkerColor;
  final Color onAccentColor;

  bool get isDark => brightness == Brightness.dark;

  Color get sidebarIndicator =>
      accentPrimary.withValues(alpha: isDark ? 0.24 : 0.16);

  @override
  WatSafePalette copyWith({
    WatSafeColorTheme? theme,
    Brightness? brightness,
    Color? backgroundDeep,
    Color? sidebarBackground,
    Color? surfaceCard,
    Color? surfaceElevated,
    Color? borderColor,
    Color? sidebarBorder,
    Color? textPrimary,
    Color? textMuted,
    Color? textSubtle,
    Color? accentPrimary,
    Color? accentSecondary,
    Color? readyColor,
    Color? warningColor,
    Color? alarmColor,
    Color? infoColor,
    Color? phoneMarkerColor,
    Color? onAccentColor,
  }) {
    return WatSafePalette(
      theme: theme ?? this.theme,
      brightness: brightness ?? this.brightness,
      backgroundDeep: backgroundDeep ?? this.backgroundDeep,
      sidebarBackground: sidebarBackground ?? this.sidebarBackground,
      surfaceCard: surfaceCard ?? this.surfaceCard,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      borderColor: borderColor ?? this.borderColor,
      sidebarBorder: sidebarBorder ?? this.sidebarBorder,
      textPrimary: textPrimary ?? this.textPrimary,
      textMuted: textMuted ?? this.textMuted,
      textSubtle: textSubtle ?? this.textSubtle,
      accentPrimary: accentPrimary ?? this.accentPrimary,
      accentSecondary: accentSecondary ?? this.accentSecondary,
      readyColor: readyColor ?? this.readyColor,
      warningColor: warningColor ?? this.warningColor,
      alarmColor: alarmColor ?? this.alarmColor,
      infoColor: infoColor ?? this.infoColor,
      phoneMarkerColor: phoneMarkerColor ?? this.phoneMarkerColor,
      onAccentColor: onAccentColor ?? this.onAccentColor,
    );
  }

  @override
  WatSafePalette lerp(
    covariant ThemeExtension<WatSafePalette>? other,
    double t,
  ) {
    if (other is! WatSafePalette) {
      return this;
    }
    return WatSafePalette(
      theme: t < 0.5 ? theme : other.theme,
      brightness: t < 0.5 ? brightness : other.brightness,
      backgroundDeep: Color.lerp(backgroundDeep, other.backgroundDeep, t)!,
      sidebarBackground: Color.lerp(
        sidebarBackground,
        other.sidebarBackground,
        t,
      )!,
      surfaceCard: Color.lerp(surfaceCard, other.surfaceCard, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      borderColor: Color.lerp(borderColor, other.borderColor, t)!,
      sidebarBorder: Color.lerp(sidebarBorder, other.sidebarBorder, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textSubtle: Color.lerp(textSubtle, other.textSubtle, t)!,
      accentPrimary: Color.lerp(accentPrimary, other.accentPrimary, t)!,
      accentSecondary: Color.lerp(accentSecondary, other.accentSecondary, t)!,
      readyColor: Color.lerp(readyColor, other.readyColor, t)!,
      warningColor: Color.lerp(warningColor, other.warningColor, t)!,
      alarmColor: Color.lerp(alarmColor, other.alarmColor, t)!,
      infoColor: Color.lerp(infoColor, other.infoColor, t)!,
      phoneMarkerColor: Color.lerp(
        phoneMarkerColor,
        other.phoneMarkerColor,
        t,
      )!,
      onAccentColor: Color.lerp(onAccentColor, other.onAccentColor, t)!,
    );
  }
}

/// WATSafe color palette and Material 3 theme definition backed by the shared
/// [WatSafeThemeCatalog].
class WatSafeTheme {
  static WatSafeColorTheme _activeColorTheme = WatSafeColorTheme.obsidianAmber;

  static WatSafeColorTheme get activeColorTheme => _activeColorTheme;

  static WatSafePalette get activePalette => paletteFor(_activeColorTheme);

  /// Subscribes [context] to the active [WatSafePalette] via [Theme.of],
  /// ensuring widgets, dialogs, and sheets rebuild immediately when the user
  /// switches themes.
  static WatSafePalette of(BuildContext context) {
    return Theme.of(context).extension<WatSafePalette>() ?? activePalette;
  }

  /// Primes the active theme early during startup before the first frame.
  static void primeColorTheme(WatSafeColorTheme theme) {
    _activeColorTheme = theme;
  }

  // Dynamic semantic getters bound to the active palette so all existing
  // token references honor the selected theme.
  static Color get charcoalDeep => activePalette.backgroundDeep;
  static Color get sidebarSurface => activePalette.sidebarBackground;
  static Color get sidebarBorder => activePalette.sidebarBorder;
  static Color get charcoalSurface => activePalette.surfaceCard;
  static Color get charcoalElevated => activePalette.surfaceElevated;
  static Color get charcoalBorder => activePalette.borderColor;

  static Color get warmOffWhite => activePalette.textPrimary;
  static Color get warmMuted => activePalette.textMuted;
  static Color get warmSubtle => activePalette.textSubtle;

  static Color get amberAccent => activePalette.accentPrimary;
  static Color get orangeAccent => activePalette.accentSecondary;
  static Color get amberSignal => activePalette.warningColor;
  static Color get warningAmber => activePalette.warningColor;
  static Color get alarmCrimson => activePalette.alarmColor;
  static Color get readyEmerald => activePalette.readyColor;
  static Color get infoSteel => activePalette.infoColor;

  static WatSafePalette paletteFor(WatSafeColorTheme theme) {
    return WatSafePalette.fromSpec(WatSafeThemeCatalog.specFor(theme));
  }

  static ThemeData darkTheme() => themeFor(WatSafeColorTheme.obsidianAmber);

  static ThemeData themeFor(WatSafeColorTheme colorTheme) {
    _activeColorTheme = colorTheme;
    final p = paletteFor(colorTheme);
    final isDark = p.isDark;
    final colorScheme =
        (isDark ? const ColorScheme.dark() : const ColorScheme.light())
            .copyWith(
              brightness: p.brightness,
              primary: p.accentPrimary,
              onPrimary: p.onAccentColor,
              primaryContainer: p.sidebarIndicator,
              onPrimaryContainer: p.textPrimary,
              secondary: p.accentSecondary,
              onSecondary: p.onAccentColor,
              secondaryContainer: p.surfaceElevated,
              onSecondaryContainer: p.textPrimary,
              tertiary: p.readyColor,
              onTertiary: Colors.white,
              error: p.alarmColor,
              onError: Colors.white,
              surface: p.surfaceCard,
              onSurface: p.textPrimary,
              onSurfaceVariant: p.textMuted,
              surfaceContainerLowest: p.backgroundDeep,
              surfaceContainerLow: p.sidebarBackground,
              surfaceContainer: p.surfaceCard,
              surfaceContainerHigh: p.surfaceElevated,
              surfaceContainerHighest: p.surfaceElevated,
              outline: p.borderColor,
              outlineVariant: p.sidebarBorder,
            );

    final stateOverlay = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.pressed)) {
        return p.accentPrimary.withValues(alpha: isDark ? 0.22 : 0.16);
      }
      if (states.contains(WidgetState.focused)) {
        return p.accentPrimary.withValues(alpha: isDark ? 0.18 : 0.14);
      }
      if (states.contains(WidgetState.hovered)) {
        return p.accentPrimary.withValues(alpha: isDark ? 0.12 : 0.09);
      }
      return null;
    });

    return ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: colorScheme,
      extensions: <ThemeExtension<dynamic>>[p],
      scaffoldBackgroundColor: p.backgroundDeep,
      hoverColor: p.accentPrimary.withValues(alpha: isDark ? 0.12 : 0.08),
      focusColor: p.accentPrimary.withValues(alpha: isDark ? 0.20 : 0.14),
      highlightColor: p.accentPrimary.withValues(alpha: isDark ? 0.16 : 0.12),
      splashColor: p.accentPrimary.withValues(alpha: isDark ? 0.22 : 0.16),
      cardTheme: CardThemeData(
        color: p.surfaceCard,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: p.borderColor, width: 1),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.sidebarBackground,
        foregroundColor: p.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surfaceCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: p.borderColor, width: 1),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surfaceCard,
        modalBackgroundColor: p.surfaceCard,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surfaceElevated,
        labelStyle: TextStyle(color: p.textMuted),
        hintStyle: TextStyle(color: p.textSubtle),
        prefixIconColor: p.textMuted,
        suffixIconColor: p.textMuted,
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
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.borderColor.withValues(alpha: 0.5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.accentPrimary, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return p.surfaceElevated;
            }
            return p.accentPrimary;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return p.textSubtle;
            }
            return p.onAccentColor;
          }),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return p.onAccentColor.withValues(alpha: 0.16);
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return p.onAccentColor.withValues(alpha: 0.10);
            }
            return null;
          }),
          textStyle: const WidgetStatePropertyAll(
            TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.2),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return p.textSubtle;
            }
            return p.textPrimary;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return BorderSide(color: p.accentPrimary, width: 2);
            }
            if (states.contains(WidgetState.hovered)) {
              return BorderSide(color: p.accentPrimary.withValues(alpha: 0.75));
            }
            return BorderSide(color: p.borderColor);
          }),
          overlayColor: stateOverlay,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return p.textSubtle;
            }
            return p.accentPrimary;
          }),
          overlayColor: stateOverlay,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(overlayColor: stateOverlay),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return p.textSubtle;
          }
          if (states.contains(WidgetState.selected)) {
            return p.onAccentColor;
          }
          return p.textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return p.surfaceElevated.withValues(alpha: 0.5);
          }
          if (states.contains(WidgetState.selected)) {
            return p.accentPrimary;
          }
          return p.surfaceElevated;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return p.accentPrimary;
          }
          if (states.contains(WidgetState.selected)) {
            return p.accentPrimary;
          }
          return p.borderColor;
        }),
        overlayColor: stateOverlay,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.accentPrimary,
        inactiveTrackColor: p.borderColor,
        thumbColor: p.accentPrimary,
        overlayColor: p.accentPrimary.withValues(alpha: 0.18),
        valueIndicatorColor: p.accentPrimary,
        valueIndicatorTextStyle: TextStyle(
          color: p.onAccentColor,
          fontWeight: FontWeight.w700,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.surfaceElevated,
        selectedColor: p.sidebarIndicator,
        disabledColor: p.surfaceElevated.withValues(alpha: 0.5),
        checkmarkColor: p.accentPrimary,
        side: BorderSide(color: p.borderColor),
        labelStyle: TextStyle(color: p.textPrimary),
        secondaryLabelStyle: TextStyle(
          color: p.accentPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
      dividerTheme: DividerThemeData(color: p.borderColor, thickness: 1),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: p.sidebarBackground,
        useIndicator: true,
        indicatorColor: p.sidebarIndicator,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: p.accentPrimary.withValues(alpha: isDark ? 0.50 : 0.38),
            width: 1,
          ),
        ),
        selectedIconTheme: IconThemeData(color: p.accentPrimary, size: 23),
        unselectedIconTheme: IconThemeData(color: p.textMuted, size: 22),
        selectedLabelTextStyle: TextStyle(
          color: p.accentPrimary,
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: p.textMuted,
          fontWeight: FontWeight.w500,
          fontSize: 12.5,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.sidebarBackground,
        surfaceTintColor: Colors.transparent,
        indicatorColor: p.sidebarIndicator,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: p.accentPrimary.withValues(alpha: isDark ? 0.45 : 0.35),
            width: 1,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected)
                ? p.accentPrimary
                : p.textMuted,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            color: selected ? p.accentPrimary : p.textMuted,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            fontSize: 12,
          );
        }),
      ),
    );
  }

  static Color colorForProtectionState(
    ProtectionState state, [
    WatSafePalette? palette,
  ]) {
    final p = palette ?? activePalette;
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
        return p.warningColor;
      case ProtectionState.unavailable:
        return p.textSubtle;
    }
  }

  static Color colorForCapabilityStatus(
    CapabilityStatus status, [
    WatSafePalette? palette,
  ]) {
    final p = palette ?? activePalette;
    switch (status) {
      case CapabilityStatus.ready:
        return p.readyColor;
      case CapabilityStatus.supported:
        return p.infoColor;
      case CapabilityStatus.permissionRequired:
        return p.warningColor;
      case CapabilityStatus.degraded:
        return p.warningColor;
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
    final palette = WatSafeTheme.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _WatSafeShieldPainter(
          accentColor: accentColor,
          coreColor: palette.textPrimary,
          isActiveWave: isActiveWave,
        ),
      ),
    );
  }
}

class _WatSafeShieldPainter extends CustomPainter {
  _WatSafeShieldPainter({
    required this.accentColor,
    required this.coreColor,
    required this.isActiveWave,
  });

  final Color accentColor;
  final Color coreColor;
  final bool isActiveWave;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final ringPaint = Paint()
      ..color = accentColor.withValues(alpha: isActiveWave ? 0.28 : 0.14)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, radius - 2, ringPaint);

    if (isActiveWave) {
      final arcPaint = Paint()
        ..color = accentColor.withValues(alpha: 0.50)
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
      ..color = accentColor.withValues(alpha: 0.20)
      ..style = PaintingStyle.fill;
    canvas.drawPath(shield, fillPaint);

    final borderPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(shield, borderPaint);

    final corePaint = Paint()
      ..color = coreColor
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
        oldDelegate.coreColor != coreColor ||
        oldDelegate.isActiveWave != isActiveWave;
  }
}
