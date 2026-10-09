import 'package:flutter_test/flutter_test.dart';
import 'package:yangi_taxi/ride_confirmation.dart';
import 'package:yangi_taxi/driver_movement.dart';

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

  group('Confirmed driver movement', () {
    late DriverMovementEvidence movement;

    setUp(() => movement = DriverMovementEvidence());

    bool observe({
      int orderId = 1,
      int crewId = 33,
      String stateKind = 'driver_assigned',
      bool confirmed = true,
      double? latitude,
      double? longitude,
      double? speed,
    }) => movement.update(
          orderId: orderId,
          crewId: crewId,
          stateKind: stateKind,
          confirmedAssignment: confirmed,
          latitude: latitude,
          longitude: longitude,
          speed: speed,
        );

    test('assignment without telemetry remains at car found', () {
      expect(observe(), isFalse);
      expect(observe(), isFalse);
      expect(observe(), isFalse);
    });

    test('unconfirmed driver never progresses even with GPS speed', () {
      expect(observe(confirmed: false, speed: 30), isFalse);
      expect(observe(confirmed: true), isFalse);
    });

    test('two credible low-speed readings indicate movement', () {
      expect(observe(speed: 5), isFalse);
      expect(observe(speed: 5), isTrue);
      expect(observe(speed: 0), isTrue);
    });

    test('single clearly moving speed reports progress', () {
      expect(observe(speed: 19), isTrue);
    });

    test('cumulative short GPS steps eventually indicate movement', () {
      expect(observe(latitude: 41.31110, longitude: 69.27970), isFalse);
      expect(observe(latitude: 41.31119, longitude: 69.27970), isFalse);
      expect(observe(latitude: 41.31130, longitude: 69.27970), isFalse);
      expect(observe(latitude: 41.31139, longitude: 69.27970), isTrue);
    });

    test('missing GPS update keeps the displacement anchor', () {
      expect(observe(latitude: 41.31110, longitude: 69.27970), isFalse);
      expect(observe(), isFalse);
      expect(observe(latitude: 41.31125, longitude: 69.27970), isFalse);
      expect(observe(latitude: 41.31138, longitude: 69.27970), isTrue);
    });

    test('stationary GPS jitter does not indicate movement', () {
      expect(observe(latitude: 41.31110, longitude: 69.27970), isFalse);
      expect(observe(latitude: 41.31112, longitude: 69.27970), isFalse);
      expect(observe(latitude: 41.31108, longitude: 69.27971), isFalse);
    });

    test('large GPS teleport is ignored', () {
      expect(observe(latitude: 41.31110, longitude: 69.27970), isFalse);
      expect(observe(latitude: 41.35000, longitude: 69.27970), isFalse);
      expect(observe(latitude: 41.35000, longitude: 69.27970), isFalse);
    });

    test('different driver and order never inherit previous movement', () {
      expect(observe(speed: 25), isTrue);
      expect(observe(crewId: 34), isFalse);
      expect(observe(orderId: 2, crewId: 34), isFalse);
    });

    test('unassigned and arrived states reset evidence', () {
      expect(observe(speed: 25), isTrue);
      expect(observe(stateKind: 'car_at_place', speed: 30), isFalse);
      expect(observe(), isFalse);
      expect(observe(confirmed: false, speed: 30), isFalse);
    });

    test('invalid and missing GPS do not fabricate movement', () {
      expect(observe(latitude: 0, longitude: 0), isFalse);
      expect(observe(latitude: 99, longitude: 300), isFalse);
      expect(observe(speed: double.nan), isFalse);
    });
  });
}
