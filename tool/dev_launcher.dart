import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:watsafe/services/relay_config.dart';

/// Single-command WATSafe launcher (`./scripts/run_watsafe.sh`).
///
/// Supports three modes seamlessly:
/// 1. **Permanent Cloud HTTPS Service (Recommended one-time setup):**
///    Uses `WATSAFE_PUBLIC_URL`, `~/.watsafe/relay_service.json` (set via
///    `--save-permanent-url=https://...` or Settings), or `config/relay_service.json`
///    so the installed iPhone/Android Home Screen app has a permanent address forever.
/// 2. **Permanent Named Cloudflare Tunnel (`WATSAFE_CLOUDFLARE_TUNNEL_TOKEN` + `WATSAFE_PUBLIC_URL`):**
///    Starts the local durable relay (`FileRelayStore` / PostgreSQL) and binds your
///    permanent Cloudflare hostname to it across restarts.
/// 3. **Fallback Temporary Dev Tunnel (before permanent deployment is configured):**
///    Starts the local durable relay + valid-certificate HTTPS Quick Tunnel and prints
///    a clear dependency notice explaining the one-time permanent URL setup.
Future<void> main(List<String> args) async {
  final checkOnly = args.contains('--check-only');
  final relayOnly = args.contains('--relay-only');
  final noTunnel = args.contains('--no-tunnel');
  final requireHttps = args.contains('--require-https');
  final saveOnly = args.contains('--save-only');
  final clearPermanent = args.contains('--clear-permanent-url');
  final forceFlutterRun = args.contains('--flutter-run');
  final prepareMacosBundleOnly = args.contains('--prepare-macos-bundle');

  String? savePermanentArg;
  var preferredPort = 8787;
  String? deviceOverride;
  final extraFlutterArgs = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--check-only' ||
        arg == '--relay-only' ||
        arg == '--no-tunnel' ||
        arg == '--require-https' ||
        arg == '--save-only' ||
        arg == '--clear-permanent-url' ||
        arg == '--flutter-run' ||
        arg == '--prepare-macos-bundle') {
      continue;
    }
    if (arg.startsWith('--save-permanent-url=')) {
      savePermanentArg = arg.substring('--save-permanent-url='.length).trim();
      continue;
    }
    if (arg.startsWith('--port=')) {
      preferredPort =
          int.tryParse(arg.substring('--port='.length)) ?? preferredPort;
      continue;
    }
    if (arg == '-d' && i + 1 < args.length) {
      deviceOverride = args[++i];
      continue;
    }
    if (arg.startsWith('--device=')) {
      deviceOverride = arg.substring('--device='.length);
      continue;
    }
    extraFlutterArgs.add(arg);
  }

  if (clearPermanent) {
    await RelayConfig.savePermanentRelayUrl('');
    stdout.writeln(
      '[WATSafe] Cleared saved permanent relay URL from ~/.watsafe/relay_service.json.',
    );
    if (saveOnly) return;
  }

  if (savePermanentArg != null) {
    if (!RelayConfig.isPermanentHttpsUrl(savePermanentArg)) {
      stderr.writeln(
        '[WATSafe] ERROR: --save-permanent-url requires a stable https:// origin '
        '(not a temporary *.trycloudflare.com / *.lhr.life / *.ngrok URL).',
      );
      exitCode = 2;
      return;
    }
    final cleanedSave = _stripSlash(savePermanentArg);
    await RelayConfig.savePermanentRelayUrl(cleanedSave);
    stdout.writeln(
      '[WATSafe] Saved permanent HTTPS companion & relay address: $cleanedSave',
    );
    if (saveOnly) return;
  }

  final runtimeDir = Directory('.watsafe-runtime');
  if (!runtimeDir.existsSync()) {
    runtimeDir.createSync(recursive: true);
  }
  final stateFile = File('${runtimeDir.path}/launcher_state.json');
  final endpointFile = File('${runtimeDir.path}/relay_endpoint.json');
  final bundleStampFile = File('${runtimeDir.path}/macos_bundle_stamp.json');

  if (prepareMacosBundleOnly) {
    if (!Platform.isMacOS) {
      stdout.writeln('[WATSafe] --prepare-macos-bundle is macOS-only.');
      return;
    }
    final builtBundle = await _ensureReusableMacosAppBundle(
      stampFile: bundleStampFile,
    );
    if (builtBundle == null) {
      exitCode = 1;
      return;
    }
    stdout.writeln(
      '[WATSafe] Prepared reusable macOS app bundle (stable signature): ${builtBundle.path}',
    );
    return;
  }

  await _cleanupPreviousOwnedProcesses(stateFile);

  final ownedProcesses = <Process>[];
  var cleaningUp = false;

  final explicitEnvPublicUrl =
      (Platform.environment['WATSAFE_PUBLIC_URL'] ?? '').trim();
  final namedTunnelToken =
      (Platform.environment['WATSAFE_CLOUDFLARE_TUNNEL_TOKEN'] ?? '').trim();
  final persistedPermanentUrl = noTunnel && explicitEnvPublicUrl.isEmpty
      ? null
      : RelayConfig.persistedPermanentRelayUrl;

  final configuredPermanentUrl =
      explicitEnvPublicUrl.startsWith('https://') &&
          !RelayConfig.isEphemeralTunnelUrl(explicitEnvPublicUrl)
      ? _stripSlash(explicitEnvPublicUrl)
      : persistedPermanentUrl;

  var activeUrlIsPermanent = false;

  Future<void> cleanupOwned() async {
    if (cleaningUp) return;
    cleaningUp = true;
    for (final proc in ownedProcesses.reversed) {
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    for (final proc in ownedProcesses.reversed) {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
    try {
      if (stateFile.existsSync()) {
        stateFile.deleteSync();
      }
      if (!activeUrlIsPermanent && endpointFile.existsSync()) {
        endpointFile.deleteSync();
      }
      _cleanupSandboxRuntimeFiles(keepPermanentEndpoint: activeUrlIsPermanent);
    } catch (_) {}
  }

  StreamSubscription<ProcessSignal>? sigIntSub;
  StreamSubscription<ProcessSignal>? sigTermSub;
  sigIntSub = ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\n[WATSafe] Stopping owned processes...');
    await cleanupOwned();
    exit(0);
  });
  if (!Platform.isWindows) {
    sigTermSub = ProcessSignal.sigterm.watch().listen((_) async {
      await cleanupOwned();
      exit(0);
    });
  }

  try {
    String effectiveApiUrl;
    String? localRelayUrl;

    // Mode 1: Cloud-deployed permanent HTTPS relay (no local tunnel needed!)
    if (configuredPermanentUrl != null &&
        namedTunnelToken.isEmpty &&
        !noTunnel &&
        !relayOnly) {
      effectiveApiUrl = configuredPermanentUrl;
      activeUrlIsPermanent = true;
      stdout.writeln(
        '[WATSafe] Using permanent HTTPS companion & relay service: $effectiveApiUrl',
      );
      final remoteHealthy = await _waitForHealth(
        effectiveApiUrl,
        timeout: const Duration(seconds: 12),
      );
      if (remoteHealthy) {
        stdout.writeln(
          '[WATSafe] Permanent HTTPS service verified at $effectiveApiUrl/v1/health',
        );
      } else {
        stderr.writeln(
          '[WATSafe] WARNING: $effectiveApiUrl did not respond within 12s '
          '(cold-starting or offline). WATSafe will keep reconnecting automatically.',
        );
        if (requireHttps) {
          exitCode = 2;
          return;
        }
      }
    } else {
      // Mode 2 (Named Cloudflare Tunnel) or Mode 3 (Local durable relay + fallback Quick Tunnel)
      final relayPort = await _selectAvailablePort(preferredPort);
      if (relayPort != preferredPort) {
        stdout.writeln(
          '[WATSafe] Port $preferredPort is in use by another process; using free port $relayPort.',
        );
      }

      localRelayUrl = 'http://127.0.0.1:$relayPort';
      stdout.writeln(
        '[WATSafe] Starting durable local relay on $localRelayUrl ...',
      );

      final relayProc = await Process.start(
        Platform.resolvedExecutable,
        <String>['run', 'backend/server.dart', '$relayPort'],
        environment: <String, String>{
          ...Platform.environment,
          'WATSAFE_BIND_HOST': '127.0.0.1',
          'WATSAFE_PUBLIC_URL': ?configuredPermanentUrl,
        },
      );
      ownedProcesses.add(relayProc);
      relayProc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => stdout.writeln('[relay] $line'));
      relayProc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => stderr.writeln('[relay] $line'));

      final localReady = await _waitForHealth(
        localRelayUrl,
        timeout: const Duration(seconds: 15),
      );
      if (!localReady) {
        stderr.writeln(
          '[WATSafe] ERROR: Local relay failed to pass /v1/health on $localRelayUrl.',
        );
        exitCode = 1;
        return;
      }
      stdout.writeln(
        '[WATSafe] Local relay healthy at $localRelayUrl/v1/health',
      );

      effectiveApiUrl = localRelayUrl;

      if (configuredPermanentUrl != null &&
          namedTunnelToken.isNotEmpty &&
          !noTunnel) {
        stdout.writeln(
          '[WATSafe] Starting permanent Named Cloudflare Tunnel for $configuredPermanentUrl ...',
        );
        final namedOk = await _startNamedCloudflareTunnel(
          token: namedTunnelToken,
          publicHttpsUrl: configuredPermanentUrl,
          ownedProcesses: ownedProcesses,
        );
        if (namedOk) {
          effectiveApiUrl = configuredPermanentUrl;
          activeUrlIsPermanent = true;
          await _registerDynamicPublicOrigin(
            localRelayUrl: localRelayUrl,
            publicHttpsUrl: effectiveApiUrl,
          );
          stdout.writeln(
            '[WATSafe] Permanent Named Tunnel verified: $effectiveApiUrl',
          );
        } else {
          stderr.writeln(
            '[WATSafe] ERROR: Named Cloudflare Tunnel did not pass /v1/health at $configuredPermanentUrl.',
          );
          if (requireHttps) {
            exitCode = 2;
            return;
          }
        }
      } else if (explicitEnvPublicUrl.startsWith('https://')) {
        stdout.writeln(
          '[WATSafe] Using configured WATSAFE_PUBLIC_URL: $explicitEnvPublicUrl',
        );
        effectiveApiUrl = _stripSlash(explicitEnvPublicUrl);
        activeUrlIsPermanent = !RelayConfig.isEphemeralTunnelUrl(
          effectiveApiUrl,
        );
        await _registerDynamicPublicOrigin(
          localRelayUrl: localRelayUrl,
          publicHttpsUrl: effectiveApiUrl,
        );
      } else if (!noTunnel) {
        stdout.writeln(
          '[WATSafe] Starting valid-certificate HTTPS tunnel for phone QR & Web Push...',
        );
        final tunnelOutcome = await _startHttpsTunnel(
          localPort: relayPort,
          ownedProcesses: ownedProcesses,
        );
        if (tunnelOutcome != null) {
          stdout.writeln(
            '[WATSafe] Tunnel URL assigned (${tunnelOutcome.provider}): ${tunnelOutcome.httpsUrl}',
          );
          stdout.writeln(
            '[WATSafe] Verifying public HTTPS certificate and /v1/health...',
          );
          final tlsHealthy = await _waitForHealth(
            tunnelOutcome.httpsUrl,
            timeout: const Duration(seconds: 18),
          );
          if (tlsHealthy) {
            effectiveApiUrl = tunnelOutcome.httpsUrl;
            await _registerDynamicPublicOrigin(
              localRelayUrl: localRelayUrl,
              publicHttpsUrl: effectiveApiUrl,
            );
            stdout.writeln(
              '[WATSafe] Public HTTPS endpoint verified: $effectiveApiUrl',
            );
          } else {
            stderr.writeln(
              '[WATSafe] WARNING: Tunnel URL ${tunnelOutcome.httpsUrl} did not pass TLS /v1/health check in time.',
            );
            if (requireHttps) {
              exitCode = 2;
              return;
            }
          }
        } else {
          stderr.writeln(
            '[WATSafe] WARNING: Could not establish an automatic HTTPS tunnel.',
          );
          stderr.writeln(
            '          Desktop features work locally on $localRelayUrl, but iPhone Home Screen Web Push requires HTTPS.',
          );
          if (requireHttps) {
            exitCode = 2;
            return;
          }
        }
      }
    }

    final stateJson = const JsonEncoder.withIndent('  ')
        .convert(<String, Object?>{
          'startedAtUtc': DateTime.now().toUtc().toIso8601String(),
          'localRelayUrl': ?localRelayUrl,
          'effectiveApiUrl': effectiveApiUrl,
          'isPermanentHttps': activeUrlIsPermanent,
          'ownedPids': <int>[pid, ...ownedProcesses.map((p) => p.pid)],
        });
    final endpointJson = const JsonEncoder.withIndent('  ')
        .convert(<String, Object?>{
          'relayEndpointUrl': effectiveApiUrl,
          'isPermanentHttps': activeUrlIsPermanent,
          'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
        });
    stateFile.writeAsStringSync(stateJson);
    endpointFile.writeAsStringSync(endpointJson);
    _syncSandboxRuntimeFiles(stateJson: stateJson, endpointJson: endpointJson);
    if (activeUrlIsPermanent) {
      await RelayConfig.savePermanentRelayUrl(effectiveApiUrl);
    }

    stdout.writeln('');
    stdout.writeln('========================================================');
    stdout.writeln('  WATSafe Ready');
    stdout.writeln('  Active Relay URL    : $effectiveApiUrl');
    stdout.writeln('  Phone Companion URL : $effectiveApiUrl/companion');
    stdout.writeln(
      '  Address Mode        : ${activeUrlIsPermanent ? 'PERMANENT HTTPS (one-time install & pair)' : 'TEMPORARY / LOCAL DEV (one-time cloud deploy pending)'}',
    );
    if (localRelayUrl != null) {
      stdout.writeln('  Local Health        : $localRelayUrl/v1/health');
    }
    stdout.writeln('========================================================');
    if (!activeUrlIsPermanent && !checkOnly) {
      stdout.writeln(
        '[WATSafe] PERMANENT ADDRESS DEPENDENCY (One-time setup not yet completed):',
      );
      stdout.writeln(
        '          Temporary tunnels (*.trycloudflare.com) assign a new hostname on restart,',
      );
      stdout.writeln(
        '          which causes iOS Home Screen bookmarks pinned to an old tunnel to show Cloudflare 530.',
      );
      stdout.writeln(
        '          To give your iPhone Home Screen icon a permanent HTTPS address once and for all:',
      );
      stdout.writeln(
        '            1. Deploy `render.yaml` with `AIVEN_DATABASE_URL` set in Render environment secrets',
      );
      stdout.writeln(
        '               (or run a Named Cloudflare Tunnel against your local Mac relay)',
      );
      stdout.writeln(
        '            2. Verify & save once: dart run tool/verify_deployment.dart --phase=before-restart https://<your-render-service>.onrender.com',
      );
      stdout.writeln(
        '               (restart relay, then: dart run tool/verify_deployment.dart --phase=after-restart --save https://<your-render-service>.onrender.com)',
      );
    }
    stdout.writeln('');

    if (checkOnly) {
      final checkTarget = localRelayUrl ?? effectiveApiUrl;
      final qrOriginOk = await _verifyPairingQrOrigin(
        targetRelayUrl: checkTarget,
        expectedOrigin: effectiveApiUrl,
      );
      if (!qrOriginOk) {
        stderr.writeln(
          '[WATSafe] ERROR: /v1/pairing/initiate did not return expected origin $effectiveApiUrl.',
        );
        exitCode = 1;
        return;
      }
      stdout.writeln(
        '[WATSafe] Check-only verification succeeded (QR origin matches $effectiveApiUrl).',
      );
      return;
    }

    if (relayOnly) {
      stdout.writeln(
        '[WATSafe] Relay service running ($effectiveApiUrl). Press Ctrl+C to stop.',
      );
      await Completer<void>().future;
      return;
    }

    final targetDevice = deviceOverride ?? _defaultDesktopDevice();
    if (Platform.isMacOS &&
        targetDevice == 'macos' &&
        !forceFlutterRun &&
        extraFlutterArgs.isEmpty) {
      final appBundle = await _ensureReusableMacosAppBundle(
        stampFile: bundleStampFile,
      );
      if (appBundle != null) {
        stdout.writeln(
          '[WATSafe] Launching built macOS app without re-signing '
          '(preserves Keychain trust across launches; pass --flutter-run for hot reload): '
          '${appBundle.path}',
        );
        final openProc = await Process.start('/usr/bin/open', <String>[
          '-W',
          '--env',
          'WATSAFE_API_URL=$effectiveApiUrl',
          appBundle.path,
        ], mode: ProcessStartMode.inheritStdio);
        ownedProcesses.add(openProc);
        exitCode = await openProc.exitCode;
        return;
      }
    }

    final flutterCmd = Platform.isWindows ? 'flutter.bat' : 'flutter';
    final flutterArgs = <String>[
      'run',
      '-d',
      targetDevice,
      '--dart-define=WATSAFE_API_URL=$effectiveApiUrl',
      ...extraFlutterArgs,
    ];

    stdout.writeln(
      '[WATSafe] Launching WATSafe on "$targetDevice" -> $flutterCmd ${flutterArgs.join(' ')}',
    );
    final flutterProc = await Process.start(
      flutterCmd,
      flutterArgs,
      mode: ProcessStartMode.inheritStdio,
    );
    ownedProcesses.add(flutterProc);
    final flutterExit = await flutterProc.exitCode;
    exitCode = flutterExit;
  } finally {
    await sigIntSub.cancel();
    await sigTermSub?.cancel();
    await cleanupOwned();
  }
}

Directory? _macosSandboxRuntimeDir() {
  if (!Platform.isMacOS) return null;
  final home = (Platform.environment['HOME'] ?? '').trim();
  if (home.isEmpty || home.contains('/Library/Containers/')) return null;
  final containerData = Directory(
    '$home/Library/Containers/dev.watsafe.temp.watsafe/Data',
  );
  if (!containerData.existsSync()) return null;
  return Directory('${containerData.path}/.watsafe-runtime');
}

void _syncSandboxRuntimeFiles({
  required String stateJson,
  required String endpointJson,
}) {
  final dir = _macosSandboxRuntimeDir();
  if (dir == null) return;
  try {
    dir.createSync(recursive: true);
    File('${dir.path}/launcher_state.json').writeAsStringSync(stateJson);
    File('${dir.path}/relay_endpoint.json').writeAsStringSync(endpointJson);
  } catch (_) {}
}

void _cleanupSandboxRuntimeFiles({required bool keepPermanentEndpoint}) {
  final dir = _macosSandboxRuntimeDir();
  if (dir == null) return;
  try {
    final s = File('${dir.path}/launcher_state.json');
    if (s.existsSync()) s.deleteSync();
    if (!keepPermanentEndpoint) {
      final e = File('${dir.path}/relay_endpoint.json');
      if (e.existsSync()) e.deleteSync();
    }
  } catch (_) {}
}

DateTime _latestSourceModifiedUtc() {
  var latest = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  void checkFile(File f) {
    try {
      if (!f.existsSync()) return;
      final m = f.lastModifiedSync().toUtc();
      if (m.isAfter(latest)) latest = m;
    } catch (_) {}
  }

  checkFile(File('pubspec.yaml'));
  checkFile(File('pubspec.lock'));
  for (final dirPath in const <String>['lib', 'macos', 'assets']) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) continue;
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          final p = entity.path;
          if (p.contains('/Pods/') ||
              p.contains('/ephemeral/') ||
              p.endsWith('.DS_Store')) {
            continue;
          }
          checkFile(entity);
        }
      }
    } catch (_) {}
  }
  return latest;
}

Directory? _findUpToDateMacosBundle(File stampFile) {
  if (!stampFile.existsSync()) return null;
  try {
    final stamp = jsonDecode(stampFile.readAsStringSync());
    if (stamp is! Map) return null;
    final bundlePath = (stamp['bundlePath'] as String? ?? '').trim();
    final stampedExecMs = (stamp['executableModifiedEpochMs'] as num?)?.toInt();
    if (bundlePath.isEmpty || stampedExecMs == null) return null;
    final bundleDir = Directory(bundlePath);
    final execFile = File('${bundleDir.path}/Contents/MacOS/WATSafe');
    if (!bundleDir.existsSync() || !execFile.existsSync()) return null;
    final execModified = execFile.lastModifiedSync().toUtc();
    if ((execModified.millisecondsSinceEpoch - stampedExecMs).abs() > 2000) {
      // Bundle was modified outside dev_launcher (e.g., an ad-hoc `flutter run`
      // with a temporary `--dart-define`); rebuild cleanly once.
      return null;
    }
    final latestSource = _latestSourceModifiedUtc();
    if (latestSource.isAfter(execModified)) {
      return null;
    }
    return bundleDir;
  } catch (_) {
    return null;
  }
}

Future<Directory?> _ensureReusableMacosAppBundle({
  required File stampFile,
}) async {
  final existing = _findUpToDateMacosBundle(stampFile);
  if (existing != null) {
    return existing;
  }
  stdout.writeln(
    '[WATSafe] Building WATSafe.app once (subsequent launches will reuse this '
    'signed bundle without re-signing or prompting for Keychain access)...',
  );
  final buildProc = await Process.start('flutter', const <String>[
    'build',
    'macos',
    '--debug',
  ], mode: ProcessStartMode.inheritStdio);
  final code = await buildProc.exitCode;
  if (code != 0) {
    return null;
  }
  final debugBundle = Directory('build/macos/Build/Products/Debug/WATSafe.app');
  final execFile = File('${debugBundle.path}/Contents/MacOS/WATSafe');
  if (!debugBundle.existsSync() || !execFile.existsSync()) {
    return null;
  }
  try {
    stampFile.parent.createSync(recursive: true);
    stampFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'bundlePath': debugBundle.path,
        'executableModifiedEpochMs': execFile
            .lastModifiedSync()
            .toUtc()
            .millisecondsSinceEpoch,
        'builtAtUtc': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  } catch (_) {}
  return debugBundle;
}

String _defaultDesktopDevice() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  return 'linux';
}

String _stripSlash(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;

Future<void> _cleanupPreviousOwnedProcesses(File stateFile) async {
  if (!stateFile.existsSync()) return;
  try {
    final decoded = jsonDecode(stateFile.readAsStringSync());
    if (decoded is Map && decoded['ownedPids'] is List) {
      for (final rawPid in decoded['ownedPids'] as List) {
        if (rawPid is int && rawPid > 0 && rawPid != pid) {
          try {
            Process.killPid(rawPid, ProcessSignal.sigterm);
          } catch (_) {}
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    stateFile.deleteSync();
  } catch (_) {}
}

Future<int> _selectAvailablePort(int preferred) async {
  try {
    final probe = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      preferred,
    );
    final p = probe.port;
    await probe.close();
    return p;
  } on SocketException {
    final fallback = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = fallback.port;
    await fallback.close();
    return p;
  }
}

Future<bool> _waitForHealth(String baseUrl, {required Duration timeout}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client
          .getUrl(Uri.parse('$baseUrl/v1/health'))
          .timeout(const Duration(seconds: 5));
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Macintosh; WATSafeHealthCheck/1.0)',
      );
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode == HttpStatus.ok &&
          resp.headers.value('x-watsafe-companion') == '1') {
        final raw = await utf8.decoder.bind(resp).join();
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['status'] == 'ok') {
          if (decoded['storageDurable'] == false) {
            final warn =
                (decoded['storageDurabilityWarning'] as String?)?.trim() ??
                'Relay storage at $baseUrl is not durable across restarts.';
            stderr.writeln('[WATSafe] WARNING: $warn');
          }
          return true;
        }
      } else {
        await resp.drain<void>();
      }
    } catch (_) {
      // Retry until deadline
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 450));
  }
  return false;
}

Future<void> _registerDynamicPublicOrigin({
  required String localRelayUrl,
  required String publicHttpsUrl,
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('$localRelayUrl/v1/admin/public-url'),
    );
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(<String, Object?>{'publicUrl': publicHttpsUrl}));
    final resp = await req.close();
    await resp.drain<void>();
  } finally {
    client.close(force: true);
  }
}

Future<bool> _verifyPairingQrOrigin({
  required String targetRelayUrl,
  required String expectedOrigin,
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('$targetRelayUrl/v1/pairing/initiate'),
    );
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode(<String, Object?>{
        'hostDisplayName': 'Launcher Smoke Check',
        'relayUrl': expectedOrigin,
      }),
    );
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) {
      await resp.drain<void>();
      return false;
    }
    final body = jsonDecode(await utf8.decoder.bind(resp).join());
    if (body is! Map) return false;
    final pairingUrl = body['pairingUrl'] as String? ?? '';
    final hostToken = body['hostToken'] as String? ?? '';
    if (hostToken.isNotEmpty) {
      final revokeReq = await client.postUrl(
        Uri.parse('$targetRelayUrl/v1/pairing/session/revoke'),
      );
      revokeReq.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $hostToken',
      );
      revokeReq.headers.contentType = ContentType.json;
      revokeReq.write('{}');
      final revokeResp = await revokeReq.close();
      await revokeResp.drain<void>();
    }
    return pairingUrl.startsWith('$expectedOrigin/pair?');
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<bool> _startNamedCloudflareTunnel({
  required String token,
  required String publicHttpsUrl,
  required List<Process> ownedProcesses,
}) async {
  final cloudflaredBin = await _resolveBinary('cloudflared');
  if (cloudflaredBin == null) {
    stderr.writeln(
      '[WATSafe] ERROR: `cloudflared` binary not found for WATSAFE_CLOUDFLARE_TUNNEL_TOKEN.',
    );
    return false;
  }
  try {
    final proc = await Process.start(cloudflaredBin, <String>[
      'tunnel',
      '--no-autoupdate',
      '--protocol',
      'http2',
      'run',
      '--token',
      token,
    ]);
    ownedProcesses.add(proc);
    return await _waitForHealth(
      publicHttpsUrl,
      timeout: const Duration(seconds: 20),
    );
  } catch (_) {
    return false;
  }
}

class _TunnelResult {
  const _TunnelResult({required this.provider, required this.httpsUrl});
  final String provider;
  final String httpsUrl;
}

Future<String?> _resolveBinary(String binary) async {
  final extraDirs = <String>['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'];
  for (final dir in extraDirs) {
    final candidate = File('$dir/$binary');
    if (candidate.existsSync()) {
      return candidate.path;
    }
  }
  try {
    final res = await Process.run(
      Platform.isWindows ? 'where' : 'which',
      <String>[binary],
    );
    if (res.exitCode == 0) {
      final path = (res.stdout as String).trim().split('\n').first.trim();
      if (path.isNotEmpty) return path;
    }
  } catch (_) {}
  return null;
}

Future<_TunnelResult?> _startHttpsTunnel({
  required int localPort,
  required List<Process> ownedProcesses,
}) async {
  // 1. Prefer cloudflared Quick Tunnel (HTTPS/QUIC over port 443, valid cert, no interstitial)
  final cloudflaredBin = await _resolveBinary('cloudflared');
  if (cloudflaredBin != null) {
    final res = await _spawnAndExtractHttpsUrl(
      provider: 'cloudflared',
      executable: cloudflaredBin,
      arguments: <String>[
        'tunnel',
        '--url',
        'http://127.0.0.1:$localPort',
        '--protocol',
        'http2',
        '--no-autoupdate',
      ],
      urlPattern: RegExp(r'https://[a-zA-Z0-9-]+\.trycloudflare\.com'),
      readyLogSubstring: 'Registered tunnel connection',
      postReadySettle: const Duration(seconds: 2),
      ownedProcesses: ownedProcesses,
    );
    if (res != null) return res;
  }

  // 2. Try ngrok if installed and authenticated
  final ngrokBin = await _resolveBinary('ngrok');
  if (ngrokBin != null) {
    final res = await _spawnAndExtractHttpsUrl(
      provider: 'ngrok',
      executable: ngrokBin,
      arguments: <String>['http', '$localPort', '--log=stdout'],
      urlPattern: RegExp(
        r'https://[a-zA-Z0-9.-]+\.ngrok(?:-free)?\.(?:app|dev|io)',
      ),
      ownedProcesses: ownedProcesses,
    );
    if (res != null) return res;
  }

  // 3. Fallback: standard OpenSSH reverse HTTPS tunnel via localhost.run
  final sshBin = await _resolveBinary('ssh');
  if (sshBin != null) {
    final res = await _spawnAndExtractHttpsUrl(
      provider: 'localhost.run (ssh)',
      executable: sshBin,
      arguments: <String>[
        '-T',
        '-o',
        'StrictHostKeyChecking=accept-new',
        '-o',
        'BatchMode=yes',
        '-o',
        'ConnectTimeout=10',
        '-o',
        'ExitOnForwardFailure=yes',
        '-o',
        'ServerAliveInterval=30',
        '-R',
        '80:127.0.0.1:$localPort',
        'nokey@localhost.run',
      ],
      urlPattern: RegExp(
        r'https://[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.(?:lhr\.life|localhost\.run)',
      ),
      excludeHostSubstrings: const <String>[
        'admin.localhost.run',
        'docs.localhost.run',
        'twitter.com',
      ],
      ownedProcesses: ownedProcesses,
    );
    if (res != null) return res;
  }

  return null;
}

Future<_TunnelResult?> _spawnAndExtractHttpsUrl({
  required String provider,
  required String executable,
  required List<String> arguments,
  required RegExp urlPattern,
  required List<Process> ownedProcesses,
  List<String> excludeHostSubstrings = const <String>[],
  String? readyLogSubstring,
  Duration postReadySettle = Duration.zero,
}) async {
  Process proc;
  try {
    proc = await Process.start(executable, arguments);
  } catch (_) {
    return null;
  }
  ownedProcesses.add(proc);

  final completer = Completer<String?>();
  String? pendingUrl;
  var sawReadySignal = readyLogSubstring == null;

  void maybeComplete() {
    if (completer.isCompleted) return;
    if (pendingUrl != null && sawReadySignal) {
      completer.complete(pendingUrl);
    }
  }

  void inspectLine(String line) {
    if (completer.isCompleted) return;
    if (readyLogSubstring != null && line.contains(readyLogSubstring)) {
      sawReadySignal = true;
    }
    if (pendingUrl == null) {
      for (final match in urlPattern.allMatches(line)) {
        final candidate = match.group(0)!;
        final blocked = excludeHostSubstrings.any(
          (sub) => candidate.toLowerCase().contains(sub.toLowerCase()),
        );
        if (!blocked) {
          pendingUrl = _stripSlash(candidate);
          break;
        }
      }
    }
    maybeComplete();
  }

  final outSub = proc.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(inspectLine);
  final errSub = proc.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(inspectLine);

  unawaited(
    proc.exitCode.then((_) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }),
  );

  String? foundUrl;
  try {
    foundUrl = await completer.future.timeout(
      const Duration(seconds: 16),
      onTimeout: () => null,
    );
  } finally {
    if (foundUrl == null) {
      await outSub.cancel();
      await errSub.cancel();
      ownedProcesses.remove(proc);
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
  }

  if (foundUrl == null) {
    return null;
  }
  if (postReadySettle > Duration.zero) {
    await Future<void>.delayed(postReadySettle);
  }
  return _TunnelResult(provider: provider, httpsUrl: foundUrl);
}
