import 'dart:io';

import 'package:watsafe/relay/web_push.dart';

void main() {
  final keys = VapidKeyPair.generate();
  stdout.writeln(
    '# Set these as secret environment variables on your HTTPS relay host:',
  );
  stdout.writeln('VAPID_SUBJECT=mailto:alerts@watsafe.app');
  stdout.writeln('VAPID_PUBLIC_KEY=${keys.publicKeyBase64Url}');
  stdout.writeln('VAPID_PRIVATE_KEY=${keys.privateKeyBase64Url}');
}
