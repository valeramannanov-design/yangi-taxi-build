import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:yangi_taxi/main.dart';
import 'delivery_test.dart' show DeliveryTestApi;

class GoTestApi extends ApiClient {
  GoTestApi() : super('https://go.test.invalid');
  bool failShopping = false;
  final taxi = [
    {'order_id': 9, 'state_kind': 'driver_assigned'},
    {'order_id': 10, 'state_kind': 'client_inside'}
  ];
  final purchases = [
    {
      'id': 'owned-test-shopping',
      'transport_order_id': 9,
      'service_kind': 'food',
      'shop_name': 'Test restaurant',
      'status': 'accepted',
      'total_uzs': 34800
    }
  ];
  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async => taxi;
  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    if (failShopping) throw ApiException('Test connection failure');
    return purchases;
  }
}

class GoCatalogApi extends DeliveryTestApi {
  final calls = <String>[];
  Map<String, dynamic>? capability;
  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    calls.add('$path:${query?['service']}');
    final result = await super.deliveryGet(path, query: query);
    if (path == '/catalog')
      return {
        ...result as Map,
        'service': query?['service'],
        if (capability != null) 'go_checkout': capability
      };
    if (path.startsWith('/shops/'))
      return {...result as Map, 'service_kind': query?['service']};
    return result;
  }
}

class GoShellApi extends GoTestApi {
  GoShellApi() {
    token = 'test-session';
  }
  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (path == '/api/orders/current')
      return [
        {'order_id': 77, 'state_kind': 'driver_assigned'}
      ];
    if (path == '/api/orders/77/driver-location')
      return {
        'state': {
          'order_id': 77,
          'state_kind': 'driver_assigned',
          'source': 'Test pickup',
          'destination': 'Test destination'
        },
        'location': null
      };
    if (path == '/api/me')
      return {'client_id': 101, 'name': 'Test passenger', 'phones': []};
    if (path == '/api/payments/config') return {'atmosEnabled': false};
    return [];
  }

  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    if (path == '/catalog')
      return {
        'service': query?['service'],
        'categories': [],
        'shops': [],
        'products': []
      };
    return [];
  }
}

class GoRecommendationsApi extends GoCatalogApi {
  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    if (path == '/shops/1/products/1')
      return {
        'id': 1,
        'shop_id': 1,
        'name': 'Test milk',
        'description': 'Test description',
        'price_uzs': 9000,
        'stock': 10,
        'recommendations': [
          {
            'id': 3,
            'shop_id': 1,
            'name': 'Server recommendation',
            'price_uzs': 5000,
            'stock': 2
          }
        ]
      };
    return super.deliveryGet(path, query: query);
  }
}

class _NativeViewStub extends StatefulWidget {
  const _NativeViewStub({super.key, required this.taxi, this.orderId});
  final bool taxi;
  final int? orderId;
  @override
  State<_NativeViewStub> createState() => _NativeViewStubState();
}

class _NativeViewStubState extends State<_NativeViewStub> {
  @override
  Widget build(BuildContext context) =>
      Text(widget.taxi ? 'Native taxi placeholder' : 'Native ride placeholder');
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
      'product detail adds a real server recommendation to the same shared cart',
      (tester) async {
    final api = GoRecommendationsApi();
    await tester.pumpWidget(MaterialApp(
        home: DeliveryScreen(
            api: api,
            lang: 'ru',
            isActive: true,
            onMenu: () {},
            serviceKind: 'food',
            checkoutEnabled: false)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test shop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test milk'));
    await tester.pumpAndSettle();
    expect(find.text('Test description'), findsOneWidget);
    expect(find.text('Server recommendation'), findsOneWidget);
    await tester.tap(find.byTooltip('Добавить'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.text('Корзина · 1'), findsOneWidget);
    expect(api.checkoutKeys, isEmpty);
  });
  testWidgets(
      'GO switches services without recreating taxi form or losing the restored active ride',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Shell(
            api: GoShellApi(),
            lang: 'ru',
            themeSetting: 'system',
            onLang: (_) {},
            onTheme: (_) async {},
            onBackend: (_) async {},
            onLogout: () {},
            taxiPageBuilder: (key, active) =>
                _NativeViewStub(key: key, taxi: true),
            ridePageBuilder: (id, active) => _NativeViewStub(
                key: const ValueKey('test-native-ride'),
                taxi: false,
                orderId: id))));
    await tester.pumpAndSettle();
    final taxi = find.byWidgetPredicate((w) => w is _NativeViewStub && w.taxi,
        skipOffstage: false);
    final ride =
        find.byKey(const ValueKey('test-native-ride'), skipOffstage: false);
    final formState = tester.state(taxi);
    final rideState = tester.state(ride);
    expect(tester.widget<_NativeViewStub>(ride).orderId, 77);
    await tester.tap(find.widgetWithText(NavigationDestination, 'Главная'));
    await tester.pumpAndSettle();
    expect(find.textContaining('#77'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('go-service-food')));
    await tester.pumpAndSettle();
    expect(tester.state(taxi), same(formState));
    await tester.tap(find.widgetWithText(NavigationDestination, 'Главная'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('#77'));
    await tester.pumpAndSettle();
    expect(tester.state(ride), same(rideState));
    expect(tester.widget<_NativeViewStub>(ride).orderId, 77);
    await tester.tap(find.widgetWithText(NavigationDestination, 'Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Test passenger'), findsOneWidget);
    expect(find.text('Адреса'), findsOneWidget);
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'GO home has four in-app services and shared profile on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    GoService? selected;
    var profiles = 0;
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: GoHomeScreen(
                api: GoTestApi(),
                lang: 'ru',
                isActive: false,
                onService: (s) => selected = s,
                onProfile: () => profiles++,
                onOrders: () {},
                onAddresses: () {},
                onCards: () {},
                onTaxiOrder: (_) {},
                onPurchaseOrder: (_) {}))));
    expect(find.text('Yangi Taxi GO'), findsOneWidget);
    for (final service in GoService.values) {
      await tester.tap(find.byKey(ValueKey('go-service-${service.name}')));
      expect(selected, service);
    }
    await tester.tap(find.byKey(const ValueKey('go-profile')));
    expect(profiles, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'unified history deduplicates shopping TM transport and filters server service kind',
      (tester) async {
    final api = GoTestApi();
    Map<String, dynamic>? opened;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: GoOrdersPanel(
                    api: api,
                    lang: 'ru',
                    isActive: true,
                    activeOnly: false,
                    onTaxiOrder: (_) {},
                    onPurchaseOrder: (o) => opened = o)))));
    await tester.pumpAndSettle();
    expect(find.textContaining('#9'), findsNothing);
    expect(find.textContaining('#10'), findsOneWidget);
    expect(find.textContaining('Test restaurant'), findsOneWidget);
    await tester.tap(find.textContaining('Test restaurant'));
    expect(opened?['id'], 'owned-test-shopping');
    await tester.tap(find.widgetWithText(ChoiceChip, 'ЕДА'));
    await tester.pumpAndSettle();
    expect(find.textContaining('#10'), findsNothing);
    api.failShopping = true;
    await tester.tap(find.text('Обновить'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Test restaurant'), findsOneWidget);
    expect(find.textContaining('Часть заказов'), findsOneWidget);
  });
  testWidgets(
      'GO catalog uses server classification and cannot submit the previous financial flow',
      (tester) async {
    final api = GoCatalogApi();
    await tester.pumpWidget(MaterialApp(
        home: DeliveryScreen(
            api: api,
            lang: 'ru',
            isActive: true,
            onMenu: () {},
            serviceKind: 'food',
            checkoutEnabled: false,
            addressPicker: (_, __) async =>
                Place('Test destination', 40.001, 65))));
    await tester.pumpAndSettle();
    expect(api.calls, contains('/catalog:food'));
    await tester.tap(find.text('Test shop'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('/shops/1:food'));
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Корзина · 1'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Оформление временно недоступно'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Рассчитать стоимость'))
            .onPressed,
        isNull);
    expect(api.checkoutKeys, isEmpty);
  });
  testWidgets(
      'old backend without service filter acknowledgement is rejected instead of mixing catalogs',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: DeliveryScreen(
            api: DeliveryTestApi(),
            lang: 'ru',
            isActive: true,
            onMenu: () {},
            serviceKind: 'market',
            checkoutEnabled: false)));
    await tester.pumpAndSettle();
    expect(find.textContaining('требуется обновление сервера'), findsOneWidget);
    expect(find.text('Test shop'), findsNothing);
  });
  testWidgets(
      'GO TEST capability enables checkout and visibly labels fixture prices',
      (tester) async {
    final api = GoCatalogApi()
      ..capability = {'enabled': true, 'environment': 'TEST'};
    await tester.pumpWidget(MaterialApp(
        home: DeliveryScreen(
            api: api,
            lang: 'ru',
            isActive: true,
            onMenu: () {},
            serviceKind: 'food',
            addressPicker: (_, __) async =>
                Place('Test destination', 40.001, 65))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test shop'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Корзина · 1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('TEST —'), findsOneWidget);
    await tester.tap(find.text('Выбрать адрес на карте'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Рассчитать стоимость'));
    await tester.tap(find.text('Рассчитать стоимость'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Оформить заказ'));
    await tester.tap(find.text('Оформить заказ'));
    await tester.pumpAndSettle();
    expect(api.checkoutKeys.length, 1);
  });
  testWidgets(
      'GO missing production capability disables checkout even when local flag is true',
      (tester) async {
    final api = GoCatalogApi();
    await tester.pumpWidget(MaterialApp(
        home: DeliveryScreen(
            api: api,
            lang: 'ru',
            isActive: true,
            onMenu: () {},
            serviceKind: 'food')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test shop'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Корзина · 1'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Рассчитать стоимость'))
            .onPressed,
        isNull);
    expect(api.checkoutKeys, isEmpty);
  });
}
