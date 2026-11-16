import 'dart:convert';
import 'dart:io';

String? readRuntimeRelayEnvUrl() {
  final envApi = (Platform.environment['WATSAFE_API_URL'] ?? '').trim();
  if (envApi.isNotEmpty) {
    return envApi;
  }
  final envRelay = (Platform.environment['WATSAFE_RELAY_URL'] ?? '').trim();
  if (envRelay.isNotEmpty) {
    return envRelay;
  }
  try {
    final runtimeFile = File('.watsafe-runtime/relay_endpoint.json');
    if (runtimeFile.existsSync()) {
      final decoded = jsonDecode(runtimeFile.readAsStringSync());
      if (decoded is Map) {
        final url = (decoded['relayEndpointUrl'] as String? ?? '').trim();
        if (url.isNotEmpty) {
          return url;
        }
      }
    }
  } catch (_) {
    // Ignore when running inside a restricted mobile/desktop sandbox container.
  }
  return null;
}
