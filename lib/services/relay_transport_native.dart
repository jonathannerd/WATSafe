import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'local_storage_service.dart';
import 'relay_transport.dart';

Future<RelayHttpResponse> sendRelayJsonRequest({
  required String method,
  required String url,
  Map<String, Object?>? body,
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final client = HttpClient();
  client.connectionTimeout = timeout;
  try {
    final uri = Uri.parse(url);
    final request = await client.openUrl(method, uri).timeout(timeout);
    request.headers.contentType = ContentType.json;
    if (headers != null) {
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
    }
    if (body != null) {
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(timeout);
    final responseBody = await utf8.decoder
        .bind(response)
        .join()
        .timeout(timeout);
    return RelayHttpResponse(
      statusCode: response.statusCode,
      body: responseBody,
      errorSummary: response.statusCode >= 200 && response.statusCode < 300
          ? null
          : 'HTTP ${response.statusCode}',
    );
  } catch (error) {
    return RelayHttpResponse(statusCode: 0, body: '', errorSummary: '$error');
  } finally {
    client.close(force: true);
  }
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

Future<void> writePersistedJson(
  String filename,
  String content, {
  Object? storageDirectory,
}) async {
  final dir = await _resolveStorageDir(storageDirectory);
  final file = File('${dir.path}${Platform.pathSeparator}$filename');
  await file.parent.create(recursive: true);
  await file.writeAsString(content, flush: true);
}
