import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yangi_taxi/main.dart';

class InboxApi extends ApiClient {
  InboxApi() : super('https://inbox.test.invalid');
  bool offline = false, failRead = false;
  int loads = 0, reads = 0;
  final keys = <String?>[];
  Completer<void>? holdRead;
  final rows = <Map<String, dynamic>>[
    {
      'id': 3,
      'order_id': 'owned',
      'kind': 'complaint_updated',
      'shop_name': 'TEST shop',
      'created_at': 1000,
      'read_at': null,
      'status': 'completed'
    },
    {
      'id': 2,
      'order_id': 'owned',
      'kind': 'order_completed',
      'shop_name': 'TEST shop',
      'created_at': 900,
      'read_at': null,
      'status': 'completed'
    },
    {
      'id': 1,
      'order_id': 'owned',
      'kind': 'pickup_ready',
      'shop_name': 'TEST shop',
      'created_at': 800,
      'read_at': 1,
      'status': 'completed'
    },
  ];
  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    if (offline) throw StateError('TEST offline');
    if (path == '/customer/notification-summary')
      return {
        'unread': rows.where((n) => n['read_at'] == null).length,
        'push': {'available': false, 'project_id': null}
      };
    if (path == '/customer/notifications') {
      loads++;
      final before = int.tryParse(query?['before'] ?? '');
      return rows
          .where((n) => before == null || (n['id'] as int) < before)
          .take(100)
          .map((n) => {...n})
          .toList();
    }
    throw StateError('Unexpected TEST route');
  }

  @override
  Future<dynamic> deliveryPost(String path, Map<String, dynamic> body,
      {String? idempotencyKey}) async {
    reads++;
    keys.add(idempotencyKey);
    if (holdRead != null) await holdRead!.future;
    if (failRead) throw StateError('TEST lost acknowledgement');
    final id = int.parse(path.split('/')[3]);
    rows.firstWhere((n) => n['id'] == id)['read_at'] = 2000;
    return {'id': id, 'read_at': 2000};
  }
}

Future<void> mount(WidgetTester t, InboxApi api,
    {bool active = true,
    bool full = false,
    ValueChanged<String>? opened}) async {
  final hub = GoNotificationHub(
      api: api,
      lang: 'ru',
      isActive: active,
      fullPage: full,
      onOrder: opened ?? (_) {});
  await t.pumpWidget(MaterialApp(
      home: Scaffold(body: full ? hub : SingleChildScrollView(child: hub))));
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
      'general feed shows backend unread count and all supported event kinds without duplicate refresh',
      (t) async {
    final api = InboxApi();
    await mount(t, api);
    expect(find.text('Уведомления (2)'), findsOneWidget);
    expect(find.text('Обновление по обращению'), findsOneWidget);
    expect(find.text('Заказ завершён'), findsOneWidget);
    expect(find.text('Заказ готов к самовывозу'), findsNothing);
    await t.pump(const Duration(seconds: 30));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('go-notice-3')), findsOneWidget);
    expect(api.loads, 2);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('inbox opens from existing GO feed and retains read history',
      (t) async {
    final api = InboxApi();
    String? opened;
    await mount(t, api, opened: (id) => opened = id);
    await t.tap(find.byKey(const ValueKey('go-notifications-open')));
    await t.pumpAndSettle();
    expect(find.text('Уведомления'), findsOneWidget);
    expect(find.text('Заказ готов к самовывозу'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('go-notice-3')).last);
    await t.pumpAndSettle();
    expect(opened, 'owned');
    expect(api.reads, 1);
    expect(api.keys.single, isNotEmpty);
    expect(find.byKey(const ValueKey('go-notice-3')),
        findsOneWidget); // read row remains in the visible inbox
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'acknowledged notice leaves preview, while failed ack retries same key and stays unread',
      (t) async {
    final api = InboxApi()..failRead = true;
    await mount(t, api);
    await t.tap(find.byKey(const ValueKey('go-notice-3')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('go-notice-3')), findsOneWidget);
    api.failRead = false;
    await t.tap(find.byKey(const ValueKey('go-notice-3')));
    await t.pumpAndSettle();
    expect(api.keys[0], api.keys[1]);
    expect(find.byKey(const ValueKey('go-notice-3')), findsNothing);
    expect(find.text('Уведомления (1)'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'read command blocks duplicate taps and ignores completion after identity change',
      (t) async {
    final api = InboxApi()..holdRead = Completer<void>();
    String? opened;
    await mount(t, api, opened: (id) => opened = id);
    await t.tap(find.byKey(const ValueKey('go-notice-3')));
    await t.pump();
    expect(
        t
            .widget<ListTile>(find.descendant(
                of: find.byKey(const ValueKey('go-notice-2')),
                matching: find.byType(ListTile)))
            .onTap,
        isNull);
    api.token = 'another-account';
    await mount(t, api, opened: (id) => opened = id);
    api.holdRead!.complete();
    await t.pumpAndSettle();
    expect(opened, isNull);
    expect(api.reads, 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'background and inactive GO do not poll or retain stale visible data',
      (t) async {
    final api = InboxApi();
    await mount(t, api);
    final loads = api.loads;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump(const Duration(seconds: 60));
    expect(api.loads, loads);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(api.loads, loads + 1);
    await mount(t, api, active: false);
    await t.pump(const Duration(seconds: 60));
    expect(api.loads, loads + 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'old/offline backend offers retry and never fabricates notifications',
      (t) async {
    final api = InboxApi()..offline = true;
    await mount(t, api, full: true);
    expect(find.text('Не удалось загрузить уведомления'), findsOneWidget);
    expect(find.text('Заказ завершён'), findsNothing);
    api.offline = false;
    await t.tap(find.text('Не удалось загрузить уведомления'));
    await t.pumpAndSettle();
    expect(find.text('Заказ завершён'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('history is paginated by server cursor and deduplicated',
      (t) async {
    final api = InboxApi();
    api.rows.clear();
    for (var id = 105; id > 0; id--)
      api.rows.add({
        'id': id,
        'order_id': 'owned',
        'kind': 'order_completed',
        'shop_name': 'TEST $id',
        'created_at': 1000,
        'read_at': 1
      });
    await mount(t, api, full: true);
    final scroll = find.byType(Scrollable).last;
    await t.scrollUntilVisible(find.text('Ранее'), 500,
        scrollable: scroll, maxScrolls: 100);
    await t.tap(find.text('Ранее'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.byKey(const ValueKey('go-notice-1')), 400,
        scrollable: scroll, maxScrolls: 10);
    expect(find.byKey(const ValueKey('go-notice-1')), findsOneWidget);
    expect(find.text('Ранее'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'unconfigured Android push stays off without initializing Firebase or requesting permission',
      (t) async {
    final api = InboxApi();
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: GoAndroidPushSetting(api: api, lang: 'ru'))));
    expect(find.text('Сервис пока не подключён'), findsOneWidget);
    expect(t.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(GoAndroidPush.instance.configured, isFalse);
    expect(api.loads, 0);
    await t.pumpWidget(const SizedBox());
  });
}
