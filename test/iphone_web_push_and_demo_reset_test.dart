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
import 'package:watsafe/main.dart';
import 'package:watsafe/services/audio_alarm_service.dart';
import 'package:watsafe/services/local_notification_service.dart';
import 'package:watsafe/services/local_relay_supervisor.dart';
import 'package:watsafe/services/local_storage_service.dart';
import 'package:watsafe/services/location_service.dart';
import 'package:watsafe/services/pin_security_service.dart';
import 'package:watsafe/services/remote_notification_service.dart';
import 'package:watsafe/services/secure_pin_storage_service.dart';

import '../backend/server.dart';
import 'alarm_controller_test.dart';

class _CapturedPushRequest {
  _CapturedPushRequest({required this.headers, required this.body});

  final Map<String, String> headers;
  final Uint8List body;
}

Future<Map<String, dynamic>> _jsonRequest({
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

void main() {
  group('iPhone 13 Guided Web Push, Simplified Startup & Demo Reset Suite', () {
    test(
      '1. Real RFC 8291 (aes128gcm) + RFC 8292 (VAPID ES256) Web Push round-trip, strict notification readiness, and 410 Gone auto-expiry',
      () async {
        HttpOverrides.global = null;
        final tempDir = await Directory.systemTemp.createTemp(
          'watsafe_webpush_test_',
        );
        final client = HttpClient();
        HttpServer? pushEndpointServer;
        WatSafeRelayServer? relayServer;

        try {
          // 1. Persist and reload VAPID keys to verify key durability across restarts
          final keyFile = File('${tempDir.path}/vapid_keys.json');
          final vapidKeys = VapidKeyPair.loadOrCreate(
            environment: const <String, String>{},
            keyFile: keyFile,
            persistToDisk: true,
          );
          final reloadedKeys = VapidKeyPair.loadOrCreate(
            environment: const <String, String>{},
            keyFile: keyFile,
            persistToDisk: true,
          );
          expect(
            reloadedKeys.publicKeyBase64Url,
            equals(vapidKeys.publicKeyBase64Url),
          );

          // 2. Start a local mock Web Push service (simulating Apple web.push.apple.com / FCM)
          final capturedPushes = <_CapturedPushRequest>[];
          var nextPushStatusCode = HttpStatus.created;
          pushEndpointServer = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final pushPort = pushEndpointServer.port;
          pushEndpointServer.listen((HttpRequest request) async {
            final chunks = <int>[];
            await for (final chunk in request) {
              chunks.addAll(chunk);
            }
            final flatHeaders = <String, String>{};
            request.headers.forEach((name, values) {
              flatHeaders[name.toLowerCase()] = values.join(', ');
            });
            capturedPushes.add(
              _CapturedPushRequest(
                headers: flatHeaders,
                body: Uint8List.fromList(chunks),
              ),
            );
            request.response.statusCode = nextPushStatusCode;
            await request.response.close();
          });

          // 3. Start WATSafe relay configured with real VAPID Web Push keys
          final pushProvider = EnvironmentPushProviderAdapter(
            environment: <String, String>{
              'VAPID_PUBLIC_KEY': vapidKeys.publicKeyBase64Url,
              'VAPID_PRIVATE_KEY': vapidKeys.privateKeyBase64Url,
              'VAPID_SUBJECT': 'mailto:alerts@watsafe.local',
            },
          );
          relayServer = WatSafeRelayServer(
            store: InMemoryRelayStore(),
            pushProvider: pushProvider,
          );
          final relayPort = await relayServer.start(
            address: InternetAddress.loopbackIPv4,
            port: 0,
          );
          final relayBase = 'http://127.0.0.1:$relayPort';

          // 4. Create laptop session & pair iPhone 13 web companion (initially without push subscription)
          final created = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$relayBase/v1/pairing/initiate'),
            body: <String, Object?>{'hostDisplayName': 'Jonathan’s MacBook'},
            expectedStatuses: const <int>[200],
          );
          final hostToken = created['hostToken'] as String;
          final pairingCode = created['pairingCode'] as String;

          final paired = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$relayBase/v1/pairing/complete'),
            body: <String, Object?>{
              'pairingCode': pairingCode,
              'displayName': 'Jonathan’s iPhone 13',
              'platform': 'iPhone (Safari)',
              'httpsReady': true,
              'homeScreenInstalled': true,
              'notificationPermission': 'granted',
              // Even if client claims notificationsEnabled: true before registering a real
              // Web Push subscription, the server must keep notificationsEnabled false!
              'notificationsEnabled': true,
            },
            expectedStatuses: const <int>[200],
          );
          final companionToken = paired['companionToken'] as String;
          expect(paired['notificationsEnabled'], isFalse);

          // Spoofing notificationsEnabled via /v1/companion/status without a push subscription
          // must also remain false on both phone and laptop!
          final statusBeforeSub = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$relayBase/v1/companion/status'),
            bearerToken: companionToken,
            body: <String, Object?>{
              'notificationsEnabled': true,
              'httpsReady': true,
              'homeScreenInstalled': true,
              'notificationPermission': 'granted',
            },
            expectedStatuses: const <int>[200],
          );
          expect(statusBeforeSub['notificationsEnabled'], isFalse);
          expect(statusBeforeSub['backendPushRegistered'], isFalse);

          final laptopDevicesBefore = await _jsonRequest(
            client: client,
            method: 'GET',
            uri: Uri.parse('$relayBase/v1/pairing/devices'),
            bearerToken: hostToken,
            expectedStatuses: const <int>[200],
          );
          final firstDeviceBefore =
              (laptopDevicesBefore['devices'] as List<dynamic>).single
                  as Map<String, dynamic>;
          expect(firstDeviceBefore['notificationsEnabled'], isFalse);
          expect(firstDeviceBefore['backendPushRegistered'], isFalse);

          // 5. Generate a real subscriber P-256 ECDH keypair + 16-byte auth secret
          final rng = Random.secure();
          final subscriberKeyPair = VapidKeyPair.generate(rng);
          final subAuthSecret = Uint8List.fromList(
            List<int>.generate(16, (_) => rng.nextInt(256)),
          );

          final pushEndpointUrl =
              'http://127.0.0.1:$pushPort/wpush/v2/iphone13_sub_token_abc';

          final registered = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$relayBase/v1/companion/push-subscription'),
            bearerToken: companionToken,
            body: <String, Object?>{
              'endpoint': pushEndpointUrl,
              'p256dh': subscriberKeyPair.publicKeyBase64Url,
              'auth': base64UrlNoPadEncode(subAuthSecret),
              'platform': 'iPhone (Home Screen)',
              'httpsReady': true,
              'homeScreenInstalled': true,
              'notificationPermission': 'granted',
            },
            expectedStatuses: const <int>[200],
          );
          expect(registered['notificationsEnabled'], isTrue);
          expect(registered['backendPushRegistered'], isTrue);

          final laptopDevicesAfter = await _jsonRequest(
            client: client,
            method: 'GET',
            uri: Uri.parse('$relayBase/v1/pairing/devices'),
            bearerToken: hostToken,
            expectedStatuses: const <int>[200],
          );
          final firstDeviceAfter =
              (laptopDevicesAfter['devices'] as List<dynamic>).single
                  as Map<String, dynamic>;
          expect(firstDeviceAfter['notificationsEnabled'], isTrue);
          expect(firstDeviceAfter['backendPushRegistered'], isTrue);

          // 6. Trigger companion's own test alert AND a real laptop alarm with GPS coordinates
          final companionTestResp = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$relayBase/v1/companion/test-alert'),
            bearerToken: companionToken,
            body: const <String, Object?>{},
            expectedStatuses: const <int>[200],
          );
          expect(companionTestResp['pushDispatchedCount'], 1);

          final realAlarmResp = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$relayBase/v1/incidents:report'),
            bearerToken: hostToken,
            body: <String, Object?>{
              'incidentId': 'inc_real_webpush_1',
              'isTest': false,
              'deviceName': 'Jonathan’s MacBook',
              'triggerSummary': 'Motion detected while armed',
              'triggeredAtUtc': '2026-11-16T06:30:00Z',
              'locationStatus': 'attached',
              'location': <String, Object?>{
                'latitude': 43.4723,
                'longitude': -80.5449,
                'accuracyMeters': 11.2,
                'capturedAtUtc': '2026-11-16T06:30:01Z',
              },
            },
            expectedStatuses: const <int>[200],
          );
          expect(realAlarmResp['pushDispatchedCount'], 1);
          expect(capturedPushes, hasLength(2));

          // 7. Cryptographically verify VAPID ES256 JWT + decrypt RFC 8291 aes128gcm payload!
          final alarmPush = capturedPushes.last;
          expect(alarmPush.headers['content-encoding'], 'aes128gcm');
          expect(alarmPush.headers['urgency'], 'high');
          final authHeader = alarmPush.headers['authorization'] ?? '';
          expect(authHeader, startsWith('vapid t='));

          final jwtMatch = RegExp(
            r't=([^,\s]+),\s*k=([^,\s]+)',
          ).firstMatch(authHeader);
          expect(jwtMatch, isNotNull);
          final jwtToken = jwtMatch!.group(1)!;
          final vapidK = jwtMatch.group(2)!;
          expect(vapidK, equals(vapidKeys.publicKeyBase64Url));

          final jwtParts = jwtToken.split('.');
          expect(jwtParts, hasLength(3));
          final signingInput = ascii.encode('${jwtParts[0]}.${jwtParts[1]}');
          final jwtSig = base64FlexibleDecode(jwtParts[2]);
          expect(
            P256Curve.verifyEs256(
              publicPoint: vapidKeys.publicPoint,
              messageBytes: signingInput,
              signatureBytes: jwtSig,
            ),
            isTrue,
            reason:
                'VAPID JWT ES256 signature must verify against server public key',
          );
          final jwtClaims =
              jsonDecode(utf8.decode(base64FlexibleDecode(jwtParts[1])))
                  as Map<String, dynamic>;
          expect(jwtClaims['aud'], 'http://127.0.0.1:$pushPort');

          final decryptedBytes = await WebPushCrypto.decryptAes128Gcm(
            encryptedBody: alarmPush.body,
            clientKeyPair: subscriberKeyPair,
            clientAuthSecret: subAuthSecret,
          );
          final decryptedText = utf8.decode(decryptedBytes);
          final decryptedJson =
              jsonDecode(decryptedText) as Map<String, dynamic>;

          expect(decryptedJson['title'], 'Jonathan’s MacBook');
          expect(
            (decryptedJson['data'] as Map<String, dynamic>)['incidentId'],
            'inc_real_webpush_1',
          );
          // Lock-screen Web Push payload must NEVER leak GPS coordinates or session tokens!
          expect(decryptedText, isNot(contains('43.4723')));
          expect(decryptedText, isNot(contains('-80.5449')));
          expect(decryptedText, isNot(contains(companionToken)));
          expect(decryptedText, isNot(contains(hostToken)));

          // 8. Simulate 410 Gone from Apple/FCM -> relay auto-revokes dead subscription!
          nextPushStatusCode = HttpStatus.gone;
          await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$relayBase/v1/companion/test-alert'),
            bearerToken: companionToken,
            body: const <String, Object?>{},
            expectedStatuses: const <int>[200],
          );

          final statusAfterGone = await _jsonRequest(
            client: client,
            method: 'GET',
            uri: Uri.parse('$relayBase/v1/companion/status'),
            bearerToken: companionToken,
            expectedStatuses: const <int>[200],
          );
          expect(statusAfterGone['notificationsEnabled'], isFalse);
          expect(statusAfterGone['backendPushRegistered'], isFalse);

          final laptopAfterGone = await _jsonRequest(
            client: client,
            method: 'GET',
            uri: Uri.parse('$relayBase/v1/pairing/devices'),
            bearerToken: hostToken,
            expectedStatuses: const <int>[200],
          );
          final deviceAfterGone =
              (laptopAfterGone['devices'] as List<dynamic>).single
                  as Map<String, dynamic>;
          expect(deviceAfterGone['notificationsEnabled'], isFalse);
          expect(deviceAfterGone['backendPushRegistered'], isFalse);
        } finally {
          client.close(force: true);
          await relayServer?.stop();
          await pushEndpointServer?.close(force: true);
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        }
      },
    );

    test(
      '2. PWA manifest/icons/sw.js, plain HTTP accuracy, Safari -> Home Screen handoff without URL tokens, and webhook verification',
      () async {
        HttpOverrides.global = null;
        final client = HttpClient();
        var serverClockUtc = DateTime.utc(2026, 11, 16, 6, 0, 0);

        // Start a live webhook listener to test webhook reachability verification
        final liveWebhook = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        liveWebhook.listen((req) async {
          req.response.statusCode = HttpStatus.ok;
          await req.response.close();
        });

        WatSafeRelayServer? deadWebhookRelay;
        WatSafeRelayServer? relayServer;
        try {
          // A. Webhook pointing at closed port must report webhookSenderVerified == false
          final tempClosed = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final closedPort = tempClosed.port;
          await tempClosed.close(force: true);

          deadWebhookRelay = WatSafeRelayServer(
            store: InMemoryRelayStore(),
            pushProvider: EnvironmentPushProviderAdapter(
              environment: <String, String>{
                'WATSAFE_PUSH_WEBHOOK_URL':
                    'http://127.0.0.1:$closedPort/push-hook',
              },
            ),
          );
          final deadPort = await deadWebhookRelay.start(
            address: InternetAddress.loopbackIPv4,
            port: 0,
          );
          final deadHealth = await _jsonRequest(
            client: client,
            method: 'GET',
            uri: Uri.parse('http://127.0.0.1:$deadPort/v1/health'),
            expectedStatuses: const <int>[200],
          );
          expect(deadHealth['webhookConfigured'], isTrue);
          expect(deadHealth['webhookSenderVerified'], isFalse);
          await deadWebhookRelay.stop();
          deadWebhookRelay = null;

          // B. Relay with live verified webhook + direct Web Push
          final vapidKeys = VapidKeyPair.generate();
          relayServer = WatSafeRelayServer(
            store: InMemoryRelayStore(),
            clock: () => serverClockUtc,
            pushProvider: EnvironmentPushProviderAdapter(
              environment: <String, String>{
                'WATSAFE_PUSH_WEBHOOK_URL':
                    'http://127.0.0.1:${liveWebhook.port}/push-hook',
                'VAPID_PUBLIC_KEY': vapidKeys.publicKeyBase64Url,
                'VAPID_PRIVATE_KEY': vapidKeys.privateKeyBase64Url,
              },
            ),
          );
          final port = await relayServer.start(
            address: InternetAddress.loopbackIPv4,
            port: 0,
          );
          final base = 'http://127.0.0.1:$port';

          final health = await _jsonRequest(
            client: client,
            method: 'GET',
            uri: Uri.parse('$base/v1/health'),
            expectedStatuses: const <int>[200],
          );
          expect(health['webhookSenderVerified'], isTrue);
          expect(health['directWebPushReady'], isTrue);
          expect(
            health['vapidPublicKey'],
            equals(vapidKeys.publicKeyBase64Url),
          );

          // C. Verify PWA manifest, PNG icons, Service Worker, and guided companion HTML
          final manifest = await _jsonRequest(
            client: client,
            method: 'GET',
            uri: Uri.parse('$base/manifest.webmanifest'),
            expectedStatuses: const <int>[200],
          );
          expect(manifest['display'], 'standalone');
          expect(manifest['start_url'], '/companion?source=homescreen');
          expect(
            (manifest['icons'] as List<dynamic>).length,
            greaterThanOrEqualTo(3),
          );

          for (final iconPath in <String>[
            '/icons/icon-192.png',
            '/icons/icon-512.png',
            '/icons/apple-touch-icon.png',
            '/favicon.png',
          ]) {
            final req = await client.getUrl(Uri.parse('$base$iconPath'));
            final resp = await req.close();
            final bytes = await resp.fold<List<int>>(
              <int>[],
              (acc, chunk) => acc..addAll(chunk),
            );
            expect(resp.statusCode, 200, reason: 'Failed icon $iconPath');
            expect(resp.headers.contentType?.mimeType, 'image/png');
            // Verify PNG magic signature: 89 50 4E 47
            expect(bytes.take(4).toList(), <int>[0x89, 0x50, 0x4E, 0x47]);
          }

          final swReq = await client.getUrl(Uri.parse('$base/sw.js'));
          final swResp = await swReq.close();
          final swText = await utf8.decoder.bind(swResp).join();
          expect(swResp.statusCode, 200);
          expect(swText, contains("addEventListener('push'"));
          expect(swText, contains("addEventListener('notificationclick'"));
          expect(swText, contains('/companion?event='));

          final pageReq = await client.getUrl(Uri.parse('$base/companion'));
          final pageResp = await pageReq.close();
          final pageHtml = await utf8.decoder.bind(pageResp).join();
          expect(pageResp.statusCode, 200);
          expect(
            pageHtml,
            contains('rel="manifest" href="/manifest.webmanifest"'),
          );
          expect(pageHtml, contains('href="/icons/apple-touch-icon.png"'));
          expect(
            pageHtml,
            isNot(
              contains('This browser does not support system notifications'),
            ),
          );

          // D. Register public HTTPS origin via loopback admin endpoint & verify QR URL uses HTTPS
          await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$base/v1/admin/public-url'),
            body: const <String, Object?>{'publicUrl': 'ftp://invalid-scheme'},
            expectedStatuses: const <int>[400],
          );
          await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$base/v1/admin/public-url'),
            body: const <String, Object?>{
              'publicUrl': 'https://watsafe-demo.lhr.life/',
            },
            expectedStatuses: const <int>[200],
          );

          final session = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$base/v1/pairing/initiate'),
            body: const <String, Object?>{'hostDisplayName': 'My MacBook'},
            expectedStatuses: const <int>[200],
          );
          expect(
            session['pairingUrl'] as String,
            startsWith('https://watsafe-demo.lhr.life/pair?code='),
          );
          final hostToken = session['hostToken'] as String;
          final pairingCode = session['pairingCode'] as String;

          // E. Safari -> Home Screen handoff preserves pairing, rotates token, keeps tokens out of URLs
          final safariPair = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$base/v1/pairing/complete'),
            body: <String, Object?>{
              'pairingCode': pairingCode,
              'displayName': 'iPhone 13 (Safari)',
              'platform': 'iPhone (Safari)',
              'notificationsEnabled': false,
            },
            expectedStatuses: const <int>[200],
          );
          final safariToken = safariPair['companionToken'] as String;

          // Report Safari state (HTTPS ready, NOT installed to Home Screen yet)
          await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$base/v1/companion/status'),
            bearerToken: safariToken,
            body: const <String, Object?>{
              'notificationsEnabled': false,
              'httpsReady': true,
              'homeScreenInstalled': false,
              'notificationPermission': 'unavailable',
            },
            expectedStatuses: const <int>[200],
          );

          final handoff = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$base/v1/companion/handoff-code'),
            bearerToken: safariToken,
            body: const <String, Object?>{},
            expectedStatuses: const <int>[200],
          );
          final handoffCode = handoff['handoffCode'] as String;
          expect(
            RegExp(r'^[A-Z0-9]{6}$').hasMatch(handoffCode.replaceAll('-', '')),
            isTrue,
          );
          expect(handoff.toString(), isNot(contains(safariToken)));

          // Claim handoff from the isolated iOS Home Screen web app
          final claimed = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$base/v1/companion/claim-handoff'),
            body: <String, Object?>{
              'handoffCode': handoffCode,
              'homeScreenInstalled': true,
              'httpsReady': true,
            },
            expectedStatuses: const <int>[200],
          );
          final homeScreenToken = claimed['companionToken'] as String;
          expect(homeScreenToken, isNot(equals(safariToken)));
          expect(claimed['hostDisplayName'], 'My MacBook');

          // Old Safari token must now be invalidated (401) and handoff code cannot be reused!
          await _jsonRequest(
            client: client,
            method: 'GET',
            uri: Uri.parse('$base/v1/companion/status'),
            bearerToken: safariToken,
            expectedStatuses: const <int>[401],
          );
          await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$base/v1/companion/claim-handoff'),
            body: <String, Object?>{'handoffCode': handoffCode},
            expectedStatuses: const <int>[404],
          );

          // Laptop still sees exactly ONE paired iPhone bond, now marked homeScreenInstalled: true!
          final devicesResp = await _jsonRequest(
            client: client,
            method: 'GET',
            uri: Uri.parse('$base/v1/pairing/devices'),
            bearerToken: hostToken,
            expectedStatuses: const <int>[200],
          );
          final devices = devicesResp['devices'] as List<dynamic>;
          expect(devices, hasLength(1));
          expect(
            (devices.single as Map<String, dynamic>)['homeScreenInstalled'],
            isTrue,
          );

          // Also verify expired handoff codes return 400 (HANDOFF_CODE_EXPIRED)
          final expiringHandoff = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$base/v1/companion/handoff-code'),
            bearerToken: homeScreenToken,
            body: const <String, Object?>{},
            expectedStatuses: const <int>[200],
          );
          serverClockUtc = serverClockUtc.add(const Duration(minutes: 20));
          final expiredResp = await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$base/v1/companion/claim-handoff'),
            body: <String, Object?>{
              'handoffCode': expiringHandoff['handoffCode'],
            },
            expectedStatuses: const <int>[400],
          );
          expect(expiredResp['error'], 'HANDOFF_CODE_EXPIRED');
        } finally {
          client.close(force: true);
          await deadWebhookRelay?.stop();
          await relayServer?.stop();
          await liveWebhook.close(force: true);
        }
      },
    );

    test(
      '3. Simplified startup (LocalRelaySupervisor occupied port & public HTTPS discovery), backend outage resilience, and auto-reconnect on app restart',
      () async {
        HttpOverrides.global = null;
        final tempDir = await Directory.systemTemp.createTemp(
          'watsafe_startup_test_',
        );
        HttpServer? blockerServer;
        WatSafeRelayServer? externalRelay;
        final supervisor1 = LocalRelaySupervisor(forceEnableForTest: true);
        final supervisor2 = LocalRelaySupervisor(forceEnableForTest: true);
        final client = HttpClient();

        try {
          // A. Occupy a port with a non-WATSafe HTTP server (even returning {"status":"ok"});
          // LocalRelaySupervisor must detect it is not WATSafe and bind a clean embedded port!
          blockerServer = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final occupiedPort = blockerServer.port;
          blockerServer.listen((req) async {
            req.response.statusCode = HttpStatus.ok;
            req.response.headers.contentType = ContentType.json;
            req.response.write('{"status":"ok","otherService":true}');
            await req.response.close();
          });

          final embeddedUrl = await supervisor1.ensureRelayAvailable(
            currentEndpointUrl: 'http://127.0.0.1:$occupiedPort',
            fallbackPort: occupiedPort,
          );
          expect(embeddedUrl, isNotNull);
          expect(embeddedUrl, isNot('http://127.0.0.1:$occupiedPort'));
          final embeddedHealth = await _jsonRequest(
            client: client,
            method: 'GET',
            uri: Uri.parse('$embeddedUrl/v1/health'),
            expectedStatuses: const <int>[200],
          );
          expect(embeddedHealth['status'], 'ok');
          expect(embeddedHealth['storageBackend'], 'memory');
          await supervisor1.dispose();

          // B. External relay with registered publicHttpsOrigin is discovered automatically
          final sharedStore = InMemoryRelayStore();
          externalRelay = WatSafeRelayServer(store: sharedStore);
          final extPort = await externalRelay.start(
            address: InternetAddress.loopbackIPv4,
            port: 0,
          );
          await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('http://127.0.0.1:$extPort/v1/admin/public-url'),
            body: const <String, Object?>{
              'publicUrl': 'https://cloud-tunnel.example.com',
            },
            expectedStatuses: const <int>[200],
          );

          final discoveredUrl = await supervisor2.ensureRelayAvailable(
            currentEndpointUrl: 'http://127.0.0.1:$extPort',
            fallbackPort: extPort,
          );
          expect(discoveredUrl, 'https://cloud-tunnel.example.com');

          // C. Backend outage + app restart auto-reconnection
          final localRelayUrl = 'http://127.0.0.1:$extPort';
          final laptopStoragePath = '${tempDir.path}/laptop_store';

          final remote1 = ConfigurableRemoteNotificationService(
            persistToDisk: true,
            storageDirectory: laptopStoragePath,
            initialRelayEndpointUrl: localRelayUrl,
            enableBackgroundPolling: false,
          );
          final invite = await remote1.initiateHostPairing(
            hostDisplayName: 'Studio MacBook',
          );
          await _jsonRequest(
            client: client,
            method: 'POST',
            uri: Uri.parse('$localRelayUrl/v1/pairing/complete'),
            body: <String, Object?>{
              'pairingCode': invite.pairingCode,
              'displayName': 'Jonathan’s iPhone 13',
              'platform': 'iPhone',
            },
            expectedStatuses: const <int>[200],
          );
          expect((await remote1.syncPairedDevicesFromRelay()), hasLength(1));
          remote1.dispose();

          // Simulate backend outage!
          await externalRelay.stop();

          final remoteDuringOutage = ConfigurableRemoteNotificationService(
            persistToDisk: true,
            storageDirectory: laptopStoragePath,
            enableBackgroundPolling: false,
          );
          // Cached paired device survives temporary outage without crashing or wiping tokens
          expect(
            (await remoteDuringOutage.syncPairedDevicesFromRelay()),
            hasLength(1),
          );
          final cachedDevices = await remoteDuringOutage.listPairedDevices();
          expect(cachedDevices, hasLength(1));
          remoteDuringOutage.dispose();

          // Restart relay on same port with the shared store & reopen AlarmController
          externalRelay = WatSafeRelayServer(store: sharedStore);
          await externalRelay.start(
            address: InternetAddress.loopbackIPv4,
            port: extPort,
          );

          final reopenedRemote = ConfigurableRemoteNotificationService(
            persistToDisk: true,
            storageDirectory: laptopStoragePath,
            enableBackgroundPolling: false,
          );
          final detector = FakeMotionDetector();
          final pinStorage = InMemorySecurePinStorage();
          final pinService = PinSecurityService(
            storage: pinStorage,
            pbkdf2Iterations: 500,
          );
          await pinService.setupInitialPin(pin: '135790', confirmPin: '135790');

          final reopenedController = AlarmController(
            detectors: <DetectorType, MotionDetectorAdapter>{
              DetectorType.macosCameraSceneMotion: detector,
            },
            audioAdapter: FakeAudioAlarmAdapter(),
            pinService: pinService,
            incidentStorage: InMemoryIncidentStorage(),
            settingsStorage: InMemorySettingsStorage(),
            notificationAdapter: reopenedRemote,
          );
          await reopenedController.initialize();
          // Reopening WATSafe automatically reconnects to the relay and syncs paired phone!
          expect(reopenedController.pairedDevices, hasLength(1));
          expect(
            reopenedController.pairedDevices.first.displayName,
            'Jonathan’s iPhone 13',
          );

          reopenedController.dispose();
          reopenedRemote.dispose();
          await detector.dispose();
        } finally {
          client.close(force: true);
          await supervisor1.dispose();
          await supervisor2.dispose();
          await externalRelay?.stop();
          await blockerServer?.close(force: true);
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        }
      },
    );

    testWidgets(
      '4. Desktop (1280x860) & Phone (390x844): Guided status accuracy, Preview onboarding, and Reset demo & restart onboarding (stopping active siren & scoping relay revocation)',
      (WidgetTester tester) async {
        HttpOverrides.global = null;
        final client = HttpClient();
        final vapidKeys = VapidKeyPair.generate();
        final pushServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        pushServer.listen((req) async {
          req.response.statusCode = HttpStatus.created;
          await req.response.close();
        });

        final relayServer = WatSafeRelayServer(
          store: InMemoryRelayStore(),
          pushProvider: EnvironmentPushProviderAdapter(
            environment: <String, String>{
              'VAPID_PUBLIC_KEY': vapidKeys.publicKeyBase64Url,
              'VAPID_PRIVATE_KEY': vapidKeys.privateKeyBase64Url,
            },
          ),
        );
        late int relayPort;
        await tester.runAsync(() async {
          relayPort = await relayServer.start(
            address: InternetAddress.loopbackIPv4,
            port: 0,
          );
        });
        final endpoint = 'http://127.0.0.1:$relayPort';

        late FakeMotionDetector laptopDetector;
        late FakeAudioAlarmAdapter laptopAudio;
        late InMemorySecurePinStorage pinStorage;
        late InMemoryIncidentStorage incidentStorage;
        late InMemorySettingsStorage settingsStorage;
        late ConfigurableRemoteNotificationService laptopRemote;
        late AlarmController laptopController;

        late String companionToken;
        late String otherUserHostToken;

        try {
          await tester.binding.setSurfaceSize(const Size(1280, 860));

          await tester.runAsync(() async {
            laptopDetector = FakeMotionDetector(
              type: DetectorType.macosCameraSceneMotion,
            );
            laptopAudio = FakeAudioAlarmAdapter();
            pinStorage = InMemorySecurePinStorage();
            incidentStorage = InMemoryIncidentStorage();
            settingsStorage = InMemorySettingsStorage();
            laptopRemote = ConfigurableRemoteNotificationService(
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
                storage: pinStorage,
                pbkdf2Iterations: 500,
              ),
              incidentStorage: incidentStorage,
              settingsStorage: settingsStorage,
              notificationAdapter: laptopRemote,
              locationAdapter: FakeLocationService(
                permission: PermissionStatus.granted,
              ),
              localNotificationAdapter: FakeLocalNotificationService(
                permission: PermissionStatus.granted,
              ),
              enableDeveloperControlsForTest: true,
            );
            await laptopController.initialize();
          });

          await tester.pumpWidget(WatSafeApp(controller: laptopController));
          await tester.pumpAndSettle();

          // Complete onboarding with device name + PIN 246810
          await tester.enterText(
            find.byKey(const Key('onboarding_device_name_input')),
            'Jonathan’s MacBook',
          );
          await tester.enterText(
            find.byKey(const Key('onboarding_pin_input')),
            '246810',
          );
          await tester.enterText(
            find.byKey(const Key('onboarding_confirm_pin_input')),
            '246810',
          );
          final onboardingCompleteBtn = find.byKey(
            const Key('onboarding_complete_button'),
          );
          await tester.ensureVisible(onboardingCompleteBtn);
          await tester.tap(onboardingCompleteBtn);
          await tester.pumpAndSettle();

          // Create an unrelated second user's session on the same relay to ensure
          // Reset Demo NEVER wipes another user's pairing records!
          await tester.runAsync(() async {
            final otherSession = await _jsonRequest(
              client: client,
              method: 'POST',
              uri: Uri.parse('$endpoint/v1/pairing/initiate'),
              body: const <String, Object?>{'hostDisplayName': 'Teammate PC'},
              expectedStatuses: const <int>[200],
            );
            otherUserHostToken = otherSession['hostToken'] as String;
            await _jsonRequest(
              client: client,
              method: 'POST',
              uri: Uri.parse('$endpoint/v1/pairing/complete'),
              body: <String, Object?>{
                'pairingCode': otherSession['pairingCode'],
                'displayName': 'Teammate Pixel',
                'platform': 'Android',
              },
              expectedStatuses: const <int>[200],
            );

            // Pair Jonathan's iPhone 13 with Jonathan's MacBook
            final invite = await laptopController.initiateHostPairing();
            final paired = await _jsonRequest(
              client: client,
              method: 'POST',
              uri: Uri.parse('$endpoint/v1/pairing/complete'),
              body: <String, Object?>{
                'pairingCode': invite.pairingCode,
                'displayName': 'Jonathan’s iPhone 13',
                'platform': 'iPhone (Safari)',
              },
              expectedStatuses: const <int>[200],
            );
            companionToken = paired['companionToken'] as String;

            // Step A: Plain HTTP companion status -> Laptop shows "HTTPS setup needed on phone"
            await _jsonRequest(
              client: client,
              method: 'POST',
              uri: Uri.parse('$endpoint/v1/companion/status'),
              bearerToken: companionToken,
              body: const <String, Object?>{
                'notificationsEnabled': false,
                'httpsReady': false,
                'homeScreenInstalled': false,
                'notificationPermission': 'unavailable',
              },
              expectedStatuses: const <int>[200],
            );
            await laptopController.syncPairedDevicesFromRelay();
          });
          await tester.pumpAndSettle();
          expect(
            find.textContaining('HTTPS setup needed on phone'),
            findsOneWidget,
          );
          expect(
            find.textContaining('Phone connected • Notifications on'),
            findsNothing,
          );

          // Step B: HTTPS Safari (not added to Home Screen yet) -> "Add to Home Screen on phone"
          await tester.runAsync(() async {
            await _jsonRequest(
              client: client,
              method: 'POST',
              uri: Uri.parse('$endpoint/v1/companion/status'),
              bearerToken: companionToken,
              body: const <String, Object?>{
                'notificationsEnabled': false,
                'httpsReady': true,
                'homeScreenInstalled': false,
                'notificationPermission': 'unavailable',
              },
              expectedStatuses: const <int>[200],
            );
            await laptopController.syncPairedDevicesFromRelay();
          });
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Add to Home Screen on phone'),
            findsOneWidget,
          );

          // Step C: Home Screen installed + full Web Push registered -> "Phone connected • Notifications on"
          await tester.runAsync(() async {
            final rng = Random.secure();
            final subscriberKeys = VapidKeyPair.generate(rng);
            final auth = Uint8List.fromList(
              List<int>.generate(16, (_) => rng.nextInt(256)),
            );
            await _jsonRequest(
              client: client,
              method: 'POST',
              uri: Uri.parse('$endpoint/v1/companion/push-subscription'),
              bearerToken: companionToken,
              body: <String, Object?>{
                'endpoint': 'http://127.0.0.1:${pushServer.port}/wpush/iphone',
                'p256dh': subscriberKeys.publicKeyBase64Url,
                'auth': base64UrlNoPadEncode(auth),
                'platform': 'iPhone (Home Screen)',
                'httpsReady': true,
                'homeScreenInstalled': true,
                'notificationPermission': 'granted',
              },
              expectedStatuses: const <int>[200],
            );
            await laptopController.syncPairedDevicesFromRelay();
          });
          await tester.pumpAndSettle();
          expect(
            find.textContaining('Phone connected • Notifications on'),
            findsOneWidget,
          );

          // Also verify phone-width layout (390x844) renders Settings -> Advanced -> Preview onboarding cleanly
          await tester.binding.setSurfaceSize(const Size(390, 844));
          await tester.pumpAndSettle();

          await tester.tap(find.text('Settings'));
          await tester.pumpAndSettle();

          final advancedTile = find.byKey(const Key('advanced_settings_tile'));
          await tester.ensureVisible(advancedTile);
          await tester.tap(advancedTile);
          await tester.pumpAndSettle();

          // Test 1: Preview onboarding preserves ALL saved data on Exit preview!
          final previewBtn = find.byKey(const Key('preview_onboarding_button'));
          await tester.ensureVisible(previewBtn);
          await tester.tap(previewBtn);
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('onboarding_preview_banner')),
            findsOneWidget,
          );
          expect(find.text('Welcome to WATSafe'), findsOneWidget);

          await tester.tap(
            find.byKey(const Key('exit_onboarding_preview_button')),
          );
          await tester.pumpAndSettle();

          expect(laptopController.hasPinConfigured, isTrue);
          expect(laptopController.effectiveDeviceName, 'Jonathan’s MacBook');
          expect(laptopController.pairedDevices, hasLength(1));

          // Re-expand Advanced after returning from Onboarding preview
          await tester.ensureVisible(advancedTile);
          await tester.tap(advancedTile);
          await tester.pumpAndSettle();

          // Test 2: Open Reset Demo confirmation dialog, verify Cancel leaves everything untouched
          final resetBtn = find.byKey(const Key('reset_demo_button'));
          await tester.ensureVisible(resetBtn);
          await tester.tap(resetBtn);
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('reset_demo_confirm_dialog')),
            findsOneWidget,
          );
          expect(
            find.textContaining('Revokes this device’s phone pairing'),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const Key('cancel_reset_demo_button')));
          await tester.pumpAndSettle();
          expect(laptopController.hasPinConfigured, isTrue);
          expect(laptopController.pairedDevices, hasLength(1));

          // Test 3: Trigger an ACTIVE ALARM (siren playing + detector running), then run Reset Demo!
          await tester.binding.setSurfaceSize(const Size(1280, 860));
          await tester.pumpAndSettle();

          await tester.runAsync(() async {
            await laptopController.startArming();
            final sid = laptopController.activeSessionId!;
            while (laptopController.state == ProtectionState.arming) {
              await laptopController.handleCountdownTickForSession(sid);
            }
            laptopDetector.emit(
              DetectorEvent(
                eventId: 'evt_reset_during_alarm',
                sessionId: sid,
                detectorType: DetectorType.macosCameraSceneMotion,
                eventType: DetectorEventType.motionTriggered,
                timestamp: DateTime.utc(2026, 11, 16, 6, 45, 0),
                summary: 'Motion triggered before demo reset',
                motionScore: 0.51,
                threshold: 0.095,
                consecutiveAboveThresholdFrames: 3,
              ),
            );
            await Future<void>.delayed(const Duration(milliseconds: 80));
          });
          await tester.pumpAndSettle();

          expect(laptopController.state, ProtectionState.alarming);
          expect(laptopAudio.isPlaying, isTrue);
          expect(laptopController.incidents, isNotEmpty);

          // Execute Reset Demo while siren is sounding
          await tester.runAsync(() async {
            await laptopController.resetDemoAndRestartOnboarding();
          });
          await tester.pumpAndSettle();

          // Siren stopped immediately, monitoring stopped, PIN deleted, incidents cleared, back on Welcome!
          expect(laptopAudio.isPlaying, isFalse);
          expect(laptopController.state, ProtectionState.disarmed);
          expect(laptopController.hasPinConfigured, isFalse);
          expect(laptopController.incidents, isEmpty);
          expect(laptopController.pairedDevices, isEmpty);
          expect(find.text('Welcome to WATSafe'), findsOneWidget);
          expect(
            find.byKey(const Key('onboarding_preview_banner')),
            findsNothing,
          );
          // Relay endpoint URL stays configured so fresh QR pairing works immediately after onboarding!
          expect(laptopController.relayEndpointUrl, endpoint);

          await tester.runAsync(() async {
            // Verify THIS installation's companion token was revoked on the relay (401)
            await _jsonRequest(
              client: client,
              method: 'GET',
              uri: Uri.parse('$endpoint/v1/companion/status'),
              bearerToken: companionToken,
              expectedStatuses: const <int>[401],
            );

            // Verify the OTHER user's session on the same relay is 100% untouched!
            final otherDevices = await _jsonRequest(
              client: client,
              method: 'GET',
              uri: Uri.parse('$endpoint/v1/pairing/devices'),
              bearerToken: otherUserHostToken,
              expectedStatuses: const <int>[200],
            );
            expect(otherDevices['devices'] as List<dynamic>, hasLength(1));

            // Verify restarting a fresh AlarmController against the same storage stays on onboarding
            final restartedController = AlarmController(
              detectors: <DetectorType, MotionDetectorAdapter>{
                DetectorType.macosCameraSceneMotion: laptopDetector,
              },
              audioAdapter: FakeAudioAlarmAdapter(),
              pinService: PinSecurityService(
                storage: pinStorage,
                pbkdf2Iterations: 500,
              ),
              incidentStorage: incidentStorage,
              settingsStorage: settingsStorage,
              notificationAdapter: laptopRemote,
            );
            await restartedController.initialize();
            expect(restartedController.hasPinConfigured, isFalse);
            expect(restartedController.settings.onboardingCompleted, isFalse);
            expect(restartedController.incidents, isEmpty);
            restartedController.dispose();
          });
        } finally {
          await tester.binding.setSurfaceSize(null);
          laptopController.dispose();
          laptopRemote.dispose();
          await tester.runAsync(() async {
            client.close(force: true);
            await laptopDetector.dispose();
            await relayServer.stop();
            await pushServer.close(force: true);
          });
        }
      },
    );
  });
}
