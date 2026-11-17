import 'relay_config_env_stub.dart'
    if (dart.library.io) 'relay_config_env_native.dart';

/// Build-time, runtime-environment, and permanent-service relay URL configuration.
///
/// Resolution priority:
/// 1. `--dart-define=WATSAFE_API_URL=https://...` (or `WATSAFE_RELAY_URL`)
/// 2. Runtime `WATSAFE_API_URL` / persisted permanent HTTPS service (`~/.watsafe/relay_service.json` or `config/relay_service.json`)
/// 3. Active launcher runtime endpoint (`.watsafe-runtime/relay_endpoint.json` while launcher is alive)
/// 4. Browser origin when opened directly from an HTTPS/HTTP relay host
/// 5. Local loopback relay (`http://127.0.0.1:8787`, auto-started on desktop)
class RelayConfig {
  const RelayConfig._();

  static const String _compiledApiUrl = String.fromEnvironment(
    'WATSAFE_API_URL',
  );
  static const String _compiledRelayUrl = String.fromEnvironment(
    'WATSAFE_RELAY_URL',
  );

  static const String localDevelopmentRelayUrl = 'http://127.0.0.1:8787';

  static bool isEphemeralTunnelUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      return false;
    }
    final parsed = Uri.tryParse(rawUrl.trim());
    final host = (parsed?.host ?? rawUrl.trim()).toLowerCase();
    return host.endsWith('.trycloudflare.com') ||
        host.endsWith('.lhr.life') ||
        host.endsWith('.localhost.run') ||
        host.endsWith('.ngrok-free.app') ||
        host.endsWith('.ngrok-free.dev') ||
        host.endsWith('.ngrok.io');
  }

  static bool isPlaceholderUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      return false;
    }
    final lower = rawUrl.trim().toLowerCase();
    if (lower.contains('<') || lower.contains('>')) {
      return true;
    }
    final parsed = Uri.tryParse(lower);
    final host = parsed?.host ?? lower;
    return host == 'example.com' ||
        host.endsWith('.example.com') ||
        host == 'example.org' ||
        host.endsWith('.example.org') ||
        host.contains('your-service') ||
        host.contains('your-render-service') ||
        host.contains('yourdomain.com') ||
        host.contains('your-relay-domain');
  }

  static bool isPermanentHttpsUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      return false;
    }
    if (isPlaceholderUrl(rawUrl)) {
      return false;
    }
    final cleaned = _trimTrailingSlash(rawUrl);
    final parsed = Uri.tryParse(cleaned);
    if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty) {
      return false;
    }
    return !isEphemeralTunnelUrl(cleaned);
  }

  static String? get persistedPermanentRelayUrl =>
      readPersistedPermanentRelayUrl();

  static Future<void> savePermanentRelayUrl(String? url) =>
      writePersistedPermanentRelayUrl(url);

  static bool get hasExplicitCompileOrEnvOverride =>
      _compiledApiUrl.trim().isNotEmpty ||
      _compiledRelayUrl.trim().isNotEmpty ||
      hasExplicitRuntimeEnvVarOverride();

  static String resolveDefaultRelayUrl({Uri? browserOrigin}) {
    if (_compiledApiUrl.trim().isNotEmpty) {
      return _trimTrailingSlash(_compiledApiUrl);
    }
    if (_compiledRelayUrl.trim().isNotEmpty) {
      return _trimTrailingSlash(_compiledRelayUrl);
    }
    final runtimeEnv = readRuntimeRelayEnvUrl();
    if (runtimeEnv != null && runtimeEnv.trim().isNotEmpty) {
      return _trimTrailingSlash(runtimeEnv);
    }
    if (browserOrigin != null &&
        (browserOrigin.scheme == 'http' || browserOrigin.scheme == 'https') &&
        (browserOrigin.port == 8787 ||
            browserOrigin.path.startsWith('/pair') ||
            browserOrigin.path.startsWith('/companion'))) {
      return '${browserOrigin.scheme}://${browserOrigin.authority}';
    }
    return localDevelopmentRelayUrl;
  }

  static String _trimTrailingSlash(String raw) {
    final trimmed = raw.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
}
