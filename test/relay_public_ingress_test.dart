import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/relay/relay_server.dart';

void main() {
  group('Relay public ingress hardening', () {
    late WatSafeRelayServer relay;
    late HttpClient client;
    late Uri baseUrl;

    setUp(() async {
      relay = WatSafeRelayServer(environment: const <String, String>{});
      final port = await relay.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
      baseUrl = Uri(scheme: 'http', host: '127.0.0.1', port: port);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await relay.stop();
    });

    Future<(int, Map<String, dynamic>)> postJson(
      String path,
      Map<String, Object?> body,
    ) async {
      final request = await client.postUrl(baseUrl.resolve(path));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      final raw = await utf8.decoder.bind(response).join();
      return (
        response.statusCode,
        raw.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(raw) as Map<String, dynamic>,
      );
    }

    test(
      'obsolete public registration and watchdog routes are no longer exposed',
      () async {
        final register = await postJson(
          '/v1/devices/register',
          <String, Object?>{'displayName': 'Untrusted client'},
        );
        expect(register.$1, HttpStatus.notFound);

        final request = await client.getUrl(
          baseUrl.resolve('/v1/watchdog/sweep'),
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.notFound);
        await response.drain<void>();
      },
    );

    test(
      'unknown and already-used handoff codes count toward the rate limit',
      () async {
        for (var attempt = 0; attempt < 5; attempt++) {
          final result = await postJson(
            '/v1/companion/claim-handoff',
            <String, Object?>{'handoffCode': 'AAAAAA'},
          );
          expect(result.$1, HttpStatus.notFound);
          expect(result.$2['error'], 'HANDOFF_CODE_NOT_FOUND');
        }

        final limited = await postJson(
          '/v1/companion/claim-handoff',
          <String, Object?>{'handoffCode': 'AAAAAA'},
        );
        expect(limited.$1, HttpStatus.tooManyRequests);
        expect(limited.$2['error'], 'TOO_MANY_ATTEMPTS');
      },
    );

    test(
      'JSON request bodies larger than 2 MiB are rejected with 413',
      () async {
        final payload = jsonEncode(<String, Object?>{
          'hostDisplayName': ''.padRight(2 * 1024 * 1024, 'x'),
        });
        final bytes = utf8.encode(payload);
        final request = await client.postUrl(
          baseUrl.resolve('/v1/pairing/initiate'),
        );
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);

        final response = await request.close();
        final raw = await utf8.decoder.bind(response).join();
        expect(response.statusCode, HttpStatus.requestEntityTooLarge);
        final body = jsonDecode(raw) as Map<String, dynamic>;
        expect(body['error'], 'REQUEST_BODY_TOO_LARGE');
      },
    );
  });
}
