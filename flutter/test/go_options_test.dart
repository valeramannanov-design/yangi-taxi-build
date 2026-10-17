import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:yangi_taxi/main.dart';
import 'delivery_test.dart' show DeliveryTestApi;

class OptionsApi extends DeliveryTestApi {
  List<dynamic>? quotedItems;
  bool recommend = false;
  final product = <String, dynamic>{
    'id': 1,
    'shop_id': 1,
    'name': 'TEST drink',
    'description': 'TEST',
    'ingredients': 'Water, fruit',
    'volume_ml': 500,
    'price_uzs': 18000,
    'stock': 3,
    'has_variants': true,
    'variants': [
      {
        'id': 'small',
        'name': 'Small',
        'price_uzs': 18000,
        'stock': 2,
        'active': true,
        'volume_ml': 500
      },
      {
        'id': 'large',
        'name': 'Large',
        'price_uzs': 25000,
        'stock': 1,
        'active': true,
        'volume_ml': 1000
      }
    ]
  };
  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    if (path == '/shops/1') {
      final shop = Map<String, dynamic>.from(
          await super.deliveryGet(path, query: query) as Map);
      return {
        ...shop,
        'products': [product]
      };
    }
    if (path == '/shops/1/products/1')
      return {
        ...product,
        'recommendations': [
          if (recommend) {...product, 'id': 2, 'name': 'TEST recommendation'}
        ]
      };
    return super.deliveryGet(path, query: query);
  }

  @override
  Future<dynamic> deliveryPost(String path, Map<String, dynamic> body,
      {String? idempotencyKey}) async {
    if (path == '/customer/quotes') {
      quotedItems = body['items'] as List;
      return {
        'id': 'test-quote',
        'subtotal_uzs': 43000,
        'delivery_uzs': 6000,
        'total_uzs': 49000,
        'destination': body['destination']
      };
    }
    return super.deliveryPost(path, body, idempotencyKey: idempotencyKey);
  }
}

Future<void> open(WidgetTester tester, OptionsApi api) async {
  await tester.pumpWidget(MaterialApp(
      home: DeliveryScreen(
          api: api,
          lang: 'ru',
          isActive: true,
          onMenu: () {},
          addressPicker: (_, __) async =>
              Place('Test destination', 40.001, 65))));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Test shop'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
      'variant selection is mandatory and two options remain distinct in one cart and quote',
      (tester) async {
    final api = OptionsApi();
    await open(tester, api);
    final grid =
        tester.widget<GridView>(find.byKey(const ValueKey('go-products-grid')));
    expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2);
    await tester.tap(find.byTooltip('Добавить'));
    await tester.pumpAndSettle();
    expect(find.text('Выберите вариант'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Корзина ·'), findsNothing);
    for (final name in ['Small', 'Large']) {
      await tester.tap(find.byTooltip('Добавить'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Корзина · 2'));
    await tester.pumpAndSettle();
    expect(find.text('TEST drink · Small'), findsOneWidget);
    expect(find.text('TEST drink · Large'), findsOneWidget);
    await tester.ensureVisible(find.text('Выбрать адрес на карте'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать адрес на карте'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Рассчитать стоимость'), 150);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Рассчитать стоимость'));
    await tester.pumpAndSettle();
    expect(api.quotedItems?.map((i) => i['variant_id']).toSet(),
        {'small', 'large'});
    expect(api.quotedItems?.every((i) => i['product_id'] == 1), true);
  });
  testWidgets(
      'two-column product cards fit narrow Android width and show real composition in details',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = OptionsApi();
    await open(tester, api);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('TEST drink'));
    await tester.pumpAndSettle();
    expect(find.text('Состав: Water, fruit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'recommended product with variants opens selection before adding to shared cart',
      (tester) async {
    final api = OptionsApi()..recommend = true;
    await open(tester, api);
    await tester.tap(find.text('TEST drink'));
    await tester.pumpAndSettle();
    final recommendation = find.byKey(const ValueKey('go-product-2'));
    await tester.scrollUntilVisible(recommendation, 150,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: recommendation, matching: find.byTooltip('Добавить')));
    await tester.pumpAndSettle();
    expect(find.text('Выберите вариант'), findsOneWidget);
    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Корзина · 1'));
    await tester.pumpAndSettle();
    expect(find.text('TEST recommendation · Large'), findsOneWidget);
  });
}
