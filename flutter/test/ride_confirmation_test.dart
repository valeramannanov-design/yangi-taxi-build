import 'package:flutter_test/flutter_test.dart';
import 'package:yangi_taxi/ride_confirmation.dart';

void main() {
  group('Yangi Taxi vehicle assignment', () {
    const assigned = <String, Object>{
      'state_kind': 'driver_assigned',
      'crew_id': 33,
      'driver_id': 15,
      'car_id': 17,
    };

    test('unconfirmed assignment remains waiting even with all IDs', () {
      expect(canDisplayConfirmedAssignment(<String, Object>{
        ...assigned,
        'confirmed': 'not_confirmed',
      }), isFalse);
    });

    test('accepted driver with crew is displayed', () {
      expect(canDisplayConfirmedAssignment(<String, Object>{
        ...assigned,
        'confirmed': 'confirmed_by_driver',
      }), isTrue);
      expect(isDriverAcceptanceConfirmed(<String, Object>{
        'confirmed': 'confirmed_by_driver',
      }), isTrue);
    });

    test('dispatcher-confirmed assigned vehicle is displayed', () {
      expect(canDisplayConfirmedAssignment(<String, Object>{
        ...assigned,
        'confirmed': 'confirmed_by_oper',
      }), isTrue);
      expect(isDriverAcceptanceConfirmed(<String, Object>{
        'confirmed': 'confirmed_by_oper',
      }), isFalse);
    });

    test('legacy detailed assignment with absent confirmation is usable', () {
      expect(canDisplayConfirmedAssignment(assigned), isTrue);
    });

    test('just a crew ID and car model is not enough', () {
      expect(canDisplayConfirmedAssignment(<String, Object>{
        'state_kind': 'driver_assigned',
        'crew_id': 33,
        'car_model': 'Cobalt',
        'car_number': '01 A 123 BC',
      }), isFalse);
    });

    test('unknown confirmation never overrides missing acceptance', () {
      expect(canDisplayConfirmedAssignment(<String, Object>{
        ...assigned,
        'confirmed': 'unexpected',
      }), isFalse);
    });

    test('new orders without assigned crew stay searching', () {
      expect(canDisplayConfirmedAssignment(<String, Object>{
        ...assigned, 'state_kind': 'new_order',
      }), isFalse);
    });

    test('no vehicle without crew, even if confirmation says yes', () {
      expect(canDisplayConfirmedAssignment(<String, Object>{
        'state_kind': 'driver_assigned',
        'confirmed': 'confirmed_by_driver',
      }), isFalse);
    });
  });
}
