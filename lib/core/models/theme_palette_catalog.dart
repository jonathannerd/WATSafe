import 'dart:convert';

/// User-facing color themes shared across WATSafe desktop and phone companion.
enum WatSafeColorTheme {
  obsidianAmber(
    'obsidian_amber',
    'Obsidian & Amber (Default)',
    'Obsidian & Amber',
    'Deep slate charcoal with warm amber security accents',
  ),
  cyberSentinel(
    'cyber_sentinel',
    'Cyber Sentinel (Cobalt & Cyan)',
    'Cyber Sentinel',
    'Midnight navy with electric cyan and cobalt highlights',
  ),
  emeraldTactical(
    'emerald_tactical',
    'Emerald Tactical (Matrix Green)',
    'Emerald Tactical',
    'Stealth forest dark with crisp emerald and mint indicators',
  ),
  crimsonNight(
    'crimson_night',
    'Crimson Night (Ruby Alert)',
    'Crimson Night',
    'Deep onyx-burgundy with high-urgency ruby and coral accents',
  ),
  royalViolet(
    'royal_violet',
    'Royal Violet (Amethyst)',
    'Royal Violet',
    'Cosmic indigo surface with luminous amethyst and lavender accents',
  ),
  arcticDaylight(
    'arctic_daylight',
    'Arctic Daylight (High-Contrast Light)',
    'Arctic Daylight',
    'Clean alabaster daylight surfaces with royal blue and slate contrast',
  );

  const WatSafeColorTheme(
    this.id,
    this.displayName,
    this.shortName,
    this.description,
  );

  final String id;
  final String displayName;
  final String shortName;
  final String description;

  /// Resolves a saved theme identifier, tolerating null, empty, case changes,
  /// enum names, kebab-case, or legacy aliases, falling back to [obsidianAmber].
  static WatSafeColorTheme fromId(String? raw) {
    if (raw == null) {
      return WatSafeColorTheme.obsidianAmber;
    }
    final cleaned = raw.trim();
    if (cleaned.isEmpty) {
      return WatSafeColorTheme.obsidianAmber;
    }
    final lower = cleaned.toLowerCase();
    final snake = lower.replaceAll('-', '_').replaceAll(' ', '_');
    for (final item in WatSafeColorTheme.values) {
      if (item.id == lower ||
          item.id == snake ||
          item.name.toLowerCase() == lower ||
          item.shortName.toLowerCase() == lower ||
          item.displayName.toLowerCase() == lower) {
        return item;
      }
    }
    // Legacy / friendly alias migration
    switch (snake) {
      case 'default':
      case 'dark':
      case 'amber':
      case 'obsidian':
        return WatSafeColorTheme.obsidianAmber;
      case 'cyber':
      case 'cyan':
      case 'cobalt':
        return WatSafeColorTheme.cyberSentinel;
      case 'emerald':
      case 'green':
      case 'matrix':
        return WatSafeColorTheme.emeraldTactical;
      case 'crimson':
      case 'ruby':
        return WatSafeColorTheme.crimsonNight;
      case 'violet':
      case 'purple':
      case 'amethyst':
        return WatSafeColorTheme.royalViolet;
      case 'light':
      case 'daylight':
      case 'arctic':
        return WatSafeColorTheme.arcticDaylight;
    }
    return WatSafeColorTheme.obsidianAmber;
  }
}

/// Platform-neutral ARGB palette tokens for a [WatSafeColorTheme], shared by
/// both the Flutter desktop/mobile app and the embedded phone web companion.
class WatSafePaletteSpec {
  const WatSafePaletteSpec({
    required this.theme,
    required this.isDark,
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
    required this.onAccentColor,
    required this.readyColor,
    required this.warningColor,
    required this.alarmColor,
    required this.infoColor,
    required this.phoneMarkerColor,
  });

  final WatSafeColorTheme theme;
  final bool isDark;
  final int backgroundDeep;
  final int sidebarBackground;
  final int surfaceCard;
  final int surfaceElevated;
  final int borderColor;
  final int sidebarBorder;
  final int textPrimary;
  final int textMuted;
  final int textSubtle;
  final int accentPrimary;
  final int accentSecondary;
  final int onAccentColor;
  final int readyColor;
  final int warningColor;
  final int alarmColor;
  final int infoColor;
  final int phoneMarkerColor;

  static String hexRgb(int argb) {
    final rgb = argb & 0x00FFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  static String rgbaCss(int argb, double alpha) {
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    final a = alpha.clamp(0.0, 1.0).toStringAsFixed(2);
    return 'rgba($r, $g, $b, $a)';
  }

  Map<String, Object?> toWebMap() {
    return <String, Object?>{
      'id': theme.id,
      'name': theme.displayName,
      'shortName': theme.shortName,
      'description': theme.description,
      'isDark': isDark,
      'bg': hexRgb(backgroundDeep),
      'chrome': hexRgb(sidebarBackground),
      'chromeTranslucent': rgbaCss(sidebarBackground, 0.96),
      'surface': hexRgb(surfaceCard),
      'elevated': hexRgb(surfaceElevated),
      'detailsBg': rgbaCss(
        isDark ? backgroundDeep : surfaceElevated,
        isDark ? 0.42 : 0.65,
      ),
      'border': hexRgb(borderColor),
      'chromeBorder': hexRgb(sidebarBorder),
      'text': hexRgb(textPrimary),
      'muted': hexRgb(textMuted),
      'subtle': hexRgb(textSubtle),
      'accent': hexRgb(accentPrimary),
      'accentSecondary': hexRgb(accentSecondary),
      'onAccent': hexRgb(onAccentColor),
      'accentSoft': rgbaCss(accentPrimary, isDark ? 0.22 : 0.14),
      'accentHover': rgbaCss(accentPrimary, isDark ? 0.14 : 0.09),
      'accentBorder': rgbaCss(accentPrimary, isDark ? 0.58 : 0.45),
      'accentHalo': rgbaCss(accentPrimary, 0.44),
      'emerald': hexRgb(readyColor),
      'okBg': rgbaCss(readyColor, isDark ? 0.18 : 0.12),
      'okFg': isDark ? '#6EE7B7' : '#065F46',
      'warning': hexRgb(warningColor),
      'warnBg': rgbaCss(warningColor, isDark ? 0.18 : 0.14),
      'warnFg': isDark ? '#FDE68A' : '#92400E',
      'crimson': hexRgb(alarmColor),
      'alertBg': rgbaCss(alarmColor, isDark ? 0.18 : 0.11),
      'alertFg': isDark ? '#FECACA' : '#991B1B',
      'info': hexRgb(infoColor),
      'phoneMarker': hexRgb(phoneMarkerColor),
      'laptopMarker': '#0F8A5F',
      'themeColorMeta': hexRgb(sidebarBackground),
    };
  }
}

/// Canonical palette catalog shared by Flutter and the Phone Web Companion.
class WatSafeThemeCatalog {
  const WatSafeThemeCatalog._();

  static WatSafePaletteSpec specFor(WatSafeColorTheme theme) {
    switch (theme) {
      case WatSafeColorTheme.obsidianAmber:
        return const WatSafePaletteSpec(
          theme: WatSafeColorTheme.obsidianAmber,
          isDark: true,
          backgroundDeep: 0xFF101318,
          sidebarBackground: 0xFF171C24,
          surfaceCard: 0xFF1B212B,
          surfaceElevated: 0xFF252D3A,
          borderColor: 0xFF3B4659,
          sidebarBorder: 0xFF2E3747,
          textPrimary: 0xFFF8F5EE,
          textMuted: 0xFFD2CBBF,
          textSubtle: 0xFFA29B8E,
          accentPrimary: 0xFFF59E0B,
          accentSecondary: 0xFFFB923C,
          onAccentColor: 0xFF111419,
          readyColor: 0xFF10B981,
          warningColor: 0xFFF59E0B,
          alarmColor: 0xFFEF4444,
          infoColor: 0xFF38BDF8,
          phoneMarkerColor: 0xFF2563EB,
        );
      case WatSafeColorTheme.cyberSentinel:
        return const WatSafePaletteSpec(
          theme: WatSafeColorTheme.cyberSentinel,
          isDark: true,
          backgroundDeep: 0xFF060E1E,
          sidebarBackground: 0xFF0B1830,
          surfaceCard: 0xFF0F203D,
          surfaceElevated: 0xFF182F54,
          borderColor: 0xFF2B4D82,
          sidebarBorder: 0xFF203C66,
          textPrimary: 0xFFF0F7FF,
          textMuted: 0xFFB4CCF0,
          textSubtle: 0xFF82A0CC,
          accentPrimary: 0xFF00D4FF,
          accentSecondary: 0xFF3B82F6,
          onAccentColor: 0xFF041020,
          readyColor: 0xFF10B981,
          warningColor: 0xFFFBBF24,
          alarmColor: 0xFFF43F5E,
          infoColor: 0xFF60A5FA,
          phoneMarkerColor: 0xFF2563EB,
        );
      case WatSafeColorTheme.emeraldTactical:
        return const WatSafePaletteSpec(
          theme: WatSafeColorTheme.emeraldTactical,
          isDark: true,
          backgroundDeep: 0xFF05140E,
          sidebarBackground: 0xFF0A2118,
          surfaceCard: 0xFF0E2A1E,
          surfaceElevated: 0xFF163D2C,
          borderColor: 0xFF256147,
          sidebarBorder: 0xFF1D4B37,
          textPrimary: 0xFFECFDF5,
          textMuted: 0xFFAEDCCB,
          textSubtle: 0xFF7CB39E,
          accentPrimary: 0xFF10E092,
          accentSecondary: 0xFF34D399,
          onAccentColor: 0xFF041810,
          readyColor: 0xFF22C55E,
          warningColor: 0xFFFBBF24,
          alarmColor: 0xFFEF4444,
          infoColor: 0xFF2DD4BF,
          phoneMarkerColor: 0xFF2563EB,
        );
      case WatSafeColorTheme.crimsonNight:
        return const WatSafePaletteSpec(
          theme: WatSafeColorTheme.crimsonNight,
          isDark: true,
          backgroundDeep: 0xFF16070C,
          sidebarBackground: 0xFF230C14,
          surfaceCard: 0xFF2B111A,
          surfaceElevated: 0xFF3E1927,
          borderColor: 0xFF682A40,
          sidebarBorder: 0xFF502031,
          textPrimary: 0xFFFFF1F3,
          textMuted: 0xFFE8BCC6,
          textSubtle: 0xFFBA8894,
          accentPrimary: 0xFFFF4D79,
          accentSecondary: 0xFFFB7185,
          onAccentColor: 0xFF190409,
          readyColor: 0xFF10B981,
          warningColor: 0xFFFBBF24,
          alarmColor: 0xFFEF4444,
          infoColor: 0xFF38BDF8,
          phoneMarkerColor: 0xFF2563EB,
        );
      case WatSafeColorTheme.royalViolet:
        return const WatSafePaletteSpec(
          theme: WatSafeColorTheme.royalViolet,
          isDark: true,
          backgroundDeep: 0xFF0C081D,
          sidebarBackground: 0xFF150F30,
          surfaceCard: 0xFF1C143C,
          surfaceElevated: 0xFF291F57,
          borderColor: 0xFF493791,
          sidebarBorder: 0xFF37296E,
          textPrimary: 0xFFF6F3FF,
          textMuted: 0xFFCEC5F0,
          textSubtle: 0xFF9C90C9,
          accentPrimary: 0xFFBD6BFF,
          accentSecondary: 0xFFD896FF,
          onAccentColor: 0xFF120726,
          readyColor: 0xFF10B981,
          warningColor: 0xFFFBBF24,
          alarmColor: 0xFFF43F5E,
          infoColor: 0xFF38BDF8,
          phoneMarkerColor: 0xFF2563EB,
        );
      case WatSafeColorTheme.arcticDaylight:
        return const WatSafePaletteSpec(
          theme: WatSafeColorTheme.arcticDaylight,
          isDark: false,
          backgroundDeep: 0xFFEEF4FB,
          sidebarBackground: 0xFFDCE9F8,
          surfaceCard: 0xFFFFFFFF,
          surfaceElevated: 0xFFE3EEF9,
          borderColor: 0xFFB3C9E4,
          sidebarBorder: 0xFFC0D4EC,
          textPrimary: 0xFF0B1528,
          textMuted: 0xFF324665,
          textSubtle: 0xFF516684,
          accentPrimary: 0xFF1D4ED8,
          accentSecondary: 0xFF0284C7,
          onAccentColor: 0xFFFFFFFF,
          readyColor: 0xFF047857,
          warningColor: 0xFFB45309,
          alarmColor: 0xFFDC2626,
          infoColor: 0xFF0369A1,
          phoneMarkerColor: 0xFF1D4ED8,
        );
    }
  }

  /// Ordered list of web theme descriptors serialized directly into the phone
  /// companion so desktop and phone stay 100% synchronized.
  static String toWebCatalogJson() {
    return jsonEncode(<Map<String, Object?>>[
      for (final theme in WatSafeColorTheme.values) specFor(theme).toWebMap(),
    ]);
  }
}
