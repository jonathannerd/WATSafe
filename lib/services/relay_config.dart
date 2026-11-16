import 'relay_config_env_stub.dart'
    if (dart.library.io) 'relay_config_env_native.dart';

/// Build-time, runtime-environment, and deployment-time relay URL configuration.
///
/// Resolution priority:
/// 1. `--dart-define=WATSAFE_API_URL=https://...` (or `WATSAFE_RELAY_URL`)
/// 2. Runtime `WATSAFE_API_URL` / `.watsafe-runtime/relay_endpoint.json`
/// 3. Browser origin when opened directly from an HTTPS/HTTP relay host
/// 4. Local loopback relay (`http://127.0.0.1:8787`, auto-started on desktop)
class RelayConfig {
  const RelayConfig._();

  static const String _compiledApiUrl = String.fromEnvironment(
    'WATSAFE_API_URL',
  );
  static const String _compiledRelayUrl = String.fromEnvironment(
    'WATSAFE_RELAY_URL',
  );

  static const String localDevelopmentRelayUrl = 'http://127.0.0.1:8787';

  static bool get hasExplicitCompileOrEnvOverride =>
      _compiledApiUrl.trim().isNotEmpty ||
      _compiledRelayUrl.trim().isNotEmpty ||
      (readRuntimeRelayEnvUrl()?.trim().isNotEmpty ?? false);

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
