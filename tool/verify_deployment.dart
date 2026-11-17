import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:watsafe/relay/web_push.dart';
import 'package:watsafe/services/relay_config.dart';

/// End-to-end verifier for a permanent HTTPS WATSafe Relay & Companion deployment.
///
/// Verifies:
/// 1. Stable `https://` origin (rejecting placeholders and temporary quick tunnels).
/// 2. `/v1/health` reports `X-WATSafe-Companion: 1`, `storageDurable == true`,
///    and a non-empty `vapidPublicKey` (and `storageBackend == 'aiven_postgres'`
///    for cloud deployments unless `--allow-local-durable-file` is set).
/// 3. PWA `/manifest.webmanifest` (`id: '/companion'`, `start_url: '/companion?source=homescreen'`,
///    `scope: '/'`, `display: 'standalone'`), `/sw.js`, and `/companion`.
/// 4. Persistence across a relay restart / container redeploy:
///    - `--phase=before-restart <https-url>` creates an isolated verification
///      pairing session, paired companion bond, and RFC 8291 Web Push subscription,
///      saving probe state (`0600`) to `~/.watsafe/deploy_verify_probe.json`.
///    - `--phase=after-restart [--save] <https-url>` verifies after a relay
///      restart/redeploy that `vapidPublicKey`, the companion bond, and its Web Push
///      subscription survived intact, verifies `Laptop offline` -> `Connected`
///      presence transitions, revokes the temporary probe session, and optionally
///      saves the verified endpoint to `~/.watsafe/relay_service.json`.
class DeploymentVerificationResult {
  const DeploymentVerificationResult({
    required this.ok,
    required this.endpointUrl,
    required this.message,
    this.storageBackend,
    this.storageDurable,
    this.vapidPublicKey,
  });

  final bool ok;
  final String endpointUrl;
  final String message;
  final String? storageBackend;
  final bool? storageDurable;
  final String? vapidPublicKey;
}

class DeploymentVerifier {
  DeploymentVerifier({
    this.allowLocalHttpForTest = false,
    this.requirePostgresBackend = false,
    File? probeStateFile,
  }) : probeStateFile = probeStateFile ?? _defaultProbeStateFile();

  final bool allowLocalHttpForTest;
  final bool requirePostgresBackend;
  final File probeStateFile;

  static File _defaultProbeStateFile() {
    final home =
        (Platform.environment['HOME'] ??
                Platform.environment['USERPROFILE'] ??
                '')
            .trim();
    final dir = home.isNotEmpty
        ? '$home/.watsafe'
        : '${Directory.systemTemp.path}/watsafe';
    return File('$dir/deploy_verify_probe.json');
  }

  static String _normalizeUrl(String raw) {
    final trimmed = raw.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  String? _validateOriginUrl(String normalized) {
    if (normalized.isEmpty) {
      return 'Endpoint URL is empty.';
    }
    if (RelayConfig.isPlaceholderUrl(normalized)) {
      return 'Endpoint "$normalized" is a documentation placeholder, not a deployed service.';
    }
    if (RelayConfig.isEphemeralTunnelUrl(normalized)) {
      return 'Endpoint "$normalized" is a temporary quick tunnel (*.trycloudflare.com / *.lhr.life / *.ngrok) and will change on restart.';
    }
    final parsed = Uri.tryParse(normalized);
    if (parsed == null || parsed.host.isEmpty) {
      return 'Endpoint "$normalized" is not a valid URL.';
    }
    if (parsed.scheme != 'https') {
      final isLoopback =
          parsed.host == '127.0.0.1' ||
          parsed.host == 'localhost' ||
          parsed.host == '::1';
      if (!(allowLocalHttpForTest && parsed.scheme == 'http' && isLoopback)) {
        return 'Permanent phone pairing requires an https:// origin (got "${parsed.scheme}://").';
      }
    }
    return null;
  }

  Future<DeploymentVerificationResult> verifyEndpointHealthAndPwa(
    String rawUrl,
  ) async {
    final baseUrl = _normalizeUrl(rawUrl);
    final urlError = _validateOriginUrl(baseUrl);
    if (urlError != null) {
      return DeploymentVerificationResult(
        ok: false,
        endpointUrl: baseUrl,
        message: urlError,
      );
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      // 1. Verify /v1/health
      final healthResp = await _request(client, 'GET', '$baseUrl/v1/health');
      if (healthResp.statusCode != HttpStatus.ok) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          message:
              'GET $baseUrl/v1/health returned HTTP ${healthResp.statusCode}.',
        );
      }
      if (healthResp.companionHeader != '1') {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          message:
              'GET $baseUrl/v1/health is missing X-WATSafe-Companion: 1 (response did not come from WATSafe).',
        );
      }

      final healthJson = _tryDecodeMap(healthResp.body);
      if (healthJson == null || healthJson['status'] != 'ok') {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          message: 'GET $baseUrl/v1/health returned invalid JSON.',
        );
      }

      final storageBackend = (healthJson['storageBackend'] as String? ?? '')
          .trim();
      final storageDurable = healthJson['storageDurable'] == true;
      final durabilityWarning =
          (healthJson['storageDurabilityWarning'] as String?)?.trim();
      final vapidPublicKey = (healthJson['vapidPublicKey'] as String? ?? '')
          .trim();

      if (!storageDurable) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          storageBackend: storageBackend,
          storageDurable: false,
          vapidPublicKey: vapidPublicKey,
          message:
              'Storage at $baseUrl is NOT durable (storageBackend=$storageBackend, storageDurable=false). '
              '${durabilityWarning ?? 'Configure AIVEN_DATABASE_URL in environment secrets and redeploy.'}',
        );
      }

      final hostLower = Uri.parse(baseUrl).host.toLowerCase();
      final isHostedCloud =
          hostLower.endsWith('.onrender.com') ||
          hostLower.endsWith('.fly.dev') ||
          hostLower.endsWith('.railway.app');
      if ((requirePostgresBackend || isHostedCloud) &&
          storageBackend != 'aiven_postgres') {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          storageBackend: storageBackend,
          storageDurable: storageDurable,
          vapidPublicKey: vapidPublicKey,
          message:
              'Cloud deployment at $baseUrl reported storageBackend=$storageBackend instead of aiven_postgres. '
              'Set AIVEN_DATABASE_URL in environment secrets so pairings and VAPID keys survive container redeploys.',
        );
      }

      if (vapidPublicKey.isEmpty) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          storageBackend: storageBackend,
          storageDurable: storageDurable,
          message: 'GET $baseUrl/v1/health did not include a vapidPublicKey.',
        );
      }

      final vapidSubject = (healthJson['vapidSubject'] as String? ?? '').trim();
      if (vapidSubject.isNotEmpty &&
          !VapidKeyPair.isValidPublicSubject(vapidSubject)) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          storageBackend: storageBackend,
          storageDurable: storageDurable,
          vapidPublicKey: vapidPublicKey,
          message:
              'GET $baseUrl/v1/health reported an invalid VAPID subject "$vapidSubject" '
              '(Apple Web Push rejects .local/.localhost/private subjects with 403 BadJwtToken).',
        );
      }

      // 2. Verify /manifest.webmanifest
      final manifestResp = await _request(
        client,
        'GET',
        '$baseUrl/manifest.webmanifest',
      );
      final manifestJson = _tryDecodeMap(manifestResp.body);
      if (manifestResp.statusCode != HttpStatus.ok ||
          manifestJson == null ||
          manifestJson['id'] != '/companion' ||
          manifestJson['start_url'] != '/companion?source=homescreen' ||
          manifestJson['scope'] != '/' ||
          manifestJson['display'] != 'standalone') {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          storageBackend: storageBackend,
          storageDurable: storageDurable,
          vapidPublicKey: vapidPublicKey,
          message:
              'Manifest check failed at $baseUrl/manifest.webmanifest (expected stable id=/companion, start_url=/companion?source=homescreen, scope=/, display=standalone).',
        );
      }

      // 3. Verify /sw.js and /companion
      final swResp = await _request(client, 'GET', '$baseUrl/sw.js');
      if (swResp.statusCode != HttpStatus.ok ||
          swResp.serviceWorkerAllowed != '/' ||
          !swResp.body.contains('pushsubscriptionchange')) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          storageBackend: storageBackend,
          storageDurable: storageDurable,
          vapidPublicKey: vapidPublicKey,
          message:
              'Service worker check failed at $baseUrl/sw.js (status=${swResp.statusCode}).',
        );
      }

      final companionResp = await _request(client, 'GET', '$baseUrl/companion');
      if (companionResp.statusCode != HttpStatus.ok ||
          companionResp.companionHeader != '1') {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          storageBackend: storageBackend,
          storageDurable: storageDurable,
          vapidPublicKey: vapidPublicKey,
          message:
              'Companion shell check failed at $baseUrl/companion (status=${companionResp.statusCode}).',
        );
      }

      return DeploymentVerificationResult(
        ok: true,
        endpointUrl: baseUrl,
        storageBackend: storageBackend,
        storageDurable: storageDurable,
        vapidPublicKey: vapidPublicKey,
        message:
            'Endpoint $baseUrl passed HTTPS/PWA/health checks (storageBackend=$storageBackend, storageDurable=$storageDurable).',
      );
    } catch (e) {
      return DeploymentVerificationResult(
        ok: false,
        endpointUrl: baseUrl,
        message: 'Could not reach $baseUrl: $e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Phase 1: Records a live pairing bond + Web Push subscription before a
  /// relay restart or cloud redeploy.
  Future<DeploymentVerificationResult> recordPreRestartProbe(
    String rawUrl,
  ) async {
    final baseCheck = await verifyEndpointHealthAndPwa(rawUrl);
    if (!baseCheck.ok) {
      return baseCheck;
    }
    final baseUrl = baseCheck.endpointUrl;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final initResp = await _request(
        client,
        'POST',
        '$baseUrl/v1/pairing/initiate',
        jsonBody: <String, Object?>{
          'hostDisplayName': 'WATSafe Deploy Probe',
          'hostDeviceId': 'deploy-verify-host',
          'relayBaseUrl': baseUrl,
        },
      );
      final initJson = _tryDecodeMap(initResp.body);
      if (initResp.statusCode != HttpStatus.ok || initJson == null) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          message:
              'POST /v1/pairing/initiate failed (${initResp.statusCode}): ${initResp.body}',
        );
      }
      final pairingSessionId = initJson['pairingSessionId'] as String? ?? '';
      final hostToken = initJson['hostToken'] as String? ?? '';
      final pairingCode = initJson['pairingCode'] as String? ?? '';

      final completeResp = await _request(
        client,
        'POST',
        '$baseUrl/v1/pairing/complete',
        jsonBody: <String, Object?>{
          'pairingCode': pairingCode,
          'displayName': 'Deploy Verify iPhone',
          'platform': 'ios_web_pwa',
          'deviceId': 'deploy-verify-iphone',
        },
      );
      final completeJson = _tryDecodeMap(completeResp.body);
      if (completeResp.statusCode != HttpStatus.ok || completeJson == null) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          message:
              'POST /v1/pairing/complete failed (${completeResp.statusCode}): ${completeResp.body}',
        );
      }
      final companionToken = completeJson['companionToken'] as String? ?? '';

      // Generate a cryptographically valid NIST P-256 p256dh + 16-byte auth secret.
      final subKeys = VapidKeyPair.generate();
      final rng = Random.secure();
      final authSecret = base64Url
          .encode(List<int>.generate(16, (_) => rng.nextInt(256)))
          .replaceAll('=', '');
      final subEndpoint =
          'https://web.push.apple.com/watsafe-deploy-verify-${rng.nextInt(999999)}';

      final subResp = await _request(
        client,
        'POST',
        '$baseUrl/v1/companion/push-subscription',
        bearerToken: companionToken,
        jsonBody: <String, Object?>{
          'platform': 'ios_web_pwa',
          'httpsReady': true,
          'homeScreenInstalled': true,
          'notificationPermission': 'granted',
          'endpoint': subEndpoint,
          'p256dh': subKeys.publicKeyBase64Url,
          'auth': authSecret,
        },
      );
      if (subResp.statusCode != HttpStatus.ok) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          message:
              'POST /v1/companion/push-subscription failed (${subResp.statusCode}): ${subResp.body}',
        );
      }

      await probeStateFile.parent.create(recursive: true);
      final statePayload = const JsonEncoder.withIndent('  ')
          .convert(<String, Object?>{
            'endpointUrl': baseUrl,
            'storageBackend': baseCheck.storageBackend,
            'vapidPublicKey': baseCheck.vapidPublicKey,
            'pairingSessionId': pairingSessionId,
            'hostToken': hostToken,
            'companionToken': companionToken,
            'webPushEndpoint': subEndpoint,
            'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
          });
      await probeStateFile.writeAsString(statePayload, flush: true);
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', <String>['600', probeStateFile.path]);
        } catch (_) {}
      }

      return DeploymentVerificationResult(
        ok: true,
        endpointUrl: baseUrl,
        storageBackend: baseCheck.storageBackend,
        storageDurable: baseCheck.storageDurable,
        vapidPublicKey: baseCheck.vapidPublicKey,
        message:
            'Recorded pre-restart persistence probe on $baseUrl (storageBackend=${baseCheck.storageBackend}). '
            'Restart or redeploy the relay now, then run --phase=after-restart.',
      );
    } catch (e) {
      return DeploymentVerificationResult(
        ok: false,
        endpointUrl: baseUrl,
        message: 'Pre-restart probe failed on $baseUrl: $e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Phase 2: Verifies after a relay restart or redeploy that VAPID keys,
  /// companion pairing, Web Push registration, and host offline/online presence
  /// survived intact, then cleans up the temporary probe session.
  Future<DeploymentVerificationResult> verifyAfterRestart(
    String rawUrl, {
    bool saveVerifiedUrl = false,
  }) async {
    if (!probeStateFile.existsSync()) {
      return DeploymentVerificationResult(
        ok: false,
        endpointUrl: _normalizeUrl(rawUrl),
        message:
            'No pre-restart probe found at ${probeStateFile.path}. Run --phase=before-restart first.',
      );
    }
    final savedProbe = _tryDecodeMap(await probeStateFile.readAsString());
    if (savedProbe == null) {
      return DeploymentVerificationResult(
        ok: false,
        endpointUrl: _normalizeUrl(rawUrl),
        message: 'Saved probe file ${probeStateFile.path} is corrupt.',
      );
    }

    final postCheck = await verifyEndpointHealthAndPwa(rawUrl);
    if (!postCheck.ok) {
      return postCheck;
    }
    final baseUrl = postCheck.endpointUrl;
    final expectedUrl = (savedProbe['endpointUrl'] as String? ?? '').trim();
    if (expectedUrl != baseUrl) {
      return DeploymentVerificationResult(
        ok: false,
        endpointUrl: baseUrl,
        message:
            'Probe URL mismatch: pre-restart used $expectedUrl, after-restart checked $baseUrl.',
      );
    }

    final preVapidKey = (savedProbe['vapidPublicKey'] as String? ?? '').trim();
    if (preVapidKey.isEmpty || postCheck.vapidPublicKey != preVapidKey) {
      return DeploymentVerificationResult(
        ok: false,
        endpointUrl: baseUrl,
        storageBackend: postCheck.storageBackend,
        storageDurable: postCheck.storageDurable,
        vapidPublicKey: postCheck.vapidPublicKey,
        message:
            'VAPID public key changed across restart/redeploy! Existing iPhone Web Push subscriptions would break. '
            'Ensure AIVEN_DATABASE_URL is set so watsafe_server_secrets persists VAPID keys.',
      );
    }

    final hostToken = (savedProbe['hostToken'] as String? ?? '').trim();
    final companionToken = (savedProbe['companionToken'] as String? ?? '')
        .trim();

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      // 1. Verify companion bond & push registration survived restart without re-pairing!
      final devicesResp = await _request(
        client,
        'GET',
        '$baseUrl/v1/pairing/devices',
        bearerToken: hostToken,
      );
      final devicesJson = _tryDecodeMap(devicesResp.body);
      final devicesList = devicesJson?['devices'];
      if (devicesResp.statusCode != HttpStatus.ok ||
          devicesList is! List ||
          devicesList.isEmpty) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          storageBackend: postCheck.storageBackend,
          storageDurable: postCheck.storageDurable,
          vapidPublicKey: postCheck.vapidPublicKey,
          message:
              'Paired phone record did NOT survive relay restart/redeploy (GET /v1/pairing/devices status=${devicesResp.statusCode}).',
        );
      }
      final firstDevice = Map<String, Object?>.from(devicesList.first as Map);
      if (firstDevice['notificationsEnabled'] != true ||
          firstDevice['backendPushRegistered'] != true) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          storageBackend: postCheck.storageBackend,
          storageDurable: postCheck.storageDurable,
          vapidPublicKey: postCheck.vapidPublicKey,
          message: 'Web Push subscription readiness did NOT survive relay restart/redeploy.',
        );
      }

      // 2. Verify Laptop offline -> Connected automatic presence transitions!
      await _request(
        client,
        'POST',
        '$baseUrl/v1/host/offline',
        bearerToken: hostToken,
        jsonBody: const <String, Object?>{},
      );
      final offlinePoll = await _request(
        client,
        'GET',
        '$baseUrl/v1/companion/alerts?afterSeq=0',
        bearerToken: companionToken,
      );
      final offlineJson = _tryDecodeMap(offlinePoll.body);
      if (offlinePoll.statusCode != HttpStatus.ok ||
          offlineJson?['hostOnline'] != false) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          message:
              'Companion presence check after host offline failed (status=${offlinePoll.statusCode}).',
        );
      }

      await _request(
        client,
        'POST',
        '$baseUrl/v1/host/heartbeat',
        bearerToken: hostToken,
        jsonBody: const <String, Object?>{'protectionState': 'armed'},
      );
      final onlinePoll = await _request(
        client,
        'GET',
        '$baseUrl/v1/companion/alerts?afterSeq=0',
        bearerToken: companionToken,
      );
      final onlineJson = _tryDecodeMap(onlinePoll.body);
      if (onlinePoll.statusCode != HttpStatus.ok ||
          onlineJson?['hostOnline'] != true) {
        return DeploymentVerificationResult(
          ok: false,
          endpointUrl: baseUrl,
          message:
              'Companion presence check after host heartbeat failed (status=${onlinePoll.statusCode}).',
        );
      }

      // 3. Clean up only our verification probe session
      await _request(
        client,
        'POST',
        '$baseUrl/v1/pairing/session/revoke',
        bearerToken: hostToken,
        jsonBody: const <String, Object?>{},
      );
      if (probeStateFile.existsSync()) {
        await probeStateFile.delete();
      }

      if (saveVerifiedUrl) {
        await RelayConfig.savePermanentRelayUrl(baseUrl);
      }

      return DeploymentVerificationResult(
        ok: true,
        endpointUrl: baseUrl,
        storageBackend: postCheck.storageBackend,
        storageDurable: postCheck.storageDurable,
        vapidPublicKey: postCheck.vapidPublicKey,
        message:
            'Verified durable persistence across restart/redeploy at $baseUrl '
            '(storageBackend=${postCheck.storageBackend}, VAPID key preserved, '
            'paired phone + Web Push subscription retained, Laptop offline/online verified)'
            '${saveVerifiedUrl ? ' and saved to ~/.watsafe/relay_service.json.' : '.'}',
      );
    } catch (e) {
      return DeploymentVerificationResult(
        ok: false,
        endpointUrl: baseUrl,
        message: 'Post-restart verification failed on $baseUrl: $e',
      );
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, Object?>? _tryDecodeMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, Object?>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  Future<_RawHttpResponse> _request(
    HttpClient client,
    String method,
    String url, {
    String? bearerToken,
    Map<String, Object?>? jsonBody,
  }) async {
    final req = await client
        .openUrl(method, Uri.parse(url))
        .timeout(const Duration(seconds: 10));
    if (bearerToken != null && bearerToken.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearerToken');
    }
    if (jsonBody != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(jsonBody));
    }
    final res = await req.close().timeout(const Duration(seconds: 10));
    final text = await utf8.decoder
        .bind(res)
        .join()
        .timeout(const Duration(seconds: 10));
    return _RawHttpResponse(
      statusCode: res.statusCode,
      body: text,
      companionHeader: res.headers.value('x-watsafe-companion'),
      serviceWorkerAllowed: res.headers.value('service-worker-allowed'),
    );
  }
}

class _RawHttpResponse {
  const _RawHttpResponse({
    required this.statusCode,
    required this.body,
    this.companionHeader,
    this.serviceWorkerAllowed,
  });

  final int statusCode;
  final String body;
  final String? companionHeader;
  final String? serviceWorkerAllowed;
}

Future<void> main(List<String> args) async {
  var phase = 'health';
  var saveUrl = false;
  var requirePostgres = false;
  String? targetUrl;

  for (final arg in args) {
    if (arg == '--help' || arg == '-h') {
      _printUsage();
      return;
    }
    if (arg == '--save') {
      saveUrl = true;
      continue;
    }
    if (arg == '--require-postgres') {
      requirePostgres = true;
      continue;
    }
    if (arg.startsWith('--phase=')) {
      phase = arg.substring('--phase='.length).trim();
      continue;
    }
    if (!arg.startsWith('-')) {
      targetUrl = arg.trim();
    }
  }

  targetUrl ??= RelayConfig.persistedPermanentRelayUrl;
  if (targetUrl == null || targetUrl.isEmpty) {
    stderr.writeln(
      '[WATSafe] ERROR: Provide your deployed https:// endpoint URL.',
    );
    _printUsage();
    exitCode = 2;
    return;
  }

  final verifier = DeploymentVerifier(requirePostgresBackend: requirePostgres);
  late final DeploymentVerificationResult result;
  switch (phase) {
    case 'health':
      result = await verifier.verifyEndpointHealthAndPwa(targetUrl);
      if (result.ok && saveUrl) {
        await RelayConfig.savePermanentRelayUrl(result.endpointUrl);
      }
      break;
    case 'before-restart':
      result = await verifier.recordPreRestartProbe(targetUrl);
      break;
    case 'after-restart':
      result = await verifier.verifyAfterRestart(
        targetUrl,
        saveVerifiedUrl: saveUrl,
      );
      break;
    default:
      stderr.writeln(
        '[WATSafe] ERROR: Unknown --phase=$phase (expected health, before-restart, or after-restart).',
      );
      exitCode = 2;
      return;
  }

  if (result.ok) {
    stdout.writeln('[WATSafe VERIFIED] ${result.message}');
  } else {
    stderr.writeln('[WATSafe VERIFICATION FAILED] ${result.message}');
    exitCode = 1;
  }
}

void _printUsage() {
  stdout.writeln(
    'Usage:\n'
    '  1. Check HTTPS, PWA manifest/SW, and durable storage:\n'
    '     dart run tool/verify_deployment.dart https://<your-render-service>.onrender.com\n'
    '  2. Verify persistence across a relay restart / Render redeploy:\n'
    '     dart run tool/verify_deployment.dart --phase=before-restart https://<your-render-service>.onrender.com\n'
    '     # Restart or redeploy the relay service, then run:\n'
    '     dart run tool/verify_deployment.dart --phase=after-restart --save https://<your-render-service>.onrender.com',
  );
}
