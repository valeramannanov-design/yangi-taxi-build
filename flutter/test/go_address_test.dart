import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:yangi_taxi/main.dart';
import 'delivery_test.dart' show DeliveryTestApi;

class AddressApi extends DeliveryTestApi {
  final favorites = <Map<String, dynamic>>[
    {
      'id': 'home',
      'name': 'Дом',
      'address': 'Saved home',
      'lat': 40.002,
      'lon': 65.0,
      'entrance': '2',
      'floor': '3',
      'apartment': '12A',
      'landmark': 'Park'
    }
  ];
  bool previous = false;
  Map<String, dynamic>? requestedDestination;
  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (path == '/api/profile/favorites') return {'favorites': favorites};
    return super.get(path, query: query);
  }

  @override
  Future<dynamic> post(String path, Map<String, dynamic> body) async {
    if (path.startsWith('/api/profile/favorites')) {
      favorites[0] = {...favorites[0], ...body};
      return {'favorite': favorites[0]};
    }
    throw StateError('Unexpected test profile write');
  }

  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    if (path == '/customer/orders' && previous)
      return [
        {...order, 'destination': favorites[0]}
      ];
    return super.deliveryGet(path, query: query);
  }

  @override
  Future<dynamic> deliveryPost(String path, Map<String, dynamic> body,
      {String? idempotencyKey}) async {
    if (path == '/customer/quotes') {
      requestedDestination =
          Map<String, dynamic>.from(body['destination'] as Map);
      return {
        'id': 'test-quote',
        'subtotal_uzs': 10000,
        'delivery_uzs': 7000,
        'total_uzs': 17000,
        'destination': requestedDestination
      };
    }
    return super.deliveryPost(path, body, idempotencyKey: idempotencyKey);
  }
}

Future<void> cart(WidgetTester tester, AddressApi api,
    Future<Place?> Function(BuildContext, Place) picker) async {
  await tester.pumpWidget(MaterialApp(
      home: DeliveryScreen(
          api: api,
          lang: 'ru',
          isActive: true,
          onMenu: () {},
          addressPicker: picker)));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Test shop'));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.add_circle_outline));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Корзина · 1'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
      'first courier order confirms saved coordinates on map; details reach server quote',
      (tester) async {
    final api = AddressApi();
    var maps = 0;
    await cart(tester, api, (_, initial) async {
      maps++;
      return initial;
    });
    await tester.ensureVisible(find.text('Дом · Saved home'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Дом · Saved home'));
    await tester.pumpAndSettle();
    expect(maps, 1);
    expect(find.textContaining('Квартира: 12A'), findsOneWidget);
    await tester.ensureVisible(find.text('Рассчитать стоимость'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Рассчитать стоимость'));
    await tester.pumpAndSettle();
    expect(api.requestedDestination?['apartment'], '12A');
    expect(api.requestedDestination?['lat'], 40.002);
  });
  testWidgets(
      'returning passenger chooses existing shared address and can edit/save entrance without map',
      (tester) async {
    final api = AddressApi()..previous = true;
    var maps = 0;
    await cart(tester, api, (_, initial) async {
      maps++;
      return initial;
    });
    await tester.ensureVisible(find.text('Дом · Saved home'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Дом · Saved home'));
    await tester.pumpAndSettle();
    expect(maps, 0);
    await tester.ensureVisible(find.text('Подъезд, этаж, квартира, ориентир'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подъезд, этаж, квартира, ориентир'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('go-address-entrance')), '5');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Сохранить адрес в профиле'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить адрес в профиле'));
    await tester.pumpAndSettle();
    expect(api.favorites.single['entrance'], '5');
    expect(api.favorites.single['apartment'], '12A');
    expect(find.text('Адрес сохранён в вашем профиле'), findsOneWidget);
  });
  test('old servers cannot silently discard nonempty delivery details', () {
    expect(
        () => requireGoAddressDetailsEcho({
              'apartment': '12A'
            }, {
              'favorite': {'address': 'home'}
            }),
        throwsA(isA<ApiException>()));
    expect(
        () => requireGoAddressDetailsEcho({
              'apartment': ''
            }, {
              'favorite': {'apartment': '12A'}
            }),
        throwsA(isA<ApiException>()));
  });
}
