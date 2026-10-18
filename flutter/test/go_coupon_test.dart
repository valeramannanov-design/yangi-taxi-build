import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'delivery_test.dart' show DeliveryTestApi, screen;

class CouponApi extends DeliveryTestApi {
  bool ignoresCoupon = false;
  Map<String, dynamic>? lastQuoteBody;
  @override
  Future<dynamic> deliveryPost(String path, Map<String, dynamic> body,
      {String? idempotencyKey}) async {
    if (path == '/customer/quotes') {
      lastQuoteBody = body;
      final coupon = body['coupon_code'] == 'SAVE10' && !ignoresCoupon
          ? {'code': 'SAVE10', 'discount_uzs': 1000, 'funding': 'merchant'}
          : null;
      if (coupon != null) {
        order['coupon'] = coupon;
        order['total_uzs'] = 16000;
      }
      return {
        'id': 'test-quote',
        'destination': body['destination'],
        'subtotal_uzs': coupon == null ? 10000 : 9000,
        'delivery_uzs': 7000,
        'total_uzs': coupon == null ? 17000 : 16000,
        if (coupon != null) 'coupon': coupon,
      };
    }
    return super.deliveryPost(path, body, idempotencyKey: idempotencyKey);
  }
}

Future<void> openCart(WidgetTester tester, CouponApi api) async {
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
  await tester.ensureVisible(find.byKey(const ValueKey('go-coupon-code')));
  await tester.enterText(
      find.byKey(const ValueKey('go-coupon-code')), ' save10 ');
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
}

Future<void> calculate(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Рассчитать стоимость'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Рассчитать стоимость'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets('coupon uses server total and editing code invalidates quote',
      (tester) async {
    final api = CouponApi();
    await openCart(tester, api);
    await calculate(tester);
    expect(api.lastQuoteBody?['coupon_code'], 'SAVE10');
    expect((api.lastQuoteBody?['items'] as List).single.keys,
        containsAll(['product_id', 'quantity']));
    expect(
        (api.lastQuoteBody?['items'] as List).single.containsKey('price_uzs'),
        false);
    expect(find.text('Итого: 16000 сум'), findsOneWidget);
    expect(find.text('Купон SAVE10: −1000 сум'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('go-coupon-code')));
    await tester.enterText(find.byKey(const ValueKey('go-coupon-code')), '');
    await tester.pumpAndSettle();
    expect(find.text('Оформить заказ'), findsNothing);
    expect(find.text('Итого: 16000 сум'), findsNothing);
    await calculate(tester);
    expect(api.lastQuoteBody!.containsKey('coupon_code'), false);
    expect(find.text('Итого: 17000 сум'), findsOneWidget);
  });
  testWidgets('old backend cannot silently ignore a supplied coupon',
      (tester) async {
    final api = CouponApi()..ignoresCoupon = true;
    await openCart(tester, api);
    await calculate(tester);
    expect(find.text('Оформить заказ'), findsNothing);
    expect(find.textContaining('Сервер не подтвердил купон'), findsOneWidget);
    expect(api.checkoutKeys, isEmpty);
  });
  testWidgets('checkout history retains server coupon and reduced cash total',
      (tester) async {
    final api = CouponApi();
    await openCart(tester, api);
    await calculate(tester);
    await tester.scrollUntilVisible(find.text('Оформить заказ'), 150,
        scrollable: find
            .descendant(
                of: find.byKey(const ValueKey('go-cart-scroll')),
                matching: find.byType(Scrollable))
            .first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Оформить заказ'));
    await tester.pumpAndSettle();
    expect(api.checkoutKeys, hasLength(1));
    expect(find.text('Купон SAVE10: −1000 сум'), findsOneWidget);
    expect(find.text('16000 сум'), findsOneWidget);
  });
}
