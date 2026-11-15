import 'package:integration_test/integration_test.dart';

import '../test/pin_alarm_integration_test.dart' as pin_alarm_suite;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  pin_alarm_suite.main();
}
