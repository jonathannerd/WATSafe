import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/incident_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/main.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_notification_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/location_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

import '../backend/server.dart';
import 'alarm_controller_test.dart';

void main() {
  group('End-to-End UX, Pairing, Real Notifications & Protected Device Location', () {
    late WatSafeRelayServer relayServer;
    late EnvironmentPushProviderAdapter pushProvider;
    late List<OutboundPushEnvelope> recordedPushEnvelopes;
    late int relayPort;
    late DateTime serverClockUtc;

    setUp(() async {
      HttpOverrides.global = null;
      serverClockUtc = DateTime.now().toUtc();
      recordedPushEnvelopes = <OutboundPushEnvelope>[];
      pushProvider = EnvironmentPushProviderAdapter(
        environment: const <String, String>{
          'VAPID_PUBLIC_KEY': 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFg',
        },
        customSender: (envelope) async {
          recordedPushEnvelopes.add(envelope);
          return true;
        },
      );
      relayServer = WatSafeRelayServer(
        store: InMemoryRelayStore(),
        pushProvider: pushProvider,
        clock: () => serverClockUtc,
      );
      relayPort = await relayServer.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
    });

    tearDown(() async {
      await relayServer.stop();
    });

    testWidgets(
      'Scenario 1 (Desktop 1280x860 + Phone 390x844): Fresh install -> Onboarding -> Real QR -> "Connect to Jonathan’s MacBook?" -> Notification permission -> Laptop auto-updates',
      (WidgetTester tester) async {
        HttpOverrides.global = null;
        final endpoint = 'http://127.0.0.1:$relayPort';

        // --- PART A: Fresh install on Desktop (1280x860) ---
        await tester.binding.setSurfaceSize(const Size(1280, 860));

        late FakeMotionDetector laptopDetector;
        late FakeAudioAlarmAdapter laptopAudio;
        late FakeLocationService laptopLocation;
        late FakeLocalNotificationService laptopLocalNotifs;
        late AlarmController laptopController;

        await tester.runAsync(() async {
          laptopDetector = FakeMotionDetector(
            type: DetectorType.macosCameraSceneMotion,
          );
          laptopAudio = FakeAudioAlarmAdapter();
          laptopLocation = FakeLocationService(
            permission: PermissionStatus.notDetermined,
          );
          laptopLocalNotifs = FakeLocalNotificationService(
            permission: PermissionStatus.notDetermined,
          );
          final laptopRemoteNotifs = ConfigurableRemoteNotificationService(
            persistToDisk: false,
            initialRelayEndpointUrl: endpoint,
            enableBackgroundPolling: false,
          );
          laptopController = AlarmController(
            detectors: <DetectorType, MotionDetectorAdapter>{
              DetectorType.macosCameraSceneMotion: laptopDetector,
            },
            audioAdapter: laptopAudio,
            pinService: PinSecurityService(
              storage: InMemorySecurePinStorage(),
              pbkdf2Iterations: 500,
            ),
            incidentStorage: InMemoryIncidentStorage(),
            settingsStorage: InMemorySettingsStorage(),
            notificationAdapter: laptopRemoteNotifs,
            locationAdapter: laptopLocation,
            localNotificationAdapter: laptopLocalNotifs,
          );
          await laptopController.initialize();
        });
        expect(laptopController.hasPinConfigured, isFalse);

        await tester.pumpWidget(WatSafeApp(controller: laptopController));
        await tester.pumpAndSettle();

        // Complete fresh onboarding: device name, location permission, 6-digit PIN
        await tester.enterText(
          find.byKey(const Key('onboarding_device_name_input')),
          'Jonathan’s MacBook',
        );
        await tester.tap(
          find.byKey(const Key('onboarding_allow_location_button')),
        );
        await tester.pumpAndSettle();
        expect(
          laptopController.locationPermissionStatus,
          PermissionStatus.granted,
        );

        await tester.enterText(
          find.byKey(const Key('onboarding_pin_input')),
          '246810',
        );
        await tester.enterText(
          find.byKey(const Key('onboarding_confirm_pin_input')),
          '246810',
        );
        await tester.tap(find.byKey(const Key('onboarding_complete_button')));
        await tester.pumpAndSettle();

        // Desktop uses NavigationRail with Home, Activity, Settings and plain language
        expect(find.byType(NavigationRail), findsOneWidget);
        expect(find.text('Home'), findsWidgets);
        expect(find.text('Activity'), findsOneWidget);
        expect(find.text('Settings'), findsOneWidget);
        expect(find.text('Off'), findsOneWidget);
        expect(find.text('Arm protection'), findsOneWidget);
        expect(find.text('Pair your phone'), findsOneWidget);

        // No developer/framework jargon or secondary remote clutter on Home
        expect(find.textContaining('AVFoundation'), findsNothing);
        expect(find.textContaining('MediaFoundation'), findsNothing);
        expect(find.textContaining('WinRT'), findsNothing);
        expect(find.text('Ring Device'), findsNothing);
        expect(find.text('Sync Status'), findsNothing);

        // Initiate QR pairing and open "Pair your phone" sheet
        late PairingCodeInvitation invite;
        await tester.runAsync(() async {
          invite = await laptopController.initiateHostPairing();
        });
        await tester.tap(find.byKey(const Key('pair_your_phone_row')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byKey(const Key('pairing_qr_matrix')), findsOneWidget);
        expect(
          find.text('Scan this with your phone’s camera.'),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('active_pairing_code_label')),
          findsOneWidget,
        );
        expect(invite.effectiveScanUrl, contains('/pair?code='));

        // Verify live HTTP endpoints scanned by real phone cameras & browsers
        await tester.runAsync(() async {
          final client = HttpClient();
          try {
            final pairPageReq = await client.getUrl(
              Uri.parse(invite.effectiveScanUrl),
            );
            final pairPageResp = await pairPageReq.close();
            final pairHtml = await utf8.decoder.bind(pairPageResp).join();
            expect(pairPageResp.statusCode, HttpStatus.ok);
            expect(pairHtml, contains('Connect'));
            expect(pairHtml, contains('/v1/pairing/lookup'));

            final swReq = await client.getUrl(Uri.parse('$endpoint/sw.js'));
            final swResp = await swReq.close();
            expect(swResp.statusCode, HttpStatus.ok);
            await swResp.drain<void>();

            final aasaReq = await client.getUrl(
              Uri.parse('$endpoint/.well-known/apple-app-site-association'),
            );
            final aasaResp = await aasaReq.close();
            expect(aasaResp.statusCode, HttpStatus.ok);
            await aasaResp.drain<void>();

            final assetLinksReq = await client.getUrl(
              Uri.parse('$endpoint/.well-known/assetlinks.json'),
            );
            final assetLinksResp = await assetLinksReq.close();
            expect(assetLinksResp.statusCode, HttpStatus.ok);
            await assetLinksResp.drain<void>();
          } finally {
            client.close(force: true);
          }
        });

        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();

        // --- PART B: Narrow Phone (390x844) opens scanned QR link ---
        await tester.binding.setSurfaceSize(const Size(390, 844));

        late FakeMotionDetector phoneDetector;
        late FakeLocalNotificationService phoneLocalNotifs;
        late AlarmController phoneController;

        await tester.runAsync(() async {
          phoneDetector = FakeMotionDetector(
            type: DetectorType.iosCoreMotionForeground,
          );
          phoneLocalNotifs = FakeLocalNotificationService(
            permission: PermissionStatus.notDetermined,
            pushToken: 'apns_tok_phone_1',
          );
          final phoneRemoteNotifs = ConfigurableRemoteNotificationService(
            persistToDisk: false,
            enableBackgroundPolling: false,
          );
          final phonePin = PinSecurityService(
            storage: InMemorySecurePinStorage(),
            pbkdf2Iterations: 500,
          );
          await phonePin.setupInitialPin(pin: '135790', confirmPin: '135790');
          phoneController = AlarmController(
            detectors: <DetectorType, MotionDetectorAdapter>{
              DetectorType.iosCoreMotionForeground: phoneDetector,
            },
            audioAdapter: FakeAudioAlarmAdapter(),
            pinService: phonePin,
            incidentStorage: InMemoryIncidentStorage(),
            settingsStorage: InMemorySettingsStorage(
              const ProtectionSettings(
                selectedDetector: DetectorType.iosCoreMotionForeground,
                onboardingCompleted: true,
                deviceDisplayName: 'Jonathan’s iPhone',
              ),
            ),
            notificationAdapter: phoneRemoteNotifs,
            localNotificationAdapter: phoneLocalNotifs,
          );
          await phoneController.initialize();
        });

        // Verify non-consuming lookup preview returns "Jonathan’s MacBook"
        late PairingLookupPreview preview;
        await tester.runAsync(() async {
          preview = await phoneController.lookupPairingInvitation(
            invite.effectiveScanUrl,
          );
        });
        expect(preview.hostDisplayName, 'Jonathan’s MacBook');

        Future<void> pumpRealHttp() async {
          for (var i = 0; i < 6; i++) {
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 25));
            });
            await tester.pump(const Duration(milliseconds: 20));
          }
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(
          WatSafeApp(
            key: const ValueKey<String>('phone_app'),
            controller: phoneController,
            initialPairingPayload: invite.effectiveScanUrl,
          ),
        );
        await tester.pump();
        await pumpRealHttp();

        // Narrow layout uses bottom NavigationBar with Home, Activity, Settings
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(find.byType(NavigationRail), findsNothing);

        // Phone displays "Connect to Jonathan’s MacBook?" with one Connect button
        expect(find.byKey(const Key('connect_to_host_title')), findsOneWidget);
        expect(find.text('Connect to Jonathan’s MacBook?'), findsOneWidget);
        expect(
          find.byKey(const Key('confirm_connect_phone_button')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('confirm_connect_phone_button')));
        await pumpRealHttp();

        // Phone asks for notification permission after explaining what it sends
        expect(
          find.byKey(const Key('enable_phone_notifications_button')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('enable_phone_notifications_button')),
        );
        await pumpRealHttp();
        await tester.runAsync(() async {
          await laptopController.syncPairedDevicesFromRelay();
        });
        await tester.pumpAndSettle();

        expect(phoneLocalNotifs.requestPermissionCount, 1);
        expect(
          phoneController.localNotificationPermissionStatus,
          PermissionStatus.granted,
        );
        expect(phoneController.companionSession.isConnected, isTrue);

        // Switch back to Desktop Laptop -> verify automatic "Phone connected • Notifications on"
        await tester.binding.setSurfaceSize(const Size(1280, 860));
        await tester.pumpWidget(
          WatSafeApp(
            key: const ValueKey<String>('laptop_app_after_pair'),
            controller: laptopController,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Jonathan’s iPhone'), findsOneWidget);
        expect(
          find.textContaining('Phone connected • Notifications on'),
          findsOneWidget,
        );

        // Open phone row details -> verify "Send test alert" and "Disconnect phone"
        await tester.tap(find.byKey(const Key('paired_phone_details_trigger')));
        await pumpRealHttp();
        expect(find.byKey(const Key('send_test_alert_button')), findsOneWidget);
        expect(
          find.byKey(const Key('disconnect_phone_button')),
          findsOneWidget,
        );

        laptopController.dispose();
        phoneController.dispose();
        await laptopDetector.dispose();
        await phoneDetector.dispose();
      },
    );

    testWidgets(
      'Scenarios 2 & 3: Unified test/real alert path, non-blocking async location, lock-screen push privacy, tap-to-open exact Activity event, map preview + Open in Maps, and coordinate auth',
      (WidgetTester tester) async {
        HttpOverrides.global = null;
        final endpoint = 'http://127.0.0.1:$relayPort';

        late FakeMotionDetector laptopDetector;
        late FakeAudioAlarmAdapter laptopAudio;
        late Completer<DeviceLocationSnapshot?> slowLocationCompleter;
        late FakeLocationService laptopLocation;
        late AlarmController laptopController;

        late FakeMotionDetector phoneDetector;
        late FakeLocalNotificationService phoneLocalNotifs;
        late AlarmController phoneController;

        await tester.runAsync(() async {
          laptopDetector = FakeMotionDetector(
            type: DetectorType.macosCameraSceneMotion,
          );
          laptopAudio = FakeAudioAlarmAdapter();
          slowLocationCompleter = Completer<DeviceLocationSnapshot?>();
          laptopLocation = FakeLocationService(
            permission: PermissionStatus.granted,
            captureCompleter: slowLocationCompleter,
          );

          final laptopPin = PinSecurityService(
            storage: InMemorySecurePinStorage(),
            pbkdf2Iterations: 500,
          );
          await laptopPin.setupInitialPin(pin: '246810', confirmPin: '246810');

          laptopController = AlarmController(
            detectors: <DetectorType, MotionDetectorAdapter>{
              DetectorType.macosCameraSceneMotion: laptopDetector,
            },
            audioAdapter: laptopAudio,
            pinService: laptopPin,
            incidentStorage: InMemoryIncidentStorage(),
            settingsStorage: InMemorySettingsStorage(
              const ProtectionSettings(
                selectedDetector: DetectorType.macosCameraSceneMotion,
                armingCountdownSeconds: 1,
                onboardingCompleted: true,
                deviceDisplayName: 'Jonathan’s MacBook',
                shareLocationOnAlarm: true,
              ),
            ),
            notificationAdapter: ConfigurableRemoteNotificationService(
              persistToDisk: false,
              initialRelayEndpointUrl: endpoint,
              enableBackgroundPolling: false,
            ),
            locationAdapter: laptopLocation,
          );
          await laptopController.initialize();

          phoneDetector = FakeMotionDetector(
            type: DetectorType.iosCoreMotionForeground,
          );
          phoneLocalNotifs = FakeLocalNotificationService(
            permission: PermissionStatus.granted,
            pushToken: 'apns_device_tok_99',
          );
          final phonePin = PinSecurityService(
            storage: InMemorySecurePinStorage(),
            pbkdf2Iterations: 500,
          );
          await phonePin.setupInitialPin(pin: '998877', confirmPin: '998877');

          final phoneRemoteNotifs = ConfigurableRemoteNotificationService(
            persistToDisk: false,
            enableBackgroundPolling: false,
          );
          phoneController = AlarmController(
            detectors: <DetectorType, MotionDetectorAdapter>{
              DetectorType.iosCoreMotionForeground: phoneDetector,
            },
            audioAdapter: FakeAudioAlarmAdapter(),
            pinService: phonePin,
            incidentStorage: InMemoryIncidentStorage(),
            settingsStorage: InMemorySettingsStorage(
              const ProtectionSettings(
                selectedDetector: DetectorType.iosCoreMotionForeground,
                onboardingCompleted: true,
                deviceDisplayName: 'Jonathan’s iPhone',
              ),
            ),
            notificationAdapter: phoneRemoteNotifs,
            localNotificationAdapter: phoneLocalNotifs,
          );
          await phoneController.initialize();

          final invite = await laptopController.initiateHostPairing();
          await phoneController.pairAsCompanionPhone(
            pairingCodeOrPayload: invite.effectiveScanUrl,
            displayName: 'Jonathan’s iPhone',
            platform: 'iOS',
          );
          await laptopController.syncPairedDevicesFromRelay();
        });

        // 1. Send test alert uses the exact same relay + push + companion alert pipeline!
        laptopLocation.captureCompleter = null;
        laptopLocation.nextLocation = DeviceLocationSnapshot(
          latitude: 43.47230,
          longitude: -80.54490,
          accuracyMeters: 18,
          capturedAt: DateTime.utc(2026, 11, 15, 20, 1, 0),
          isApproximate: false,
        );

        await tester.runAsync(() async {
          final testDispatch = await laptopController
              .sendTestAlertToPairedPhone();
          expect(testDispatch.delivered, isTrue);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          await phoneController.pollCompanionAlertsOnce();
        });

        expect(recordedPushEnvelopes, hasLength(1));
        expect(recordedPushEnvelopes.first.title, 'Jonathan’s MacBook');
        expect(recordedPushEnvelopes.first.isTest, isTrue);
        // Lock-screen push text MUST NOT contain coordinates!
        expect(recordedPushEnvelopes.first.body, isNot(contains('43.4723')));
        expect(recordedPushEnvelopes.first.body, isNot(contains('-80.5449')));
        expect(phoneLocalNotifs.displayedNotifications, hasLength(1));
        expect(
          phoneLocalNotifs.displayedNotifications.first.deviceName,
          'Jonathan’s MacBook',
        );

        // 2. Real motion alarm with slow location lookup:
        //    Siren and initial phone notification MUST happen immediately BEFORE location resolves!
        laptopLocation.captureCompleter = slowLocationCompleter;
        await tester.runAsync(() async {
          await laptopController.startArming();
          final sid = laptopController.activeSessionId!;
          await laptopController.handleCountdownTickForSession(sid);
          expect(laptopController.state, ProtectionState.armed);

          laptopDetector.emit(
            DetectorEvent(
              eventId: 'evt_real_theft_e2e',
              sessionId: sid,
              detectorType: DetectorType.macosCameraSceneMotion,
              eventType: DetectorEventType.motionTriggered,
              timestamp: DateTime.utc(2026, 11, 15, 20, 5, 0),
              summary: 'Sudden movement detected while protected',
              motionScore: 0.44,
              threshold: 0.095,
              consecutiveAboveThresholdFrames: 3,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 120));
          await phoneController.pollCompanionAlertsOnce();
        });

        // Verify local siren AND initial phone notification arrived BEFORE slowLocationCompleter resolved!
        expect(slowLocationCompleter.isCompleted, isFalse);
        expect(laptopController.state, ProtectionState.alarming);
        expect(laptopAudio.isPlaying, isTrue);
        expect(recordedPushEnvelopes, hasLength(2));
        expect(phoneLocalNotifs.displayedNotifications, hasLength(2));
        final realAlarmIncidentId = laptopController.activeIncident!.id;
        expect(
          phoneLocalNotifs.displayedNotifications.last.incidentId,
          realAlarmIncidentId,
        );
        expect(phoneController.receivedCompanionAlerts.first.location, isNull);

        // 3. Resolve async location lookup -> attaches to laptop & relay & phone WITHOUT duplicate notification!
        final capturedFix = DeviceLocationSnapshot(
          latitude: 43.47230,
          longitude: -80.54490,
          accuracyMeters: 165,
          capturedAt: DateTime.utc(2026, 11, 15, 20, 5, 4),
          isApproximate: true,
          isLastKnown: false,
        );
        await tester.runAsync(() async {
          slowLocationCompleter.complete(capturedFix);
          await Future<void>.delayed(const Duration(milliseconds: 120));
          await phoneController.pollCompanionAlertsOnce();
        });

        // Deduplication check: NO third OS notification was displayed when location arrived!
        expect(phoneLocalNotifs.displayedNotifications, hasLength(2));
        final updatedRemoteEvent = phoneController.receivedCompanionAlerts
            .firstWhere((e) => e.incidentId == realAlarmIncidentId);
        expect(updatedRemoteEvent.location, isNotNull);
        expect(updatedRemoteEvent.location!.latitude, closeTo(43.4723, 0.0001));
        expect(
          updatedRemoteEvent.location!.precisionLabel,
          'Approximate location',
        );

        // 4. Verify unauthenticated HTTP client CANNOT fetch precise coordinates (401)
        await tester.runAsync(() async {
          final client = HttpClient();
          try {
            final unauthReq = await client.getUrl(
              Uri.parse('$endpoint/v1/companion/events/$realAlarmIncidentId'),
            );
            final unauthResp = await unauthReq.close();
            expect(unauthResp.statusCode, HttpStatus.unauthorized);
            await unauthResp.drain<void>();
          } finally {
            client.close(force: true);
          }
        });

        // 5. Render narrow phone UI (390x844), tap OS notification -> opens exact event in Activity!
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await tester.pumpWidget(WatSafeApp(controller: phoneController));
        await tester.pumpAndSettle();

        await tester.runAsync(() async {
          phoneLocalNotifs.simulateTap(realAlarmIncidentId);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('activity_selected_event_card')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('event_location_card')), findsOneWidget);
        expect(
          find.byKey(const Key('location_precision_badge')),
          findsOneWidget,
        );
        expect(find.text('Approximate location'), findsOneWidget);
        expect(
          find.byKey(const Key('location_recorded_time_label')),
          findsOneWidget,
        );

        // Verify in-app map centering is available and external "Open in Maps" is removed
        expect(find.byKey(const Key('open_in_maps_button')), findsNothing);
        final centerBtn = find.byKey(
          const Key('incident_center_on_device_button'),
        );
        await tester.ensureVisible(centerBtn);
        await tester.pumpAndSettle();
        await tester.tap(centerBtn);
        await tester.pumpAndSettle();

        laptopController.dispose();
        phoneController.dispose();
        await laptopDetector.dispose();
        await phoneDetector.dispose();
      },
    );

    testWidgets(
      'Scenarios 4 & 5: Location denied, notifications denied, expired QR & brute-force rate limit, persistence & disconnect revocation, and PIN disarm stopping siren immediately',
      (WidgetTester tester) async {
        HttpOverrides.global = null;
        final endpoint = 'http://127.0.0.1:$relayPort';
        late Directory tempDir;
        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp('watsafe_e2e_');
        });

        try {
          // --- 1. Expired QR code recovery + brute-force rate limiting ---
          await tester.binding.setSurfaceSize(const Size(1280, 860));

          late FakeMotionDetector laptopDetector;
          late FakeAudioAlarmAdapter laptopAudio;
          late AlarmController laptopController;
          late PairingCodeInvitation firstInvite;

          await tester.runAsync(() async {
            laptopDetector = FakeMotionDetector(
              type: DetectorType.macosCameraSceneMotion,
            );
            laptopAudio = FakeAudioAlarmAdapter();
            // Location permission DENIED on protected laptop
            final deniedLocation = FakeLocationService(
              permission: PermissionStatus.denied,
            );
            final laptopPin = PinSecurityService(
              storage: InMemorySecurePinStorage(),
              pbkdf2Iterations: 500,
            );
            await laptopPin.setupInitialPin(
              pin: '654321',
              confirmPin: '654321',
            );

            final laptopRemote = ConfigurableRemoteNotificationService(
              persistToDisk: true,
              storageDirectory: tempDir.path,
              initialRelayEndpointUrl: endpoint,
              enableBackgroundPolling: false,
              clock: () => serverClockUtc,
            );
            laptopController = AlarmController(
              detectors: <DetectorType, MotionDetectorAdapter>{
                DetectorType.macosCameraSceneMotion: laptopDetector,
              },
              audioAdapter: laptopAudio,
              pinService: laptopPin,
              incidentStorage: InMemoryIncidentStorage(),
              settingsStorage: InMemorySettingsStorage(
                const ProtectionSettings(
                  selectedDetector: DetectorType.macosCameraSceneMotion,
                  armingCountdownSeconds: 1,
                  onboardingCompleted: true,
                  deviceDisplayName: 'Campus Laptop',
                  shareLocationOnAlarm: true,
                ),
              ),
              notificationAdapter: laptopRemote,
              locationAdapter: deniedLocation,
            );
            await laptopController.initialize();
            firstInvite = await laptopController.initiateHostPairing();
          });

          // Advance server clock past 5-minute TTL -> code expires!
          serverClockUtc = serverClockUtc.add(const Duration(minutes: 6));
          await tester.runAsync(() async {
            await expectLater(
              laptopController.lookupPairingInvitation(firstInvite.pairingCode),
              throwsStateError,
            );
            // Mint a fresh code -> succeeds!
            firstInvite = await laptopController.initiateHostPairing();
          });

          // Verify brute-force protection: 5 wrong guesses trigger 429 rate limit
          await tester.runAsync(() async {
            final client = HttpClient();
            try {
              var saw429 = false;
              for (var i = 0; i < 6; i++) {
                final req = await client.postUrl(
                  Uri.parse('$endpoint/v1/pairing/complete'),
                );
                req.headers.set('x-forwarded-for', '203.0.113.77');
                req.headers.contentType = ContentType.json;
                req.write(
                  jsonEncode(<String, Object?>{
                    'pairingCode': 'ZZZ999',
                    'displayName': 'Attacker',
                    'platform': 'Web',
                  }),
                );
                final resp = await req.close();
                if (resp.statusCode == HttpStatus.tooManyRequests) {
                  saw429 = true;
                }
                await resp.drain<void>();
              }
              expect(saw429, isTrue);
            } finally {
              client.close(force: true);
            }
          });

          // --- 2. Phone pairs with notifications DENIED + persists across restart ---
          late FakeMotionDetector phoneDetector;
          late AlarmController phoneController;
          late ConfigurableRemoteNotificationService phoneRemoteReloaded;

          await tester.runAsync(() async {
            final phoneDir = await Directory('${tempDir.path}/phone').create();
            final deniedPhoneNotifs = FakeLocalNotificationService(
              permission: PermissionStatus.denied,
            );
            final phonePin = PinSecurityService(
              storage: InMemorySecurePinStorage(),
              pbkdf2Iterations: 500,
            );
            await phonePin.setupInitialPin(pin: '111222', confirmPin: '111222');

            final phoneRemote1 = ConfigurableRemoteNotificationService(
              persistToDisk: true,
              storageDirectory: phoneDir.path,
              enableBackgroundPolling: false,
            );
            phoneDetector = FakeMotionDetector(
              type: DetectorType.androidMotionSensors,
            );
            phoneController = AlarmController(
              detectors: <DetectorType, MotionDetectorAdapter>{
                DetectorType.androidMotionSensors: phoneDetector,
              },
              audioAdapter: FakeAudioAlarmAdapter(),
              pinService: phonePin,
              incidentStorage: InMemoryIncidentStorage(),
              settingsStorage: InMemorySettingsStorage(
                const ProtectionSettings(
                  selectedDetector: DetectorType.androidMotionSensors,
                  onboardingCompleted: true,
                ),
              ),
              notificationAdapter: phoneRemote1,
              localNotificationAdapter: deniedPhoneNotifs,
            );
            await phoneController.initialize();

            await phoneController.pairAsCompanionPhone(
              pairingCodeOrPayload: firstInvite.effectiveScanUrl,
              displayName: 'Sam’s Pixel',
              platform: 'Android',
            );
            await laptopController.syncPairedDevicesFromRelay();

            // Laptop reflects "Notifications off" when phone denied notification permission
            expect(laptopController.pairedDevices, hasLength(1));
            expect(
              laptopController.pairedDevices.first.notificationsEnabled,
              isFalse,
            );

            // Simulate restarting the phone's remote notification adapter from disk
            phoneRemote1.dispose();
            phoneRemoteReloaded = ConfigurableRemoteNotificationService(
              persistToDisk: true,
              storageDirectory: phoneDir.path,
              enableBackgroundPolling: false,
            );
            await phoneRemoteReloaded.getStatus();
            expect(phoneRemoteReloaded.companionSession.isConnected, isTrue);
            expect(
              phoneRemoteReloaded.companionSession.hostDisplayName,
              'Campus Laptop',
            );
          });

          // --- 3. Trigger alarm while laptop location permission is DENIED ---
          //        Siren & phone alert STILL succeed, and Activity explains location is unavailable!
          await tester.pumpWidget(WatSafeApp(controller: laptopController));
          await tester.pumpAndSettle();

          await tester.runAsync(() async {
            await laptopController.startArming();
            final sid = laptopController.activeSessionId!;
            await laptopController.handleCountdownTickForSession(sid);
            laptopDetector.emit(
              DetectorEvent(
                eventId: 'evt_loc_denied_1',
                sessionId: sid,
                detectorType: DetectorType.macosCameraSceneMotion,
                eventType: DetectorEventType.motionTriggered,
                timestamp: DateTime.utc(2026, 11, 15, 20, 12, 0),
                summary: 'Laptop lifted while location permission off',
                motionScore: 0.42,
                threshold: 0.095,
                consecutiveAboveThresholdFrames: 3,
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 120));
            final polled = await phoneRemoteReloaded.pollCompanionAlertsOnce();
            expect(polled, hasLength(1));
            expect(polled.first.location, isNull);
            expect(
              polled.first.locationStatus,
              IncidentLocationStatus.permissionDenied,
            );
          });
          await tester.pumpAndSettle();

          // --- 4. Scenario 5: Active Alarm Screen & Immediate Siren Stop on Correct PIN ---
          expect(laptopController.state, ProtectionState.alarming);
          expect(laptopAudio.isPlaying, isTrue);
          expect(find.byKey(const Key('alarm_pin_input')), findsOneWidget);
          expect(find.byKey(const Key('alarm_disarm_button')), findsOneWidget);

          // Wrong PIN leaves alarm active and siren playing
          await tester.enterText(
            find.byKey(const Key('alarm_pin_input')),
            '000000',
          );
          await tester.tap(find.byKey(const Key('alarm_disarm_button')));
          await tester.pumpAndSettle();
          expect(laptopController.state, ProtectionState.alarming);
          expect(laptopAudio.isPlaying, isTrue);

          // Correct PIN stops siren IMMEDIATELY and returns to Off
          await tester.enterText(
            find.byKey(const Key('alarm_pin_input')),
            '654321',
          );
          await tester.tap(find.byKey(const Key('alarm_disarm_button')));
          await tester.runAsync(() async {
            final deadline = DateTime.now().add(const Duration(seconds: 5));
            while ((laptopController.state != ProtectionState.disarmed ||
                    laptopAudio.isPlaying) &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
          await tester.pumpAndSettle();

          expect(laptopAudio.isPlaying, isFalse);
          expect(laptopController.state, ProtectionState.disarmed);
          expect(find.text('Off'), findsOneWidget);

          // Open Activity tab on laptop -> select incident -> verify plain-language location-denied notice
          await tester.tap(find.text('Activity'));
          await tester.pumpAndSettle();
          final deniedIncidentId = laptopController.incidents.first.id;
          await tester.tap(find.byKey(Key('activity_row_$deniedIncidentId')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('location_unavailable_notice')),
            findsOneWidget,
          );
          expect(
            find.textContaining('location permission was turned off'),
            findsOneWidget,
          );

          // --- 5. Disconnect from phone revokes companion token & updates laptop ---
          await tester.runAsync(() async {
            await phoneRemoteReloaded.disconnectCompanionSession();
            expect(phoneRemoteReloaded.companionSession.isConnected, isFalse);
            await laptopController.syncPairedDevicesFromRelay();
          });
          expect(laptopController.pairedDevices, isEmpty);

          phoneRemoteReloaded.dispose();
          laptopController.dispose();
          phoneController.dispose();
          await laptopDetector.dispose();
          await phoneDetector.dispose();
        } finally {
          await tester.runAsync(() async {
            if (await tempDir.exists()) {
              await tempDir.delete(recursive: true);
            }
          });
        }
      },
    );
  });
}
