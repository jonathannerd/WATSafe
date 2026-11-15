export 'relay_transport_native.dart'
    if (dart.library.js_interop) 'relay_transport_web.dart';

class RelayHttpResponse {
  const RelayHttpResponse({
    required this.statusCode,
    required this.body,
    this.errorSummary,
  });

  final int statusCode;
  final String body;
  final String? errorSummary;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}
