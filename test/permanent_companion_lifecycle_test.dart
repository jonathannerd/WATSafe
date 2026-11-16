import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watsafe/core/alarm/alarm_controller.dart';
import 'package:watsafe/core/alarm/alarm_state.dart';
import 'package:watsafe/core/contracts/platform_contracts.dart';
import 'package:watsafe/core/models/detector_models.dart';
import 'package:watsafe/core/models/incident_models.dart';
import 'package:watsafe/core/models/settings_models.dart';
import 'package:watsafe/features/settings/settings_screen.dart';
import 'package:watsafe/main.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/relay_config.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

import '../backend/server.dart';
import '../tool/verify_deployment.dart';
import 'alarm_controller_test.dart';

class _CapturedPush {
  const _CapturedPush({
    required this.path,
    required this.headers,
    required this.body,
  });

  final String path;
  final Map<String, String> headers;
  final Uint8List body;
}

class _FixedTestLocationService implements LocationServiceAdapter {
  const _FixedTestLocationService(this.snapshot);

  final DeviceLocationSnapshot snapshot;

  @override
  bool get isSupported => true;

  @override
  Future<PermissionStatus> checkPermission() async => PermissionStatus.granted;

  @override
  Future<PermissionStatus> requestPermission() async =>
      PermissionStatus.granted;

  @override
  Future<({DeviceLocationSnapshot? location, IncidentLocationStatus status})>
  captureCurrentLocation({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    return (location: snapshot, status: IncidentLocationStatus.attached);
  }
}

Future<Map<String, dynamic>> _rawJsonRequest({
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
  final flatHeaders = <String, String>{};
  resp.headers.forEach((name, values) {
    flatHeaders[name.toLowerCase()] = values.join(', ');
  });
  expect(
    expectedStatuses,
    contains(resp.statusCode),
    reason: 'Unexpected HTTP ${resp.statusCode} from $method $uri: $text',
  );
  final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
  return <String, dynamic>{
    '_status': resp.statusCode,
    '_headers': flatHeaders,
    if (decoded is Map<String, dynamic>) ...decoded,
  };
}

void main() {
  group('Permanent Companion Address, Durable Pairing & Offline Lifecycle Suite', () {
    test('1. Stable manifest/start_url/scope, offline Service Worker shell caching, and anti-530 white-page guard', () async {
      HttpOverrides.global = null;
      final tempDir = await Directory.systemTemp.createTemp(
        'watsafe_pwa_shell_test_',
      );
      final client = HttpClient();
      WatSafeRelayServer? relay;

      try {
        relay = WatSafeRelayServer(
          store: FileRelayStore(directory: Directory('${tempDir.path}/relay')),
          environment: const <String, String>{
            'RENDER_EXTERNAL_URL': 'https://watsafe-test-relay.onrender.com',
          },
        );
        final port = await relay.start(
          address: InternetAddress.loopbackIPv4,
          port: 0,
        );
        final base = 'http://127.0.0.1:$port';

        // Verify /v1/health reports permanentHttpsOrigin, X-WATSafe-Companion: 1,
        // and honestly marks container durable_file without AIVEN_DATABASE_URL as storageDurable: false!
        final health = await _rawJsonRequest(
          client: client,
          method: 'GET',
          uri: Uri.parse('$base/v1/health'),
          expectedStatuses: const <int>[200],
        );
        final healthHeaders = health['_headers'] as Map<String, String>;
        expect(healthHeaders['x-watsafe-companion'], '1');
        expect(healthHeaders['x-watsafe-sw-version'], isNotEmpty);
        expect(health['storageBackend'], 'durable_file');
        expect(health['storageDurable'], isFalse);
        expect(
          health['storageDurabilityWarning'] as String?,
          contains('AIVEN_DATABASE_URL'),
        );
        expect(
          health['permanentHttpsOrigin'],
          'https://watsafe-test-relay.onrender.com',
        );

        // Verify Web App Manifest keeps stable id, start_url, scope, and standalone mode
        final manifestReq = await client.getUrl(
          Uri.parse('$base/manifest.webmanifest'),
        );
        final manifestResp = await manifestReq.close();
        expect(manifestResp.statusCode, HttpStatus.ok);
        expect(manifestResp.headers.value('x-watsafe-companion'), equals('1'));
        final manifest = jsonDecode(
          await utf8.decoder.bind(manifestResp).join(),
        ) as Map<String, dynamic>;
        expect(manifest['id'], '/companion');
        expect(manifest['start_url'], '/companion?source=homescreen');
        expect(manifest['scope'], '/');
        expect(manifest['display'], 'standalone');

        // Verify Service Worker pre-caches shell, preserves IndexedDB/localStorage across cache rotations,
        // handles pushsubscriptionchange, and blocks non-WATSafe proxy pages (e.g. Cloudflare 530 "Was this helpful?")
        final swReq = await client.getUrl(Uri.parse('$base/sw.js'));
        final swResp = await swReq.close();
        expect(swResp.statusCode, HttpStatus.ok);
        expect(swResp.headers.value('service-worker-allowed'), '/');
        final swSource = await utf8.decoder.bind(swResp).join();
        expect(swSource, contains("SHELL_CACHE = 'watsafe-shell-"));
        expect(swSource, contains("'/companion'"));
        expect(swSource, contains("'/manifest.webmanifest'"));
        expect(
          swSource,
          contains("res.headers.get('x-watsafe-companion') === '1'"),
        );
        expect(swSource, contains("addEventListener('pushsubscriptionchange'"));
        expect(swSource, contains("IDB_NAME = 'watsafe_companion_v2'"));
        expect(swSource, contains("indexedDB.open(IDB_NAME"));

        // Verify /companion HTML includes mirrored IndexedDB + localStorage, Laptop offline, Retry button,
        // token refresh, and temporary-tunnel migration notice
        final compReq = await client.getUrl(
          Uri.parse('$base/companion?source=homescreen'),
        );
        final compResp = await compReq.close();
        expect(compResp.statusCode, HttpStatus.ok);
        expect(compResp.headers.value('x-watsafe-companion'), '1');
        final compHtml = await utf8.decoder.bind(compResp).join();
        expect(compHtml, contains('Laptop offline'));
        expect(compHtml, contains('Service temporarily unavailable'));
        expect(compHtml, contains('Connecting…'));
        expect(compHtml, contains('id="retryConnectionBtn"'));
        expect(compHtml, contains('id="migrationBanner"'));
        expect(compHtml, contains('/v1/companion/token/refresh'));
      } finally {
        client.close(force: true);
        await relay?.stop();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    test('2. Complete one-time pairing lifecycle: laptop restart, phone restart, relay restart, token rotation, push renewal, network/530 proxy outage, Wi-Fi/cellular recovery, and deduplicated real alarm notification with location', () async {
      HttpOverrides.global = null;
      final tempDir = await Directory.systemTemp.createTemp(
        'watsafe_full_lifecycle_test_',
      );
      final relayDataDir = Directory('${tempDir.path}/relay_data');
      final vapidKeyFile = File('${tempDir.path}/relay_data/vapid_keys.json');
      final laptopStorageDir = '${tempDir.path}/laptop_app_data';
      final phoneStorageDir = '${tempDir.path}/phone_app_data';

      final client = HttpClient();
      final capturedPushes = <_CapturedPush>[];
      HttpServer? pushServer;
      HttpServer? fakeCloudflare530Proxy;
      WatSafeRelayServer? relayServer;

      var simulatedNow = DateTime.utc(2026, 11, 16, 15, 0, 0);

      try {
        // A. Start mock Apple Web Push endpoint server (web.push.apple.com)
        pushServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final pushPort = pushServer.port;
        pushServer.listen((HttpRequest request) async {
          final bytes = <int>[];
          await for (final chunk in request) {
            bytes.addAll(chunk);
          }
          final headers = <String, String>{};
          request.headers.forEach((k, v) {
            headers[k.toLowerCase()] = v.join(', ');
          });
          capturedPushes.add(
            _CapturedPush(
              path: request.uri.path,
              headers: headers,
              body: Uint8List.fromList(bytes),
            ),
          );
          request.response.statusCode = HttpStatus.created;
          await request.response.close();
        });

        // B. Start durable WATSafe relay #1 (FileRelayStore + durable VAPID keys)
        Future<WatSafeRelayServer> buildDurableRelay() async {
          final store = FileRelayStore(
            directory: relayDataDir,
            clock: () => simulatedNow,
          );
          final pushProvider = EnvironmentPushProviderAdapter(
            environment: const <String, String>{},
            persistVapidKeysToDisk: true,
            vapidKeyFile: vapidKeyFile,
          );
          await pushProvider.syncDurableVapidKeys(store);
          return WatSafeRelayServer(
            store: store,
            pushProvider: pushProvider,
            clock: () => simulatedNow,
          );
        }

        relayServer = await buildDurableRelay();
        final relayPort = await relayServer.start(
          address: InternetAddress.loopbackIPv4,
          port: 0,
        );
        final relayOrigin = 'http://127.0.0.1:$relayPort';

        final initialHealth = await _rawJsonRequest(
          client: client,
          method: 'GET',
          uri: Uri.parse('$relayOrigin/v1/health'),
          expectedStatuses: const <int>[200],
        );
        final originalVapidPublicKey =
            initialHealth['vapidPublicKey'] as String;
        expect(originalVapidPublicKey, isNotEmpty);

        // C. PAIR ONCE: Laptop initiates QR pairing, iPhone 13 pairs, claims Home Screen handoff, and registers Web Push
        final laptopRemote1 = ConfigurableRemoteNotificationService(
          persistToDisk: true,
          storageDirectory: laptopStorageDir,
          initialRelayEndpointUrl: relayOrigin,
          enableBackgroundPolling: false,
          clock: () => simulatedNow,
        );
        final initialHostInstallId = laptopRemote1.hostInstallationId;
        final invite = await laptopRemote1.initiateHostPairing(
          hostDisplayName: 'Jonathan’s MacBook Pro',
        );

        final phoneRemote1 = ConfigurableRemoteNotificationService(
          persistToDisk: true,
          storageDirectory: phoneStorageDir,
          enableBackgroundPolling: false,
          clock: () => simulatedNow,
        );
        final pairedState = await phoneRemote1.pairAsCompanionPhone(
          pairingCodeOrPayload: invite.effectiveScanUrl,
          displayName: 'Jonathan’s iPhone 13',
          platform: 'iPhone (Home Screen)',
        );
        expect(pairedState.isConnected, isTrue);

        // Verify raw bearer tokens are NEVER stored in plain watsafe_paired_devices.json,
        // and ARE stored in watsafe_secure_pairing_credentials.json!
        final secureLaptopSecrets = jsonDecode(
          await File(
            '$laptopStorageDir/watsafe_secure_pairing_credentials.json',
          ).readAsString(),
        ) as Map<String, dynamic>;
        final savedHostToken = secureLaptopSecrets['hostToken'] as String;
        expect(savedHostToken, startsWith('host_'));

        final plainLaptopJson = await File(
          '$laptopStorageDir/watsafe_paired_devices.json',
        ).readAsString();
        expect(plainLaptopJson, isNot(contains('"hostToken"')));
        expect(plainLaptopJson, isNot(contains(savedHostToken)));

        final securePhoneSecrets = jsonDecode(
          await File('$phoneStorageDir/watsafe_secure_pairing_credentials.json')
              .readAsString(),
        ) as Map<String, dynamic>;
        var activeCompanionToken =
            securePhoneSecrets['companionToken'] as String;
        expect(activeCompanionToken, startsWith('comp_'));

        final plainPhoneJson = await File(
          '$phoneStorageDir/watsafe_paired_devices.json',
        ).readAsString();
        expect(plainPhoneJson, isNot(contains('"companionToken"')));
        expect(plainPhoneJson, isNot(contains(activeCompanionToken)));

        // Register real RFC 8291 Web Push subscription #1 on iPhone 13
        final rng = Random.secure();
        var subscriberKeyPair = VapidKeyPair.generate(rng);
        var subAuthSecret = Uint8List.fromList(
          List<int>.generate(16, (_) => rng.nextInt(256)),
        );
        final pushEndpoint1 =
            'http://127.0.0.1:$pushPort/wpush/v2/iphone13_initial_sub';

        final pushReg1 = await _rawJsonRequest(
          client: client,
          method: 'POST',
          uri: Uri.parse('$relayOrigin/v1/companion/push-subscription'),
          bearerToken: activeCompanionToken,
          body: <String, Object?>{
            'endpoint': pushEndpoint1,
            'p256dh': subscriberKeyPair.publicKeyBase64Url,
            'auth': base64UrlNoPadEncode(subAuthSecret),
            'platform': 'iPhone (Home Screen)',
            'httpsReady': true,
            'homeScreenInstalled': true,
            'notificationPermission': 'granted',
          },
          expectedStatuses: const <int>[200],
        );
        expect(pushReg1['notificationsEnabled'], isTrue);
        expect(pushReg1['hostOnline'], isTrue);

        final syncedLaptopDevices1 = await laptopRemote1
            .syncPairedDevicesFromRelay();
        expect(syncedLaptopDevices1, hasLength(1));
        expect(syncedLaptopDevices1.first.notificationsEnabled, isTrue);

        // D. CLOSE AND REOPEN THE LAPTOP APP:
        // Laptop notifies offline & closes -> phone sees hostOnline: false (with lastSeenAtUtc) while keeping pairing!
        expect(await laptopRemote1.notifyHostOffline(), isTrue);
        laptopRemote1.dispose();

        await phoneRemote1.pollCompanionAlertsOnce();
        expect(phoneRemote1.companionSession.isConnected, isTrue);
        expect(
          phoneRemote1.companionSession.statusMessage,
          contains('Laptop offline'),
        );

        final alertsWhileLaptopClosed = await _rawJsonRequest(
          client: client,
          method: 'GET',
          uri: Uri.parse('$relayOrigin/v1/companion/alerts?afterSeq=0'),
          bearerToken: activeCompanionToken,
          expectedStatuses: const <int>[200],
        );
        expect(alertsWhileLaptopClosed['hostOnline'], isFalse);
        expect(alertsWhileLaptopClosed['hostLastSeenAtUtc'], isNotNull);
        expect(alertsWhileLaptopClosed['hostDisconnectedAtUtc'], isNotNull);

        // Reopen laptop app -> restores same hostInstallationId + hostToken and marks hostOnline: true automatically!
        simulatedNow = simulatedNow.add(const Duration(minutes: 3));
        final laptopRemote2 = ConfigurableRemoteNotificationService(
          persistToDisk: true,
          storageDirectory: laptopStorageDir,
          enableBackgroundPolling: false,
          clock: () => simulatedNow,
        );
        final syncedAfterLaptopReopen = await laptopRemote2
            .syncPairedDevicesFromRelay();
        expect(laptopRemote2.hostInstallationId, equals(initialHostInstallId));
        expect(syncedAfterLaptopReopen, hasLength(1));

        await phoneRemote1.pollCompanionAlertsOnce();
        expect(phoneRemote1.companionSession.isConnected, isTrue);
        expect(
          phoneRemote1.companionSession.statusMessage,
          contains('Connected to Jonathan’s MacBook Pro'),
        );

        // E. CLOSE AND REOPEN PHONE COMPANION + CREDENTIAL REFRESH & PUSH SUBSCRIPTION RENEWAL:
        phoneRemote1.dispose();
        final phoneRemote2 = ConfigurableRemoteNotificationService(
          persistToDisk: true,
          storageDirectory: phoneStorageDir,
          enableBackgroundPolling: false,
          clock: () => simulatedNow,
        );
        await phoneRemote2.pollCompanionAlertsOnce();
        expect(phoneRemote2.companionSession.isConnected, isTrue);

        final previousCompanionToken = activeCompanionToken;
        expect(await phoneRemote2.refreshCompanionCredential(), isTrue);

        final rotatedPhoneSecrets = jsonDecode(
          await File('$phoneStorageDir/watsafe_secure_pairing_credentials.json')
              .readAsString(),
        ) as Map<String, dynamic>;
        activeCompanionToken = rotatedPhoneSecrets['companionToken'] as String;
        expect(activeCompanionToken, isNot(equals(previousCompanionToken)));

        // Within the 60s grace window, an in-flight request using previousCompanionToken still succeeds!
        await _rawJsonRequest(
          client: client,
          method: 'GET',
          uri: Uri.parse('$relayOrigin/v1/companion/alerts?afterSeq=0'),
          bearerToken: previousCompanionToken,
          expectedStatuses: const <int>[200],
        );

        // Advance past the 60s grace window -> previous token expires cleanly while rotated token stays active!
        simulatedNow = simulatedNow.add(const Duration(seconds: 65));
        await _rawJsonRequest(
          client: client,
          method: 'GET',
          uri: Uri.parse('$relayOrigin/v1/companion/alerts?afterSeq=0'),
          bearerToken: previousCompanionToken,
          expectedStatuses: const <int>[401],
        );
        await _rawJsonRequest(
          client: client,
          method: 'GET',
          uri: Uri.parse('$relayOrigin/v1/companion/alerts?afterSeq=0'),
          bearerToken: activeCompanionToken,
          expectedStatuses: const <int>[200],
        );

        // Simulate silent pushsubscriptionchange renewal on iPhone (new endpoint + new ECDH keys, zero re-pairing)
        subscriberKeyPair = VapidKeyPair.generate(rng);
        subAuthSecret = Uint8List.fromList(
          List<int>.generate(16, (_) => rng.nextInt(256)),
        );
        final pushEndpointRenewed =
            'http://127.0.0.1:$pushPort/wpush/v2/iphone13_renewed_sub';
        final pushRegRenewed = await _rawJsonRequest(
          client: client,
          method: 'POST',
          uri: Uri.parse('$relayOrigin/v1/companion/push-subscription'),
          bearerToken: activeCompanionToken,
          body: <String, Object?>{
            'endpoint': pushEndpointRenewed,
            'p256dh': subscriberKeyPair.publicKeyBase64Url,
            'auth': base64UrlNoPadEncode(subAuthSecret),
            'platform': 'iPhone (Home Screen)',
            'httpsReady': true,
            'homeScreenInstalled': true,
            'notificationPermission': 'granted',
          },
          expectedStatuses: const <int>[200],
        );
        expect(pushRegRenewed['notificationsEnabled'], isTrue);

        // F. RESTART RELAY / BACKEND SERVICE & BOTH DEVICES (simulating server deploy + device reboot):
        laptopRemote2.dispose();
        phoneRemote2.dispose();
        await relayServer.stop();
        relayServer = null;

        // Restart brand-new WatSafeRelayServer on the SAME port backed by FileRelayStore + durable VAPID keys
        relayServer = await buildDurableRelay();
        await relayServer.start(
          address: InternetAddress.loopbackIPv4,
          port: relayPort,
        );
        final restartedHealth = await _rawJsonRequest(
          client: client,
          method: 'GET',
          uri: Uri.parse('$relayOrigin/v1/health'),
          expectedStatuses: const <int>[200],
        );
        expect(
          restartedHealth['vapidPublicKey'],
          equals(originalVapidPublicKey),
          reason: 'VAPID public key must survive relay restarts and deploys',
        );

        // G. CLOUDFLARE 530 ("Was this helpful?") PROXY ERROR, NON-WATSAFE 401, & NETWORK OUTAGE DEFENSE:
        var proxyMode = 'cloudflare_530';
        fakeCloudflare530Proxy = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final proxyOrigin = 'http://127.0.0.1:${fakeCloudflare530Proxy.port}';
        fakeCloudflare530Proxy.listen((HttpRequest req) async {
          if (proxyMode == 'cloudflare_530') {
            req.response.statusCode = 530;
            req.response.headers.contentType = ContentType.html;
            req.response.write(
              '<!DOCTYPE html><html><body><h1>Error 1033</h1>'
              '<p>Cloudflare Tunnel error</p><p>Was this helpful?</p></body></html>',
            );
          } else {
            // Non-WATSafe proxy 401 (no X-WATSafe-Companion: 1 header!)
            req.response.statusCode = HttpStatus.unauthorized;
            req.response.headers.contentType = ContentType.html;
            req.response.write('<html><body>Proxy gateway login</body></html>');
          }
          await req.response.close();
        });

        final phoneDuringProxyFault = ConfigurableRemoteNotificationService(
          persistToDisk: true,
          storageDirectory: phoneStorageDir,
          initialRelayEndpointUrl: proxyOrigin,
          enableBackgroundPolling: false,
          clock: () => simulatedNow,
        );
        await phoneDuringProxyFault.configureRelayEndpoint(proxyOrigin);
        await phoneDuringProxyFault.pollCompanionAlertsOnce();
        expect(
          phoneDuringProxyFault.companionSession.isConnected,
          isTrue,
          reason: 'Cloudflare 530 HTML must never wipe companion pairing',
        );
        expect(
          phoneDuringProxyFault.companionSession.statusMessage,
          contains('Service temporarily unavailable'),
        );

        proxyMode = 'rogue_proxy_401';
        await phoneDuringProxyFault.pollCompanionAlertsOnce();
        expect(
          phoneDuringProxyFault.companionSession.isConnected,
          isTrue,
          reason: 'Non-WATSafe proxy 401 without X-WATSafe-Companion header must never unpair phone',
        );

        final laptopDuringProxyFault = ConfigurableRemoteNotificationService(
          persistToDisk: true,
          storageDirectory: laptopStorageDir,
          enableBackgroundPolling: false,
          clock: () => simulatedNow,
        );
        await laptopDuringProxyFault.configureRelayEndpoint(proxyOrigin);
        expect(
          await laptopDuringProxyFault.syncPairedDevicesFromRelay(),
          hasLength(1),
          reason: 'Non-WATSafe proxy 401/530 must preserve cached paired devices on laptop',
        );

        // Switch back to healthy permanent relay (simulating Wi-Fi <-> cellular recovery / network restore)
        await laptopDuringProxyFault.configureRelayEndpoint(relayOrigin);
        await phoneDuringProxyFault.configureRelayEndpoint(relayOrigin);
        expect(
          await laptopDuringProxyFault.syncPairedDevicesFromRelay(),
          hasLength(1),
        );
        await phoneDuringProxyFault.pollCompanionAlertsOnce();
        expect(phoneDuringProxyFault.companionSession.isConnected, isTrue);
        expect(
          phoneDuringProxyFault.companionSession.statusMessage,
          contains('Connected to Jonathan’s MacBook Pro'),
        );

        // H. POST-RECONNECTION REAL ALARM TRIGGER:
        // Verify ONE encrypted Web Push arrives on renewed subscription, opens exact incident, and attaches location!
        final detector = FakeMotionDetector();
        final pinStorage = InMemorySecurePinStorage();
        final pinService = PinSecurityService(
          storage: pinStorage,
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '246810', confirmPin: '246810');

        final expectedLocation = DeviceLocationSnapshot(
          latitude: 43.4723,
          longitude: -80.5449,
          accuracyMeters: 8.4,
          capturedAt: simulatedNow,
        );

        final reopenedController = AlarmController(
          detectors: <DetectorType, MotionDetectorAdapter>{
            DetectorType.macosCameraSceneMotion: detector,
          },
          audioAdapter: FakeAudioAlarmAdapter(),
          pinService: pinService,
          incidentStorage: InMemoryIncidentStorage(),
          settingsStorage: InMemorySettingsStorage(
            const ProtectionSettings(
              selectedDetector: DetectorType.macosCameraSceneMotion,
              armingCountdownSeconds: 1,
              onboardingCompleted: true,
              shareLocationOnAlarm: true,
              deviceDisplayName: 'Jonathan’s MacBook Pro',
            ),
          ),
          notificationAdapter: laptopDuringProxyFault,
          locationAdapter: _FixedTestLocationService(expectedLocation),
          clock: () => simulatedNow,
        );
        await reopenedController.initialize();
        expect(reopenedController.pairedDevices, hasLength(1));

        expect(await reopenedController.startArming(), isTrue);
        final sessionId = reopenedController.activeSessionId!;
        await reopenedController.handleCountdownTickForSession(sessionId);
        expect(reopenedController.state, ProtectionState.armed);

        detector.emit(
          DetectorEvent(
            eventId: 'evt_post_reconnect_1',
            sessionId: sessionId,
            detectorType: DetectorType.macosCameraSceneMotion,
            eventType: DetectorEventType.motionTriggered,
            timestamp: simulatedNow,
            summary: 'Laptop lifted from desk',
            motionScore: 0.91,
          ),
        );
        // Allow async push + async location attachment to complete
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(reopenedController.state, ProtectionState.alarming);
        final triggeredIncident = reopenedController.activeIncident!;

        // Exactly ONE Web Push notification delivered to the renewed push endpoint!
        expect(capturedPushes, hasLength(1));
        expect(capturedPushes.single.path, '/wpush/v2/iphone13_renewed_sub');

        final decryptedBytes = await WebPushCrypto.decryptAes128Gcm(
          encryptedBody: capturedPushes.single.body,
          clientKeyPair: subscriberKeyPair,
          clientAuthSecret: subAuthSecret,
        );
        final decryptedJson =
            jsonDecode(utf8.decode(decryptedBytes)) as Map<String, dynamic>;
        final pushData = decryptedJson['data'] as Map<String, dynamic>;
        expect(pushData['incidentId'], equals(triggeredIncident.id));
        expect(
          pushData['url'],
          equals(
            '/companion?event=${Uri.encodeComponent(triggeredIncident.id)}',
          ),
        );
        // Lock-screen push never leaks precise coordinates
        expect(utf8.decode(decryptedBytes), isNot(contains('43.4723')));

        // Tapping the notification fetches GET /v1/companion/events/<incidentId> and returns exact incident + coordinates!
        final exactEvent = await _rawJsonRequest(
          client: client,
          method: 'GET',
          uri: Uri.parse(
            '$relayOrigin/v1/companion/events/${Uri.encodeComponent(triggeredIncident.id)}',
          ),
          bearerToken: activeCompanionToken,
          expectedStatuses: const <int>[200],
        );
        expect(exactEvent['incidentId'], equals(triggeredIncident.id));
        final locMap = exactEvent['location'] as Map<String, dynamic>;
        expect(locMap['latitude'], closeTo(43.4723, 0.0001));
        expect(locMap['longitude'], closeTo(-80.5449, 0.0001));

        // Companion poll + replay from zero emits the incident ONCE with zero duplicates!
        final firstDelivery = await phoneDuringProxyFault
            .pollCompanionAlertsOnce();
        expect(firstDelivery, hasLength(1));
        expect(firstDelivery.single.incidentId, equals(triggeredIncident.id));

        final replayDelivery = await phoneDuringProxyFault
            .pollCompanionAlertsOnce(replayFromZero: true);
        expect(replayDelivery, isEmpty);
        expect(phoneDuringProxyFault.receivedCompanionAlerts, hasLength(1));

        // Disarm cleanly & test explicit user disconnect (authentic WATSafe 401)
        final disarm = await reopenedController.verifyAndDisarm('246810');
        expect(disarm.verified, isTrue);
        expect(reopenedController.state, ProtectionState.disarmed);

        await phoneDuringProxyFault.disconnectCompanionSession();
        expect(phoneDuringProxyFault.companionSession.isConnected, isFalse);
        await _rawJsonRequest(
          client: client,
          method: 'GET',
          uri: Uri.parse('$relayOrigin/v1/companion/alerts?afterSeq=0'),
          bearerToken: activeCompanionToken,
          expectedStatuses: const <int>[401],
        );

        reopenedController.dispose();
        phoneDuringProxyFault.dispose();
        await detector.dispose();
      } finally {
        client.close(force: true);
        await relayServer?.stop();
        await fakeCloudflare530Proxy?.close(force: true);
        await pushServer?.close(force: true);
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });

    testWidgets(
      '3. Settings & Pairing UI surface temporary-tunnel dependency clearly, reject ephemeral tunnels as permanent URLs, and guide one-time iPhone Home Screen migration',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        final priorSavedPerm = RelayConfig.persistedPermanentRelayUrl;

        final detector = FakeMotionDetector();
        final pinService = PinSecurityService(
          storage: InMemorySecurePinStorage(),
          pbkdf2Iterations: 500,
        );
        await pinService.setupInitialPin(pin: '112233', confirmPin: '112233');

        final remote = ConfigurableRemoteNotificationService(
          persistToDisk: false,
          initialRelayEndpointUrl:
              'https://random-words-1234.trycloudflare.com',
          enableBackgroundPolling: false,
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
              selectedDetector: DetectorType.macosCameraSceneMotion,
              onboardingCompleted: true,
              deviceDisplayName: 'Jonathan’s MacBook',
            ),
          ),
          notificationAdapter: remote,
        );
        await controller.initialize();

        try {
          expect(controller.isEphemeralTunnelRelay, isTrue);
          expect(controller.isPermanentRelayConfigured, isFalse);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: SettingsScreen(controller: controller)),
            ),
          );
          await tester.pumpAndSettle();

          // Settings card flags Temporary / Local status clearly
          expect(
            find.byKey(const Key('permanent_companion_settings_card')),
            findsOneWidget,
          );
          expect(find.text('Temporary / Local'), findsOneWidget);

          // Entering a temporary *.trycloudflare.com URL as permanent is rejected with guidance
          await tester.ensureVisible(
            find.byKey(const Key('permanent_relay_url_input')),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('permanent_relay_url_input')),
            'https://another-temp.trycloudflare.com',
          );
          await tester.ensureVisible(
            find.byKey(const Key('save_permanent_relay_url_button')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('save_permanent_relay_url_button')),
          );
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Temporary tunnel addresses'),
            findsOneWidget,
          );
          expect(controller.isPermanentRelayConfigured, isFalse);

          // Expanding the one-time iPhone migration steps reveals explicit instructions
          await tester.ensureVisible(
            find.byKey(const Key('iphone_migration_steps_tile')),
          );
          await tester.tap(
            find.byKey(const Key('iphone_migration_steps_tile')),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('Delete Bookmark'), findsOneWidget);

          // Entering a documentation placeholder URL is rejected with clear guidance
          await tester.enterText(
            find.byKey(const Key('permanent_relay_url_input')),
            'https://<your-render-service>.onrender.com',
          );
          await tester.tap(
            find.byKey(const Key('save_permanent_relay_url_button')),
          );
          await tester.pumpAndSettle();
          expect(controller.isPermanentRelayConfigured, isFalse);

          // Entering a real permanent HTTPS origin updates status to Permanent HTTPS
          await tester.enterText(
            find.byKey(const Key('permanent_relay_url_input')),
            'https://watsafe-test-relay.onrender.com',
          );
          await tester.runAsync(() async {
            await controller.savePermanentRelayEndpoint(
              'https://watsafe-test-relay.onrender.com',
            );
          });
          await tester.pumpAndSettle();
          expect(controller.isPermanentRelayConfigured, isTrue);
          expect(find.text('Permanent HTTPS'), findsOneWidget);

          // Verify a brand-new AlarmController launched with the same settings storage
          // remembers the permanent HTTPS endpoint on normal startup automatically!
          final relaunchedDetector = FakeMotionDetector();
          final relaunchedRemote = ConfigurableRemoteNotificationService(
            persistToDisk: false,
            initialRelayEndpointUrl: RelayConfig.localDevelopmentRelayUrl,
            enableBackgroundPolling: false,
          );
          final relaunchedController = AlarmController(
            detectors: <DetectorType, MotionDetectorAdapter>{
              DetectorType.macosCameraSceneMotion: relaunchedDetector,
            },
            audioAdapter: FakeAudioAlarmAdapter(),
            pinService: PinSecurityService(
              storage: InMemorySecurePinStorage(),
              pbkdf2Iterations: 500,
            ),
            incidentStorage: InMemoryIncidentStorage(),
            settingsStorage: InMemorySettingsStorage(controller.settings),
            notificationAdapter: relaunchedRemote,
          );
          await tester.runAsync(() async {
            await relaunchedController.initialize();
          });
          expect(
            relaunchedController.relayEndpointUrl,
            'https://watsafe-test-relay.onrender.com',
          );
          expect(relaunchedController.isPermanentRelayConfigured, isTrue);
          relaunchedController.dispose();
          await relaunchedDetector.dispose();

          // Also verify WatSafeApp pairing sheet banner shows verified Permanent HTTPS status
          await tester.pumpWidget(WatSafeApp(controller: controller));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('pair_your_phone_row')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            find.byKey(const Key('companion_address_status_banner')),
            findsOneWidget,
          );
          expect(
            find.textContaining('Permanent HTTPS companion'),
            findsOneWidget,
          );
        } finally {
          await tester.runAsync(() async {
            await RelayConfig.savePermanentRelayUrl(priorSavedPerm);
          });
          controller.dispose();
          await detector.dispose();
        }
      },
    );

    test('4. DeploymentVerifier rejects placeholders & ephemeral cloud storage, and verifies VAPID + pairing + push persistence across restart', () async {
      HttpOverrides.global = null;
      final tempDir = await Directory.systemTemp.createTemp(
        'watsafe_deploy_verifier_test_',
      );
      final probeFile = File('${tempDir.path}/probe.json');
      WatSafeRelayServer? ephemeralCloudRelay;
      WatSafeRelayServer? durableRelay1;
      WatSafeRelayServer? durableRelay2;

      try {
        final verifier = DeploymentVerifier(
          allowLocalHttpForTest: true,
          probeStateFile: probeFile,
        );

        // 1. Rejects placeholder and temporary tunnel URLs
        final placeholderRes = await verifier.verifyEndpointHealthAndPwa(
          'https://<your-render-service>.onrender.com',
        );
        expect(placeholderRes.ok, isFalse);
        expect(placeholderRes.message, contains('placeholder'));

        final quickTunnelRes = await verifier.verifyEndpointHealthAndPwa(
          'https://random-words.trycloudflare.com',
        );
        expect(quickTunnelRes.ok, isFalse);
        expect(quickTunnelRes.message, contains('temporary quick tunnel'));

        // 2. Rejects Render container running WITHOUT AIVEN_DATABASE_URL (ephemeral disk)
        ephemeralCloudRelay = WatSafeRelayServer.fromEnvironment(
          environment: <String, String>{
            'RENDER': 'true',
            'WATSAFE_DATA_DIR': '${tempDir.path}/ephemeral_container',
          },
        );
        final ephemeralPort = await ephemeralCloudRelay.start(
          address: InternetAddress.loopbackIPv4,
          port: 0,
        );
        final ephemeralCheck = await verifier.verifyEndpointHealthAndPwa(
          'http://127.0.0.1:$ephemeralPort',
        );
        expect(ephemeralCheck.ok, isFalse);
        expect(ephemeralCheck.storageDurable, isFalse);
        expect(ephemeralCheck.message, contains('AIVEN_DATABASE_URL'));
        await ephemeralCloudRelay.stop();
        ephemeralCloudRelay = null;

        // 3. Verifies pre-restart probe + full relay restart + VAPID/pairing/push survival
        final durableEnv = <String, String>{
          'WATSAFE_DATA_DIR': '${tempDir.path}/durable_relay',
        };
        durableRelay1 = WatSafeRelayServer.fromEnvironment(
          environment: durableEnv,
        );
        final durablePort = await durableRelay1.start(
          address: InternetAddress.loopbackIPv4,
          port: 0,
        );
        final baseUrl = 'http://127.0.0.1:$durablePort';

        final preRes = await verifier.recordPreRestartProbe(baseUrl);
        expect(preRes.ok, isTrue, reason: preRes.message);
        expect(preRes.storageDurable, isTrue);
        expect(preRes.vapidPublicKey, isNotEmpty);
        expect(probeFile.existsSync(), isTrue);

        // Stop relay #1 completely and start brand-new WatSafeRelayServer.fromEnvironment on same port
        await durableRelay1.stop();
        durableRelay1 = null;

        durableRelay2 = WatSafeRelayServer.fromEnvironment(
          environment: durableEnv,
        );
        await durableRelay2.start(
          address: InternetAddress.loopbackIPv4,
          port: durablePort,
        );

        final postRes = await verifier.verifyAfterRestart(baseUrl);
        expect(postRes.ok, isTrue, reason: postRes.message);
        expect(postRes.vapidPublicKey, equals(preRes.vapidPublicKey));
        expect(probeFile.existsSync(), isFalse);
      } finally {
        await ephemeralCloudRelay?.stop();
        await durableRelay1?.stop();
        await durableRelay2?.stop();
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}
