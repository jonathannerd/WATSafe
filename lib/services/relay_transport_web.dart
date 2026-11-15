import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'relay_transport.dart';

Future<RelayHttpResponse> sendRelayJsonRequest({
  required String method,
  required String url,
  Map<String, Object?>? body,
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 3),
}) async {
  try {
    final requestHeaders = web.Headers();
    requestHeaders.set('Content-Type', 'application/json');
    if (headers != null) {
      for (final entry in headers.entries) {
        requestHeaders.set(entry.key, entry.value);
      }
    }
    final init = body != null
        ? web.RequestInit(
            method: method,
            headers: requestHeaders,
            body: jsonEncode(body).toJS,
          )
        : web.RequestInit(method: method, headers: requestHeaders);

    final response = await web.window
        .fetch(url.toJS, init)
        .toDart
        .timeout(timeout);
    final textJs = await response.text().toDart.timeout(timeout);
    final text = textJs.toDart;
    return RelayHttpResponse(
      statusCode: response.status,
      body: text,
      errorSummary: response.status >= 200 && response.status < 300
          ? null
          : 'HTTP ${response.status}',
    );
  } catch (error) {
    return RelayHttpResponse(statusCode: 0, body: '', errorSummary: '$error');
  }
}

Future<String?> readPersistedJson(
  String filename, {
  Object? storageDirectory,
}) async {
  return web.window.localStorage.getItem('watsafe.file.$filename');
}

Future<void> writePersistedJson(
  String filename,
  String content, {
  Object? storageDirectory,
}) async {
  web.window.localStorage.setItem('watsafe.file.$filename', content);
}
