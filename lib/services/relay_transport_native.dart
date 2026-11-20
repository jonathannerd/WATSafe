import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'local_storage_service.dart';
import 'relay_transport.dart';

const MethodChannel _secureStorageChannel = MethodChannel(
  'dev.watsafe/secure_storage',
);

Future<RelayHttpResponse> sendRelayJsonRequest({
  required String method,
  required String url,
  Map<String, Object?>? body,
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 3),
}) {
  return Zone.root.run<Future<RelayHttpResponse>>(() async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    final timedOut = Completer<RelayHttpResponse>();
    final watchdog = Zone.root.createTimer(timeout, () {
      if (!timedOut.isCompleted) {
        timedOut.complete(
          const RelayHttpResponse(
            statusCode: 0,
            body: '',
            errorSummary: 'Request timed out',
          ),
        );
      }
      client.close(force: true);
    });
    try {
      return await Future.any<RelayHttpResponse>(<Future<RelayHttpResponse>>[
        timedOut.future,
        () async {
          final uri = Uri.parse(url);
          final request = await client.openUrl(method, uri);
          request.headers.contentType = ContentType.json;
          if (headers != null) {
            for (final entry in headers.entries) {
              request.headers.set(entry.key, entry.value);
            }
          }
          if (body != null) {
            request.write(jsonEncode(body));
          }
          final response = await request.close();
          final responseHeaders = <String, String>{};
          response.headers.forEach((name, values) {
            if (values.isNotEmpty) {
              responseHeaders[name.toLowerCase()] = values.join(', ');
            }
          });
          final responseBody = await utf8.decoder.bind(response).join();
          return RelayHttpResponse(
            statusCode: response.statusCode,
            body: responseBody,
            headers: responseHeaders,
            errorSummary:
                response.statusCode >= 200 && response.statusCode < 300
                ? null
                : 'HTTP ${response.statusCode}',
          );
        }(),
      ]);
    } catch (error) {
      return RelayHttpResponse(statusCode: 0, body: '', errorSummary: '$error');
    } finally {
      watchdog.cancel();
      client.close(force: true);
    }
  });
}

Future<Directory> _resolveStorageDir(Object? storageDirectory) async {
  if (storageDirectory is Directory) {
    return storageDirectory;
  }
  if (storageDirectory is String && storageDirectory.trim().isNotEmpty) {
    return Directory(storageDirectory.trim());
  }
  return LocalAppDataPaths.resolveDirectory();
}

Future<void> _tightenPosixPermissions(File file) async {
  if (Platform.isMacOS || Platform.isLinux) {
    try {
      await Process.run('chmod', <String>['600', file.path]);
    } catch (_) {
      // Best-effort permission tightening
    }
  }
}

Future<String?> readPersistedJson(
  String filename, {
  Object? storageDirectory,
}) async {
  final dir = await _resolveStorageDir(storageDirectory);
  final file = File('${dir.path}${Platform.pathSeparator}$filename');
  if (!await file.exists()) {
    return null;
  }
  return file.readAsString();
}

int _atomicWriteSeq = 0;
final Set<String> _tightenedPaths = <String>{};

Future<void> writePersistedJson(
  String filename,
  String content, {
  Object? storageDirectory,
}) async {
  final dir = await _resolveStorageDir(storageDirectory);
  await dir.create(recursive: true);
  final file = File('${dir.path}${Platform.pathSeparator}$filename');
  final tmp = File(
    '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}_${++_atomicWriteSeq}',
  );
  await tmp.writeAsString(content, flush: true);
  if (!_tightenedPaths.contains(file.path)) {
    await _tightenPosixPermissions(tmp);
    await tmp.rename(file.path);
    await _tightenPosixPermissions(file);
    _tightenedPaths.add(file.path);
  } else {
    await tmp.rename(file.path);
  }
}

Future<String?> readSecurePersistedSecret(
  String key, {
  Object? storageDirectory,
}) async {
  if (storageDirectory == null && Platform.isMacOS) {
    try {
      final value = await _secureStorageChannel.invokeMethod<String>(
        'readSecureSecret',
        <String, Object?>{'key': key},
      );
      if (value != null && value.trim().isNotEmpty) {
        return value;
      }
    } catch (_) {
      // Fall back to restricted 0600 file when running outside Flutter engine (e.g. dart test)
    }
  }
  return readPersistedJson(
    'watsafe_secure_$key.json',
    storageDirectory: storageDirectory,
  );
}

Future<void> writeSecurePersistedSecret(
  String key,
  String content, {
  Object? storageDirectory,
}) async {
  if (storageDirectory == null && Platform.isMacOS) {
    try {
      await _secureStorageChannel.invokeMethod<String>(
        'writeSecureSecret',
        <String, Object?>{'key': key, 'payload': content},
      );
    } catch (_) {
      // Fall through to ensure restricted 0600 local backup exists as well
    }
  }
  await writePersistedJson(
    'watsafe_secure_$key.json',
    content,
    storageDirectory: storageDirectory,
  );
}

Future<void> deleteSecurePersistedSecret(
  String key, {
  Object? storageDirectory,
}) async {
  if (storageDirectory == null && Platform.isMacOS) {
    try {
      await _secureStorageChannel.invokeMethod<void>(
        'deleteSecureSecret',
        <String, Object?>{'key': key},
      );
    } catch (_) {
      // Ignore outside Flutter engine
    }
  }
  final dir = await _resolveStorageDir(storageDirectory);
  final file = File(
    '${dir.path}${Platform.pathSeparator}watsafe_secure_$key.json',
  );
  if (await file.exists()) {
    await file.delete();
  }
}
