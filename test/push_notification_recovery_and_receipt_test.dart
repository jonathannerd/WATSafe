import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/relay/relay_server.dart';
import 'package:watsafe/relay/web_push.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

import 'alarm_controller_test.dart';

Future<Map<String, dynamic>> _requestJson({
  required HttpClient client,
  required String method,
  required Uri uri,
  Map<String, Object?>? body,
  String? bearerToken,
  required List<int> expectedStatuses,
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
  final text = await utf8.decoder.bind(resp).join();
  expect(
    expectedStatuses,
    contains(resp.statusCode),
    reason: 'Unexpected HTTP ${resp.statusCode} from $method $uri: $text',
  );
  final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
  return <String, dynamic>{
    '_status': resp.statusCode,
    if (decoded is Map<String, dynamic>) ...decoded,
  };
}

Map<String, dynamic> _decodeVapidJwtClaims(String authHeader) {
  final match = RegExp(r't=([^,\s]+),\s*k=([^,\s]+)').firstMatch(authHeader);
  expect(match, isNotNull, reason: 'Expected RFC 8292 vapid Authorization');
  final jwt = match!.group(1)!;
  final parts = jwt.split('.');
  expect(parts, hasLength(3));
  return jsonDecode(utf8.decode(base64FlexibleDecode(parts[1])))
      as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phone Push Notification Recovery, VAPID Subject & Receipt Suite', () {
    test('1. Rejects .local/.localhost/private VAPID subjects that trigger Apple Web Push 403 BadJwtToken and normalizes automatically', () async {
      HttpOverrides.global = null;
      expect(
        VapidKeyPair.isValidPublicSubject('mailto:alerts@watsafe.local'),
        isFalse,
      );
      expect(
        VapidKeyPair.isValidPublicSubject('mailto:alerts@localhost'),
        isFalse,
      );
      expect(
        VapidKeyPair.isValidPublicSubject('https://192.168.0.115:8787'),
        isFalse,
      );
      expect(
        VapidKeyPair.isValidPublicSubject('mailto:alerts@watsafe.app'),
        isTrue,
      );
      expect(
        VapidKeyPair.isValidPublicSubject('https://watsafe-relay.onrender.com'),
        isTrue,
      );
      expect(
        VapidKeyPair.normalizeSubject(
          'mailto:alerts@watsafe.local',
          publicHttpsOrigin: 'https://watsafe-relay.onrender.com',
        ),
        equals('https://watsafe-relay.onrender.com'),
      );
      expect(
        VapidKeyPair.normalizeSubject('mailto:alerts@watsafe.local'),
        equals(VapidKeyPair.defaultSubject),
      );

      // Endpoint sanitization must strip full Web Push URLs from diagnostic text.
      final sanitized = DirectWebPushSender.sanitizeDiagnosticText(
        'Rejected https://web.push.apple.com/QNl3SecretTokenPathXYZ with BadJwtToken',
      );
      expect(sanitized, isNot(contains('QNl3SecretTokenPathXYZ')));
      expect(sanitized, contains('BadJwtToken'));

      final client = HttpClient();
      HttpServer? mockApplePush;
      WatSafeRelayServer? relay;
      try {
        // Mock Apple Web Push gateway enforcing strict RFC 8292 public `sub` rules.
        String? observedSub;
        mockApplePush = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        mockApplePush.listen((HttpRequest req) async {
          await req.drain<void>();
          final auth = req.headers.value('authorization') ?? '';
          final claims = _decodeVapidJwtClaims(auth);
          final sub = (claims['sub'] as String? ?? '');
          observedSub = sub;
          if (!VapidKeyPair.isValidPublicSubject(sub)) {
            req.response.statusCode = HttpStatus.forbidden;
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({'reason': 'BadJwtToken'}));
            await req.response.close();
            return;
          }
          req.response.statusCode = HttpStatus.created;
          await req.response.close();
        });

        final vapidKeys = VapidKeyPair.generate();
        final pushProvider = EnvironmentPushProviderAdapter(
          environment: <String, String>{
            'VAPID_PUBLIC_KEY': vapidKeys.publicKeyBase64Url,
            'VAPID_PRIVATE_KEY': vapidKeys.privateKeyBase64Url,
            // Exact broken env var seen in production before fix:
            'VAPID_SUBJECT': 'mailto:alerts@watsafe.local',
            'RENDER_EXTERNAL_URL': 'https://watsafe-relay.onrender.com',
          },
          logWebPushFailures: false,
        );
        relay = WatSafeRelayServer(
          store: InMemoryRelayStore(),
          pushProvider: pushProvider,
        );
        final relayPort = await relay.start(
          address: InternetAddress.loopbackIPv4,
          port: 0,
        );
        final relayBase = 'http://127.0.0.1:$relayPort';

        final health = await _requestJson(
          client: client,
          method: 'GET',
          uri: Uri.parse('$relayBase/v1/health'),
          expectedStatuses: const <int>[200],
        );
        expect(
          health['vapidSubject'],
          equals('https://watsafe-relay.onrender.com'),
        );
        expect(
          health['swVersion'],
          equals(WatSafeRelayServer.companionSwVersion),
        );
        expect(health['swVersion'], equals('2026.11.18-v6'));

        final initiated = await _requestJson(
          client: client,
          method: 'POST',
          uri: Uri.parse('$relayBase/v1/pairing/initiate'),
          body: const <String, Object?>{'hostDisplayName': 'MacBook Pro'},
          expectedStatuses: const <int>[200],
        );
        final paired = await _requestJson(
          client: client,
          method: 'POST',
          uri: Uri.parse('$relayBase/v1/pairing/complete'),
          body: <String, Object?>{
            'pairingCode': initiated['pairingCode'],
            'displayName': 'My iPhone',
            'platform': 'iOS Home Screen Web App',
            'httpsReady': true,
            'homeScreenInstalled': true,
            'notificationPermission': 'granted',
          },
          expectedStatuses: const <int>[200],
        );
        final companionToken = paired['companionToken'] as String;

        final subKeys = VapidKeyPair.generate();
        final rng = Random.secure();
        final authSecret = Uint8List.fromList(
          List<int>.generate(16, (_) => rng.nextInt(256)),
        );
        await _requestJson(
          client: client,
          method: 'POST',
          uri: Uri.parse('$relayBase/v1/companion/push-subscription'),
          bearerToken: companionToken,
          body: <String, Object?>{
            'endpoint':
                'http://127.0.0.1:${mockApplePush.port}/wpush/v2/test_sub_1',
            'p256dh': subKeys.publicKeyBase64Url,
            'auth': base64UrlNoPadEncode(authSecret),
            'subscribedVapidPublicKey': vapidKeys.publicKeyBase64Url,
            'platform': 'iOS Home Screen Web App',
            'httpsReady': true,
            'homeScreenInstalled': true,
            'notificationPermission': 'granted',
          },
          expectedStatuses: const <int>[200],
        );

        final testAlert = await _requestJson(
          client: client,
          method: 'POST',
          uri: Uri.parse('$relayBase/v1/companion/test-alert'),
          bearerToken: companionToken,
          body: const <String, Object?>{'delaySeconds': 0},
          expectedStatuses: const <int>[200],
        );
        expect(observedSub, equals('https://watsafe-relay.onrender.com'));
        expect(testAlert['delivered'], isTrue);
        expect(testAlert['pushAccepted'], isTrue);
        expect(testAlert['pushAcceptedCount'], equals(1));
        expect(testAlert['receiptConfirmed'], isFalse);
        expect(testAlert['deliveryStage'], equals('push_service_accepted'));
      } finally {
        client.close(force: true);
        await relay?.stop();
        await mockApplePush?.close(force: true);
      }
    });

    test('2. Distinguishes push service accepted from confirmed phone receipt, never reports misleading success on provider rejection, and recovers VAPID/token mismatch without re-pairing', () async {
      HttpOverrides.global = null;
      final client = HttpClient();
      HttpServer? pushGateway;
      WatSafeRelayServer? relay;
      AlarmController? controller;
      ConfigurableRemoteNotificationService? remoteNotifications;

      try {
        var gatewayStatus = HttpStatus.created;
        Map<String, Object?>? gatewayErrorJson;
        pushGateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        pushGateway.listen((HttpRequest req) async {
          await req.drain<void>();
          req.response.statusCode = gatewayStatus;
          if (gatewayErrorJson != null) {
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode(gatewayErrorJson));
          }
          await req.response.close();
        });

        final vapidKeys = VapidKeyPair.generate();
        relay = WatSafeRelayServer(
          store: InMemoryRelayStore(),
          pushProvider: EnvironmentPushProviderAdapter(
            environment: <String, String>{
              'VAPID_PUBLIC_KEY': vapidKeys.publicKeyBase64Url,
              'VAPID_PRIVATE_KEY': vapidKeys.privateKeyBase64Url,
              'VAPID_SUBJECT': 'mailto:alerts@watsafe.app',
            },
            logWebPushFailures: false,
          ),
        );
        final relayPort = await relay.start(
          address: InternetAddress.loopbackIPv4,
          port: 0,
        );
        final relayBase = 'http://127.0.0.1:$relayPort';

        final pinService = PinSecurityService(
          storage: InMemorySecurePinStorage(),
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '2468', confirmPin: '2468');

        remoteNotifications = ConfigurableRemoteNotificationService(
          persistToDisk: false,
          initialRelayEndpointUrl: relayBase,
          enableBackgroundPolling: false,
        );
        final fakeDetector = FakeMotionDetector(
          type: DetectorType.windowsCameraSceneMotion,
        );
        final fakeAudio = FakeAudioAlarmAdapter();
        controller = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.windowsCameraSceneMotion: fakeDetector,
          },
          audioAdapter: fakeAudio,
          pinService: pinService,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: InMemorySettingsStorage(
            const ProtectionSettings(
              selectedDetector: DetectorType.windowsCameraSceneMotion,
              armingCountdownSeconds: 1,
              onboardingCompleted: true,
            ),
          ),
          notificationAdapter: remoteNotifications,
        );
        await controller.initialize();

        final invite = await remoteNotifications.initiateHostPairing(
          hostDisplayName: 'MacBook Pro',
        );

        // Pair iPhone companion once
        final paired = await _requestJson(
          client: client,
          method: 'POST',
          uri: Uri.parse('$relayBase/v1/pairing/complete'),
          body: <String, Object?>{
            'pairingCode': invite.pairingCode,
            'deviceId': 'phone_permanent_1',
            'displayName': 'My iPhone',
            'platform': 'iOS Home Screen Web App',
            'httpsReady': true,
            'homeScreenInstalled': true,
            'notificationPermission': 'granted',
          },
          expectedStatuses: const <int>[200],
        );
        final companionToken = paired['companionToken'] as String;
        final bondId = paired['bondId'] as String;

        // Case A: VAPID key mismatch returns 409 with current server key while keeping pairing alive!
        final staleVapid = VapidKeyPair.generate();
        final subKeys = VapidKeyPair.generate();
        final rng = Random.secure();
        final authSecret = Uint8List.fromList(
          List<int>.generate(16, (_) => rng.nextInt(256)),
        );
        final mismatchRes = await _requestJson(
          client: client,
          method: 'POST',
          uri: Uri.parse('$relayBase/v1/companion/push-subscription'),
          bearerToken: companionToken,
          body: <String, Object?>{
            'endpoint':
                'http://127.0.0.1:${pushGateway.port}/wpush/v2/sub_stale',
            'p256dh': subKeys.publicKeyBase64Url,
            'auth': base64UrlNoPadEncode(authSecret),
            'subscribedVapidPublicKey': staleVapid.publicKeyBase64Url,
            'platform': 'iOS Home Screen Web App',
            'httpsReady': true,
            'homeScreenInstalled': true,
            'notificationPermission': 'granted',
          },
          expectedStatuses: const <int>[409],
        );
        expect(mismatchRes['error'], equals('VAPID_KEY_MISMATCH'));
        expect(
          mismatchRes['vapidPublicKey'],
          equals(vapidKeys.publicKeyBase64Url),
        );

        // Registering with refreshed server VAPID key succeeds on the SAME companionToken & bondId!
        final validSubRes = await _requestJson(
          client: client,
          method: 'POST',
          uri: Uri.parse('$relayBase/v1/companion/push-subscription'),
          bearerToken: companionToken,
          body: <String, Object?>{
            'endpoint':
                'http://127.0.0.1:${pushGateway.port}/wpush/v2/sub_live_1',
            'p256dh': subKeys.publicKeyBase64Url,
            'auth': base64UrlNoPadEncode(authSecret),
            'subscribedVapidPublicKey': vapidKeys.publicKeyBase64Url,
            'platform': 'iOS Home Screen Web App',
            'httpsReady': true,
            'homeScreenInstalled': true,
            'notificationPermission': 'granted',
          },
          expectedStatuses: const <int>[200],
        );
        expect(validSubRes['bondId'], equals(bondId));
        expect(validSubRes['notificationsEnabled'], isTrue);
        expect(validSubRes['vapidKeyMismatch'], isFalse);

        await remoteNotifications.syncPairedDevicesFromRelay();
        await controller.refreshNotificationStatus();

        // Case B: Send test alert from desktop -> reports "Push service accepted ... awaiting phone receipt"
        final dispatchOk = await controller.sendTestAlertToPairedPhone();
        expect(dispatchOk.delivered, isTrue);
        expect(dispatchOk.pushAccepted, isTrue);
        expect(dispatchOk.receiptConfirmed, isFalse);
        expect(dispatchOk.deliveryStage, equals('push_service_accepted'));
        expect(dispatchOk.message, contains('Push service accepted'));
        expect(dispatchOk.message, contains('awaiting phone receipt'));

        final sentIncidentId = controller.incidents.first.id;
        expect(
          controller.incidents.first.remoteNotificationStatus,
          contains('awaiting phone receipt'),
        );

        // Phone Service Worker confirms receipt -> status upgrades to "Phone receipt confirmed"!
        final ackRes = await _requestJson(
          client: client,
          method: 'POST',
          uri: Uri.parse(
            '$relayBase/v1/companion/events/${Uri.encodeComponent(sentIncidentId)}/ack',
          ),
          bearerToken: companionToken,
          body: const <String, Object?>{'source': 'push_sw'},
          expectedStatuses: const <int>[200],
        );
        expect(ackRes['receiptConfirmed'], isTrue);
        expect(ackRes['receiptSource'], equals('push_sw'));

        await remoteNotifications.syncPairedDevicesFromRelay();
        await controller.refreshNotificationStatus();
        expect(
          controller.incidents.first.remoteNotificationStatus,
          contains('Phone receipt confirmed on "My iPhone"'),
        );

        // Case C: Provider rejects push with 400 BadWebPushToken -> NEVER claims delivered, marks renewal needed while preserving pairing!
        gatewayStatus = HttpStatus.badRequest;
        gatewayErrorJson = const <String, Object?>{'reason': 'BadWebPushToken'};
        final rejectedDispatch = await controller.sendTestAlertToPairedPhone();
        expect(rejectedDispatch.delivered, isFalse);
        expect(rejectedDispatch.relayRecorded, isTrue);
        expect(rejectedDispatch.pushAccepted, isFalse);
        expect(rejectedDispatch.deliveryStage, equals('push_rejected'));
        expect(rejectedDispatch.message, contains('Push delivery rejected'));
        expect(rejectedDispatch.message, contains('BadWebPushToken'));

        // Companion pairing remains connected, surfaces pushSubscriptionNeedsRenewal = true, and recovers in-place!
        final statusAfterExpire = await _requestJson(
          client: client,
          method: 'GET',
          uri: Uri.parse('$relayBase/v1/companion/status'),
          bearerToken: companionToken,
          expectedStatuses: const <int>[200],
        );
        expect(statusAfterExpire['connected'], isTrue);
        expect(statusAfterExpire['notificationsEnabled'], isFalse);
        expect(statusAfterExpire['pushSubscriptionNeedsRenewal'], isTrue);
        expect(
          statusAfterExpire['lastPushErrorCode'],
          equals('BadWebPushToken'),
        );

        gatewayStatus = HttpStatus.created;
        gatewayErrorJson = null;
        final renewedSubRes = await _requestJson(
          client: client,
          method: 'POST',
          uri: Uri.parse('$relayBase/v1/companion/push-subscription'),
          bearerToken: companionToken,
          body: <String, Object?>{
            'endpoint':
                'http://127.0.0.1:${pushGateway.port}/wpush/v2/sub_renewed_2',
            'p256dh': subKeys.publicKeyBase64Url,
            'auth': base64UrlNoPadEncode(authSecret),
            'subscribedVapidPublicKey': vapidKeys.publicKeyBase64Url,
            'platform': 'iOS Home Screen Web App',
            'httpsReady': true,
            'homeScreenInstalled': true,
            'notificationPermission': 'granted',
          },
          expectedStatuses: const <int>[200],
        );
        expect(renewedSubRes['bondId'], equals(bondId));
        expect(renewedSubRes['notificationsEnabled'], isTrue);
        expect(renewedSubRes['pushSubscriptionNeedsRenewal'], isFalse);
      } finally {
        client.close(force: true);
        controller?.dispose();
        remoteNotifications?.dispose();
        await relay?.stop();
        await pushGateway?.close(force: true);
      }
    });

    test('3. Immediate local siren starts and keeps ringing even if relay or push provider is unreachable', () async {
      HttpOverrides.global = null;
      final tempRelay = WatSafeRelayServer(store: InMemoryRelayStore());
      final tempPort = await tempRelay.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );

      final pinService = PinSecurityService(
        storage: InMemorySecurePinStorage(),
        pbkdf2Iterations: 500,
      );
      final pinSetup = await pinService.setupInitialPin(
        pin: '135791',
        confirmPin: '135791',
      );
      expect(pinSetup.isValid, isTrue);

      final remoteNotifications = ConfigurableRemoteNotificationService(
        persistToDisk: false,
        initialRelayEndpointUrl: 'http://127.0.0.1:$tempPort',
        httpTimeout: const Duration(milliseconds: 250),
        enableBackgroundPolling: false,
      );
      final fakeDetector = FakeMotionDetector(
        type: DetectorType.windowsCameraSceneMotion,
      );
      final fakeAudio = FakeAudioAlarmAdapter();
      final controller = AlarmController(
        detectors: <DetectorType, MotionDetectorAdapter>{
          DetectorType.windowsCameraSceneMotion: fakeDetector,
        },
        audioAdapter: fakeAudio,
        pinService: pinService,
        incidentStorage: InMemoryIncidentStorage(),
        settingsStorage: InMemorySettingsStorage(
          const ProtectionSettings(
            selectedDetector: DetectorType.windowsCameraSceneMotion,
            armingCountdownSeconds: 1,
            onboardingCompleted: true,
          ),
        ),
        notificationAdapter: remoteNotifications,
      );
      try {
        await controller.initialize();
        await controller.pairCompanionDevice(
          displayName: 'My iPhone',
          platform: 'iOS Home Screen Web App',
          pairingCode: 'WAT-777',
        );
        expect(controller.pairedDevices, hasLength(1));

        // Shut down the relay completely so remote notification dispatch fails on alarm!
        await tempRelay.stop();

        await controller.startArming();
        final sessionId = controller.activeSessionId!;
        await controller.handleCountdownTickForSession(sessionId);
        expect(controller.state, ProtectionState.armed);

        fakeDetector.emit(
          DetectorEvent(
            eventId: 'evt_offline_push_1',
            sessionId: sessionId,
            detectorType: DetectorType.windowsCameraSceneMotion,
            eventType: DetectorEventType.motionTriggered,
            timestamp: DateTime.utc(2026, 11, 17, 2, 0, 0),
            summary: 'Sustained camera scene motion detected',
            motionScore: 0.41,
            threshold: 0.095,
            consecutiveAboveThresholdFrames: 3,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(controller.state, ProtectionState.alarming);
        expect(fakeAudio.isPlaying, isTrue);

        // Wait past relay failure timeout; siren must remain active uninterrupted.
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(controller.state, ProtectionState.alarming);
        expect(fakeAudio.isPlaying, isTrue);
        expect(
          controller.activeIncident?.remoteNotificationStatus,
          contains('Could not reach'),
        );
      } finally {
        controller.dispose();
        remoteNotifications.dispose();
        await tempRelay.stop();
      }
    });
  });
}
