import 'package:flutter_test/flutter_test.dart';
import 'package:watsafe/services/relay_config.dart';

void main() {
  group('RelayConfig development defaults', () {
    test('loopback relay is used only when desktop development opts in', () {
      expect(RelayConfig.resolveDefaultRelayUrl(), isEmpty);
      expect(
        RelayConfig.resolveDefaultRelayUrl(allowLocalDevelopment: true),
        RelayConfig.localDevelopmentRelayUrl,
      );
    });

    test('browser companion routes use their own origin as the relay', () {
      final origin = Uri.parse('https://watsafe.example.org/pair?code=ABC123');
      expect(
        RelayConfig.resolveDefaultRelayUrl(browserOrigin: origin),
        'https://watsafe.example.org',
      );
    });

    test('standalone hosted web apps do not guess that their static host is a relay', () {
      final origin = Uri.parse('https://static.example.org/app/');
      expect(RelayConfig.resolveDefaultRelayUrl(browserOrigin: origin), isEmpty);
    });
  });
}
