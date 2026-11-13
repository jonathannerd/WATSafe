import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Standalone WATSafe REST Relay Server implementing the endpoints specified in
/// `backend/README.md`:
/// - `POST /v1/devices/register`
/// - `POST /v1/pairing/initiate`
/// - `POST /v1/pairing/complete`
/// - `GET  /v1/pairing/devices`
/// - `POST /v1/incidents:report`
///
/// Privacy & Security invariants enforced:
/// - Rejects any incident payload containing raw camera frame/image fields or PIN material.
/// - Deduplicates incident reports by `incidentId` (idempotency key).
class WatSafeRelayServer {
  HttpServer? _server;
  final List<Map<String, Object?>> _registeredDevices =
      <Map<String, Object?>>[];
  final List<Map<String, Object?>> _pairedDevices = <Map<String, Object?>>[];
  final Map<String, Map<String, Object?>> _reportedIncidents =
      <String, Map<String, Object?>>{};
  int _seq = 0;

  int get port => _server?.port ?? 0;
  List<Map<String, Object?>> get pairedDevices =>
      List<Map<String, Object?>>.unmodifiable(_pairedDevices);
  List<Map<String, Object?>> get reportedIncidents =>
      List<Map<String, Object?>>.unmodifiable(_reportedIncidents.values);

  Future<int> start({InternetAddress? address, int port = 8787}) async {
    final bindAddress = address ?? InternetAddress.loopbackIPv4;
    final server = await HttpServer.bind(bindAddress, port);
    _server = server;
    server.listen(_handleRequest);
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      final method = request.method.toUpperCase();

      if (method == 'GET' && path == '/v1/pairing/devices') {
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'devices': _pairedDevices,
        });
        return;
      }

      if (method == 'POST' && path == '/v1/devices/register') {
        final body = await _readJsonBody(request);
        final id = 'reg_${++_seq}_${DateTime.now().millisecondsSinceEpoch}';
        final entry = <String, Object?>{
          'deviceId': id,
          'displayName': body['displayName'] ?? 'WATSafe Host',
          'platform': body['platform'] ?? 'unknown',
          'bearerToken': 'tok_$id',
          'registeredAtUtc': DateTime.now().toUtc().toIso8601String(),
        };
        _registeredDevices.add(entry);
        _writeJson(request.response, HttpStatus.ok, entry);
        return;
      }

      if (method == 'POST' && path == '/v1/pairing/initiate') {
        final code = 'WAT-${(100 + (++_seq % 900))}';
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'pairingCode': code,
          'expiresInSeconds': 300,
        });
        return;
      }

      if (method == 'POST' && path == '/v1/pairing/complete') {
        final body = await _readJsonBody(request);
        final bond = <String, Object?>{
          'bondId': 'bond_${++_seq}',
          'deviceId': body['deviceId'] ?? 'dev_$_seq',
          'displayName': body['displayName'] ?? 'Companion Device',
          'platform': body['platform'] ?? 'Android (FCM)',
          'pairedAtUtcIso':
              body['pairedAtUtc'] ?? DateTime.now().toUtc().toIso8601String(),
          'pushChannelReady': true,
        };
        _pairedDevices.add(bond);
        _writeJson(request.response, HttpStatus.ok, bond);
        return;
      }

      if (method == 'POST' && path == '/v1/incidents:report') {
        final body = await _readJsonBody(request);
        // Enforce strict privacy invariant: reject camera frames or PIN hashes
        if (body.containsKey('frameBytes') ||
            body.containsKey('imageBytes') ||
            body.containsKey('pin') ||
            body.containsKey('pinHash')) {
          _writeJson(request.response, HttpStatus.badRequest, <String, Object?>{
            'error': 'PRIVACY_INVARIANT_VIOLATION',
            'message':
                'Incident payloads must never contain camera images or PIN material.',
          });
          return;
        }

        final incidentId = body['incidentId'] as String? ?? 'inc_${++_seq}';
        final existing = _reportedIncidents[incidentId];
        if (existing != null) {
          _writeJson(request.response, HttpStatus.ok, <String, Object?>{
            'delivered': true,
            'deduplicated': true,
            'incidentId': incidentId,
            'dispatchedCount': _pairedDevices.length,
          });
          return;
        }

        _reportedIncidents[incidentId] = body;
        _writeJson(request.response, HttpStatus.ok, <String, Object?>{
          'delivered': true,
          'deduplicated': false,
          'incidentId': incidentId,
          'dispatchedCount': _pairedDevices.length,
        });
        return;
      }

      _writeJson(request.response, HttpStatus.notFound, <String, Object?>{
        'error': 'NOT_FOUND',
        'path': path,
      });
    } catch (error) {
      _writeJson(
        request.response,
        HttpStatus.internalServerError,
        <String, Object?>{'error': '$error'},
      );
    }
  }

  Future<Map<String, Object?>> _readJsonBody(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (raw.trim().isEmpty) {
      return <String, Object?>{};
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return Map<String, Object?>.from(decoded);
    }
    return <String, Object?>{};
  }

  void _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> body,
  ) {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    response.close();
  }
}

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? (int.tryParse(args.first) ?? 8787) : 8787;
  final server = WatSafeRelayServer();
  final boundPort = await server.start(port: port);
  stdout.writeln(
    'WATSafe Relay Server listening on http://127.0.0.1:$boundPort',
  );
}
