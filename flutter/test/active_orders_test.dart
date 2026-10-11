import 'package:flutter_test/flutter_test.dart';
import 'package:yangi_taxi/active_orders.dart';

void main() {
  group('Multiple passenger orders', () {
    test('returns distinct active orders with normalized IDs', () {
      final orders = currentPassengerOrders(<dynamic>[
        <String, dynamic>{'order_id': 104, 'state_kind': 'driver_assigned'},
        <String, dynamic>{'orderId': '105', 'state_kind': 'new_order'},
        <String, dynamic>{'order_id': 104, 'state_kind': 'driver_assigned'},
        <String, dynamic>{'id': -2},
        'invalid',
      ]);
      expect(orders.map((e) => e['order_id']).toList(), <int>[104, 105]);
    });

    test('live entry wins over an earlier stale terminal entry for the same ID', () {
      final orders = currentPassengerOrders(<dynamic>[
        <String, dynamic>{'order_id': 22, 'state_kind': 'finished'},
        <String, dynamic>{'order_id': 22, 'state_kind': 'driver_assigned'},
      ]);
      expect(orders.single['order_id'], 22);
    });

    test('filters finished and cancelled rides from the active picker', () {
      final orders = currentPassengerOrders(<dynamic>[
        <String, dynamic>{'order_id': 11, 'state_kind': 'finished'},
        <String, dynamic>{'order_id': 12, 'state_kind': 'aborted'},
        <String, dynamic>{'order_id': 13, 'state_type': 'cancelled'},
        <String, dynamic>{'order_id': 14, 'state_kind': 'client_inside'},
      ]);
      expect(orders.single['order_id'], 14);
    });

    test('invalid or missing API response is safely empty', () {
      expect(currentPassengerOrders(null), isEmpty);
      expect(currentPassengerOrders(<String, Object>{'orders': <Object>[]}), isEmpty);
    });

    test('restoring prefers saved second ride even when API returns first ride first', () {
      final orders = currentPassengerOrders(<dynamic>[
        <String, dynamic>{'order_id': 20},
        <String, dynamic>{'order_id': 21},
      ]);
      expect(preferredPassengerOrderId(orders, 21), 21);
      expect(preferredPassengerOrderId(orders, 99), 20);
      expect(preferredPassengerOrderId(orders, null), 20);
    });

    test('no live orders does not invent a selected ride', () {
      expect(preferredPassengerOrderId(<Map<String, dynamic>>[], 21), isNull);
    });
  });
}
