import 'package:flutter_test/flutter_test.dart';
import 'package:yangi_taxi/ride_confirmation.dart';

void main() {
  group('TaxiMaster driver acceptance', () {
    test('a crew assigned without confirmation is still waiting', () {
      expect(isDriverAcceptanceConfirmed(<String, Object>{
        'state_kind': 'driver_assigned', 'crew_id': 33,
        'car_model': 'Nexia', 'car_number': '85Y074FA',
      }), isFalse);
    });

    test('not_confirmed must not show a car found', () {
      expect(isDriverAcceptanceConfirmed(<String, Object>{
        'confirmed': 'not_confirmed',
      }), isFalse);
    });

    test('operator confirmation is not driver acceptance', () {
      expect(isDriverAcceptanceConfirmed(<String, Object>{
        'confirmed': 'confirmed_by_oper',
      }), isFalse);
    });

    test('driver confirmation allows assigned card', () {
      expect(isDriverAcceptanceConfirmed(<String, Object>{
        'confirmed': 'confirmed_by_driver',
      }), isTrue);
    });

    test('whitespace and case variations are harmless', () {
      expect(isDriverAcceptanceConfirmed(<String, Object>{
        'confirmed': ' Confirmed_By_Driver ',
      }), isTrue);
    });

    test('unknown or empty confirmation stays pending', () {
      expect(isDriverAcceptanceConfirmed(<String, Object>{
        'confirmed': '',
      }), isFalse);
      expect(isDriverAcceptanceConfirmed(<String, Object>{
        'confirmed': 'unknown',
      }), isFalse);
    });
  });
}
