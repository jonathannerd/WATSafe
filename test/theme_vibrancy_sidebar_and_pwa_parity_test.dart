import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/core/models/theme_palette_catalog.dart';
import 'package:watsafe/features/theme/watsafe_theme.dart';
import 'package:watsafe/main.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

import '../backend/server.dart';
import 'alarm_controller_test.dart';

double _relativeLuminance(int argb) {
  double linearize(int channel) {
    final srgb = (channel & 0xFF) / 255.0;
    return srgb <= 0.03928
        ? srgb / 12.92
        : math.pow((srgb + 0.055) / 1.055, 2.4).toDouble();
  }

  final r = linearize((argb >> 16) & 0xFF);
  final g = linearize((argb >> 8) & 0xFF);
  final b = linearize(argb & 0xFF);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

double _contrastRatio(int fgArgb, int bgArgb) {
  final l1 = _relativeLuminance(fgArgb);
  final l2 = _relativeLuminance(bgArgb);
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  setUpAll(() {
    HttpOverrides.global = null;
  });

  group('Vibrant Multi-Theme System, Desktop Sidebar & Phone Companion Parity', () {
    test('1. All 6 shared themes preserve IDs, provide distinct vibrant sidebar/surface/accent colors, and pass WCAG AA (>= 4.5:1) contrast', () {
      expect(
        WatSafeColorTheme.values.map((t) => t.id).toList(),
        equals(<String>[
          'obsidian_amber',
          'cyber_sentinel',
          'emerald_tactical',
          'crimson_night',
          'royal_violet',
          'arctic_daylight',
        ]),
      );

      final sidebarColors = <int>{};
      final surfaceColors = <int>{};
      final accentColors = <int>{};

      for (final theme in WatSafeColorTheme.values) {
        final spec = WatSafeThemeCatalog.specFor(theme);
        sidebarColors.add(spec.sidebarBackground);
        surfaceColors.add(spec.surfaceCard);
        accentColors.add(spec.accentPrimary);

        // Sidebar must visibly differ from main page background in every theme.
        expect(
          spec.sidebarBackground,
          isNot(equals(spec.backgroundDeep)),
          reason:
              '${theme.id} sidebarBackground should stand out from backgroundDeep',
        );

        // WCAG AA (>= 4.5:1) for normal text (textPrimary & textMuted) across surfaces.
        final surfaces = <String, int>{
          'backgroundDeep': spec.backgroundDeep,
          'sidebarBackground': spec.sidebarBackground,
          'surfaceCard': spec.surfaceCard,
          'surfaceElevated': spec.surfaceElevated,
        };
        for (final entry in surfaces.entries) {
          final primaryRatio = _contrastRatio(spec.textPrimary, entry.value);
          final mutedRatio = _contrastRatio(spec.textMuted, entry.value);
          expect(
            primaryRatio,
            greaterThanOrEqualTo(4.5),
            reason:
                '${theme.id} textPrimary on ${entry.key} contrast $primaryRatio < 4.5',
          );
          expect(
            mutedRatio,
            greaterThanOrEqualTo(4.5),
            reason:
                '${theme.id} textMuted on ${entry.key} contrast $mutedRatio < 4.5',
          );
        }

        // Primary button text on accent fill must meet >= 4.5:1.
        final onAccentRatio = _contrastRatio(
          spec.onAccentColor,
          spec.accentPrimary,
        );
        expect(
          onAccentRatio,
          greaterThanOrEqualTo(4.5),
          reason:
              '${theme.id} onAccentColor on accentPrimary contrast $onAccentRatio < 4.5',
        );

        // Laptop marker (#0F8A5F) and phone marker must remain visually distinct.
        expect(
          spec.phoneMarkerColor,
          isNot(equals(0xFF0F8A5F)),
          reason: '${theme.id} phoneMarkerColor must differ from laptop marker',
        );
      }

      expect(sidebarColors.length, WatSafeColorTheme.values.length);
      expect(surfaceColors.length, WatSafeColorTheme.values.length);
      expect(accentColors.length, WatSafeColorTheme.values.length);
    });

    test('2. Missing, legacy, camelCase, kebab-case, or corrupted theme preferences migrate safely without throwing', () {
      expect(WatSafeColorTheme.fromId(null), WatSafeColorTheme.obsidianAmber);
      expect(WatSafeColorTheme.fromId(''), WatSafeColorTheme.obsidianAmber);
      expect(WatSafeColorTheme.fromId('   '), WatSafeColorTheme.obsidianAmber);
      expect(
        WatSafeColorTheme.fromId('deleted_future_theme_v99'),
        WatSafeColorTheme.obsidianAmber,
      );
      expect(
        WatSafeColorTheme.fromId('cyberSentinel'),
        WatSafeColorTheme.cyberSentinel,
      );
      expect(
        WatSafeColorTheme.fromId('emerald-tactical'),
        WatSafeColorTheme.emeraldTactical,
      );
      expect(
        WatSafeColorTheme.fromId('CRIMSON_NIGHT'),
        WatSafeColorTheme.crimsonNight,
      );
      expect(
        WatSafeColorTheme.fromId('Royal Violet'),
        WatSafeColorTheme.royalViolet,
      );
      expect(
        WatSafeColorTheme.fromId('light'),
        WatSafeColorTheme.arcticDaylight,
      );

      // ProtectionSettings.fromJson handles missing or non-string colorTheme gracefully.
      final missingJson = ProtectionSettings.fromJson(const <String, Object?>{
        'onboardingCompleted': true,
      });
      expect(missingJson.colorTheme, WatSafeColorTheme.obsidianAmber);

      final corruptedJson = ProtectionSettings.fromJson(const <String, Object?>{
        'colorTheme': 12345,
        'onboardingCompleted': true,
      });
      expect(corruptedJson.colorTheme, WatSafeColorTheme.obsidianAmber);

      final aliasJson = ProtectionSettings.fromJson(const <String, Object?>{
        'colorTheme': 'royal-violet',
      });
      expect(aliasJson.colorTheme, WatSafeColorTheme.royalViolet);
    });

    testWidgets(
      '3. Desktop sidebar (NavigationRail + divider + AppBar), all screens, ActiveAlarmScreen, persistence, and 1.3x text scaling work cleanly across all 6 themes',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 860));
        addTearDown(() async {
          await tester.binding.setSurfaceSize(null);
          WatSafeTheme.primeColorTheme(WatSafeColorTheme.obsidianAmber);
        });

        final detector = FakeMotionDetector(
          type: DetectorType.macosCameraSceneMotion,
        );
        final audio = FakeAudioAlarmAdapter();
        final pinStorage = InMemorySecurePinStorage();
        final pinService = PinSecurityService(
          storage: pinStorage,
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '246810', confirmPin: '246810');

        final settingsStorage = InMemorySettingsStorage(
          const ProtectionSettings(
            selectedDetector: DetectorType.macosCameraSceneMotion,
            onboardingCompleted: true,
            shareLocationOnAlarm: true,
            armingCountdownSeconds: 3,
          ),
        );

        final controller = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.macosCameraSceneMotion: detector,
          },
          audioAdapter: audio,
          pinService: pinService,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: settingsStorage,
          notificationAdapter: const UnconfiguredRemoteNotificationService(),
        );
        await controller.initialize();

        await tester.pumpWidget(WatSafeApp(controller: controller));
        await tester.pumpAndSettle();

        // Navigate to Settings -> Appearance on desktop via NavigationRail.
        await tester.tap(find.text('Settings').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings_category_appearance')));
        await tester.pumpAndSettle();

        for (final theme in WatSafeColorTheme.values) {
          final optionFinder = find.byKey(Key('theme_option_${theme.id}'));
          await tester.ensureVisible(optionFinder);
          await tester.pumpAndSettle();
          await tester.tap(optionFinder);
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(controller.settings.colorTheme, theme);

          // Non-appearance settings remain completely untouched.
          expect(controller.settings.shareLocationOnAlarm, isTrue);
          expect(controller.settings.armingCountdownSeconds, 3);
          expect(
            controller.settings.selectedDetector,
            DetectorType.macosCameraSceneMotion,
          );

          final expectedPalette = WatSafeTheme.paletteFor(theme);

          final rail = tester.widget<NavigationRail>(
            find.byKey(const Key('desktop_navigation_rail')),
          );
          expect(rail.backgroundColor, expectedPalette.sidebarBackground);
          expect(rail.indicatorColor, expectedPalette.sidebarIndicator);
          expect(rail.selectedIconTheme?.color, expectedPalette.accentPrimary);
          expect(rail.unselectedIconTheme?.color, expectedPalette.textMuted);

          final sidebarDivider = tester.widget<VerticalDivider>(
            find.byKey(const Key('desktop_sidebar_divider')),
          );
          expect(sidebarDivider.color, expectedPalette.sidebarBorder);

          final headerDivider = tester.widget<Container>(
            find.byKey(const Key('app_header_divider')),
          );
          expect(headerDivider.color, expectedPalette.sidebarBorder);

          final appBar = tester.widget<AppBar>(find.byType(AppBar).first);
          expect(appBar.backgroundColor, expectedPalette.sidebarBackground);
        }

        // Select Royal Violet and verify Home, Devices, Activity, ActiveAlarmScreen, and restart persistence.
        final royalCard = find.byKey(
          Key('theme_option_${WatSafeColorTheme.royalViolet.id}'),
        );
        await tester.ensureVisible(royalCard);
        await tester.pumpAndSettle();
        await tester.tap(royalCard);
        await tester.pumpAndSettle();
        expect(controller.settings.colorTheme, WatSafeColorTheme.royalViolet);

        for (final navLabel in <String>['Home', 'Devices', 'Activity']) {
          await tester.tap(find.text(navLabel).first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        // Verify 1.3x text scaling at mobile portrait (390x844) & landscape (844x390) under Arctic Daylight.
        await controller.selectColorTheme(WatSafeColorTheme.arcticDaylight);
        for (final size in const <Size>[Size(390, 844), Size(844, 390)]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(
            MediaQuery(
              data: const MediaQueryData(
                size: Size(390, 844),
                textScaler: TextScaler.linear(1.3),
              ).copyWith(size: size),
              child: WatSafeApp(controller: controller),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        // Trigger ActiveAlarmScreen in Arctic Daylight and disarm cleanly.
        await tester.binding.setSurfaceSize(const Size(1280, 860));
        await tester.pumpWidget(WatSafeApp(controller: controller));
        await tester.pumpAndSettle();

        final started = await controller.startArming();
        expect(started, isTrue);
        final sessionId = controller.activeSessionId!;
        for (var i = 0; i < 3; i++) {
          await controller.handleCountdownTickForSession(sessionId);
        }
        expect(controller.state, ProtectionState.armed);

        detector.emit(
          DetectorEvent(
            eventId: 'evt_theme_alarm_check',
            sessionId: sessionId,
            detectorType: DetectorType.macosCameraSceneMotion,
            eventType: DetectorEventType.cameraObstructed,
            timestamp: DateTime.now().toUtc(),
            summary: 'Camera blocked during armed session',
            motionScore: 0.0,
            threshold: 0.095,
            consecutiveAboveThresholdFrames: 10,
          ),
        );
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump();
        expect(controller.state, ProtectionState.alarming);
        expect(tester.takeException(), isNull);

        final disarmed = await controller.verifyAndDisarm('246810');
        expect(disarmed.verified, isTrue);
        await tester.pumpAndSettle();
        expect(controller.state, ProtectionState.disarmed);

        // Verify saved theme persists across a fresh AlarmController initialization.
        final reloadedController = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.macosCameraSceneMotion: detector,
          },
          audioAdapter: audio,
          pinService: pinService,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: settingsStorage,
          notificationAdapter: const UnconfiguredRemoteNotificationService(),
        );
        await reloadedController.initialize();
        expect(
          reloadedController.settings.colorTheme,
          WatSafeColorTheme.arcticDaylight,
        );

        reloadedController.dispose();
        controller.dispose();
        await detector.dispose();
      },
    );

    test('4. Phone web companion embeds exact shared 6-theme catalog, applies theme synchronously in <head>, decouples appearance storage from pairing state, and serves swVersion 2026.11.19-v9', () async {
      final server = WatSafeRelayServer(store: InMemoryRelayStore());
      await server.start(port: 0);
      addTearDown(() async => server.stop());

      final baseUrl = 'http://127.0.0.1:${server.port}';
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      Future<String> fetchText(String path) async {
        final req = await client.getUrl(Uri.parse('$baseUrl$path'));
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        return utf8.decoder.bind(resp).join();
      }

      final healthRaw = await fetchText('/v1/health');
      final health = jsonDecode(healthRaw) as Map<String, dynamic>;
      expect(health['swVersion'], CompanionPwaAssets.serviceWorkerVersion);
      expect(health['swVersion'], '2026.11.19-v9');

      final swJs = await fetchText('/sw.js');
      expect(swJs, contains("SHELL_CACHE = 'watsafe-shell-2026.11.19-v9'"));

      final html = await fetchText('/companion');
      expect(
        html,
        contains(
          '<meta name="theme-color" id="themeColorMeta" content="#171C24">',
        ),
      );
      expect(
        html,
        contains(
          '<meta name="apple-mobile-web-app-status-bar-style" content="black" id="appleStatusBarMeta">',
        ),
      );

      // Extract embedded theme catalog JSON from <head> and compare 1:1 with WatSafeThemeCatalog.
      final catalogMatch = RegExp(r'const THEMES = (\[[\s\S]*?\]);')
          .firstMatch(html);
      expect(catalogMatch, isNotNull);
      final parsedThemes = (jsonDecode(
        catalogMatch!.group(1)!,
      ) as List<dynamic>).cast<Map<String, dynamic>>();
      expect(parsedThemes, hasLength(WatSafeColorTheme.values.length));

      for (var i = 0; i < WatSafeColorTheme.values.length; i++) {
        final expected = WatSafeThemeCatalog.specFor(
          WatSafeColorTheme.values[i],
        ).toWebMap();
        final actual = parsedThemes[i];
        expect(actual['id'], expected['id']);
        expect(actual['name'], expected['name']);
        expect(actual['shortName'], expected['shortName']);
        expect(actual['bg'], expected['bg']);
        expect(actual['chrome'], expected['chrome']);
        expect(actual['surface'], expected['surface']);
        expect(actual['accent'], expected['accent']);
        expect(actual['onAccent'], expected['onAccent']);
        expect(actual['themeColorMeta'], expected['themeColorMeta']);
        expect(actual['phoneMarker'], expected['phoneMarker']);
        expect(actual['laptopMarker'], expected['laptopMarker']);
      }

      // Verify Settings -> Appearance UI hooks & decoupled appearance storage keys.
      expect(html, contains('id="openAppearancePageBtn"'));
      expect(html, contains('id="settingsAppearancePage"'));
      expect(html, contains('id="phoneThemeOptionsList"'));
      expect(html, contains('role="radiogroup"'));
      expect(html, contains("const APPEARANCE_KEY = 'watsafe.appearance.v1'"));
      expect(html, contains("const IDB_APPEARANCE_KEY = 'appearance'"));
      expect(html, contains('activeSettingsSubpage'));

      // Verify session revocation & disconnect only remove pairing keys and never wipe watsafe.appearance.v1.
      final revokedFnMatch = RegExp(
        r'async function handleServerRevokedSession\(\)\s*\{[\s\S]*?\n    \}',
      ).firstMatch(html);
      expect(revokedFnMatch, isNotNull);
      final revokedFnSource = revokedFnMatch!.group(0)!;
      expect(revokedFnSource, contains('localStorage.removeItem(STORAGE_KEY)'));
      expect(revokedFnSource, isNot(contains('APPEARANCE_STORAGE_KEY')));
      expect(revokedFnSource, isNot(contains('IDB_APPEARANCE_KEY')));
      expect(html, isNot(contains('removeItem(APPEARANCE_STORAGE_KEY)')));
      expect(html, isNot(contains('delete(IDB_APPEARANCE_KEY)')));

      // Verify Dockerfile copies the shared pure-Dart theme catalog for standalone cloud builds.
      final dockerfile = await File('Dockerfile').readAsString();
      expect(
        dockerfile,
        contains(
          'COPY lib/core/models/theme_palette_catalog.dart ./lib/core/models/theme_palette_catalog.dart',
        ),
      );
    });
  });
}
