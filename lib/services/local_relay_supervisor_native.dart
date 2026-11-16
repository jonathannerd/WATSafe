import 'dart:convert';
import 'dart:io';

import '../relay/relay_server.dart';
import '../relay/web_push.dart';
import 'relay_config.dart';

/// Ensures desktop launches (`WATSafe.app` on macOS/Windows/Linux) always have
/// a reachable relay service without requiring the user to open two terminals:
/// - Prefers any configured permanent HTTPS service (persisting it across restarts
///   and keeping it selected even during temporary offline blips).
/// - Discovers any active local HTTPS tunnel registered with a local relay.
/// - Starts a durable embedded [WatSafeRelayServer] (`FileRelayStore` / PostgreSQL)
///   automatically when no external relay is running on loopback.
class LocalRelaySupervisor {
  LocalRelaySupervisor({
    this.forceEnableForTest = false,
    this.storageDirectory,
  });

  final bool forceEnableForTest;
  final String? storageDirectory;
  WatSafeRelayServer? _embeddedServer;

  bool get isRunningEmbeddedRelay => _embeddedServer != null;

  bool get _isDesktopHost =>
      forceEnableForTest ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux;

  static bool isEphemeralDevTunnelHost(String host) {
    final lower = host.toLowerCase();
    return lower.endsWith('.lhr.life') ||
        lower.endsWith('.localhost.run') ||
        lower.endsWith('.trycloudflare.com') ||
        lower.endsWith('.ngrok-free.app') ||
        lower.endsWith('.ngrok-free.dev') ||
        lower.endsWith('.ngrok.io');
  }

  Future<String?> ensureRelayAvailable({
    required String currentEndpointUrl,
    int fallbackPort = 8787,
  }) async {
    if (!_isDesktopHost) {
      return currentEndpointUrl;
    }

    var candidateUrl = currentEndpointUrl.trim();
    if (!forceEnableForTest &&
        (candidateUrl.isEmpty ||
            candidateUrl == RelayConfig.localDevelopmentRelayUrl)) {
      final persistedPerm = RelayConfig.persistedPermanentRelayUrl;
      if (persistedPerm != null && persistedPerm.isNotEmpty) {
        candidateUrl = persistedPerm;
      }
    }

    final cleaned = candidateUrl.endsWith('/')
        ? candidateUrl.substring(0, candidateUrl.length - 1)
        : candidateUrl;
    final parsed = Uri.tryParse(cleaned);
    final isLoopback =
        parsed == null ||
        parsed.host.isEmpty ||
        parsed.host == '127.0.0.1' ||
        parsed.host == 'localhost' ||
        parsed.host == '::1';

    if (!isLoopback) {
      final remoteHealth = await _probeHealth(cleaned);
      if (remoteHealth != null) {
        if (!forceEnableForTest && RelayConfig.isPermanentHttpsUrl(cleaned)) {
          await RelayConfig.savePermanentRelayUrl(cleaned);
        }
        return cleaned;
      }
      // Keep permanent cloud HTTPS services intact across temporary offline blips;
      // only fall back when a previous temporary dev tunnel is no longer running.
      if (!isEphemeralDevTunnelHost(parsed.host) ||
          RelayConfig.hasExplicitCompileOrEnvOverride) {
        return cleaned;
      }
    }

    final targetPort = (isLoopback && parsed != null && parsed.hasPort)
        ? parsed.port
        : fallbackPort;
    final localOrigin = 'http://127.0.0.1:$targetPort';
    final localHealth = await _probeHealth(localOrigin);
    if (localHealth != null) {
      final permHttps = (localHealth['permanentHttpsOrigin'] as String?)
          ?.trim();
      if (permHttps != null && permHttps.startsWith('https://')) {
        return permHttps;
      }
      final publicHttps = (localHealth['publicHttpsOrigin'] as String?)?.trim();
      if (publicHttps != null && publicHttps.startsWith('https://')) {
        return publicHttps;
      }
      return localOrigin;
    }

    if (_embeddedServer != null && _embeddedServer!.port > 0) {
      return 'http://127.0.0.1:${_embeddedServer!.port}';
    }

    return _startEmbeddedRelay(preferredPort: targetPort);
  }

  Future<String> _startEmbeddedRelay({required int preferredPort}) async {
    late final WatSafeRelayServer server;
    if (storageDirectory != null && storageDirectory!.trim().isNotEmpty) {
      final dir = storageDirectory!.trim();
      final store = FileRelayStore(directory: Directory(dir));
      final pushAdapter = EnvironmentPushProviderAdapter(
        persistVapidKeysToDisk: true,
        vapidKeyFile: File('$dir/vapid_keys.json'),
      );
      server = WatSafeRelayServer(store: store, pushProvider: pushAdapter);
    } else if (forceEnableForTest) {
      final vapidFile = File(
        '${Directory.systemTemp.path}/watsafe_embedded_vapid_keys.json',
      );
      final pushAdapter = EnvironmentPushProviderAdapter(
        persistVapidKeysToDisk: true,
        vapidKeyFile: vapidFile,
      );
      server = WatSafeRelayServer(
        store: InMemoryRelayStore(),
        pushProvider: pushAdapter,
      );
    } else {
      final pgStore = PostgresRelayStore.fromEnvironment();
      final pushAdapter = EnvironmentPushProviderAdapter(
        persistVapidKeysToDisk: true,
        vapidKeyFile: VapidKeyPair.resolveDefaultVapidKeyFile(),
      );
      server = WatSafeRelayServer(
        store: pgStore ?? FileRelayStore.fromEnvironment(),
        pushProvider: pushAdapter,
      );
    }

    int boundPort;
    try {
      boundPort = await server.start(
        address: InternetAddress.loopbackIPv4,
        port: preferredPort,
      );
    } on SocketException {
      // Preferred port is occupied by a non-WATSafe process; bind a free port cleanly.
      boundPort = await server.start(
        address: InternetAddress.loopbackIPv4,
        port: 0,
      );
    }
    _embeddedServer = server;
    return 'http://127.0.0.1:$boundPort';
  }

  Future<Map<String, Object?>?> _probeHealth(String origin) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 1800);
    try {
      final req = await client
          .getUrl(Uri.parse('$origin/v1/health'))
          .timeout(const Duration(milliseconds: 2200));
      final resp = await req.close().timeout(
        const Duration(milliseconds: 2200),
      );
      if (resp.statusCode != HttpStatus.ok) {
        await resp.drain<void>();
        return null;
      }
      final raw = await utf8.decoder
          .bind(resp)
          .join()
          .timeout(const Duration(milliseconds: 2000));
      final decoded = jsonDecode(raw);
      if (decoded is Map &&
          decoded['status'] == 'ok' &&
          decoded.containsKey('storageBackend') &&
          decoded.containsKey('deliveryMode')) {
        return Map<String, Object?>.from(decoded);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> dispose() async {
    final srv = _embeddedServer;
    _embeddedServer = null;
    if (srv != null) {
      await srv.stop();
    }
  }
}
