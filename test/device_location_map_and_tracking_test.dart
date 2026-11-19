import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/incident_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/features/devices/device_geographic_map.dart';
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

Future<({int statusCode, Map<String, dynamic> json, String rawBody})>
_httpJson({
  required HttpClient client,
  required String method,
  required Uri uri,
  String? bearerToken,
  Map<String, Object?>? body,
}) async {
  final req = await client.openUrl(method, uri);
  req.headers.contentType = ContentType.json;
  if (bearerToken != null) {
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearerToken');
  }
  if (body != null) {
    req.add(utf8.encode(jsonEncode(body)));
  }
  final resp = await req.close();
  final raw = await utf8.decoder.bind(resp).join();
  Map<String, dynamic> decoded = <String, dynamic>{};
  if (raw.trim().isNotEmpty) {
    final parsed = jsonDecode(raw);
    if (parsed is Map<String, dynamic>) {
      decoded = parsed;
    }
  }
  return (statusCode: resp.statusCode, json: decoded, rawBody: raw);
}

void main() {
  group('Priority 1: Device Location, Maps, Authorization & Following an Alarm', () {
    late WatSafeRelayServer relayServer;
    late EnvironmentPushProviderAdapter pushProvider;
    late List<OutboundPushEnvelope> recordedPushEnvelopes;
    late int relayPort;
    late DateTime serverClockUtc;

    setUp(() async {
      HttpOverrides.global = null;
      serverClockUtc = DateTime.utc(2026, 11, 17, 15, 0, 0);
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

    test('1. Coordinate validation rejects (0, 0), NaN, out-of-range & negative accuracy; trail filter suppresses Wi-Fi jitter and impossible jumps', () {
      final t0 = DateTime.utc(2026, 11, 17, 15, 0, 0);

      expect(
        DeviceLocationSnapshot.isValidCoordinates(0.0, 0.0),
        isFalse,
        reason:
            'Null-island (0, 0) must never be treated as a usable coordinate',
      );
      expect(DeviceLocationSnapshot.isValidCoordinates(1e-7, -1e-7), isFalse);
      expect(
        DeviceLocationSnapshot.isValidCoordinates(double.nan, -80.54),
        isFalse,
      );
      expect(DeviceLocationSnapshot.isValidCoordinates(91.2, -80.54), isFalse);
      expect(DeviceLocationSnapshot.isValidCoordinates(43.47, -181.0), isFalse);
      expect(
        DeviceLocationSnapshot.isValidCoordinates(
          43.4723,
          -80.5449,
          accuracyMeters: -5.0,
        ),
        isFalse,
      );

      expect(
        DeviceLocationSnapshot.tryFromJson(<String, Object?>{
          'latitude': 0.0,
          'longitude': 0.0,
          'accuracyMeters': 10.0,
          'capturedAt': t0.toIso8601String(),
        }),
        isNull,
      );

      final p1 = DeviceLocationSnapshot(
        latitude: 43.47230,
        longitude: -80.54490,
        accuracyMeters: 42.0,
        capturedAt: t0,
      );
      expect(p1.isValid, isTrue);
      expect(p1.isApproximate, isFalse);

      final approxWifi = DeviceLocationSnapshot(
        latitude: 43.47230,
        longitude: -80.54490,
        accuracyMeters: 140.0,
        capturedAt: t0,
      );
      expect(approxWifi.isEffectivelyApproximate, isTrue);
      expect(approxWifi.accuracyDescription, contains('Approximate location'));

      var trail = DeviceLocationSnapshot.appendFilteredTrailPoint(
        const <DeviceLocationSnapshot>[],
        p1,
      );
      expect(trail, hasLength(1));

      // Noisy Wi-Fi bounce (~14m away with 45m accuracy -> inside accuracy circle):
      final jitterPoint = DeviceLocationSnapshot(
        latitude: 43.47240,
        longitude: -80.54480,
        accuracyMeters: 45.0,
        capturedAt: t0.add(const Duration(seconds: 15)),
      );
      trail = DeviceLocationSnapshot.appendFilteredTrailPoint(
        trail,
        jitterPoint,
      );
      expect(
        trail,
        hasLength(1),
        reason: 'Approximate Wi-Fi jitter inside accuracy circle must not draw a fake route',
      );

      // Impossible jump (~11 km in 10 seconds -> > 1,000 m/s):
      final teleportPoint = DeviceLocationSnapshot(
        latitude: 43.57230,
        longitude: -80.54490,
        accuracyMeters: 15.0,
        capturedAt: t0.add(const Duration(seconds: 25)),
      );
      trail = DeviceLocationSnapshot.appendFilteredTrailPoint(
        trail,
        teleportPoint,
      );
      expect(
        trail,
        hasLength(1),
        reason: 'Impossible > 65 m/s jump must be filtered out',
      );

      // Genuine walking/carrying movement (~185m away over 45 seconds, 14m accuracy):
      final walkedPoint = DeviceLocationSnapshot(
        latitude: 43.47380,
        longitude: -80.54390,
        accuracyMeters: 14.0,
        capturedAt: t0.add(const Duration(seconds: 45)),
      );
      trail = DeviceLocationSnapshot.appendFilteredTrailPoint(
        trail,
        walkedPoint,
      );
      expect(trail, hasLength(2));
      expect(walkedPoint.differsMeaningfullyFrom(p1), isTrue);
    });

    test('2. Relay enforces strict authenticated session isolation (401/403), rejects invalid coordinates (400), and attributes protected-device location strictly to the protected device', () async {
      final endpoint = 'http://127.0.0.1:$relayPort';
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      // Create Session A (Jonathan's MacBook <-> Jonathan's iPhone)
      final hostA = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/initiate'),
        body: const <String, Object?>{'hostDisplayName': 'Jonathan MacBook'},
      );
      expect(hostA.statusCode, 200);
      final sessionAId = hostA.json['pairingSessionId'] as String;
      final hostAToken = hostA.json['hostToken'] as String;
      final pairingCodeA = hostA.json['pairingCode'] as String;

      final pairA = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': pairingCodeA,
          'displayName': 'Jonathan iPhone 13',
          'platform': 'iOS Web App',
          'notificationsEnabled': true,
        },
      );
      expect(pairA.statusCode, 200);
      final deviceAId = pairA.json['deviceId'] as String;
      final companionAToken = pairA.json['companionToken'] as String;

      // Create Session B (Separate User's Laptop <-> Phone)
      final hostB = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/initiate'),
        body: const <String, Object?>{'hostDisplayName': 'Other Laptop'},
      );
      expect(hostB.statusCode, 200);
      final hostBToken = hostB.json['hostToken'] as String;
      final pairingCodeB = hostB.json['pairingCode'] as String;

      final pairB = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': pairingCodeB,
          'displayName': 'Other Phone',
          'platform': 'Android',
        },
      );
      expect(pairB.statusCode, 200);
      final companionBToken = pairB.json['companionToken'] as String;

      // Unauthenticated requests are rejected with 401
      final unauthDevices = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations'),
      );
      expect(unauthDevices.statusCode, 401);

      // Invalid (0, 0) coordinate upload is rejected with 400
      final badLocResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/host/location'),
        bearerToken: hostAToken,
        body: <String, Object?>{
          'locationStatus': 'attached',
          'location': <String, Object?>{
            'latitude': 0.0,
            'longitude': 0.0,
            'accuracyMeters': 10.0,
            'capturedAt': serverClockUtc.toIso8601String(),
          },
        },
      );
      expect(badLocResp.statusCode, 400);
      expect(badLocResp.json['error'], 'INVALID_LOCATION_COORDINATES');

      // Upload valid protected-device location for Laptop A
      final validLocResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/host/location'),
        bearerToken: hostAToken,
        body: <String, Object?>{
          'locationStatus': 'attached',
          'protectionState': 'Protected',
          'location': <String, Object?>{
            'latitude': 43.472285,
            'longitude': -80.544858,
            'accuracyMeters': 28.0,
            'capturedAt': serverClockUtc.toIso8601String(),
          },
        },
      );
      expect(validLocResp.statusCode, 200);

      // Cross-session ID tampering from Companion B or Host B MUST return 403 and zero coordinates
      final crossSessionAttempt = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations?sessionId=$sessionAId'),
        bearerToken: companionBToken,
      );
      expect(crossSessionAttempt.statusCode, 403);
      expect(
        crossSessionAttempt.json['error'],
        'FORBIDDEN_CROSS_SESSION_ACCESS',
      );
      expect(crossSessionAttempt.rawBody, isNot(contains('43.472285')));

      final crossDeviceAttempt = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse(
          '$endpoint/v1/devices/locations?deviceId=host_$sessionAId',
        ),
        bearerToken: hostBToken,
      );
      expect(crossDeviceAttempt.statusCode, 403);
      expect(crossDeviceAttempt.json['error'], 'FORBIDDEN_DEVICE_ACCESS');
      expect(crossDeviceAttempt.rawBody, isNot(contains('43.472285')));

      final crossCompanionDeviceAttempt = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations?deviceId=$deviceAId'),
        bearerToken: companionBToken,
      );
      expect(crossCompanionDeviceAttempt.statusCode, 403);

      // Authorized Companion A receives Laptop A's coordinates strictly on the protected_device entry,
      // and Companion Phone A never falsely claims Laptop A's coordinates.
      final authorizedResp = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations'),
        bearerToken: companionAToken,
      );
      expect(authorizedResp.statusCode, 200);
      final devices = (authorizedResp.json['devices'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(devices, hasLength(2));

      final protectedHost = devices.singleWhere(
        (d) => d['role'] == 'protected_device',
      );
      final companionPhone = devices.singleWhere(
        (d) => d['role'] == 'companion_phone',
      );

      expect(protectedHost['displayName'], 'Jonathan MacBook');
      expect(
        (protectedHost['latestLocation'] as Map<String, dynamic>)['latitude'],
        closeTo(43.472285, 1e-6),
      );
      expect(companionPhone['displayName'], 'Jonathan iPhone 13');
      expect(companionPhone['latestLocation'], isNull);
    });

    test('3. Non-blocking alarm trigger, zero coordinates in push payload, bounded post-alarm trail updates, reconnect recovery, 7-day retention pruning, user deletion & immediate stop on PIN disarm', () async {
      final endpoint = 'http://127.0.0.1:$relayPort';
      final detector = FakeMotionDetector(
        type: DetectorType.macosCameraSceneMotion,
      );
      final audio = FakeAudioAlarmAdapter();
      final initialLocationCompleter = Completer<DeviceLocationSnapshot?>();
      final locationService = FakeLocationService(
        permission: PermissionStatus.granted,
        captureCompleter: initialLocationCompleter,
      );
      final pinService = PinSecurityService(
        storage: InMemorySecurePinStorage(),
        pbkdf2Iterations: 500,
      );
      await pinService.setupInitialPin(pin: '246810', confirmPin: '246810');

      final remoteNotifs = ConfigurableRemoteNotificationService(
        persistToDisk: false,
        initialRelayEndpointUrl: endpoint,
        enableBackgroundPolling: false,
      );
      final controller = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.macosCameraSceneMotion: detector,
        },
        audioAdapter: audio,
        pinService: pinService,
        incidentStorage: InMemoryIncidentStorage(),
        settingsStorage: InMemorySettingsStorage(
          const ProtectionSettings(
            selectedDetector: DetectorType.macosCameraSceneMotion,
            armingCountdownSeconds: 1,
            onboardingCompleted: true,
            deviceDisplayName: 'Studio MacBook Pro',
            shareLocationOnAlarm: true,
          ),
        ),
        notificationAdapter: remoteNotifs,
        locationAdapter: locationService,
        clock: () => serverClockUtc,
        postAlarmLocationInterval: const Duration(milliseconds: 45),
        postAlarmTrackingMaxDuration: const Duration(minutes: 15),
        postAlarmMaxSamples: 40,
      );
      addTearDown(() async {
        controller.dispose();
        await detector.dispose();
      });

      await controller.initialize();

      // Pair a companion phone and register Web Push subscription on relay
      final invite = await controller.initiateHostPairing();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final pairResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': invite.pairingCode,
          'displayName': 'My iPhone 13',
          'platform': 'iOS Web App',
          'notificationsEnabled': true,
        },
      );
      expect(pairResp.statusCode, 200);
      final companionToken = pairResp.json['companionToken'] as String;

      final subKeys = VapidKeyPair.generate();
      final authSecret = Uint8List.fromList(
        List<int>.generate(16, (idx) => (idx * 17 + 9) & 0xff),
      );
      final pushReg = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/companion/push-subscription'),
        bearerToken: companionToken,
        body: <String, Object?>{
          'endpoint': 'https://web.push.apple.com/test-sub-token-xyz',
          'p256dh': subKeys.publicKeyBase64Url,
          'auth': base64UrlNoPadEncode(authSecret),
          'platform': 'iOS Home Screen Web App',
          'httpsReady': true,
          'homeScreenInstalled': true,
          'notificationPermission': 'granted',
        },
      );
      expect(pushReg.statusCode, 200);
      await controller.syncPairedDevicesFromRelay();

      // Arm protection (keeping initialLocationCompleter pending!)
      await controller.startArming();
      final sid = controller.activeSessionId!;
      await controller.handleCountdownTickForSession(sid);
      expect(controller.state, ProtectionState.armed);

      // Emit clear pickup motion trigger while location completer is still pending!
      detector.emit(
        DetectorEvent(
          eventId: 'evt_pickup_1',
          sessionId: sid,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: serverClockUtc,
          summary: 'Sustained device pickup detected',
          motionScore: 0.42,
          threshold: 0.056,
          consecutiveAboveThresholdFrames: 3,
          coherentBlocks: 10,
        ),
      );

      // Give async siren + push dispatch a moment WITHOUT completing location
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(controller.state, ProtectionState.alarming);
      expect(
        audio.isPlaying,
        isTrue,
        reason: 'Local siren must never wait for geolocation',
      );
      expect(
        recordedPushEnvelopes,
        hasLength(1),
        reason: 'Initial phone push alert must fire immediately before location resolves',
      );
      expect(
        controller.activeIncident!.locationStatus,
        IncidentLocationStatus.pending,
      );

      // Verify lock-screen push payload never exposes coordinates
      final pushEnvelope = recordedPushEnvelopes.single;
      final combinedPushFields = jsonEncode(pushEnvelope.toSafeMetadataJson());
      expect(combinedPushFields, isNot(contains('43.47')));
      expect(combinedPushFields, isNot(contains('-80.54')));

      // Queue bounded post-alarm points before completing initial capture:
      // 1) Noisy jitter point (filtered out)
      // 2) Temporary null outage -> 'reconnecting'
      // 3) Genuine carried movement -> 'live' + 2-point trail + distinct alarm vs latest
      final alarmLoc = DeviceLocationSnapshot(
        latitude: 43.47230,
        longitude: -80.54490,
        accuracyMeters: 20.0,
        capturedAt: serverClockUtc,
      );
      final jitterLoc = DeviceLocationSnapshot(
        latitude: 43.47235,
        longitude: -80.54486,
        accuracyMeters: 30.0,
        capturedAt: serverClockUtc.add(const Duration(seconds: 15)),
      );
      final movedLoc = DeviceLocationSnapshot(
        latitude: 43.47440,
        longitude: -80.54210,
        accuracyMeters: 16.0,
        capturedAt: serverClockUtc.add(const Duration(seconds: 45)),
      );
      locationService.queuedLocations.addAll(<DeviceLocationSnapshot?>[
        jitterLoc,
        null,
        movedLoc,
      ]);
      locationService.nextLocation = movedLoc;

      // Complete initial alarm-time location and switch FakeLocationService to queued mode
      locationService.captureCompleter = null;
      initialLocationCompleter.complete(alarmLoc);

      // Wait enough intervals for queued post-alarm updates to process
      await Future<void>.delayed(const Duration(milliseconds: 240));

      final activeInc = controller.activeIncident!;
      expect(activeInc.locationStatus, IncidentLocationStatus.attached);
      expect(
        activeInc.alarmTimeLocation!.latitude,
        closeTo(43.47230, 1e-5),
        reason: 'Alarm-time location must be preserved when the device moves',
      );
      expect(
        activeInc.location!.latitude,
        closeTo(43.47440, 1e-5),
        reason:
            'Latest location must update as bounded post-alarm points arrive',
      );
      expect(activeInc.hasDistinctLatestLocation, isTrue);
      expect(
        activeInc.locationTrail,
        hasLength(2),
        reason: 'Noisy jitter point was rejected while genuine movement formed a 2-point trail',
      );
      expect(controller.isPostAlarmTrackingActive, isTrue);
      expect(controller.postAlarmTrackingState, 'live');

      // Confirm companion phone sees alarmLocation, latest location, and 2-point trail on relay
      final incidentId = activeInc.id;
      final companionEventsResp = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/companion/alerts'),
        bearerToken: companionToken,
      );
      expect(companionEventsResp.statusCode, 200);
      final relayEvents = (companionEventsResp.json['alerts'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final relayAlert = relayEvents.singleWhere(
        (e) => e['incidentId'] == incidentId,
      );
      expect(
        (relayAlert['alarmLocation'] as Map<String, dynamic>)['latitude'],
        closeTo(43.47230, 1e-5),
      );
      expect(
        (relayAlert['location'] as Map<String, dynamic>)['latitude'],
        closeTo(43.47440, 1e-5),
      );
      expect((relayAlert['locationTrail'] as List<dynamic>), hasLength(2));

      // Verify notification receipt acknowledgement (/ack) still works cleanly
      final ackResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/companion/events/$incidentId/ack'),
        bearerToken: companionToken,
        body: const <String, Object?>{'source': 'service_worker_push'},
      );
      expect(ackResp.statusCode, 200);
      expect(ackResp.json['receiptConfirmed'], isTrue);

      // Disarm with correct PIN -> siren AND post-alarm location tracking stop immediately!
      final capturesBeforeDisarm = locationService.captureCount;
      final disarmResult = await controller.verifyAndDisarm('246810');
      expect(disarmResult.verified, isTrue);
      expect(controller.state, ProtectionState.disarmed);
      expect(audio.isPlaying, isFalse);
      expect(controller.isPostAlarmTrackingActive, isFalse);
      expect(controller.incidents.first.locationTrackingState, 'stopped');

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        locationService.captureCount,
        capturesBeforeDisarm,
        reason: 'Zero post-alarm location captures may occur after PIN disarm',
      );

      // Advance server clock by 8 days (> 7-day retention window) and verify
      // coordinates & trails are automatically pruned while pairings & incident summary survive!
      serverClockUtc = serverClockUtc.add(const Duration(days: 8));
      final afterRetentionDevices = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations'),
        bearerToken: companionToken,
      );
      expect(afterRetentionDevices.statusCode, 200);
      final prunedHost =
          (afterRetentionDevices.json['devices'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .singleWhere((d) => d['role'] == 'protected_device');
      expect(
        prunedHost['latestLocation'],
        isNull,
        reason: 'Relay must prune device location history older than 7 days',
      );

      final afterRetentionEvents = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/companion/alerts'),
        bearerToken: companionToken,
      );
      final prunedEvent = (afterRetentionEvents.json['alerts'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .singleWhere((e) => e['incidentId'] == incidentId);
      expect(prunedEvent['location'], isNull);
      expect(prunedEvent['alarmLocation'], isNull);
      expect(prunedEvent['locationTrail'] ?? const <Object>[], isEmpty);
      expect(
        prunedEvent['triggerSummary'],
        contains('Sustained device pickup detected'),
        reason: 'Incident audit summary and pairing remain intact after 7-day coordinate expiry',
      );

      // Record a fresh host location, then invoke user-initiated deleteStoredLocationHistory()
      final freshLoc = DeviceLocationSnapshot(
        latitude: 43.47100,
        longitude: -80.54000,
        accuracyMeters: 22.0,
        capturedAt: serverClockUtc,
      );
      locationService.nextLocation = freshLoc;
      await controller.refreshProtectedDeviceLocation(highAccuracy: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(controller.hostLatestLocation, isNotNull);

      final deletedOk = await controller.deleteStoredLocationHistory();
      expect(deletedOk, isTrue);
      expect(controller.hostLatestLocation, isNull);
      expect(controller.incidents.first.location, isNull);
      expect(controller.incidents.first.alarmTimeLocation, isNull);
      expect(controller.incidents.first.locationTrail, isEmpty);
      expect(
        controller.pairedDevices,
        isNotEmpty,
        reason: 'Deleting location history must preserve paired devices',
      );
    });

    testWidgets(
      '4. Responsive Devices map (1280x860 desktop & 390x844 iPhone 13), Location unavailable state, notification tap -> direct incident map routing, and Companion PWA map assets',
      (WidgetTester tester) async {
        final endpoint = 'http://127.0.0.1:$relayPort';
        final now = DateTime.now();

        late FakeMotionDetector detector;
        late FakeAudioAlarmAdapter audio;
        late FakeLocationService locationService;
        late FakeLocalNotificationService localNotifs;
        late AlarmController controller;

        final alarmLoc = DeviceLocationSnapshot(
          latitude: 43.47230,
          longitude: -80.54490,
          accuracyMeters: 24.0,
          capturedAt: now.subtract(const Duration(minutes: 2)),
        );
        final movedLoc = DeviceLocationSnapshot(
          latitude: 43.47480,
          longitude: -80.54150,
          accuracyMeters: 18.0,
          capturedAt: now,
        );

        await tester.runAsync(() async {
          detector = FakeMotionDetector(
            type: DetectorType.macosCameraSceneMotion,
          );
          audio = FakeAudioAlarmAdapter();
          locationService = FakeLocationService(
            permission: PermissionStatus.denied,
            nextLocation: movedLoc,
          );
          localNotifs = FakeLocalNotificationService(
            permission: PermissionStatus.granted,
          );
          final pinService = PinSecurityService(
            storage: InMemorySecurePinStorage(),
            pbkdf2Iterations: 500,
          );
          await pinService.setupInitialPin(pin: '135790', confirmPin: '135790');

          final remoteNotifs = ConfigurableRemoteNotificationService(
            persistToDisk: false,
            initialRelayEndpointUrl: endpoint,
            enableBackgroundPolling: false,
          );
          controller = AlarmController(
            detectors: <DetectorType, MotionDetectorAdapter>{
              DetectorType.macosCameraSceneMotion: detector,
            },
            audioAdapter: audio,
            pinService: pinService,
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
            notificationAdapter: remoteNotifs,
            locationAdapter: locationService,
            localNotificationAdapter: localNotifs,
            postAlarmLocationInterval: const Duration(milliseconds: 40),
          );
          await controller.initialize();
        });
        addTearDown(() async {
          controller.dispose();
          await detector.dispose();
        });

        // --- A. Desktop (1280x860): Devices screen with denied permission shows "Location unavailable", NEVER (0, 0) ---
        await tester.binding.setSurfaceSize(const Size(1280, 860));
        await tester.pumpWidget(WatSafeApp(controller: controller));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Devices'));
        await tester.pumpAndSettle();

        expect(find.text('Location unavailable'), findsWidgets);
        expect(find.textContaining('0.00000'), findsNothing);
        expect(
          find.byKey(const Key('devices_grant_location_perm_btn')),
          findsOneWidget,
        );

        // Grant permission & refresh location -> interactive DeviceGeographicMap appears with attribution & actions
        await tester.runAsync(() async {
          locationService.permission = PermissionStatus.granted;
          await controller.requestLocationPermission();
          await controller.refreshProtectedDeviceLocation(highAccuracy: true);
        });
        await tester.pumpAndSettle();

        expect(find.byType(DeviceGeographicMap), findsOneWidget);
        expect(
          find.textContaining('OpenStreetMap contributors'),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('selected_device_name_label')),
          findsOneWidget,
        );
        expect(find.text('Center on device'), findsOneWidget);
        expect(find.text('Open in Maps'), findsNothing);
        expect(tester.takeException(), isNull);

        // --- B. iPhone 13 viewport (390x844): Devices screen remains clean and readable with zero overflow ---
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await tester.pumpAndSettle();
        expect(find.byType(DeviceGeographicMap), findsOneWidget);
        expect(find.text('Center on device'), findsOneWidget);
        expect(find.text('Open in Maps'), findsNothing);
        expect(tester.takeException(), isNull);

        // --- C. Trigger an alarm with distinct alarm-time & latest locations, return to Home, then tap notification ---
        late String triggeredIncidentId;
        await tester.runAsync(() async {
          await controller.startArming();
          final sid = controller.activeSessionId!;
          await controller.handleCountdownTickForSession(sid);

          locationService.queuedLocations
            ..clear()
            ..addAll(<DeviceLocationSnapshot?>[alarmLoc, movedLoc]);
          locationService.nextLocation = movedLoc;

          detector.emit(
            DetectorEvent(
              eventId: 'evt_tap_route',
              sessionId: sid,
              detectorType: DetectorType.macosCameraSceneMotion,
              eventType: DetectorEventType.motionTriggered,
              timestamp: now,
              summary: 'Device lifted from desk',
              motionScore: 0.35,
              threshold: 0.056,
              consecutiveAboveThresholdFrames: 3,
              coherentBlocks: 9,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 110));
          triggeredIncidentId = controller.activeIncident!.id;
          await controller.verifyAndDisarm('135790');
        });
        await tester.pumpAndSettle();

        // Navigate back to Home tab, then simulate tapping the alarm notification
        await tester.tap(find.text('Home'));
        await tester.pumpAndSettle();

        await tester.runAsync(() async {
          localNotifs.simulateTap(triggeredIncidentId);
          await Future<void>.delayed(const Duration(milliseconds: 25));
        });
        await tester.pumpAndSettle();

        // Tapping notification opens the exact incident with its DeviceGeographicMap,
        // Alarm-time vs Latest location comparison, and actions immediately visible!
        expect(
          find.byKey(const Key('activity_selected_event_card')),
          findsOneWidget,
        );
        expect(find.byType(DeviceGeographicMap), findsOneWidget);
        expect(
          find.byKey(const Key('alarm_vs_latest_location_card')),
          findsOneWidget,
        );
        expect(find.text('Alarm-time location'), findsOneWidget);
        expect(find.text('Latest known location'), findsOneWidget);
        expect(
          find.byKey(const Key('incident_center_on_device_button')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('open_in_maps_button')), findsNothing);

        // --- D. Verify Companion PWA HTML & Service Worker serve Devices map, attribution & notification routing ---
        await tester.runAsync(() async {
          final client = HttpClient();
          try {
            final pwaReq = await client.getUrl(
              Uri.parse('$endpoint/companion'),
            );
            final pwaResp = await pwaReq.close();
            final pwaHtml = await utf8.decoder.bind(pwaResp).join();
            expect(pwaResp.statusCode, 200);
            expect(pwaHtml, contains('id="tabDevices"'));
            expect(pwaHtml, contains('id="devicesMapStage"'));
            expect(pwaHtml, contains('OpenFreeMap'));
            expect(pwaHtml, contains('OpenStreetMap contributors'));
            expect(pwaHtml, contains('/v1/devices/locations'));
            expect(pwaHtml, contains('/v1/location-history'));
            expect(pwaHtml, contains('Center on device'));
            expect(pwaHtml, isNot(contains('Open in Maps')));

            final swReq = await client.getUrl(Uri.parse('$endpoint/sw.js'));
            final swResp = await swReq.close();
            final swJs = await utf8.decoder.bind(swResp).join();
            expect(swResp.statusCode, 200);
            expect(swJs, contains('OPEN_INCIDENT'));
            expect(swJs, contains('/ack'));
          } finally {
            client.close(force: true);
          }
        });
      },
    );
  });
}
