import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  String pushEndpoint = 'https://web.push.apple.com/test-sub-lid-watchdog',
}) async {
  final subKeys = VapidKeyPair.generate();
  final authSecret = Uint8List.fromList(
    List<int>.generate(16, (idx) => (idx * 13 + 7) & 0xff),
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Lid-Close / Sleep Interruption, Backend Watchdog & Multi-Device Map Suite', () {
    late WatSafeRelayServer relayServer;
    late EnvironmentPushProviderAdapter pushProvider;
    late List<OutboundPushEnvelope> recordedPushEnvelopes;
    late int relayPort;
    late DateTime serverClockUtc;

    setUp(() async {
      HttpOverrides.global = null;
      serverClockUtc = DateTime.utc(2026, 11, 17, 16, 0, 0);
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

    test('1. PlatformSystemLifecycleService MethodChannel & EventChannel binary-messenger wiring (distinct from mocked FakeSystemLifecycleService)', () async {
      const methodChannelName = 'dev.watsafe/system_lifecycle';
      const eventChannelName = 'dev.watsafe/system_lifecycle_events';
      const codec = StandardMethodCodec();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      final recordedCalls = <MethodCall>[];
      var eventStreamListening = false;

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
              'platformLabel': 'macOS IOKit + NSWorkspace',
            };
          }
          return null;
        },
      );

      messenger.setMockMessageHandler(eventChannelName, (
        ByteData? message,
      ) async {
        if (message == null) {
          return null;
        }
        final call = codec.decodeMethodCall(message);
        if (call.method == 'listen') {
          eventStreamListening = true;
          return codec.encodeSuccessEnvelope(null);
        }
        if (call.method == 'cancel') {
          eventStreamListening = false;
          return codec.encodeSuccessEnvelope(null);
        }
        return null;
      });

      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel(methodChannelName),
          null,
        );
        messenger.setMockMessageHandler(eventChannelName, null);
      });

      final platformService = PlatformSystemLifecycleService(
        isDesktopOverride: true,
      );
      addTearDown(platformService.dispose);

      final receivedEvents = <SystemLifecycleEvent>[];
      final sub = platformService.events.listen(receivedEvents.add);
      addTearDown(sub.cancel);

      final caps = await platformService.initialize();
      expect(eventStreamListening, isTrue);
      expect(caps.isSupported, isTrue);
      expect(caps.supportsClamshellDetection, isTrue);
      expect(caps.supportsSleepWakeNotifications, isTrue);
      expect(caps.supportsQuitInterception, isTrue);
      expect(caps.supportsInputInteractionDetection, isTrue);
      expect(caps.platformLabel, 'macOS IOKit + NSWorkspace');

      await platformService.syncProtectionState(
        armed: true,
        monitorInputInteraction: true,
      );
      await platformService.syncProtectionState(
        armed: false,
        monitorInputInteraction: true,
      );

      // Push native EventChannel envelopes over binary messenger
      Future<void> pushNativeEvent(Map<String, Object?> payload) async {
        final completer = Completer<void>();
        messenger.handlePlatformMessage(
          eventChannelName,
          codec.encodeSuccessEnvelope(payload),
          (_) => completer.complete(),
        );
        await completer.future;
      }

      await pushNativeEvent(<String, Object?>{
        'type': 'lidClosed',
        'timestampMs': 1763395200000,
        'summary': 'AppleClamshellState transitioned to true',
        'clamshellClosed': true,
        'flushToken': 'iopm_flush_token_42',
      });
      await pushNativeEvent(<String, Object?>{
        'type': 'systemWillSleep',
        'timestampMs': 1763395200400,
        'summary': 'kIOMessageSystemWillSleep',
        'flushToken': 'iopm_flush_token_43',
      });
      await pushNativeEvent(<String, Object?>{
        'type': 'userInputDetected',
        'timestampMs': 1763395201000,
        'summary': 'HID idle seconds reset below threshold',
      });
      await Future<void>.delayed(const Duration(milliseconds: 15));

      expect(receivedEvents, hasLength(3));
      expect(receivedEvents[0].type, SystemLifecycleEventType.lidClosed);
      expect(receivedEvents[0].clamshellClosed, isTrue);
      expect(receivedEvents[0].flushToken, 'iopm_flush_token_42');
      expect(receivedEvents[1].type, SystemLifecycleEventType.systemWillSleep);
      expect(receivedEvents[1].clamshellClosed, isNull);
      expect(
        receivedEvents[2].type,
        SystemLifecycleEventType.userInputDetected,
      );

      await platformService.completeUrgentFlush('iopm_flush_token_42');

      expect(
        recordedCalls.map((c) => c.method).toList(),
        containsAllInOrder(<String>[
          'getCapabilities',
          'syncProtectionState',
          'syncProtectionState',
          'completeUrgentFlush',
        ]),
      );
      final firstSync =
          recordedCalls
                  .firstWhere((c) => c.method == 'syncProtectionState')
                  .arguments
              as Map<Object?, Object?>;
      expect(firstSync['armed'], isTrue);
      expect(firstSync['monitorInputInteraction'], isTrue);

      final secondSync =
          recordedCalls
                  .where((c) => c.method == 'syncProtectionState')
                  .elementAt(1)
                  .arguments
              as Map<Object?, Object?>;
      expect(secondSync['armed'], isFalse);
      expect(secondSync['monitorInputInteraction'], isFalse);

      final flushArgs =
          recordedCalls
                  .singleWhere((c) => c.method == 'completeUrgentFlush')
                  .arguments
              as Map<Object?, Object?>;
      expect(flushArgs['flushToken'], 'iopm_flush_token_42');
    });

    test('2. Armed lidClosed vs generic systemWillSleep: non-blocking urgent alert + siren while fresh GPS hangs, preserves last-known location & timestamp, chains flush tokens, and deduplicates 50s watchdog', () async {
      final endpoint = 'http://127.0.0.1:$relayPort';
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final detector = FakeMotionDetector(
        type: DetectorType.macosCameraSceneMotion,
      );
      final audio = FakeAudioAlarmAdapter();
      final lifecycle = FakeSystemLifecycleService();
      final preSleepKnownLoc = DeviceLocationSnapshot(
        latitude: 43.47490,
        longitude: -80.53303,
        accuracyMeters: 35.0,
        capturedAt: serverClockUtc.subtract(const Duration(minutes: 3)),
      );
      final locationService = FakeLocationService(
        permission: PermissionStatus.granted,
        nextLocation: preSleepKnownLoc,
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
        clock: () => serverClockUtc,
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
          'platform': 'iOS Web App',
          'notificationsEnabled': true,
        },
      );
      final companionToken = pairResp.json['companionToken'] as String;
      await _registerCompanionWebPush(
        client: client,
        endpoint: endpoint,
        companionToken: companionToken,
      );
      await controller.syncPairedDevicesFromRelay();

      // Arm protection so preSleepKnownLoc is captured while awake
      await controller.startArming();
      final armedSessionId = controller.activeSessionId!;
      await controller.handleCountdownTickForSession(armedSessionId);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.state, ProtectionState.armed);
      expect(lifecycle.lastSyncedArmed, isTrue);
      expect(controller.hostLatestLocation, isNotNull);

      // Now make fresh location lookup hang forever to prove pre-sleep dispatch NEVER blocks on GPS!
      final neverCompletes = Completer<DeviceLocationSnapshot?>();
      locationService.captureCompleter = neverCompletes;

      // Emit hardware-confirmed lidClosed immediately followed by OS systemWillSleep
      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.lidClosed,
          timestamp: serverClockUtc,
          summary: 'AppleClamshellState closed',
          clamshellClosed: true,
          flushToken: 'tok_lid_close_1',
        ),
      );
      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.systemWillSleep,
          timestamp: serverClockUtc.add(const Duration(milliseconds: 40)),
          summary: 'kIOMessageSystemWillSleep',
          flushToken: 'tok_will_sleep_2',
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 140));

      // Must NEVER silently pause or disarm — immediately alarms + sends urgent interruption push!
      expect(controller.state, ProtectionState.alarming);
      expect(audio.isPlaying, isTrue);
      expect(
        controller.activeIncident?.kind,
        IncidentKind.protectionInterrupted,
      );
      expect(
        controller.activeIncident?.detectorType,
        DetectorType.macosCameraSceneMotion,
      );
      expect(
        controller.activeIncident?.triggerSummary.toLowerCase(),
        contains('lid closed'),
      );

      // Both native flush tokens must have been released after urgent flush chained completion
      expect(
        lifecycle.completedFlushTokens,
        containsAll(<String>['tok_lid_close_1', 'tok_will_sleep_2']),
      );

      // Exactly 1 push sent for this episode, and lock-screen push payload contains ZERO coordinates
      expect(recordedPushEnvelopes, hasLength(1));
      expect(recordedPushEnvelopes.single.body, isNot(contains('43.4749')));
      expect(recordedPushEnvelopes.single.body, isNot(contains('-80.533')));

      // Authenticated companion alert poll sees last-known coordinates with original timestamp
      final pollResp = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/companion/alerts'),
        bearerToken: companionToken,
      );
      expect(pollResp.statusCode, 200);
      final alerts = (pollResp.json['alerts'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(alerts, hasLength(1));
      expect(alerts.single['kind'], 'protectionInterrupted');
      final alertLoc = alerts.single['location'] as Map<String, dynamic>;
      expect(alertLoc['latitude'], closeTo(43.47490, 1e-5));
      expect(alertLoc['longitude'], closeTo(-80.53303, 1e-5));
      expect(alertLoc['isLastKnown'], isTrue);
      expect(
        alertLoc['capturedAtUtc'],
        preSleepKnownLoc.capturedAt.toUtc().toIso8601String(),
      );

      // 50s later while laptop sleeps: backend watchdog sees pre-sleep interruption alert was already sent and suppresses duplicate push!
      serverClockUtc = serverClockUtc.add(const Duration(seconds: 50));
      final duplicateTriggered = await relayServer.sweepArmedHeartbeatWatchdog(
        serverClockUtc,
      );
      expect(duplicateTriggered, 0);
      expect(recordedPushEnvelopes, hasLength(1));

      // Disarm with valid PIN, re-arm, and verify generic systemWillSleep (without clamshellClosed) does NOT falsely claim lid closure
      locationService.captureCompleter = null;
      await controller.verifyAndDisarm('246810');
      expect(controller.state, ProtectionState.disarmed);

      await controller.startArming();
      final secondSessionId = controller.activeSessionId!;
      await controller.handleCountdownTickForSession(secondSessionId);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.systemWillSleep,
          timestamp: serverClockUtc,
          summary: 'Idle sleep timer',
          clamshellClosed: null,
          flushToken: 'tok_generic_sleep',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(controller.state, ProtectionState.alarming);
      expect(
        controller.activeIncident?.kind,
        IncidentKind.protectionInterrupted,
      );
      expect(
        controller.activeIncident?.triggerSummary.toLowerCase(),
        contains('sleep'),
      );
      expect(
        controller.activeIncident?.triggerSummary.toLowerCase(),
        isNot(contains('lid closed while')),
      );
    });

    test('3. Optional keyboard/trackpad interaction alert gives an 8s PIN grace period: valid PIN prevents false alarm; unauthenticated touch triggers alarm', () async {
      final detector = FakeMotionDetector(
        type: DetectorType.macosCameraSceneMotion,
      );
      final audio = FakeAudioAlarmAdapter();
      final lifecycle = FakeSystemLifecycleService();
      final pinService = PinSecurityService(
        storage: InMemorySecurePinStorage(),
        pbkdf2Iterations: 500,
      );
      await pinService.setupInitialPin(pin: '135790', confirmPin: '135790');

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
            alertOnInputInteraction: true,
          ),
        ),
        notificationAdapter: ConfigurableRemoteNotificationService(
          persistToDisk: false,
          enableBackgroundPolling: false,
        ),
        systemLifecycleAdapter: lifecycle,
        inputInteractionGracePeriod: const Duration(milliseconds: 160),
      );
      addTearDown(() async {
        controller.dispose();
        await detector.dispose();
        await lifecycle.dispose();
      });

      await controller.initialize();
      await controller.startArming();
      await controller.handleCountdownTickForSession(
        controller.activeSessionId!,
      );
      expect(controller.state, ProtectionState.armed);
      expect(lifecycle.lastSyncedMonitorInput, isTrue);

      // Case A: Owner touches trackpad/keys and enters valid PIN within grace window -> 0 alarms!
      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.userInputDetected,
          timestamp: DateTime.now(),
          summary: 'Keyboard/trackpad activity',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(controller.isInputInteractionGraceActive, isTrue);
      expect(controller.state, ProtectionState.armed);

      final disarmRes = await controller.verifyAndDisarm('135790');
      expect(disarmRes.verified, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(controller.state, ProtectionState.disarmed);
      expect(controller.incidents, isEmpty);

      // Case B: Re-arm, stranger touches keyboard/trackpad and fails to disarm before grace expires -> alarm triggers!
      await controller.startArming();
      await controller.handleCountdownTickForSession(
        controller.activeSessionId!,
      );
      expect(controller.state, ProtectionState.armed);

      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.userInputDetected,
          timestamp: DateTime.now(),
          summary: 'Unauthorized keyboard activity',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 230));
      expect(controller.state, ProtectionState.alarming);
      expect(audio.isPlaying, isTrue);
      expect(controller.incidents, hasLength(1));
      expect(
        controller.activeIncident?.triggerSummary.toLowerCase(),
        contains('keyboard or trackpad'),
      );
    });

    test('4. Backend heartbeat watchdog: 25s blip = 0 alerts, 50s sudden silence (even after /v1/host/offline) = 1 deduplicated push + reconnect marker, verified PIN disarm = 0 alerts, and FileRelayStore restart persistence', () async {
      final endpoint = 'http://127.0.0.1:$relayPort';
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      // Initiate host + pair phone + register Web Push
      final hostInit = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/initiate'),
        body: const <String, Object?>{'hostDisplayName': 'Library MacBook'},
      );
      final hostToken = hostInit.json['hostToken'] as String;
      final pairingCode = hostInit.json['pairingCode'] as String;

      final pairResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': pairingCode,
          'displayName': 'Jonathan iPhone 13',
          'platform': 'iOS Home Screen Web App',
          'notificationsEnabled': true,
        },
      );
      final companionToken = pairResp.json['companionToken'] as String;
      await _registerCompanionWebPush(
        client: client,
        endpoint: endpoint,
        companionToken: companionToken,
      );

      // Report armed heartbeat + initial laptop location
      final locPost = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/host/location'),
        bearerToken: hostToken,
        body: <String, Object?>{
          'hostDisplayName': 'Library MacBook',
          'protectionState': 'armed',
          'locationStatus': 'attached',
          'location': <String, Object?>{
            'latitude': 43.47280,
            'longitude': -80.54210,
            'accuracyMeters': 28.0,
            'capturedAtUtc': serverClockUtc.toIso8601String(),
          },
        },
      );
      expect(locPost.statusCode, 200);

      final beatArmed = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/host/heartbeat'),
        bearerToken: hostToken,
        body: const <String, Object?>{
          'hostDisplayName': 'Library MacBook',
          'protectionState': 'armed',
          'armedSessionId': 'ep_watchdog_1',
        },
      );
      expect(beatArmed.statusCode, 200);
      expect(beatArmed.json['hostArmed'], isTrue);

      // 25s transient Wi-Fi blip -> 0 watchdog alerts
      serverClockUtc = serverClockUtc.add(const Duration(seconds: 25));
      expect(await relayServer.sweepArmedHeartbeatWatchdog(serverClockUtc), 0);
      expect(recordedPushEnvelopes, isEmpty);

      // Simulate unauthenticated POST /v1/host/offline (e.g. lid shut / network teardown without PIN disarm)
      final offlineResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/host/offline'),
        bearerToken: hostToken,
        body: const <String, Object?>{},
      );
      expect(offlineResp.statusCode, 200);
      expect(
        offlineResp.json['hostArmed'],
        isTrue,
        reason:
            '/v1/host/offline without PIN disarm must NEVER clear hostArmed',
      );

      // At T+50s (> 45s timeout), backend independently fires 1 deduplicated watchdog warning!
      serverClockUtc = serverClockUtc.add(const Duration(seconds: 25));
      expect(await relayServer.sweepArmedHeartbeatWatchdog(serverClockUtc), 1);
      expect(recordedPushEnvelopes, hasLength(1));

      // Sweep again at T+75s -> 0 duplicate alerts for the same armed episode
      serverClockUtc = serverClockUtc.add(const Duration(seconds: 25));
      expect(await relayServer.sweepArmedHeartbeatWatchdog(serverClockUtc), 0);
      expect(recordedPushEnvelopes, hasLength(1));

      final alertsResp = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/companion/alerts'),
        bearerToken: companionToken,
      );
      final alerts = (alertsResp.json['alerts'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(alerts, hasLength(1));
      expect(alerts.single['kind'], 'protectionInterrupted');
      expect(alerts.single['detectorType'], 'heartbeat_watchdog');
      expect(
        (alerts.single['triggerSummary'] as String).toLowerCase(),
        contains('not confirmed theft'),
      );
      expect(
        (alerts.single['location'] as Map<String, dynamic>)['isLastKnown'],
        isTrue,
      );

      // Laptop wakes/reconnects -> hostReconnectedAtUtc recorded cleanly
      serverClockUtc = serverClockUtc.add(const Duration(seconds: 10));
      final reconnectBeat = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/host/heartbeat'),
        bearerToken: hostToken,
        body: const <String, Object?>{
          'hostDisplayName': 'Library MacBook',
          'protectionState': 'armed',
          'armedSessionId': 'ep_watchdog_1',
        },
      );
      expect(reconnectBeat.statusCode, 200);
      expect(reconnectBeat.json['hostReconnectedAtUtc'], isNotNull);

      // Owner enters valid PIN (`disarmVerified: true`), closes lid, and goes silent for 60s -> 0 false alerts!
      final disarmBeat = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/host/heartbeat'),
        bearerToken: hostToken,
        body: const <String, Object?>{
          'hostDisplayName': 'Library MacBook',
          'protectionState': 'off',
          'disarmVerified': true,
        },
      );
      expect(disarmBeat.statusCode, 200);
      expect(disarmBeat.json['hostArmed'], isFalse);

      serverClockUtc = serverClockUtc.add(const Duration(seconds: 60));
      expect(await relayServer.sweepArmedHeartbeatWatchdog(serverClockUtc), 0);
      expect(recordedPushEnvelopes, hasLength(1));

      // --- Durable FileRelayStore restart persistence test ---
      final tempDir = await Directory.systemTemp.createTemp(
        'watsafe_watchdog_restart_',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      var restartClock = DateTime.utc(2026, 11, 17, 18, 0, 0);
      final restartEnvelopes = <OutboundPushEnvelope>[];
      final restartPush = EnvironmentPushProviderAdapter(
        environment: const <String, String>{
          'VAPID_PUBLIC_KEY': 'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFg',
        },
        customSender: (env) async {
          restartEnvelopes.add(env);
          return true;
        },
      );

      final server1 = WatSafeRelayServer(
        store: FileRelayStore(directory: tempDir),
        pushProvider: restartPush,
        clock: () => restartClock,
      );
      final port1 = await server1.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      final url1 = 'http://127.0.0.1:$port1';

      final s1Init = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$url1/v1/pairing/initiate'),
        body: const <String, Object?>{'hostDisplayName': 'Restart MacBook'},
      );
      final s1HostToken = s1Init.json['hostToken'] as String;
      final s1Pair = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$url1/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': s1Init.json['pairingCode'],
          'displayName': 'Restart iPhone',
          'platform': 'iOS Home Screen Web App',
          'notificationsEnabled': true,
        },
      );
      await _registerCompanionWebPush(
        client: client,
        endpoint: url1,
        companionToken: s1Pair.json['companionToken'] as String,
        pushEndpoint: 'https://web.push.apple.com/restart-test-sub',
      );
      await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$url1/v1/host/heartbeat'),
        bearerToken: s1HostToken,
        body: const <String, Object?>{
          'hostDisplayName': 'Restart MacBook',
          'protectionState': 'armed',
          'armedSessionId': 'ep_restart_persist',
        },
      );
      await server1.stop();

      // Advance clock 55s while relay was stopped, boot fresh server2 on same FileRelayStore
      restartClock = restartClock.add(const Duration(seconds: 55));
      final server2 = WatSafeRelayServer(
        store: FileRelayStore(directory: tempDir),
        pushProvider: restartPush,
        clock: () => restartClock,
      );
      await server2.start(address: InternetAddress.loopbackIPv4, port: 0);
      addTearDown(server2.stop);

      // server2.start() automatically runs an immediate startup watchdog sweep
      // and dispatches the overdue alert; a subsequent sweep is deduplicated!
      expect(restartEnvelopes, hasLength(1));
      final duplicateSweepAfterBoot = await server2.sweepArmedHeartbeatWatchdog(
        restartClock,
      );
      expect(duplicateSweepAfterBoot, 0);
      expect(restartEnvelopes, hasLength(1));
    });

    test('5. Separate laptop + 2 companion phones (3 devices): phone location off by default, explicit opt-in, permissionDenied & DELETE cleanup, and strict 403 anti-impersonation / cross-session isolation', () async {
      final endpoint = 'http://127.0.0.1:$relayPort';
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      // Session A: MacBook + iPhone 13 + Pixel 9 (3 authorized devices)
      final hostA = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/initiate'),
        body: const <String, Object?>{'hostDisplayName': 'My MacBook'},
      );
      final sessionAId = hostA.json['pairingSessionId'] as String;
      final hostAToken = hostA.json['hostToken'] as String;

      final pairPhone1 = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': hostA.json['pairingCode'],
          'displayName': 'iPhone 13',
          'platform': 'iOS Home Screen Web App',
          'notificationsEnabled': true,
        },
      );
      final phone1Id = pairPhone1.json['deviceId'] as String;
      final phone1Token = pairPhone1.json['companionToken'] as String;

      // Generate a second pairing code on the same host session for a second companion phone
      final hostAInvite2 = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/initiate'),
        bearerToken: hostAToken,
        body: const <String, Object?>{'hostDisplayName': 'My MacBook'},
      );
      final pairPhone2 = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': hostAInvite2.json['pairingCode'],
          'displayName': 'Work Pixel',
          'platform': 'Android Web App',
          'notificationsEnabled': true,
        },
      );
      final phone2Id = pairPhone2.json['deviceId'] as String;
      final phone2Token = pairPhone2.json['companionToken'] as String;

      // Session B: Separate user session
      final hostB = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/initiate'),
        body: const <String, Object?>{'hostDisplayName': 'Other Laptop'},
      );
      final sessionBId = hostB.json['pairingSessionId'] as String;

      // Upload laptop location
      await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/host/location'),
        bearerToken: hostAToken,
        body: <String, Object?>{
          'hostDeviceId': 'host_macbook_01',
          'hostDisplayName': 'My MacBook',
          'protectionState': 'armed',
          'location': <String, Object?>{
            'latitude': 43.47490,
            'longitude': -80.53303,
            'accuracyMeters': 35.0,
            'capturedAtUtc': serverClockUtc.toIso8601String(),
          },
        },
      );

      // Default state: both companion phones have locationSharingEnabled == false and latestLocation == null
      final listDefault = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations'),
        bearerToken: phone1Token,
      );
      expect(listDefault.statusCode, 200);
      final defaultDevices = (listDefault.json['devices'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(defaultDevices, hasLength(3));

      final p1Default = defaultDevices.singleWhere(
        (d) => d['deviceId'] == phone1Id,
      );
      expect(p1Default['isCurrentRequester'], isTrue);
      expect(p1Default['locationSharingEnabled'], isFalse);
      expect(p1Default['latestLocation'], isNull);

      // Anti-impersonation: Phone 1 cannot update Phone 2's deviceId or laptop's deviceId
      final spoofPhone2 = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/companion/location'),
        bearerToken: phone1Token,
        body: <String, Object?>{
          'deviceId': phone2Id,
          'sharingEnabled': true,
          'location': <String, Object?>{
            'latitude': 43.47500,
            'longitude': -80.53310,
            'accuracyMeters': 12.0,
            'capturedAtUtc': serverClockUtc.toIso8601String(),
          },
        },
      );
      expect(spoofPhone2.statusCode, 403);
      expect(spoofPhone2.json['error'], 'FORBIDDEN_DEVICE_IMPERSONATION');

      // Anti-impersonation: Host cannot overwrite Phone 1's deviceId
      final hostSpoofPhone = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/host/location'),
        bearerToken: hostAToken,
        body: <String, Object?>{
          'deviceId': phone1Id,
          'location': <String, Object?>{
            'latitude': 43.47500,
            'longitude': -80.53310,
            'accuracyMeters': 12.0,
            'capturedAtUtc': serverClockUtc.toIso8601String(),
          },
        },
      );
      expect(hostSpoofPhone.statusCode, 403);
      expect(hostSpoofPhone.json['error'], 'FORBIDDEN_DEVICE_IMPERSONATION');

      // Cross-session isolation: Phone 1 cannot write to Session B
      final crossSession = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/companion/location'),
        bearerToken: phone1Token,
        body: <String, Object?>{
          'pairingSessionId': sessionBId,
          'sharingEnabled': true,
        },
      );
      expect(crossSession.statusCode, 403);
      expect(crossSession.json['error'], 'FORBIDDEN_CROSS_SESSION_ACCESS');

      // Explicit opt-in on Phone 1 shares its separate coordinates; Phone 2 reports permissionDenied
      final optInPhone1 = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/companion/location'),
        bearerToken: phone1Token,
        body: <String, Object?>{
          'pairingSessionId': sessionAId,
          'deviceId': phone1Id,
          'sharingEnabled': true,
          'locationStatus': 'attached',
          'location': <String, Object?>{
            'latitude': 43.47542,
            'longitude': -80.53240,
            'accuracyMeters': 11.0,
            'capturedAtUtc': serverClockUtc.toIso8601String(),
          },
        },
      );
      expect(optInPhone1.statusCode, 200);

      final deniedPhone2 = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/companion/location'),
        bearerToken: phone2Token,
        body: const <String, Object?>{
          'sharingEnabled': false,
          'locationStatus': 'permissionDenied',
        },
      );
      expect(deniedPhone2.statusCode, 200);

      final afterOptIn = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations'),
        bearerToken: phone1Token,
      );
      final updatedDevices = (afterOptIn.json['devices'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final hostEntry = updatedDevices.singleWhere(
        (d) => d['role'] == 'protected_device',
      );
      final p1Entry = updatedDevices.singleWhere(
        (d) => d['deviceId'] == phone1Id,
      );
      final p2Entry = updatedDevices.singleWhere(
        (d) => d['deviceId'] == phone2Id,
      );

      expect(
        (hostEntry['latestLocation'] as Map<String, dynamic>)['latitude'],
        closeTo(43.47490, 1e-5),
      );
      expect(p1Entry['locationSharingEnabled'], isTrue);
      expect(
        (p1Entry['latestLocation'] as Map<String, dynamic>)['latitude'],
        closeTo(43.47542, 1e-5),
      );
      expect(p2Entry['locationStatus'], 'permissionDenied');
      expect(p2Entry['latestLocation'], isNull);

      // Turning off sharing via DELETE immediately removes Phone 1's stored location
      final stopShare = await _httpJson(
        client: client,
        method: 'DELETE',
        uri: Uri.parse('$endpoint/v1/companion/location'),
        bearerToken: phone1Token,
      );
      expect(stopShare.statusCode, 200);
      expect(stopShare.json['locationSharingEnabled'], isFalse);

      final afterDelete = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations'),
        bearerToken: phone1Token,
      );
      final p1Cleared = (afterDelete.json['devices'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .singleWhere((d) => d['deviceId'] == phone1Id);
      expect(p1Cleared['locationSharingEnabled'], isFalse);
      expect(p1Cleared['latestLocation'], isNull);
    });

    testWidgets(
      '6. Redesigned DevicesScreen & PWA: co-located < 28m laptop+phone fan-out, single horizontal chip bar (zero duplicate cards), Coordinates disclosure, interruption notification routing, and responsive 390x844 / 844x390 / 1.3x / 1280x860 layouts',
      (WidgetTester tester) async {
        final endpoint = 'http://127.0.0.1:$relayPort';
        final now = DateTime.now();

        late FakeMotionDetector detector;
        late FakeAudioAlarmAdapter audio;
        late FakeLocationService locationService;
        late FakeLocalNotificationService localNotifs;
        late FakeSystemLifecycleService lifecycle;
        late AlarmController controller;
        late String phone1Id;
        late String phone2Id;

        // Laptop and iPhone are ~3.8m apart at the same desk (< 28m co-located threshold!)
        final laptopDeskLoc = DeviceLocationSnapshot(
          latitude: 43.47490,
          longitude: -80.53303,
          accuracyMeters: 35.0,
          capturedAt: now.subtract(const Duration(seconds: 50)),
        );
        final iphoneDeskLoc = DeviceLocationSnapshot(
          latitude: 43.47493,
          longitude: -80.53301,
          accuracyMeters: 12.0,
          capturedAt: now.subtract(const Duration(seconds: 48)),
        );

        await tester.runAsync(() async {
          final client = HttpClient();
          try {
            detector = FakeMotionDetector(
              type: DetectorType.macosCameraSceneMotion,
            );
            audio = FakeAudioAlarmAdapter();
            lifecycle = FakeSystemLifecycleService();
            locationService = FakeLocationService(
              permission: PermissionStatus.granted,
              nextLocation: laptopDeskLoc,
            );
            localNotifs = FakeLocalNotificationService(
              permission: PermissionStatus.granted,
            );
            final pinService = PinSecurityService(
              storage: InMemorySecurePinStorage(),
              pbkdf2Iterations: 500,
            );
            await pinService.setupInitialPin(
              pin: '135790',
              confirmPin: '135790',
            );

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
                  deviceDisplayName: 'My MacBook',
                  shareLocationOnAlarm: true,
                ),
              ),
              notificationAdapter: remoteNotifs,
              locationAdapter: locationService,
              localNotificationAdapter: localNotifs,
              systemLifecycleAdapter: lifecycle,
            );
            await controller.initialize();

            // Pair 2 companion phones so DevicesScreen renders 3 devices total
            final invite1 = await controller.initiateHostPairing();
            final pair1 = await _httpJson(
              client: client,
              method: 'POST',
              uri: Uri.parse('$endpoint/v1/pairing/complete'),
              body: <String, Object?>{
                'pairingCode': invite1.pairingCode,
                'displayName': 'iPhone',
                'platform': 'iOS Home Screen Web App',
                'notificationsEnabled': true,
              },
            );
            phone1Id = pair1.json['deviceId'] as String;
            final phone1Token = pair1.json['companionToken'] as String;

            await _httpJson(
              client: client,
              method: 'POST',
              uri: Uri.parse('$endpoint/v1/companion/location'),
              bearerToken: phone1Token,
              body: <String, Object?>{
                'sharingEnabled': true,
                'locationStatus': 'attached',
                'location': <String, Object?>{
                  'latitude': iphoneDeskLoc.latitude,
                  'longitude': iphoneDeskLoc.longitude,
                  'accuracyMeters': iphoneDeskLoc.accuracyMeters,
                  'capturedAtUtc': iphoneDeskLoc.capturedAt
                      .toUtc()
                      .toIso8601String(),
                },
              },
            );

            final invite2 = await controller.initiateHostPairing();
            final pair2 = await _httpJson(
              client: client,
              method: 'POST',
              uri: Uri.parse('$endpoint/v1/pairing/complete'),
              body: <String, Object?>{
                'pairingCode': invite2.pairingCode,
                'displayName': 'Backup Android',
                'platform': 'Android Web App',
                'notificationsEnabled': true,
              },
            );
            phone2Id = pair2.json['deviceId'] as String;

            await controller.refreshProtectedDeviceLocation(highAccuracy: true);
            await controller.refreshAuthorizedDeviceLocations();
          } finally {
            client.close(force: true);
          }
        });
        addTearDown(() async {
          controller.dispose();
          await detector.dispose();
          await lifecycle.dispose();
        });

        // --- A. iPhone 13 Portrait (390x844) ---
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await tester.pumpWidget(WatSafeApp(controller: controller));
        await tester.pumpAndSettle();

        // Home pre-arming sleep/lid notice is present
        expect(find.byKey(const Key('home_sleep_lid_notice')), findsOneWidget);

        await tester.tap(find.text('Devices'));
        await tester.pumpAndSettle();

        expect(find.byType(DeviceGeographicMap), findsOneWidget);

        // Verify rendered DeviceGeographicMapState fans out co-located (< 28m) laptop & iPhone markers
        final mapFinder = find.byType(DeviceGeographicMap);
        final mapState = tester.state<DeviceGeographicMapState>(mapFinder);
        final mapSize = tester.getSize(mapFinder);
        final screenPositions = mapState.computeMarkerScreenPositions(mapSize);
        expect(screenPositions.length, 2);
        final hostDeviceId = controller.authorizedDeviceLocations
            .singleWhere((d) => d.isProtectedDevice)
            .deviceId;
        final separationPx =
            (screenPositions[hostDeviceId]! - screenPositions[phone1Id]!)
                .distance;
        expect(
          separationPx,
          greaterThanOrEqualTo(36.0),
          reason: 'Co-located laptop and phone markers (< 28m) must fan out so both pins are visible and tappable',
        );

        expect(
          find.byKey(const Key('devices_selector_chip_bar')),
          findsOneWidget,
        );
        expect(find.byKey(Key('device_chip_$phone1Id')), findsOneWidget);
        expect(find.byKey(Key('device_chip_$phone2Id')), findsOneWidget);
        // Zero duplicate bottom roster cards (`device_roster_row_*` removed in redesign)
        expect(find.byKey(Key('device_roster_row_$phone1Id')), findsNothing);
        // 48–50s age must say "just now", NEVER "0 minutes ago"!
        expect(find.textContaining('0 minutes ago'), findsNothing);
        final ageText = tester.widget<Text>(
          find.byKey(const Key('selected_device_updated_age_label')),
        );
        expect(ageText.data?.toLowerCase(), contains('just now'));

        // Coordinates are tucked behind expandable disclosure until tapped
        expect(
          find.byKey(const Key('devices_coordinates_disclosure')),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('Coordinates'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Coordinates'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('selected_device_coordinates_label')),
          findsOneWidget,
        );

        // Tap iPhone chip -> selects iPhone cleanly with its own coordinates
        await tester.ensureVisible(find.byKey(Key('device_chip_$phone1Id')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('device_chip_$phone1Id')));
        await tester.pumpAndSettle();
        final selectedTitle = tester.widget<Text>(
          find.byKey(const Key('selected_device_name_label')),
        );
        expect(selectedTitle.data, 'iPhone');
        expect(tester.takeException(), isNull);

        // --- B. iPhone 13 Landscape (844x390) ---
        await tester.binding.setSurfaceSize(const Size(844, 390));
        await tester.pumpAndSettle();
        expect(find.byType(DeviceGeographicMap), findsOneWidget);
        expect(tester.takeException(), isNull);

        // --- C. Accessibility 1.3x Text Scale on 390x844 ---
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              textScaler: TextScaler.linear(1.3),
            ),
            child: WatSafeApp(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // --- D. Desktop (1280x860) + Tap on protectionInterrupted notification routes to Activity ---
        await tester.binding.setSurfaceSize(const Size(1280, 860));
        await tester.pumpWidget(WatSafeApp(controller: controller));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        late String interruptedId;
        await tester.runAsync(() async {
          await controller.startArming();
          await controller.handleCountdownTickForSession(
            controller.activeSessionId!,
          );
          lifecycle.emit(
            SystemLifecycleEvent(
              type: SystemLifecycleEventType.lidClosed,
              timestamp: DateTime.now(),
              summary: 'Clamshell closed during test',
              clamshellClosed: true,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 90));
          interruptedId = controller.activeIncident!.id;
          await controller.verifyAndDisarm('135790');
        });
        await tester.pumpAndSettle();

        await tester.tap(find.text('Home'));
        await tester.pumpAndSettle();

        await tester.runAsync(() async {
          localNotifs.simulateTap(interruptedId);
          await Future<void>.delayed(const Duration(milliseconds: 25));
        });
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('activity_selected_event_card')),
          findsOneWidget,
        );
        expect(find.text('Protection interrupted'), findsWidgets);

        // --- E. Companion PWA HTML/CSS/SW verification ---
        await tester.runAsync(() async {
          final client = HttpClient();
          try {
            final resp = await _httpJson(
              client: client,
              method: 'GET',
              uri: Uri.parse('$endpoint/v1/health'),
            );
            expect(resp.statusCode, 200);
            expect(resp.json['swVersion'], '2026.11.17-v5');
            expect(resp.json['watchdogTimeoutSeconds'], 45);

            final pwaReq = await client.getUrl(
              Uri.parse('$endpoint/companion'),
            );
            final pwaResp = await pwaReq.close();
            final html = await utf8.decoder.bind(pwaResp).join();
            expect(
              html,
              contains(
                'name="apple-mobile-web-app-status-bar-style" content="black"',
              ),
            );
            expect(
              html,
              contains('https://tiles.openfreemap.org/styles/liberty'),
            );
            expect(html, contains('device-chip-bar'));
            expect(html, contains('Share this phone’s location'));
            expect(html, contains('coords-disclosure'));
            expect(html, contains('/v1/companion/location'));
            expect(html, isNot(contains('styles/dark')));
          } finally {
            client.close(force: true);
          }
        });
      },
    );
  });
}
