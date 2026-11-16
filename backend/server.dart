import 'dart:io';

import 'package:watsafe/relay/relay_server.dart';

export 'package:watsafe/relay/pwa_assets.dart';
export 'package:watsafe/relay/relay_server.dart';
export 'package:watsafe/relay/web_push.dart';

Future<void> main(List<String> args) async {
  final envPort = int.tryParse(Platform.environment['PORT'] ?? '');
  final port = args.isNotEmpty
      ? (int.tryParse(args.first) ?? envPort ?? 8787)
      : (envPort ?? 8787);
  final bindHostRaw = (Platform.environment['WATSAFE_BIND_HOST'] ?? '0.0.0.0')
      .trim();
  final bindAddress =
      InternetAddress.tryParse(bindHostRaw) ?? InternetAddress.anyIPv4;

  final server = WatSafeRelayServer.fromEnvironment();
  final boundPort = await server.start(address: bindAddress, port: port);
  stdout.writeln(
    'WATSafe Relay listening on http://${bindAddress.address}:$boundPort '
    '(store=${server.storageBackend}, durable=${server.isStorageDurable}, push=${server.pushProvider.providerSummary})',
  );
  final durabilityWarning = server.storageDurabilityWarning;
  if (durabilityWarning != null) {
    stderr.writeln('[WATSafe WARNING] $durabilityWarning');
  }
}
