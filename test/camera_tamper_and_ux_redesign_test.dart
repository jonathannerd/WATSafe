import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/incident_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/core/vision/camera_motion_analyzer.dart';
import 'package:watsafe/features/devices/device_geographic_map.dart';
import 'package:watsafe/main.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_notification_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';
import 'package:watsafe/services/system_lifecycle_service.dart';

import '../backend/server.dart';
import 'alarm_controller_test.dart';
import 'camera_motion_detection_test.dart' show renderSyntheticRoomScene;

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
  if (raw.trim().startsWith('{')) {
    final parsed = jsonDecode(raw);
    if (parsed is Map<String, dynamic>) {
      decoded = parsed;
    }
  }
  return (statusCode: resp.statusCode, json: decoded, rawBody: raw);
}

class _SequencedLocationService implements LocationServiceAdapter {
  _SequencedLocationService({
    List<DeviceLocationSnapshot?>? sequence,
    this.fallback,
  }) : _sequence = List<DeviceLocationSnapshot?>.from(
         sequence ?? const <DeviceLocationSnapshot?>[],
       );

  PermissionStatus permission = PermissionStatus.granted;
  final List<DeviceLocationSnapshot?> _sequence;
  DeviceLocationSnapshot? fallback;
  int captureCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<PermissionStatus> checkPermission() async => permission;

  @override
  Future<PermissionStatus> requestPermission() async => permission;

  @override
  Future<({DeviceLocationSnapshot? location, IncidentLocationStatus status})>
  captureCurrentLocation({
    Duration timeout = const Duration(seconds: 4),
    bool highAccuracy = false,
  }) async {
    captureCalls += 1;
    final snap = _sequence.isNotEmpty ? _sequence.removeAt(0) : fallback;
    if (snap == null) {
      return (location: null, status: IncidentLocationStatus.unavailable);
    }
    return (location: snap, status: IncidentLocationStatus.attached);
  }
}

Float32List _flatFrame({
  int width = 64,
  int height = 48,
  required double luma255,
  double smoothGradient = 0.0,
}) {
  final grid = Float32List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final v =
          luma255 +
          smoothGradient * math.sin(x * 0.04) +
          smoothGradient * 0.5 * math.cos(y * 0.05);
      grid[y * width + x] = v.clamp(0.0, 255.0);
    }
  }
  return grid;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Camera Tamper Response, Decoupled Location & UX Redesign Suite', () {
    late HttpServer mockPushGateway;
    late List<({String title, String body, String url, String kind})>
    decryptedPushSummaries;
    late VapidKeyPair companionSubKeys;
    late Uint8List companionAuthSecret;
    late WatSafeRelayServer relayServer;
    late EnvironmentPushProviderAdapter pushProvider;
    late int relayPort;
    late DateTime serverClockUtc;

    setUp(() async {
      HttpOverrides.global = null;
      serverClockUtc = DateTime.utc(2026, 11, 18, 18, 0, 0);
      decryptedPushSummaries =
          <({String title, String body, String url, String kind})>[];
      companionSubKeys = VapidKeyPair.generate();
      companionAuthSecret = Uint8List.fromList(
        List<int>.generate(16, (idx) => (idx * 17 + 11) & 0xff),
      );
      mockPushGateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      mockPushGateway.listen((HttpRequest req) async {
        final encryptedBytes = BytesBuilder(copy: false);
        await for (final chunk in req) {
          encryptedBytes.add(chunk);
        }
        final plainBytes = await WebPushCrypto.decryptAes128Gcm(
          encryptedBody: encryptedBytes.takeBytes(),
          clientKeyPair: companionSubKeys,
          clientAuthSecret: companionAuthSecret,
        );
        final payload =
            jsonDecode(utf8.decode(plainBytes)) as Map<String, dynamic>;
        final data =
            (payload['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
        decryptedPushSummaries.add((
          title: payload['title'] as String? ?? '',
          body: payload['body'] as String? ?? '',
          url: data['url'] as String? ?? '',
          kind: data['kind'] as String? ?? '',
        ));
        req.response.statusCode = 201;
        await req.response.close();
      });

      final serverVapid = VapidKeyPair.generate();
      pushProvider = EnvironmentPushProviderAdapter(
        environment: <String, String>{
          'VAPID_PUBLIC_KEY': serverVapid.publicKeyBase64Url,
          'VAPID_PRIVATE_KEY': serverVapid.privateKeyBase64Url,
          'VAPID_SUBJECT': 'https://watsafe-relay.onrender.com',
        },
        persistVapidKeysToDisk: false,
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
      await mockPushGateway.close(force: true);
    });

    Future<String> pairControllerWithPhone({
      required AlarmController controller,
      required HttpClient client,
    }) async {
      final endpoint = 'http://127.0.0.1:$relayPort';
      final invite = await controller.initiateHostPairing();
      final pairResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/pairing/complete'),
        body: <String, Object?>{
          'pairingCode': invite.pairingCode,
          'displayName': 'iPhone',
          'platform': 'iOS Home Screen Web App',
          'httpsReady': true,
          'homeScreenInstalled': true,
          'notificationPermission': 'granted',
          'notificationsEnabled': true,
        },
      );
      final companionToken = pairResp.json['companionToken'] as String;
      final subResp = await _httpJson(
        client: client,
        method: 'POST',
        uri: Uri.parse('$endpoint/v1/companion/push-subscription'),
        bearerToken: companionToken,
        body: <String, Object?>{
          'endpoint':
              'http://127.0.0.1:${mockPushGateway.port}/wpush/v2/iphone_tamper_sub',
          'p256dh': companionSubKeys.publicKeyBase64Url,
          'auth': base64UrlNoPadEncode(companionAuthSecret),
          'platform': 'iOS Home Screen Web App',
          'httpsReady': true,
          'homeScreenInstalled': true,
          'notificationPermission': 'granted',
        },
      );
      expect(subResp.statusCode, 200);
      await controller.refreshNotificationStatus();
      return companionToken;
    }

    test('1. CameraMotionAnalyzer detects palm/texture-collapse, dark cover, and bright glare after 10 frames (~1.25s), rejects brief hand waves (< 1.25s), and avoids tamper loops when armed with an already-blocked camera', () {
      final room = renderSyntheticRoomScene();
      final palmCover = _flatFrame(luma255: 132.0, smoothGradient: 5.5);
      final darkCover = _flatFrame(luma255: 3.0);
      final brightGlare = _flatFrame(luma255: 251.0, smoothGradient: 1.5);

      void verifySustainedObstructionMode(
        Float32List coverFrame,
        Set<String> expectedKinds,
      ) {
        final analyzer = CameraMotionAnalyzer(
          calibrationDuration: const Duration(milliseconds: 600),
        );
        var t = DateTime.utc(2026, 11, 18, 12, 0, 0);
        for (var i = 0; i < 8; i++) {
          t = t.add(const Duration(milliseconds: 125));
          analyzer.processFrame(room, timestamp: t);
        }
        expect(analyzer.isCalibrationDone, isTrue);
        expect(analyzer.isObstructedAtCalibration, isFalse);

        // A. Brief hand wave (4 frames = 0.5s) -> NO tamper trigger and NO motion false alarm on return
        for (var i = 0; i < 4; i++) {
          t = t.add(const Duration(milliseconds: 125));
          final ev = analyzer.processFrame(coverFrame, timestamp: t);
          expect(ev.triggered, isFalse);
          expect(ev.cameraObstructed, isFalse);
          expect(ev.obstructionJustTriggered, isFalse);
        }
        for (var i = 0; i < 4; i++) {
          t = t.add(const Duration(milliseconds: 125));
          final ev = analyzer.processFrame(room, timestamp: t);
          expect(
            ev.triggered,
            isFalse,
            reason: 'Reference grid must remain frozen during brief cover so uncovering does not trigger false motion',
          );
          expect(ev.cameraObstructed, isFalse);
        }

        // B. Sustained cover (10 consecutive frames = 1.25s at 8 fps) -> triggers exactly on frame 10
        CameraMotionFrameEvaluation? triggeredEval;
        for (var i = 1; i <= 10; i++) {
          t = t.add(const Duration(milliseconds: 125));
          final ev = analyzer.processFrame(coverFrame, timestamp: t);
          expect(ev.triggered, isFalse);
          if (i < 10) {
            expect(ev.cameraObstructed, isFalse);
            expect(ev.obstructionJustTriggered, isFalse);
          } else {
            triggeredEval = ev;
          }
        }
        expect(triggeredEval, isNotNull);
        expect(triggeredEval!.cameraObstructed, isTrue);
        expect(triggeredEval.obstructionJustTriggered, isTrue);
        expect(expectedKinds, contains(triggeredEval.obstructionKind));
      }

      verifySustainedObstructionMode(palmCover, <String>{
        'texture_collapse',
        'opaque_cover',
      });
      verifySustainedObstructionMode(darkCover, <String>{'dark'});
      verifySustainedObstructionMode(brightGlare, <String>{'bright_glare'});

      // C. Arming with an already-blocked camera warns at calibration without entering an immediate tamper loop,
      // then arms tamper detection once uncovered and covered again!
      final preBlockedAnalyzer = CameraMotionAnalyzer(
        calibrationDuration: const Duration(milliseconds: 600),
      );
      var t = DateTime.utc(2026, 11, 18, 12, 5, 0);
      CameraMotionFrameEvaluation? calDoneEval;
      for (var i = 0; i < 7; i++) {
        t = t.add(const Duration(milliseconds: 125));
        final ev = preBlockedAnalyzer.processFrame(darkCover, timestamp: t);
        if (ev.calibrationJustCompleted) {
          calDoneEval = ev;
        }
      }
      expect(calDoneEval, isNotNull);
      expect(calDoneEval!.isObstructedAtCalibration, isTrue);

      for (var i = 0; i < 20; i++) {
        t = t.add(const Duration(milliseconds: 125));
        final ev = preBlockedAnalyzer.processFrame(darkCover, timestamp: t);
        expect(ev.obstructionJustTriggered, isFalse);
        expect(ev.cameraObstructed, isFalse);
      }

      for (var i = 0; i < 6; i++) {
        t = t.add(const Duration(milliseconds: 125));
        preBlockedAnalyzer.processFrame(room, timestamp: t);
      }
      var postUncoverTriggered = false;
      for (var i = 0; i < 10; i++) {
        t = t.add(const Duration(milliseconds: 125));
        final ev = preBlockedAnalyzer.processFrame(palmCover, timestamp: t);
        if (ev.obstructionJustTriggered) {
          postUncoverTriggered = true;
        }
      }
      expect(postUncoverTriggered, isTrue);
    });

    test('2. Sustained camera obstruction & capture failure while armed trigger local siren + "Camera blocked" / "Protection interrupted" Web Push, keep lid/watchdog armed, do not auto-disarm when uncovered, deduplicate immediate lid close, and stop siren on PIN disarm', () async {
      final endpoint = 'http://127.0.0.1:$relayPort';
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final detector = FakeMotionDetector(
        type: DetectorType.macosCameraSceneMotion,
      );
      final audio = FakeAudioAlarmAdapter();
      final lifecycle = FakeSystemLifecycleService();
      final remoteService = ConfigurableRemoteNotificationService(
        persistToDisk: false,
        initialRelayEndpointUrl: endpoint,
        enableBackgroundPolling: false,
      );
      final pinService = PinSecurityService(
        storage: InMemorySecurePinStorage(),
        pbkdf2Iterations: 500,
      );
      await pinService.setupInitialPin(pin: '654321', confirmPin: '654321');

      final controller = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.macosCameraSceneMotion: detector,
        },
        audioAdapter: audio,
        pinService: pinService,
        incidentStorage: InMemoryIncidentStorage(),
        settingsStorage: InMemorySettingsStorage(
          const ProtectionSettings(
            deviceDisplayName: 'My MacBook',
            selectedDetector: DetectorType.macosCameraSceneMotion,
            armingCountdownSeconds: 1,
            onboardingCompleted: true,
            shareLocationOnAlarm: false,
          ),
        ),
        notificationAdapter: remoteService,
        systemLifecycleAdapter: lifecycle,
      );
      addTearDown(() async {
        controller.dispose();
        remoteService.dispose();
        await detector.dispose();
        await lifecycle.dispose();
      });

      await controller.initialize();
      await pairControllerWithPhone(controller: controller, client: client);

      await controller.startArming();
      final session1 = controller.activeSessionId!;
      await controller.handleCountdownTickForSession(session1);
      expect(controller.state, ProtectionState.armed);
      expect(lifecycle.lastSyncedArmed, isTrue);

      // Emit sustained camera obstruction -> local siren + "Camera blocked" phone alert
      detector.emit(
        DetectorEvent(
          eventId: 'cam_cover_1',
          sessionId: session1,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.cameraObstructed,
          timestamp: DateTime.now(),
          summary: 'Camera blocked — camera view was covered or obstructed while armed.',
          obstructionKind: 'texture_collapse',
          consecutiveAboveThresholdFrames: 10,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 140));

      expect(controller.state, ProtectionState.alarming);
      expect(audio.isPlaying, isTrue);
      expect(
        controller.activeIncident?.kind,
        IncidentKind.protectionInterrupted,
      );
      expect(lifecycle.lastSyncedArmed, isTrue);
      expect(decryptedPushSummaries, hasLength(1));
      expect(decryptedPushSummaries.single.title, equals('My MacBook'));
      expect(
        decryptedPushSummaries.single.body,
        startsWith('Camera blocked on My MacBook'),
      );
      expect(
        decryptedPushSummaries.single.url,
        startsWith('/companion?incident='),
      );

      // Removing the hand/obstruction must NOT automatically disarm or stop siren
      detector.emit(
        DetectorEvent(
          eventId: 'cam_uncover_1',
          sessionId: session1,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.inputRecovered,
          timestamp: DateTime.now(),
          summary: 'Camera view restored.',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.state, ProtectionState.alarming);
      expect(audio.isPlaying, isTrue);

      // Immediate lid closure right after camera cover cooperates cleanly with 0 duplicate incidents or pushes,
      // and backend 55s watchdog is also deduplicated for this armed episode!
      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.lidClosed,
          timestamp: DateTime.now(),
          summary: 'Laptop lid closed after covering camera',
          clamshellClosed: true,
          flushToken: 'lid_after_cover_token',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(lifecycle.completedFlushTokens, contains('lid_after_cover_token'));
      expect(controller.incidents, hasLength(1));
      expect(decryptedPushSummaries, hasLength(1));

      serverClockUtc = serverClockUtc.add(const Duration(seconds: 55));
      expect(
        await relayServer.sweepArmedHeartbeatWatchdog(serverClockUtc),
        0,
        reason: 'Watchdog must not send a second push after Camera blocked alert already succeeded for this armed episode',
      );
      expect(decryptedPushSummaries, hasLength(1));

      // Wrong PIN keeps siren active; correct PIN stops siren immediately and clears armed state
      final badPin = await controller.verifyAndDisarm('000000');
      expect(badPin.verified, isFalse);
      expect(audio.isPlaying, isTrue);

      final goodPin = await controller.verifyAndDisarm('654321');
      expect(goodPin.verified, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(controller.state, ProtectionState.disarmed);
      expect(audio.isPlaying, isFalse);
      expect(lifecycle.lastSyncedArmed, isFalse);

      // Re-arm and verify camera capture failure / unplug (`detectorFailed`) while armed also triggers siren + "Protection interrupted"
      await controller.startArming();
      final session2 = controller.activeSessionId!;
      await controller.handleCountdownTickForSession(session2);
      expect(controller.state, ProtectionState.armed);

      detector.emit(
        DetectorEvent(
          eventId: 'cam_unplug_2',
          sessionId: session2,
          detectorType: DetectorType.macosCameraSceneMotion,
          eventType: DetectorEventType.detectorFailed,
          timestamp: DateTime.now(),
          summary: 'USB webcam disconnected while armed.',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(controller.state, ProtectionState.alarming);
      expect(audio.isPlaying, isTrue);
      expect(decryptedPushSummaries, hasLength(2));
      expect(decryptedPushSummaries.last.title, equals('My MacBook'));
      expect(
        decryptedPushSummaries.last.body,
        startsWith('Protection interrupted on My MacBook'),
      );

      await controller.verifyAndDisarm('654321');
      expect(audio.isPlaying, isFalse);
    });

    test('3. Disarmed laptop reports location on launch, updates periodically & on resume, honors online phone refresh (?requestRefresh=1 with 30s rate limit), and distinguishes recent vs live vs last_known', () async {
      final endpoint = 'http://127.0.0.1:$relayPort';
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final t0 = serverClockUtc.subtract(const Duration(seconds: 12));
      final t1 = serverClockUtc.subtract(const Duration(seconds: 4));
      final t2 = serverClockUtc;
      final loc0 = DeviceLocationSnapshot(
        latitude: 43.47230,
        longitude: -80.54490,
        accuracyMeters: 28.0,
        capturedAt: t0,
      );
      final loc1 = DeviceLocationSnapshot(
        latitude: 43.47285,
        longitude: -80.54410,
        accuracyMeters: 24.0,
        capturedAt: t1,
      );
      final loc2 = DeviceLocationSnapshot(
        latitude: 43.47340,
        longitude: -80.54320,
        accuracyMeters: 18.0,
        capturedAt: t2,
      );

      final locationService = _SequencedLocationService(
        sequence: <DeviceLocationSnapshot?>[loc0, loc0, loc0, loc1],
        fallback: loc2,
      );
      final detector = FakeMotionDetector(
        type: DetectorType.macosCameraSceneMotion,
      );
      final lifecycle = FakeSystemLifecycleService();
      final remoteService = ConfigurableRemoteNotificationService(
        persistToDisk: false,
        initialRelayEndpointUrl: endpoint,
        enableBackgroundPolling: false,
      );
      final pinService = PinSecurityService(
        storage: InMemorySecurePinStorage(),
        pbkdf2Iterations: 500,
      );
      await pinService.setupInitialPin(pin: '112233', confirmPin: '112233');

      final controller = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.macosCameraSceneMotion: detector,
        },
        audioAdapter: FakeAudioAlarmAdapter(),
        pinService: pinService,
        incidentStorage: InMemoryIncidentStorage(),
        settingsStorage: InMemorySettingsStorage(
          const ProtectionSettings(
            deviceDisplayName: 'Desk MacBook',
            selectedDetector: DetectorType.macosCameraSceneMotion,
            onboardingCompleted: true,
            shareLocationOnAlarm: true,
          ),
        ),
        notificationAdapter: remoteService,
        locationAdapter: locationService,
        systemLifecycleAdapter: lifecycle,
        regularLocationRefreshInterval: const Duration(milliseconds: 140),
      );
      addTearDown(() async {
        controller.dispose();
        remoteService.dispose();
        await detector.dispose();
        await lifecycle.dispose();
      });

      await controller.initialize();
      final companionToken = await pairControllerWithPhone(
        controller: controller,
        client: client,
      );
      // Trigger disarmed wake/resume refresh right after pairing so initial coordinates land on the new session
      lifecycle.emit(
        SystemLifecycleEvent(
          type: SystemLifecycleEventType.systemDidWake,
          timestamp: DateTime.now(),
          summary: 'MacBook woke from sleep',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(controller.state, ProtectionState.disarmed);
      final initialFetch = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations'),
        bearerToken: companionToken,
      );
      expect(initialFetch.statusCode, 200);
      final devices0 = initialFetch.json['devices'] as List<dynamic>;
      final host0 = devices0.firstWhere(
        (d) => (d as Map<String, dynamic>)['role'] == 'protected_device',
      ) as Map<String, dynamic>;
      expect(host0['online'], isTrue);
      expect(host0['trackingState'], equals('recent'));
      final host0Loc = host0['latestLocation'] as Map<String, dynamic>;
      expect(host0Loc['latitude'], closeTo(43.47230, 1e-5));
      expect(
        DateTime.parse(host0Loc['capturedAtUtc'] as String).toUtc(),
        equals(t0.toUtc()),
        reason: 'Server must preserve true measurement timestamp capturedAtUtc',
      );

      // Wait for regular periodic refresh -> uploads newer coordinates while still disarmed
      await Future<void>.delayed(const Duration(milliseconds: 340));
      final periodicFetch = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations'),
        bearerToken: companionToken,
      );
      final host1 = (periodicFetch.json['devices'] as List<dynamic>).firstWhere(
        (d) => (d as Map<String, dynamic>)['role'] == 'protected_device',
      ) as Map<String, dynamic>;
      expect(
        (host1['latestLocation'] as Map<String, dynamic>)['latitude'],
        greaterThan(43.4725),
      );

      // Paired phone opens Devices with ?requestRefresh=1 -> queues hostLocationRefreshQueued: true (rate-limited 30s)
      final refreshReq1 = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations?requestRefresh=1'),
        bearerToken: companionToken,
      );
      expect(refreshReq1.json['hostLocationRefreshQueued'], isTrue);

      // Immediate second request within 30s is rate-limited
      final refreshReq2 = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations?requestRefresh=1'),
        bearerToken: companionToken,
      );
      expect(refreshReq2.json['hostLocationRefreshQueued'], isFalse);

      // Advance server clock > 30s -> next ?requestRefresh=1 is accepted again
      serverClockUtc = serverClockUtc.add(const Duration(seconds: 31));
      final refreshReq3 = await _httpJson(
        client: client,
        method: 'GET',
        uri: Uri.parse('$endpoint/v1/devices/locations?requestRefresh=1'),
        bearerToken: companionToken,
      );
      expect(refreshReq3.json['hostLocationRefreshQueued'], isTrue);
    });

    testWidgets(
      '4. Phone Companion PWA contracts + Simplified Laptop HomeScreen + 7-Category SettingsScreen + Clean DevicesScreen across 390x844, 844x390 & 1280x860',
      (WidgetTester tester) async {
        final endpoint = 'http://127.0.0.1:$relayPort';

        // --- A. Verify Phone Companion PWA & Service Worker contracts ---
        await tester.runAsync(() async {
          final client = HttpClient();
          try {
            final pwaResp = await _httpJson(
              client: client,
              method: 'GET',
              uri: Uri.parse('$endpoint/companion'),
            );
            final html = pwaResp.rawBody;
            expect(pwaResp.statusCode, 200);
            expect(html, contains('id="tabDevices"'));
            expect(html, contains('id="tabSettings"'));
            expect(html, isNot(contains('id="tabHome"')));
            expect(html, isNot(contains('id="tabActivity"')));
            expect(html, isNot(contains('Send test alert')));
            expect(html, isNot(contains('Open in Maps')));
            expect(html, isNot(contains('google.com/maps')));
            expect(html, isNot(contains('Follow incident')));
            expect(html, isNot(contains('Device locations refreshed.')));
            expect(html, contains('id="stepSetupChecklist"'));
            expect(html, contains('id="settingsTroubleshootingDetails"'));
            expect(html, contains('id="locationOnboardingCard"'));
            expect(html, contains('Enable location'));
            expect(html, contains('Share phone location'));
            expect(html, contains('While app is open'));
            expect(html, contains('id="activeAlarmBanner"'));
            expect(html, contains('Camera blocked'));
            expect(html, contains('window.maplibregl.AttributionControl'));
            expect(html, contains('compact: true'));
            expect(html, contains('requestRefresh=1'));

            final swResp = await _httpJson(
              client: client,
              method: 'GET',
              uri: Uri.parse('$endpoint/sw.js'),
            );
            expect(swResp.rawBody, contains('watsafe-shell-2026.11.18-v8'));
            expect(swResp.rawBody, contains('/companion?incident='));
            expect(swResp.rawBody, contains('/ack'));
          } finally {
            client.close(force: true);
          }
        });

        // --- B. Desktop UI: Simplified HomeScreen, Clean DevicesScreen (no false Last known badge), & 7-Category SettingsScreen ---
        final detector = FakeMotionDetector(
          type: DetectorType.macosCameraSceneMotion,
        );
        final remoteNotifs = ConfigurableRemoteNotificationService(
          persistToDisk: false,
          initialRelayEndpointUrl: endpoint,
          enableBackgroundPolling: false,
        );
        final pinService = PinSecurityService(
          storage: InMemorySecurePinStorage(),
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '135790', confirmPin: '135790');
        final recentLoc = DeviceLocationSnapshot(
          latitude: 43.47490,
          longitude: -80.53303,
          accuracyMeters: 35.0,
          capturedAt: DateTime.now().subtract(const Duration(seconds: 20)),
        );
        final controller = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.macosCameraSceneMotion: detector,
          },
          audioAdapter: FakeAudioAlarmAdapter(),
          pinService: pinService,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: InMemorySettingsStorage(
            const ProtectionSettings(
              deviceDisplayName: 'My MacBook',
              selectedDetector: DetectorType.macosCameraSceneMotion,
              onboardingCompleted: true,
              shareLocationOnAlarm: true,
            ),
          ),
          notificationAdapter: remoteNotifs,
          localNotificationAdapter: FakeLocalNotificationService(
            permission: PermissionStatus.granted,
          ),
          locationAdapter: _SequencedLocationService(fallback: recentLoc),
        );
        addTearDown(() async {
          controller.dispose();
          remoteNotifs.dispose();
          await detector.dispose();
        });
        await tester.runAsync(() async {
          await controller.initialize();
          await Future<void>.delayed(const Duration(milliseconds: 60));
        });

        await tester.binding.setSurfaceSize(const Size(1280, 860));
        await tester.pumpWidget(WatSafeApp(controller: controller));
        await tester.pumpAndSettle();

        // Simplified HomeScreen checks
        expect(find.text('Protection is off'), findsOneWidget);
        expect(
          find.textContaining('Arm protection before stepping away'),
          findsNothing,
        );
        expect(find.byKey(const Key('home_sleep_lid_notice')), findsNothing);
        expect(
          find.byKey(const Key('home_protection_details_tile')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('home_protection_details_tile')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('tamper alarm if the camera is covered'),
          findsOneWidget,
        );

        // Clean DevicesScreen checks: online host shows "Updated just now", NO false "Last known location", NO "Open in Maps" or "Follow incident"
        await tester.tap(find.text('Devices'));
        await tester.pumpAndSettle();
        expect(find.byType(DeviceGeographicMap), findsOneWidget);
        expect(find.text('Updated just now'), findsOneWidget);
        expect(find.text('Last known location'), findsNothing);
        expect(find.text('Open in Maps'), findsNothing);
        expect(find.text('Follow incident'), findsNothing);
        expect(tester.takeException(), isNull);

        // 7-Category SettingsScreen checks + Back button + Camera obstruction alarm switch
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        for (final keyName in <String>[
          'settings_category_protection',
          'settings_category_alarm',
          'settings_category_devices',
          'settings_category_location',
          'settings_category_pin',
          'settings_category_appearance',
          'settings_category_advanced',
        ]) {
          expect(find.byKey(Key(keyName)), findsOneWidget);
        }

        await tester.tap(find.byKey(const Key('settings_category_protection')));
        await tester.pumpAndSettle();
        final camObstructSwitch = find.byKey(
          const Key('alert_on_camera_obstruction_switch'),
        );
        expect(camObstructSwitch, findsOneWidget);
        expect(controller.settings.alertOnCameraObstruction, isTrue);
        await tester.ensureVisible(camObstructSwitch);
        await tester.tap(camObstructSwitch);
        await tester.pumpAndSettle();
        expect(controller.settings.alertOnCameraObstruction, isFalse);

        await tester.tap(
          find.byKey(const Key('settings_category_back_button')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('settings_category_list')), findsOneWidget);

        // Verify zero overflow across iPhone 13 portrait (390x844) and landscape (844x390)
        for (final size in const <Size>[Size(390, 844), Size(844, 390)]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      },
    );
  });
}
