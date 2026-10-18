import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:yangi_taxi/main.dart';
import 'delivery_test.dart' show DeliveryTestApi;

class PickupApi extends DeliveryTestApi {
  PickupApi() {
    order.addAll({
      'fulfillment': 'pickup',
      'cash_model': 'store_pickup_cash_v1',
      'pricing_basis': 'self_pickup',
      'pickup': {'address': 'Store address', 'lat': 40.0, 'lon': 65.0},
      'destination': null,
      'subtotal_uzs': 9000,
      'delivery_uzs': 0,
      'total_uzs': 9000,
      'pickup_cash': {'events': []}
    });
  }
  bool shopPickup = true, enabled = true, ignorePickup = false;
  Map<String, dynamic>? quoteBody;
  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    final result = await super.deliveryGet(path, query: query);
    if (path == '/catalog')
      return {
        ...result as Map,
        'service': query?['service'],
        'go_checkout': {
          'enabled': enabled,
          'environment': enabled ? 'TEST' : 'production'
        }
      };
    if (path == '/shops/1')
      return {
        ...result as Map,
        'service_kind': 'food',
        'pickup_enabled': shopPickup
      };
    return result;
  }

  @override
  Future<dynamic> deliveryPost(String path, Map<String, dynamic> body,
      {String? idempotencyKey}) async {
    if (path == '/customer/quotes') {
      quoteBody = body;
      return {
        'id': 'test-quote',
        'fulfillment': ignorePickup ? 'delivery' : 'pickup',
        'cash_model': 'store_pickup_cash_v1',
        'pricing_basis': 'self_pickup',
        'destination': null,
        'subtotal_uzs': 9000,
        'delivery_uzs': 0,
        'total_uzs': 9000
      };
    }
    return super.deliveryPost(path, body, idempotencyKey: idempotencyKey);
  }
}

Future<void> cart(WidgetTester tester, PickupApi api,
    {bool mapped = false}) async {
  await tester.pumpWidget(MaterialApp(
      home: DeliveryScreen(
          api: api,
          lang: 'ru',
          isActive: true,
          serviceKind: mapped ? 'food' : null,
          onMenu: () {},
          addressPicker: (_, __) async {
            fail('Pickup must not request a customer map point');
          })));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Test shop'));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.add_circle_outline));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Корзина · 1'));
  await tester.pumpAndSettle();
}

Future<void> verify(WidgetTester tester) async {
  final scroll = find
      .descendant(
          of: find.byKey(const ValueKey('go-cart-scroll')),
          matching: find.byType(Scrollable))
      .first;
  await tester.scrollUntilVisible(find.text('Проверить заказ'), 150,
      scrollable: scroll);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Проверить заказ'));
  await tester.pumpAndSettle();
}

class NoticeApi extends ApiClient {
  NoticeApi() : super('https://pickup.test.invalid');
  int loads = 0, reads = 0;
  bool failGet = false;
  String? key;
  final rows = <Map<String, dynamic>>[
    {
      'id': 1,
      'kind': 'pickup_ready',
      'order_id': 'owned',
      'shop_name': 'TEST shop',
      'status': 'ready',
      'read_at': null,
      'pickup': {'address': 'TEST store'}
    }
  ];
  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    expect(path, '/customer/notifications');
    loads++;
    if (failGet)
      throw ApiException('TEST old/offline backend', statusCode: 404);
    return rows;
  }

  @override
  Future<dynamic> deliveryPost(String path, Map<String, dynamic> body,
      {String? idempotencyKey}) async {
    expect(path, '/customer/notifications/1/read');
    reads++;
    key = idempotencyKey;
    rows[0]['read_at'] = 1;
    return {'id': 1, 'read_at': 1};
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
      'pickup needs no map/address and durable checkout retains pickup history',
      (tester) async {
    final api = PickupApi();
    await cart(tester, api);
    await tester.tap(find.byKey(const ValueKey('go-select-pickup')));
    await tester.pumpAndSettle();
    expect(find.text('Выбрать адрес на карте'), findsNothing);
    expect(find.text('Забрать из: Store address'), findsOneWidget);
    await verify(tester);
    expect(api.quoteBody?['fulfillment'], 'pickup');
    expect(api.quoteBody!.containsKey('destination'), false);
    expect(find.text('Итого: 9000 сум'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Оформить заказ'), 150,
        scrollable: find
            .descendant(
                of: find.byKey(const ValueKey('go-cart-scroll')),
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(find.text('Оформить заказ'));
    await tester.pumpAndSettle();
    expect(api.checkoutKeys, hasLength(1));
    expect(find.byKey(const ValueKey('go-pickup-summary')), findsOneWidget);
    expect(find.text('Store address'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'changing pickup to delivery invalidates quote and restores first-address requirement',
      (tester) async {
    final api = PickupApi();
    await cart(tester, api);
    await tester.tap(find.byKey(const ValueKey('go-select-pickup')));
    await tester.pumpAndSettle();
    await verify(tester);
    await tester.ensureVisible(find.text('Доставка'));
    await tester.tap(find.text('Доставка'));
    await tester.pumpAndSettle();
    expect(find.text('Оформить заказ'), findsNothing);
    expect(find.text('Выбрать адрес на карте'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Рассчитать стоимость'), 150,
        scrollable: find
            .descendant(
                of: find.byKey(const ValueKey('go-cart-scroll')),
                matching: find.byType(Scrollable))
            .first);
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Рассчитать стоимость'));
    expect(button.onPressed, isNull);
  });
  testWidgets('old backend cannot silently treat pickup as delivery',
      (tester) async {
    final api = PickupApi()..ignorePickup = true;
    await cart(tester, api);
    await tester.tap(find.byKey(const ValueKey('go-select-pickup')));
    await tester.pumpAndSettle();
    await verify(tester);
    expect(
        find.textContaining('Сервер не подтвердил самовывоз'), findsOneWidget);
    expect(find.text('Оформить заказ'), findsNothing);
    expect(api.checkoutKeys, isEmpty);
  });
  testWidgets(
      'pickup capability is server owned and cannot bypass production checkout gate',
      (tester) async {
    final noPickup = PickupApi()..shopPickup = false;
    await cart(tester, noPickup);
    expect(find.byKey(const ValueKey('go-select-pickup')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    final disabled = PickupApi()..enabled = false;
    await cart(tester, disabled, mapped: true);
    await tester.tap(find.byKey(const ValueKey('go-select-pickup')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Проверить заказ'), 150,
        scrollable: find
            .descendant(
                of: find.byKey(const ValueKey('go-cart-scroll')),
                matching: find.byType(Scrollable))
            .first);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Проверить заказ'))
            .onPressed,
        isNull);
    expect(disabled.quoteBody, isNull);
  });
  testWidgets('pickup summary uses merchant readiness and payment state',
      (tester) async {
    final data = <String, dynamic>{
      'status': 'confirmed',
      'ready_expected_at': DateTime(2026, 10, 18, 12).millisecondsSinceEpoch,
      'pickup': {'address': 'TEST store'},
      'pickup_cash': {'events': []}
    };
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GoPickupSummary(order: data, lang: 'ru'))));
    expect(find.textContaining('Ожидаемая готовность'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GoPickupSummary(
                order: {...data, 'status': 'ready'}, lang: 'ru'))));
    expect(find.text('Заказ готов к самовывозу'), findsOneWidget);
  });
  testWidgets(
      'readiness notice is durable/unique on refresh and opens owned order once',
      (tester) async {
    final api = NoticeApi();
    String? opened;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GoReadyAlerts(
                api: api,
                lang: 'ru',
                isActive: true,
                onOrder: (id) => opened = id))));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('go-ready-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('go-ready-1')));
    await tester.pumpAndSettle();
    expect(api.reads, 1);
    expect(api.key, matches(RegExp(r'^[a-f0-9]{48}$')));
    expect(opened, 'owned');
    expect(find.byKey(const ValueKey('go-ready-1')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('offline or changed-order notice never claims current readiness',
      (tester) async {
    final api = NoticeApi();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GoReadyAlerts(
                api: api, lang: 'ru', isActive: true, onOrder: (_) {}))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('go-ready-1')), findsOneWidget);
    api.failGet = true;
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('go-ready-1')), findsNothing);
    api.failGet = false;
    api.rows[0]['status'] = 'cancelled';
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('go-ready-1')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
