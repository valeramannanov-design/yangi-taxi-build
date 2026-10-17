import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:yangi_taxi/main.dart';

class DeliveryTestApi extends ApiClient {
  DeliveryTestApi() : super('https://delivery.test.invalid');
  int catalogCalls = 0;
  int expectedShopId = 1;
  bool timeoutNextCheckout = false;
  final List<String?> checkoutKeys = [];
  final Map<String, dynamic> order = {
    'id': 'test-order',
    'quote_id': 'test-quote',
    'shop_name': 'Test shop',
    'status': 'pending_shop',
    'version': 1,
    'destination': {'address': 'Test destination', 'lat': 40.001, 'lon': 65},
    'total_uzs': 17000,
    'items': [
      {'product_id': 1, 'name': 'Test milk', 'quantity': 1, 'price_uzs': 10000}
    ],
  };
  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (path == '/api/me') return {'client_id': 101};
    throw StateError('Unexpected test API route');
  }

  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    if (path == '/catalog') {
      catalogCalls++;
      return {
        'categories': [
          {'id': 1, 'name': 'Server category'}
        ],
        'shops': [
          {'id': 1, 'name': 'Test shop', 'address': 'Store address'},
          {'id': 2, 'name': 'Second shop', 'address': 'Second store address'},
        ],
        'products': []
      };
    }
    if (path == '/shops/1')
      return {
        'id': 1,
        'name': 'Test shop',
        'address': 'Store address',
        'lat': 40.0,
        'lon': 65.0,
        'products': [
          {'id': 1, 'name': 'Test milk', 'price_uzs': 9000, 'stock': 10}
        ]
      };
    if (path == '/shops/2')
      return {
        'id': 2,
        'name': 'Second shop',
        'address': 'Second store address',
        'lat': 40.0,
        'lon': 65.0,
        'products': [
          {'id': 2, 'name': 'Second product', 'price_uzs': 9000, 'stock': 10}
        ]
      };
    if (path == '/customer/orders') return checkoutKeys.isEmpty ? [] : [order];
    throw StateError('Unexpected test delivery route');
  }

  @override
  Future<dynamic> deliveryPost(String path, Map<String, dynamic> body,
      {String? idempotencyKey}) async {
    if (path == '/customer/quotes') {
      expect(body['shop_id'], expectedShopId);
      expect(body['destination']['address'], 'Test destination');
      return {
        'id': 'test-quote',
        'subtotal_uzs': 10000,
        'delivery_uzs': 7000,
        'total_uzs': 17000
      };
    }
    if (path == '/customer/orders') {
      final stored =
          await const FlutterSecureStorage().read(key: 'delivery_checkout_101');
      expect(jsonDecode(stored!)['key'], idempotencyKey);
      checkoutKeys.add(idempotencyKey);
      if (timeoutNextCheckout) {
        timeoutNextCheckout = false;
        throw TimeoutException('Test network interruption');
      }
      return order;
    }
    if (path.endsWith('/cancel')) {
      order['status'] = 'cancelled';
      order['version'] = 2;
      return order;
    }
    throw StateError('Unexpected test mutation');
  }
}

Widget screen(ApiClient api, {bool active = true}) => MaterialApp(
        home: DeliveryScreen(
      api: api,
      lang: 'ru',
      isActive: active,
      onMenu: () {},
      addressPicker: (_, __) async => Place('Test destination', 40.001, 65),
    ));

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });
  testWidgets('loads server categories only when Delivery is active',
      (tester) async {
    final api = DeliveryTestApi();
    await tester.pumpWidget(screen(api, active: false));
    await tester.pumpAndSettle();
    expect(api.catalogCalls, 0);
    await tester.pumpWidget(screen(api));
    await tester.pumpAndSettle();
    expect(api.catalogCalls, 1);
    expect(find.text('Server category'), findsOneWidget);
    expect(find.text('Test shop'), findsOneWidget);
  });
  testWidgets(
      'cart uses server quote totals and checkout is durable before sending',
      (tester) async {
    final api = DeliveryTestApi();
    await tester.pumpWidget(screen(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test shop'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Корзина · 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать адрес на карте'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Рассчитать стоимость'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Рассчитать стоимость'));
    await tester.pumpAndSettle();
    expect(find.text('Итого: 17000 сум'), findsOneWidget);
    await tester.ensureVisible(find.text('Оформить заказ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Оформить заказ'));
    await tester.pumpAndSettle();
    expect(api.checkoutKeys.length, 1);
    expect(api.checkoutKeys.single, matches(RegExp('^[a-f0-9]{48}\$')));
    expect(
        await const FlutterSecureStorage().read(key: 'delivery_checkout_101'),
        isNull);
    expect(find.text('Магазин проверяет заказ'), findsOneWidget);
  });
  testWidgets(
      'a network interruption and process recreation retain the same checkout key',
      (tester) async {
    final api = DeliveryTestApi()..timeoutNextCheckout = true;
    FlutterSecureStorage.setMockInitialValues({
      'delivery_checkout_101': jsonEncode({
        'quote_id': 'test-quote',
        'key': 'pending-checkout-key-from-before-restart'
      })
    });
    await tester.pumpWidget(screen(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Проверить'));
    await tester.pumpAndSettle();
    expect(api.checkoutKeys.length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(screen(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Проверить'));
    await tester.pumpAndSettle();
    expect(api.checkoutKeys, [
      'pending-checkout-key-from-before-restart',
      'pending-checkout-key-from-before-restart'
    ]);
    expect(find.text('Магазин проверяет заказ'), findsOneWidget);
  });
  testWidgets('Delivery provides no mock catalog in the production demo branch',
      (tester) async {
    await tester.pumpWidget(screen(ApiClient('demo')));
    await tester.pumpAndSettle();
    expect(find.text('Доставка доступна после подключения к службе'),
        findsOneWidget);
    expect(find.text('Test shop'), findsNothing);
  });
  testWidgets(
      'emptying a cart removes its old store before ordering from another',
      (tester) async {
    final api = DeliveryTestApi()..expectedShopId = 2;
    await tester.pumpWidget(screen(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test shop'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Корзина · 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second shop'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Корзина · 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать адрес на карте'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Рассчитать стоимость'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Рассчитать стоимость'));
    await tester.pumpAndSettle();
    expect(find.text('Итого: 17000 сум'), findsOneWidget);
  });
}
