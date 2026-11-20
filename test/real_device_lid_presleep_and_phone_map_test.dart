import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/incident_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/location_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';
import 'package:watsafe/services/system_lifecycle_service.dart';

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

Future<void> _registerCompanionWebPush({
  required HttpClient client,
  required String endpoint,
  required String companionToken,
  String pushEndpoint = 'https://web.push.apple.com/test-sub-real-device-suite',
}) async {
  final subKeys = VapidKeyPair.generate();
  final authSecret = Uint8List.fromList(
    List<int>.generate(16, (idx) => (idx * 17 + 11) & 0xff),
  );
  final resp = await _httpJson(
    client: client,
    method: 'POST',
    uri: Uri.parse('$endpoint/v1/companion/push-subscription'),
    bearerToken: companionToken,
    body: <String, Object?>{
      'endpoint': pushEndpoint,
      'p256dh': subKeys.publicKeyBase64Url,
      'auth': base64UrlNoPadEncode(authSecret),
      'platform': 'iOS Home Screen Web App',
      'httpsReady': true,
      'homeScreenInstalled': true,
      'notificationPermission': 'granted',
    },
  );
  expect(resp.statusCode, 200);
}

Future<String> _armControllerImmediately(AlarmController controller) async {
  await controller.startArming();
  final sessionId = controller.activeSessionId!;
  await controller.handleCountdownTickForSession(sessionId);
  await Future<void>.delayed(const Duration(milliseconds: 50));
  expect(controller.state, ProtectionState.armed);
  return sessionId;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Real-Device Pre-Sleep Native Reporting, 30s Watchdog & Phone OSM Map Suite', () {
    setUp(() {
      HttpOverrides.global = null;
    });

    test('1. PlatformSystemLifecycleService syncs emergency credentials + cached location and decodes consumePendingEmergencyReport over MethodChannel', () async {
      const methodChannelName = 'dev.watsafe/system_lifecycle';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final recordedCalls = <MethodCall>[];

      messenger.setMockMethodCallHandler(
        const MethodChannel(methodChannelName),
        (MethodCall call) async {
          recordedCalls.add(call);
          if (call.method == 'getCapabilities') {
            return <String, Object?>{
              'isSupported': true,
              'supportsClamshellDetection': true,
              'supportsSleepWakeNotifications': true,
              'supportsShutdownLogoutNotifications': true,
              'supportsQuitInterception': true,
              'supportsInputInteractionDetection': true,
              'platformLabel': 'macOS Off-Main IOKit Emergency Bridge',
            };
          }
          if (call.method == 'consumePendingEmergencyReport') {
            return <String, Object?>{
              'incidentId': 'lid_session_99',
              'sessionId': 'session_99',
              'eventType': 'lidClosed',
              'summary': 'Laptop lid closed while armed',
              'triggeredAtMs': DateTime.utc(
                2026,
                11,
                19,
                18,
              ).millisecondsSinceEpoch,
              'clamshellClosed': true,
              'attempted': true,
              'relayRecorded': true,
              'pushAccepted': true,
              'pushFailed': false,
              'delivered': true,
              'httpStatusCode': 200,
              'deliveryStage': 'push_accepted',
            };
          }
          return null;
        },
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel(methodChannelName),
          null,
        );
      });

      final service = PlatformSystemLifecycleService(isDesktopOverride: true);
      addTearDown(() async => service.dispose());

      final loc = DeviceLocationSnapshot(
        latitude: 43.4723,
        longitude: -80.5449,
        accuracyMeters: 28.0,
        capturedAt: DateTime.utc(2026, 11, 19, 17, 58),
        isApproximate: false,
        isLastKnown: true,
      );
      await service.syncProtectionState(
        armed: true,
        monitorInputInteraction: false,
        armedSessionId: 'session_99',
        correlationIncidentId: 'lid_session_99',
        relayEndpointUrl: 'https://watsafe-relay.onrender.com',
        hostToken: 'host_tok_test_only',
        deviceName: 'My MacBook',
        detectorType: 'macosCameraSceneMotion',
        shareLocationOnAlarm: true,
        lastKnownLocationJson: loc.toJson(),
        alarmVolume: 0.85,
      );

      final syncCall = recordedCalls.singleWhere(
        (c) => c.method == 'syncProtectionState',
      );
      final args = syncCall.arguments as Map<Object?, Object?>;
      expect(args['armed'], isTrue);
      expect(args['relayEndpointUrl'], 'https://watsafe-relay.onrender.com');
      expect(args['armedSessionId'], 'session_99');
      expect(args['correlationIncidentId'], 'lid_session_99');
      expect(args['deviceName'], 'My MacBook');
      expect(args['shareLocationOnAlarm'], isTrue);
      final sentLoc = args['lastKnownLocation'] as Map<Object?, Object?>;
      expect(sentLoc['latitude'], closeTo(43.4723, 0.0001));
      expect(sentLoc['isLastKnown'], isTrue);

      final pending = await service.consumePendingEmergencyReport();
      expect(pending, isNotNull);
      expect(pending!.delivered, isTrue);
      expect(pending.pushAccepted, isTrue);
      expect(pending.incidentId, 'lid_session_99');
      expect(pending.sessionId, 'session_99');
    });

    test('2. Flutter frozen on lid close + successful native emergency POST: immediate push before sleep, zero watchdog duplicate, and wake reconciliation blocks delayed camera-motion alarms', () async {
      var clockUtc = DateTime.utc(2026, 11, 19, 18, 0, 0);
      final pushEnvelopes = <OutboundPushEnvelope>[];
      final pushProvider = EnvironmentPushProviderAdapter(
        environment: const <String, String>{
          'VAPID_PUBLIC_KEY': 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFg',
        },
        customSender: (envelope) async {
          pushEnvelopes.add(envelope);
          return true;
        },
      );
      final relay = WatSafeRelayServer(
        store: InMemoryRelayStore(clock: () => clockUtc),
        pushProvider: pushProvider,
        clock: () => clockUtc,
      );
      final port = await relay.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      addTearDown(() async => relay.stop());
      final endpoint = 'http://127.0.0.1:$port';

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final detector = FakeMotionDetector(
        type: DetectorType.macosCameraSceneMotion,
      );
      final audio = FakeAudioAlarmAdapter();
      final lifecycle = FakeSystemLifecycleService();
      final cachedLaptopLoc = DeviceLocationSnapshot(
        latitude: 43.4723,
        longitude: -80.5449,
        accuracyMeters: 32.0,
        capturedAt: clockUtc.subtract(const Duration(minutes: 2)),
      );
      final locationService = FakeLocationService(
        permission: PermissionStatus.granted,
        nextLocation: cachedLaptopLoc,
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
      final incidentStorage = InMemoryIncidentStorage();
      final controller = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.macosCameraSceneMotion: detector,
        },
        audioAdapter: audio,
        pinService: pinService,
        incidentStorage: incidentStorage,
        settingsStorage: InMemorySettingsStorage(
          const ProtectionSettings(
            selectedDetector: DetectorType.macosCameraSceneMotion,
            armingCountdownSeconds: 1,
            onboardingCompleted: true,
            deviceDisplayName: 'My MacBook',
            shareLocationOnAlarm: true,
          ),
        ),
        notificationAdapter: remoteNotifs,
        locationAdapter: locationService,
        systemLifecycleAdapter: lifecycle,
        clock: () => clockUtc,
      );
      addTearDown(() async {
        controller.dispose();
        await detector.dispose();
        await lifecycle.dispose();
      });

      await controller.initialize();
      final invite = await controller.initiateHostPairing();
      final pairResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': invite.pairingCode,
          'displayName': 'iPhone',
          'platform': 'iOS Home Screen Web App',
        },
      );
      expect(pairResp.statusCode, 200);
      final companionToken = pairResp.json['companionToken'] as String;
      await _registerCompanionWebPush(
        client: client,
        endpoint: endpoint,
        companionToken: companionToken,
      );
      await controller.syncPairedDevicesFromRelay();

      final armedSessionId = await _armControllerImmediately(controller);

      // Verify native bridge holds emergency credentials + cached last-known location
      expect(lifecycle.lastSyncedRelayEndpointUrl, endpoint);
      expect(lifecycle.lastSyncedHostToken, isNotEmpty);
      expect(lifecycle.lastSyncedArmedSessionId, armedSessionId);
      expect(lifecycle.lastSyncedCorrelationIncidentId, 'lid_$armedSessionId');
      expect(lifecycle.lastSyncedLocationJson, isNotNull);
      expect(lifecycle.lastSyncedLocationJson!['isLastKnown'], isTrue);

      final deterministicIncidentId = 'lid_$armedSessionId';

      // Simulate macOS window occlusion / main-thread stall freezing Flutter event delivery on lid close!
      clockUtc = clockUtc.add(const Duration(seconds: 5));
      lifecycle.flutterEventDeliverySuspended = true;

      // Native Swift powerEmergencyQueue posts directly to /v1/incidents:report before kernel sleep ack
      final nativePost = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/incidents:report'),
        bearerToken: lifecycle.lastSyncedHostToken,
        body: <String, Object?>{
          'incidentId': deterministicIncidentId,
          'sessionId': armedSessionId,
          'kind': 'protectionInterrupted',
          'detectorType': 'macosCameraSceneMotion',
          'triggerSummary': 'Laptop lid closed while armed',
          'triggeredAt': clockUtc.toIso8601String(),
          'deviceName': 'My MacBook',
          'locationStatus': 'attached',
          'location': lifecycle.lastSyncedLocationJson,
        },
      );
      expect(nativePost.statusCode, 200);
      expect(nativePost.json['delivered'], isTrue);

      lifecycle.pendingEmergencyReport = NativeEmergencyReportSummary(
        incidentId: deterministicIncidentId,
        sessionId: armedSessionId,
        eventType: SystemLifecycleEventType.lidClosed,
        summary: 'Laptop lid closed while armed',
        triggeredAt: clockUtc,
        clamshellClosed: true,
        attempted: true,
        relayRecorded: true,
        pushAccepted: true,
        pushFailed: false,
        delivered: true,
        httpStatusCode: 200,
        deliveryStage: 'push_accepted',
      );

      // Emitting lidClosed while Flutter is suspended drops the Dart event, reproducing real-device freeze
      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.lidClosed,
          timestamp: clockUtc,
          summary: 'AppleClamshellState closed',
          clamshellClosed: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Phone STILL received the Web Push immediately BEFORE sleep!
      expect(pushEnvelopes, hasLength(1));
      expect(pushEnvelopes.single.incidentId, deterministicIncidentId);
      expect(
        pushEnvelopes.single.body.toLowerCase(),
        contains('lid closed while armed'),
      );

      // Laptop stays asleep for 50s -> 30s server watchdog must NOT send a duplicate alert!
      clockUtc = clockUtc.add(const Duration(seconds: 50));
      final swept = await relay.sweepArmedHeartbeatWatchdog(clockUtc);
      expect(swept, 0);
      expect(pushEnvelopes, hasLength(1));

      final detectorStopsBeforeWake = detector.stopCount;

      // Now user reopens MacBook lid! Flutter unfreezes and wakes up
      clockUtc = clockUtc.add(const Duration(seconds: 5));
      lifecycle.flutterEventDeliverySuspended = false;
      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.systemDidWake,
          timestamp: clockUtc,
          summary: 'kIOMessageSystemHasPoweredOn',
        ),
      );
      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.lidOpened,
          timestamp: clockUtc,
          summary: 'AppleClamshellState opened',
          clamshellClosed: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // Wake reconciliation MUST stop the camera motion detector and reconcile the existing lid incident
      expect(detector.stopCount, greaterThan(detectorStopsBeforeWake));
      expect(controller.state, ProtectionState.alarming);
      expect(controller.activeIncident?.id, deterministicIncidentId);
      expect(
        controller.activeIncident?.kind,
        IncidentKind.protectionInterrupted,
      );

      // Even if late camera motion frames arrive on wake, no second realDetectorTrigger incident is created!
      detector.emit(
        DetectorEvent(
          eventId: 'evt_wake_late_1',
          sessionId: armedSessionId,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.motionTriggered,
          timestamp: clockUtc,
          motionScore: 0.92,
          threshold: 0.35,
          summary: 'Late wake webcam frame shift',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final savedIncidents = await incidentStorage.loadIncidents();
      expect(savedIncidents, hasLength(1));
      expect(savedIncidents.single.id, deterministicIncidentId);
      expect(pushEnvelopes, hasLength(1));

      // Correct PIN disarm stops siren immediately and wipes native emergency credentials
      final disarmed = await controller.verifyAndDisarm('135790');
      expect(disarmed.verified, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(controller.state, ProtectionState.disarmed);
      expect(audio.isPlaying, isFalse);
      expect(lifecycle.lastSyncedHostToken, isNull);
    });

    test('3. Failed native pre-sleep POST: <30s wake retries without suppression; >30s offline triggers 30s watchdog once and deduplicates late wake report', () async {
      var clockUtc = DateTime.utc(2026, 11, 19, 19, 0, 0);
      final pushEnvelopes = <OutboundPushEnvelope>[];
      final pushProvider = EnvironmentPushProviderAdapter(
        environment: const <String, String>{
          'VAPID_PUBLIC_KEY': 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFg',
        },
        customSender: (envelope) async {
          pushEnvelopes.add(envelope);
          return true;
        },
      );
      final relay = WatSafeRelayServer(
        store: InMemoryRelayStore(clock: () => clockUtc),
        pushProvider: pushProvider,
        clock: () => clockUtc,
      );
      final port = await relay.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      addTearDown(() async => relay.stop());
      final endpoint = 'http://127.0.0.1:$port';

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final detector = FakeMotionDetector(
        type: DetectorType.macosCameraSceneMotion,
      );
      final audio = FakeAudioAlarmAdapter();
      final lifecycle = FakeSystemLifecycleService();
      final locationService = FakeLocationService(
        permission: PermissionStatus.granted,
        nextLocation: DeviceLocationSnapshot(
          latitude: 43.4723,
          longitude: -80.5449,
          accuracyMeters: 25.0,
          capturedAt: clockUtc,
        ),
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
            deviceDisplayName: 'My MacBook',
            shareLocationOnAlarm: true,
          ),
        ),
        notificationAdapter: remoteNotifs,
        locationAdapter: locationService,
        systemLifecycleAdapter: lifecycle,
        clock: () => clockUtc,
      );
      addTearDown(() async {
        controller.dispose();
        await detector.dispose();
        await lifecycle.dispose();
      });

      await controller.initialize();
      final invite = await controller.initiateHostPairing();
      final pairResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': invite.pairingCode,
          'displayName': 'iPhone',
          'platform': 'iOS Home Screen Web App',
        },
      );
      await _registerCompanionWebPush(
        client: client,
        endpoint: endpoint,
        companionToken: pairResp.json['companionToken'] as String,
      );
      await controller.syncPairedDevicesFromRelay();

      // --- Subcase A: Native pre-sleep POST fails (statusCode 0), laptop wakes after 12s (< 30s) -> wake retry succeeds (NOT suppressed!) ---
      final session1 = await _armControllerImmediately(controller);

      clockUtc = clockUtc.add(const Duration(seconds: 4));
      lifecycle.flutterEventDeliverySuspended = true;
      lifecycle.pendingEmergencyReport = NativeEmergencyReportSummary(
        incidentId: 'lid_$session1',
        sessionId: session1,
        eventType: SystemLifecycleEventType.lidClosed,
        summary: 'Laptop lid closed while armed',
        triggeredAt: clockUtc,
        clamshellClosed: true,
        attempted: true,
        relayRecorded: false,
        pushAccepted: false,
        pushFailed: false,
        delivered: false,
        httpStatusCode: 0,
        deliveryStage: 'network_error',
      );

      // Reopen after 12s -> wake reconciliation flushes 'lid_$session1' immediately!
      clockUtc = clockUtc.add(const Duration(seconds: 12));
      lifecycle.flutterEventDeliverySuspended = false;
      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.systemDidWake,
          timestamp: clockUtc,
          summary: 'Wake after brief sleep',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 160));

      expect(pushEnvelopes, hasLength(1));
      expect(pushEnvelopes.single.incidentId, 'lid_$session1');
      await controller.verifyAndDisarm('246810');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      pushEnvelopes.clear();

      // --- Subcase B: Native pre-sleep POST fails AND laptop stays asleep > 30s -> watchdog fires once, late wake report is deduplicated ---
      clockUtc = clockUtc.add(const Duration(seconds: 5));
      final session2 = await _armControllerImmediately(controller);

      clockUtc = clockUtc.add(const Duration(seconds: 2));
      lifecycle.flutterEventDeliverySuspended = true;
      lifecycle.pendingEmergencyReport = NativeEmergencyReportSummary(
        incidentId: 'lid_$session2',
        sessionId: session2,
        eventType: SystemLifecycleEventType.lidClosed,
        summary: 'Laptop lid closed while armed',
        triggeredAt: clockUtc,
        clamshellClosed: true,
        attempted: true,
        relayRecorded: false,
        pushAccepted: false,
        pushFailed: false,
        delivered: false,
        httpStatusCode: 0,
        deliveryStage: 'network_error',
      );

      // 25s network jitter / brief sleep grace -> 0 watchdog alerts
      clockUtc = clockUtc.add(const Duration(seconds: 23));
      expect(await relay.sweepArmedHeartbeatWatchdog(clockUtc), 0);
      expect(pushEnvelopes, isEmpty);

      // At 32s (> 30s timeout) -> independent backend fallback fires 1 honest warning!
      clockUtc = clockUtc.add(const Duration(seconds: 7));
      expect(await relay.sweepArmedHeartbeatWatchdog(clockUtc), 1);
      expect(pushEnvelopes, hasLength(1));
      expect(
        pushEnvelopes.single.body,
        contains('Protected laptop stopped responding'),
      );
      expect(
        pushEnvelopes.single.body.toLowerCase(),
        isNot(contains('theft confirmed')),
      );

      // Laptop wakes 60s later and flushes 'lid_$session2' -> relay deduplicates against already-delivered watchdog alert!
      clockUtc = clockUtc.add(const Duration(seconds: 60));
      lifecycle.flutterEventDeliverySuspended = false;
      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.systemDidWake,
          timestamp: clockUtc,
          summary: 'Wake after watchdog already alerted',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 160));

      expect(
        pushEnvelopes,
        hasLength(1),
        reason: 'Late wake report must be deduplicated when server watchdog already alerted phone',
      );
    });

    test('4. Abrupt laptop disappearance + durable FileRelayStore restart while armed + unverified hostArmed:false immunity', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'watsafe_relay_restart_armed_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      var clockUtc = DateTime.utc(2026, 11, 19, 20, 0, 0);
      final pushEnvelopes = <OutboundPushEnvelope>[];
      PushProviderAdapter buildPush() => EnvironmentPushProviderAdapter(
        environment: const <String, String>{
          'VAPID_PUBLIC_KEY': 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFg',
        },
        customSender: (envelope) async {
          pushEnvelopes.add(envelope);
          return true;
        },
      );

      var relay = WatSafeRelayServer(
        store: FileRelayStore(directory: tempDir, clock: () => clockUtc),
        pushProvider: buildPush(),
        clock: () => clockUtc,
      );
      var port = await relay.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      var endpoint = 'http://127.0.0.1:$port';

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final initResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/initiate'),
        body: const <String, Object?>{'hostDisplayName': 'My MacBook'},
      );
      final hostToken = initResp.json['hostToken'] as String;
      final pairResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': initResp.json['pairingCode'],
          'displayName': 'iPhone',
          'platform': 'iOS Home Screen Web App',
        },
      );
      await _registerCompanionWebPush(
        client: client,
        endpoint: endpoint,
        companionToken: pairResp.json['companionToken'] as String,
      );

      // Laptop arms protection
      final armHb = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/host/heartbeat'),
        bearerToken: hostToken,
        body: const <String, Object?>{
          'hostProtectionState': 'armed',
          'hostArmed': true,
          'hostArmedSessionId': 'session_abrupt_1',
        },
      );
      expect(armHb.statusCode, 200);
      expect(armHb.json['hostArmed'], isTrue);

      // Unverified hostArmed: false request at +20s MUST NOT disarm or refresh hostLastSeenAtUtc!
      clockUtc = clockUtc.add(const Duration(seconds: 20));
      final spoofedDisarm = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/host/heartbeat'),
        bearerToken: hostToken,
        body: const <String, Object?>{
          'hostProtectionState': 'off',
          'hostArmed': false,
          'disarmVerified': false,
        },
      );
      expect(spoofedDisarm.statusCode, 200);
      expect(spoofedDisarm.json['hostArmed'], isTrue);

      // Relay server restarts at +32s (12s after spoofed heartbeat, 32s after last valid armed heartbeat!)
      await relay.stop();
      clockUtc = clockUtc.add(const Duration(seconds: 12));

      relay = WatSafeRelayServer(
        store: FileRelayStore(directory: tempDir, clock: () => clockUtc),
        pushProvider: buildPush(),
        clock: () => clockUtc,
      );
      port = await relay.start(address: InternetAddress.loopbackIPv4, port: 0);
      addTearDown(() async => relay.stop());

      // Relay boot sweep immediately detects the overdue armed laptop and sends 1 warning!
      expect(pushEnvelopes, hasLength(1));
      expect(
        pushEnvelopes.single.body,
        contains('Protected laptop stopped responding'),
      );

      // Subsequent sweeps produce 0 duplicates
      clockUtc = clockUtc.add(const Duration(seconds: 20));
      expect(await relay.sweepArmedHeartbeatWatchdog(clockUtc), 0);
      expect(pushEnvelopes, hasLength(1));
    });

    test('5. Push failure honesty (never falsely reports delivery), watchdog transient push retry backoff, and FileIncidentStorage trailing-bytes self-healing', () async {
      // --- Part A: FileIncidentStorage self-heals trailing garbage bytes & writes atomically ---
      final tempStorageDir = await Directory.systemTemp.createTemp(
        'watsafe_corrupt_incidents_',
      );
      addTearDown(() async {
        if (await tempStorageDir.exists()) {
          await tempStorageDir.delete(recursive: true);
        }
      });
      final corruptFile = File('${tempStorageDir.path}/incidents.json');
      final seedIncident = IncidentRecord(
        id: 'inc_seed_1',
        sessionId: 'sess_1',
        kind: IncidentKind.realDetectorTrigger,
        triggeredAt: DateTime.utc(2026, 11, 19, 15, 0),
        detectorType: DetectorType.macosCameraSceneMotion,
        triggerSummary: 'Seed incident',
        resolutionSummary: 'Active',
      );
      await corruptFile.writeAsString(
        '${jsonEncode(<Object>[seedIncident.toJson()])}\n{"trailing_corrupt": true]}',
      );

      final fileStorage = FileIncidentStorage(directory: tempStorageDir);
      final recovered = await fileStorage.loadIncidents();
      expect(recovered, hasLength(1));
      expect(recovered.single.id, 'inc_seed_1');

      await fileStorage.saveIncident(
        seedIncident.copyWith(resolutionSummary: 'Disarmed with PIN'),
      );
      final cleanJson =
          jsonDecode(await corruptFile.readAsString()) as List<dynamic>;
      expect(cleanJson, hasLength(1));

      // --- Part B: Push provider transient failure honesty & watchdog retry ---
      var clockUtc = DateTime.utc(2026, 11, 19, 21, 0, 0);
      var pushShouldSucceed = false;
      final deliveredEnvelopes = <OutboundPushEnvelope>[];

      final relay = WatSafeRelayServer(
        store: InMemoryRelayStore(clock: () => clockUtc),
        pushProvider: EnvironmentPushProviderAdapter(
          environment: const <String, String>{
            'VAPID_PUBLIC_KEY': 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFg',
          },
          customSender: (envelope) async {
            if (!pushShouldSucceed) {
              return false;
            }
            deliveredEnvelopes.add(envelope);
            return true;
          },
        ),
        clock: () => clockUtc,
      );
      final port = await relay.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      addTearDown(() async => relay.stop());
      final endpoint = 'http://127.0.0.1:$port';

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final remoteNotifs = ConfigurableRemoteNotificationService(
        persistToDisk: false,
        initialRelayEndpointUrl: endpoint,
        enableBackgroundPolling: false,
      );
      addTearDown(remoteNotifs.dispose);

      final invite = await remoteNotifs.initiateHostPairing(
        hostDisplayName: 'My MacBook',
      );
      final pairResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': invite.pairingCode,
          'displayName': 'iPhone',
          'platform': 'iOS Home Screen Web App',
        },
      );
      final companionToken = pairResp.json['companionToken'] as String;
      await _registerCompanionWebPush(
        client: client,
        endpoint: endpoint,
        companionToken: companionToken,
      );
      await remoteNotifs.syncPairedDevicesFromRelay();
      await remoteNotifs.syncHostArmedState(
        protectionState: 'armed',
        armed: true,
        armedSessionId: 'session_push_fail_1',
      );

      // Pre-sleep report when push gateway is failing -> delivered MUST be false and pushFailed MUST be true!
      final failedDispatch = await remoteNotifs.sendUrgentPreSuspensionAlert(
        IncidentRecord(
          id: 'lid_session_push_fail_1',
          sessionId: 'session_push_fail_1',
          kind: IncidentKind.protectionInterrupted,
          triggeredAt: clockUtc,
          detectorType: DetectorType.macosCameraSceneMotion,
          triggerSummary: 'Laptop lid closed while armed',
          resolutionSummary: 'Active — awaiting PIN disarm',
        ),
      );
      expect(failedDispatch.delivered, isFalse);
      expect(failedDispatch.pushFailed, isTrue);
      expect(deliveredEnvelopes, isEmpty);

      // Laptop is now asleep > 30s; first watchdog sweep at +32s also hits push failure -> schedules backoff retry
      clockUtc = clockUtc.add(const Duration(seconds: 32));
      expect(await relay.sweepArmedHeartbeatWatchdog(clockUtc), 0);
      expect(deliveredEnvelopes, isEmpty);

      // Push gateway recovers at +45s (past 10s retry backoff) -> watchdog sweep delivers Web Push without duplicating DB incident!
      pushShouldSucceed = true;
      clockUtc = clockUtc.add(const Duration(seconds: 13));
      expect(await relay.sweepArmedHeartbeatWatchdog(clockUtc), 1);
      expect(deliveredEnvelopes, hasLength(1));

      final alertsResp = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/companion/alerts?afterSeq=0'),
        bearerToken: companionToken,
      );
      final alerts = alertsResp.json['alerts'] as List<dynamic>;
      // 1 lid incident + 1 watchdog recovery alert (not duplicated across retries)
      expect(alerts.length, lessThanOrEqualTo(2));
    });

    test('6. Phone Companion OpenStreetMap basemap, zoom/center/fit controls, loading & failure states, concise freshness, and seamless 2026.11.19-v9 SW update', () async {
      final html = CompanionPwaAssets.companionWebHtml;
      final swJs = CompanionPwaAssets.serviceWorkerJs;

      expect(CompanionPwaAssets.serviceWorkerVersion, '2026.11.19-v9');
      expect(swJs, contains("SHELL_CACHE = 'watsafe-shell-2026.11.19-v9'"));
      // Preserves durable pairing & appearance storage keys across update
      expect(html, contains("STORAGE_KEY = 'watsafe.web_companion.v3'"));
      expect(
        html,
        contains(
          "APPEARANCE_STORAGE_KEY = window.WATSAFE_APPEARANCE_KEY || 'watsafe.appearance.v1'",
        ),
      );

      // Genuine OpenStreetMap tile template matching laptop map (zero unpkg/maplibre defer race, zero synthetic white grid)
      expect(html, contains('https://tile.openstreetmap.org/{z}/{x}/{y}.png'));
      expect(html, isNot(contains('unpkg.com/maplibre-gl')));
      expect(html, isNot(contains('tiles.openfreemap.org')));
      expect(html, isNot(contains('drawCanvasFallback')));

      // Controls: zoom in, zoom out, center selected device, fit all devices, scale bar, attribution
      expect(html, contains('data-act="in"'));
      expect(html, contains('data-act="out"'));
      expect(html, contains('data-act="center"'));
      expect(html, contains('data-act="fit"'));
      expect(html, contains('map-scale-bar'));
      expect(html, contains('© OpenStreetMap contributors'));

      // Explicit loading state and honest failure + Retry state
      expect(html, contains('Loading map…'));
      expect(html, contains('Map couldn’t load'));
      expect(html, contains('data-act="retry-map"'));

      // Concise freshness & distinct interruption labels
      expect(html, contains("' min ago'"));
      expect(html, contains('Protected laptop stopped responding'));
      expect(html, contains('Camera blocked'));
      expect(html, contains('Lid closed while armed'));
      expect(html, contains('Sleep while armed'));

      // Simplified navigation & in-app map boundaries preserved
      expect(html, isNot(contains('Open in Maps')));
      expect(html, isNot(contains('Follow incident')));
    });
  });
}
