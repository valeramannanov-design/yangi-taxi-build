import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yangi_taxi/main.dart';

class ReviewApi extends ApiClient {
  ReviewApi() : super('https://reviews.test.invalid');
  List<String> targets = ['shop', 'courier'];
  final List<Map<String, dynamic>> rows = [];
  final List<Map<String, dynamic>> calls = [];
  final List<String?> keys = [];
  bool offline = false, loseResponse = false, malformed = false;
  Completer<void>? hold;
  Map<String, dynamic> result() => {
        'eligible_targets': targets,
        'reviews': rows.map((r) => {...r}).toList()
      };
  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    if (offline) throw StateError('Offline/old backend');
    if (!path.endsWith('/reviews'))
      return {
        'id': 'owned-order',
        'status': 'completed',
        'shop_name': 'TEST store',
        'fulfillment': 'pickup',
        'pickup': {'address': 'TEST address'},
        'items': [],
        'total_uzs': 25000
      };
    return result();
  }

  @override
  Future<dynamic> deliveryPost(String path, Map<String, dynamic> body,
      {String? idempotencyKey}) async {
    calls.add({...body});
    keys.add(idempotencyKey);
    if (hold != null) await hold!.future;
    if (malformed) return {'saved': true};
    if (!rows.any((r) => r['target'] == body['target']))
      rows.add({
        ...body,
        'complaint_status': (body['rating'] as int) <= 2 ? 'open' : null
      });
    if (loseResponse) {
      loseResponse = false;
      throw StateError('Response lost after commit');
    }
    return result();
  }
}

Future<void> open(WidgetTester t, ReviewApi api,
    {String id = 'owned-order'}) async {
  await t.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SingleChildScrollView(
              child: GoOrderReviews(api: api, orderId: id, lang: 'ru')))));
  await t.pumpAndSettle();
}

Finder form(String target) => find.byKey(ValueKey('go-review-$target'));
Future<void> rate(WidgetTester t, String target, int rating) async {
  final star =
      find.descendant(of: form(target), matching: find.byTooltip('$rating'));
  await t.ensureVisible(star);
  await t.tap(star);
  await t.pump();
}

Future<void> send(WidgetTester t, String target) async {
  final button =
      find.descendant(of: form(target), matching: find.byType(FilledButton));
  await t.ensureVisible(button);
  await t.tap(button);
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
      'completed GO order opens ratings from the existing details screen',
      (t) async {
    final api = ReviewApi()..targets = ['shop'];
    await t.pumpWidget(MaterialApp(
        home: GoPurchaseDetails(api: api, lang: 'ru', orderId: 'owned-order')));
    await t.pumpAndSettle();
    final section = find.byType(GoOrderReviews);
    await t.ensureVisible(section);
    await t.pumpAndSettle();
    expect(form('shop'), findsOneWidget);
    expect(form('courier'), findsNothing);
    await rate(t, 'shop', 2);
    await send(t, 'shop');
    api.rows.single['complaint_status'] = 'resolved';
    await t.pumpWidget(const SizedBox());
    await open(t, api);
    expect(find.text('Обращение закрыто'), findsOneWidget);
  });
  testWidgets('only server-eligible targets appear and choice is required',
      (t) async {
    final api = ReviewApi()..targets = ['shop'];
    await open(t, api);
    expect(form('shop'), findsOneWidget);
    expect(form('courier'), findsNothing);
    expect(t.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await rate(t, 'shop', 4);
    await send(t, 'shop');
    expect(api.calls.single['rating'], 4);
    expect(api.keys.single, isNotNull);
    expect(find.text('Оценка сохранена'), findsOneWidget);
  });
  testWidgets(
      'low ratings explain actual automatic GO complaint and restore saved result',
      (t) async {
    final api = ReviewApi()..targets = ['shop'];
    await open(t, api);
    await rate(t, 'shop', 1);
    expect(find.textContaining('При оценке 1–2'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'TEST merchant');
    await send(t, 'shop');
    expect(find.text('Обращение создано в GO'), findsOneWidget);
    expect(api.calls.single['comment'], 'TEST merchant');
    await t.pumpWidget(const SizedBox());
    await open(t, api);
    expect(find.text('1 / 5'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(api.calls.length, 1);
  });
  testWidgets(
      'shop and courier are rated independently without client target IDs',
      (t) async {
    final api = ReviewApi();
    await open(t, api);
    await rate(t, 'shop', 5);
    await send(t, 'shop');
    await rate(t, 'courier', 3);
    await send(t, 'courier');
    expect(api.calls.map((c) => c['target']), ['shop', 'courier']);
    expect(
        api.calls.every((c) =>
            c.keys.toSet().difference({'target', 'rating', 'comment'}).isEmpty),
        isTrue);
    expect(find.text('Оценка сохранена'), findsNWidgets(2));
  });
  testWidgets('in-flight command disables repeat submit and input', (t) async {
    final api = ReviewApi()
      ..targets = ['shop']
      ..hold = Completer<void>();
    await open(t, api);
    await rate(t, 'shop', 2);
    final button = find.byType(FilledButton);
    await t.ensureVisible(button);
    await t.tap(button);
    await t.pump();
    expect(t.widget<FilledButton>(button).onPressed, isNull);
    expect(t.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(api.calls.length, 1);
    api.hold!.complete();
    await t.pumpAndSettle();
    expect(find.text('Оценка сохранена'), findsOneWidget);
  });
  testWidgets(
      'lost response retries frozen payload and same key; reopening restores server truth',
      (t) async {
    final api = ReviewApi()
      ..targets = ['shop']
      ..loseResponse = true;
    await open(t, api);
    await rate(t, 'shop', 2);
    await t.enterText(find.byType(TextField), 'TEST');
    await send(t, 'shop');
    expect(find.textContaining('Подтверждение не получено'), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.text('Оценка сохранена'), findsNothing);
    await send(t, 'shop');
    expect(api.calls.length, 2);
    expect(api.calls[0], api.calls[1]);
    expect(api.keys[0], api.keys[1]);
    expect(api.rows.length, 1);
    await t.pumpWidget(const SizedBox());
    await open(t, api);
    expect(find.text('Оценка сохранена'), findsOneWidget);
  });
  testWidgets('offline or older backend cannot create a fake successful review',
      (t) async {
    final api = ReviewApi()..offline = true;
    await open(t, api);
    expect(find.textContaining('Оценки недоступны'), findsOneWidget);
    expect(form('shop'), findsNothing);
    expect(api.calls, isEmpty);
    api.offline = false;
    await t.tap(find.byType(TextButton));
    await t.pumpAndSettle();
    expect(form('shop'), findsOneWidget);
  });
  testWidgets(
      'malformed submit response never claims saved and disposed request is ignored',
      (t) async {
    final api = ReviewApi()
      ..targets = ['shop']
      ..malformed = true;
    await open(t, api);
    await rate(t, 'shop', 5);
    await send(t, 'shop');
    expect(find.text('Оценка сохранена'), findsNothing);
    expect(find.textContaining('Подтверждение не получено'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    api.malformed = false;
    api.hold = Completer<void>();
    await open(t, api);
    await rate(t, 'shop', 5);
    await t.ensureVisible(find.byType(FilledButton));
    await t.tap(find.byType(FilledButton));
    await t.pump();
    await t.pumpWidget(const SizedBox());
    api.hold!.complete();
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
