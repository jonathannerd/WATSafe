import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Single-command WATSafe development launcher (`./scripts/run_watsafe.sh`).
///
/// Orchestrates:
/// 1. Port readiness & cleanup of any stale launcher-owned child processes
/// 2. Local WATSafe relay startup (`backend/server.dart`) + `/v1/health` verification
/// 3. Valid-certificate public HTTPS tunnel (`cloudflared` -> `ngrok` -> `ssh localhost.run`)
///    so iPhone 13 & Android phones can scan QR codes over real HTTPS and register Web Push
/// 4. Public TLS `/v1/health` verification + dynamic QR origin registration
/// 5. Launching WATSafe (`flutter run -d macos --dart-define=WATSAFE_API_URL=...`)
/// 6. Deterministic cleanup of all owned processes on exit / Ctrl-C.
Future<void> main(List<String> args) async {
  final checkOnly = args.contains('--check-only');
  final relayOnly = args.contains('--relay-only');
  final noTunnel = args.contains('--no-tunnel');
  final requireHttps = args.contains('--require-https');

  var preferredPort = 8787;
  String? deviceOverride;
  final extraFlutterArgs = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--check-only' ||
        arg == '--relay-only' ||
        arg == '--no-tunnel' ||
        arg == '--require-https') {
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

  final runtimeDir = Directory('.watsafe-runtime');
  if (!runtimeDir.existsSync()) {
    runtimeDir.createSync(recursive: true);
  }
  final stateFile = File('${runtimeDir.path}/launcher_state.json');
  final endpointFile = File('${runtimeDir.path}/relay_endpoint.json');

  await _cleanupPreviousOwnedProcesses(stateFile);

  final ownedProcesses = <Process>[];
  var cleaningUp = false;

  final explicitPublicUrl =
      (Platform.environment['WATSAFE_PUBLIC_URL'] ?? '').trim();

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
      if (explicitPublicUrl.isEmpty && endpointFile.existsSync()) {
        endpointFile.deleteSync();
      }
    } catch (_) {}
  }

  StreamSubscription<ProcessSignal>? sigIntSub;
  StreamSubscription<ProcessSignal>? sigTermSub;
  sigIntSub = ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\n[WATSafe] Stopping local relay and tunnel...');
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
    // 1. Select a clean port (use preferredPort if free, else pick an open port).
    final relayPort = await _selectAvailablePort(preferredPort);
    if (relayPort != preferredPort) {
      stdout.writeln(
        '[WATSafe] Port $preferredPort is in use by another process; using free port $relayPort.',
      );
    }

    final localRelayUrl = 'http://127.0.0.1:$relayPort';
    stdout.writeln('[WATSafe] Starting local relay on $localRelayUrl ...');

    final relayProc = await Process.start(
      Platform.resolvedExecutable,
      <String>['run', 'backend/server.dart', '$relayPort'],
      environment: <String, String>{
        ...Platform.environment,
        'WATSAFE_BIND_HOST': '127.0.0.1',
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
    stdout.writeln('[WATSafe] Local relay healthy at $localRelayUrl/v1/health');

    // 2. Establish valid-certificate HTTPS URL for iPhone / Android QR pairing & Web Push.
    String effectiveApiUrl = localRelayUrl;

    if (explicitPublicUrl.startsWith('https://')) {
      stdout.writeln(
        '[WATSafe] Using configured WATSAFE_PUBLIC_URL: $explicitPublicUrl',
      );
      effectiveApiUrl = _stripSlash(explicitPublicUrl);
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
        stderr.writeln(
          '          Tip: Check internet access, install `brew install cloudflared`, or set WATSAFE_PUBLIC_URL to your deployed HTTPS relay.',
        );
        if (requireHttps) {
          exitCode = 2;
          return;
        }
      }
    }

    // Persist launcher state & active endpoint so normal `WATSafe.app` launches can also discover it.
    stateFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'startedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'localRelayUrl': localRelayUrl,
        'effectiveApiUrl': effectiveApiUrl,
        'ownedPids': ownedProcesses.map((p) => p.pid).toList(),
      }),
    );
    endpointFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'relayEndpointUrl': effectiveApiUrl,
        'updatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      }),
    );

    stdout.writeln('');
    stdout.writeln('========================================================');
    stdout.writeln('  WATSafe Ready');
    stdout.writeln('  Active Relay URL : $effectiveApiUrl');
    stdout.writeln('  Local Health     : $localRelayUrl/v1/health');
    stdout.writeln('========================================================');
    stdout.writeln('');

    if (checkOnly) {
      // Verify QR initiation returns the exact effectiveApiUrl!
      final qrOriginOk = await _verifyPairingQrOrigin(
        localRelayUrl: localRelayUrl,
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
        '[WATSafe] Relay + HTTPS tunnel running. Press Ctrl+C to stop.',
      );
      await Completer<void>().future;
      return;
    }

    // 3. Launch Flutter desktop app with WATSAFE_API_URL injected!
    final targetDevice = deviceOverride ?? _defaultDesktopDevice();
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

Future<bool> _waitForHealth(
  String baseUrl, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client
          .getUrl(Uri.parse('$baseUrl/v1/health'))
          .timeout(const Duration(seconds: 5));
      req.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Macintosh; WATSafeHealthCheck/1.0)',
      );
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode == HttpStatus.ok) {
        final raw = await utf8.decoder.bind(resp).join();
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['status'] == 'ok') {
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
  required String localRelayUrl,
  required String expectedOrigin,
}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(
      Uri.parse('$localRelayUrl/v1/pairing/initiate'),
    );
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode(<String, Object?>{'hostDisplayName': 'Launcher Smoke Check'}),
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
        Uri.parse('$localRelayUrl/v1/pairing/session/revoke'),
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

class _TunnelResult {
  const _TunnelResult({required this.provider, required this.httpsUrl});
  final String provider;
  final String httpsUrl;
}

Future<String?> _resolveBinary(String binary) async {
  final extraDirs = <String>[
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '/usr/bin',
  ];
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
