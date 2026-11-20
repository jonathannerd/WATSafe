import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:watsafe/services/pin_security_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('Benchmark production PIN KDF on this physical device', () async {
    final samples = await PinSecurityService.benchmarkPbkdf2(
      iterations: PinSecurityService.productionPbkdf2Iterations,
      samples: 3,
    );
    final microseconds = samples
        .map((sample) => sample.inMicroseconds)
        .toList(growable: false);
    final average = microseconds.reduce((a, b) => a + b) / microseconds.length;

    // Printed values are captured in the integration-test output. This is a
    // measurement, not a timing assertion: hardware varies by platform/device.
    // ignore: avoid_print
    print(
      'WATSAFE_PIN_KDF_BENCHMARK '
      'iterations=${PinSecurityService.productionPbkdf2Iterations} '
      'samples_us=$microseconds average_us=${average.round()}',
    );
    expect(samples, hasLength(3));
  });
}
