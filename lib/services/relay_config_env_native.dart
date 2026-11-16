import 'dart:convert';
import 'dart:io';

bool _isEphemeralTunnelHost(String host) {
  final lower = host.toLowerCase();
  return lower.endsWith('.trycloudflare.com') ||
      lower.endsWith('.lhr.life') ||
      lower.endsWith('.localhost.run') ||
      lower.endsWith('.ngrok-free.app') ||
      lower.endsWith('.ngrok-free.dev') ||
      lower.endsWith('.ngrok.io');
}

bool _isPermanentHttps(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.startsWith('https://')) {
    return false;
  }
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || parsed.host.isEmpty) {
    return false;
  }
  return !_isEphemeralTunnelHost(parsed.host);
}

List<File> _permanentConfigCandidates() {
  final home =
      (Platform.environment['HOME'] ??
              Platform.environment['USERPROFILE'] ??
              '')
          .trim();
  return <File>[
    if (home.isNotEmpty) File('$home/.watsafe/relay_service.json'),
    if (home.isNotEmpty && Platform.isMacOS)
      File('$home/Library/Application Support/dev.watsafe/relay_service.json'),
    File('config/relay_service.json'),
  ];
}

String? readPersistedPermanentRelayUrl() {
  final envPub = (Platform.environment['WATSAFE_PUBLIC_URL'] ?? '').trim();
  if (_isPermanentHttps(envPub)) {
    return envPub.endsWith('/')
        ? envPub.substring(0, envPub.length - 1)
        : envPub;
  }
  for (final file in _permanentConfigCandidates()) {
    try {
      if (!file.existsSync()) continue;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) {
        final raw = (decoded['permanentRelayUrl'] as String? ?? '').trim();
        if (_isPermanentHttps(raw)) {
          return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
        }
      }
    } catch (_) {}
  }
  return null;
}

Future<void> writePersistedPermanentRelayUrl(String? url) async {
  final cleaned = (url ?? '').trim();
  final normalized = cleaned.endsWith('/')
      ? cleaned.substring(0, cleaned.length - 1)
      : cleaned;
  final home =
      (Platform.environment['HOME'] ??
              Platform.environment['USERPROFILE'] ??
              '')
          .trim();
  final targets = <File>[
    if (home.isNotEmpty) File('$home/.watsafe/relay_service.json'),
    if (home.isNotEmpty && Platform.isMacOS)
      File('$home/Library/Application Support/dev.watsafe/relay_service.json'),
  ];
  final payload = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
    'permanentRelayUrl': normalized,
    'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
  });
  for (final target in targets) {
    try {
      await target.parent.create(recursive: true);
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsString(payload, flush: true);
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', <String>['600', tmp.path]);
        } catch (_) {}
      }
      await tmp.rename(target.path);
    } catch (_) {}
  }
}

bool _isLauncherRuntimeStillActive() {
  try {
    final stateFile = File('.watsafe-runtime/launcher_state.json');
    if (!stateFile.existsSync()) return false;
    final decoded = jsonDecode(stateFile.readAsStringSync());
    if (decoded is! Map) return false;
    final pids = decoded['ownedPids'];
    if (pids is! List || pids.isEmpty) return false;
    if (Platform.isWindows) return true;
    for (final rawPid in pids) {
      if (rawPid is int && rawPid > 0) {
        final check = Process.runSync('kill', <String>['-0', '$rawPid']);
        if (check.exitCode == 0) {
          return true;
        }
      }
    }
    return false;
  } catch (_) {
    return false;
  }
}

String? readRuntimeRelayEnvUrl() {
  final envApi = (Platform.environment['WATSAFE_API_URL'] ?? '').trim();
  if (envApi.isNotEmpty) {
    return envApi;
  }
  final envRelay = (Platform.environment['WATSAFE_RELAY_URL'] ?? '').trim();
  if (envRelay.isNotEmpty) {
    return envRelay;
  }
  final permanent = readPersistedPermanentRelayUrl();
  if (permanent != null && permanent.isNotEmpty) {
    return permanent;
  }
  final envPub = (Platform.environment['WATSAFE_PUBLIC_URL'] ?? '').trim();
  if (envPub.isNotEmpty) {
    return envPub;
  }
  try {
    final runtimeFile = File('.watsafe-runtime/relay_endpoint.json');
    if (runtimeFile.existsSync()) {
      final decoded = jsonDecode(runtimeFile.readAsStringSync());
      if (decoded is Map) {
        final url = (decoded['relayEndpointUrl'] as String? ?? '').trim();
        if (url.isNotEmpty) {
          final parsed = Uri.tryParse(url);
          final isEphemeral =
              parsed != null && _isEphemeralTunnelHost(parsed.host);
          if (!isEphemeral || _isLauncherRuntimeStillActive()) {
            return url;
          }
        }
      }
    }
  } catch (_) {
    // Ignore when running inside a restricted mobile/desktop sandbox container.
  }
  return null;
}
