import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yangi_taxi/main.dart';

Map<String, dynamic> order() => {
      'id': 'TEST-order',
      'status': 'assigned',
      'transport_order_id': 99,
      'crew_id': 4,
      'driver_id': 5,
      'pickup': {'address': 'TEST store', 'lat': 40.01, 'lon': 65.01},
      'destination': {'address': 'TEST recipient', 'lat': 40.02, 'lon': 65.02},
      'cash': <String, dynamic>{},
    };

class EtaApi extends ApiClient {
  EtaApi() : super('https://eta.test.invalid');
  int calls = 0;
  bool fail = false;
  Completer<dynamic>? deferred;
  final payload = <String, dynamic>{
    'state': {
      'order_id': 99,
      'crew_id': 4,
      'driver_id': 5,
      'state_kind': 'driver_assigned'
    },
    'location': {'crew_id': 4, 'lat': 40.0, 'lon': 65.0},
    'tracking': {
      'source': 'TaxiMaster',
      'available': true,
      'location_age_seconds': 0
    },
  };
  @override
  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    expect(path, '/api/orders/99/driver-location');
    calls++;
    if (fail) throw ApiException('TEST offline');
    if (deferred != null) return deferred!.future;
    return jsonDecode(jsonEncode(payload));
  }
}

Future<void> showEta(WidgetTester tester, EtaApi api, Map<String, dynamic> data,
    GoRouteSeconds provider) async {
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: GoCourierEta(
              api: api, order: data, lang: 'ru', routeSeconds: provider))));
  await tester.pumpAndSettle();
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
}

class DetailApi extends EtaApi {
  final detail = <String, dynamic>{
    ...order(),
    'shop_name': 'TEST shop',
    'total_uzs': 1000,
    'items': <dynamic>[]
  };
  int reads = 0;
  @override
  Future<dynamic> deliveryGet(String path, {Map<String, String>? query}) async {
    expect(path, '/customer/orders/TEST-order');
    reads++;
    return jsonDecode(jsonEncode(detail));
  }
}

void main() {
  test(
      'ETA requires exact assignment/fresh coordinates and uses correct destination',
      () {
    final api = EtaApi(), o = order();
    final route = readGoEtaObservation(o, api.payload)!;
    expect(route.leg, 'to_store');
    expect(route.source!.lat, 40);
    expect(route.target!.lat, 40.01);
    expect(readGoEtaObservation({...o, 'crew_id': 7}, api.payload), isNull);
    expect(readGoEtaObservation({...o, 'driver_id': 7}, api.payload), isNull);
    expect(readGoEtaObservation({...o, 'transport_order_id': 100}, api.payload),
        isNull);
    for (final age in [-1, 121, 1.5, null]) {
      api.payload['tracking'] = {
        ...api.payload['tracking'] as Map,
        'location_age_seconds': age
      };
      expect(readGoEtaObservation(o, api.payload), isNull);
    }
    api.payload['tracking']['location_age_seconds'] = 0;
    api.payload['location']['lat'] = 91;
    expect(readGoEtaObservation(o, api.payload), isNull);
  });
  testWidgets(
      'ETA recomputes from fresh source and provider without a fake countdown',
      (tester) async {
    final api = EtaApi(), starts = <double>[], o = order();
    var duration = 300;
    await showEta(tester, api, o, (from, to) async {
      starts.add(from.lat);
      expect(to.lat, 40.01);
      return duration;
    });
    expect(find.text('Курьер до магазина'), findsOneWidget);
    expect(find.text('≈ 5 мин'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('≈ 5 мин'), findsOneWidget);
    api.payload['location']['lat'] = 40.005;
    duration = 120;
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(starts, [40.0, 40.005]);
    expect(find.text('≈ 2 мин'), findsOneWidget);
    await close(tester);
  });
  testWidgets(
      'network failure clears old minutes; old server and stale GPS cannot show ETA',
      (tester) async {
    final api = EtaApi();
    var routes = 0;
    await showEta(tester, api, order(), (a, b) async {
      routes++;
      return 240;
    });
    expect(find.text('≈ 4 мин'), findsOneWidget);
    api.fail = true;
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(find.text('≈ 4 мин'), findsNothing);
    expect(find.text('Время уточняется'), findsOneWidget);
    api.fail = false;
    api.payload.remove('tracking');
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(routes, 1);
    api.payload['tracking'] = {
      'source': 'TaxiMaster',
      'available': true,
      'location_age_seconds': 121
    };
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(routes, 1);
    await close(tester);
  });
  testWidgets(
      'pickup changes route leg; arrival is server state, terminal orders hide ETA',
      (tester) async {
    final api = EtaApi(), o = order();
    double? target;
    Future<int?> route(Place a, Place b) async {
      target = b.lat;
      return 360;
    }

    await showEta(tester, api, o, route);
    expect(target, 40.01);
    api.payload['state']['state_kind'] = 'client_inside';
    final picked = {...o, 'status': 'picked_up'};
    await showEta(tester, api, picked, route);
    expect(target, 40.02);
    expect(find.text('Путь до вас'), findsOneWidget);
    await showEta(
        tester,
        api,
        {
          ...picked,
          'cash': {'client_arrived': true}
        },
        route);
    expect(find.text('Курьер прибыл'), findsOneWidget);
    expect(find.text('≈ 6 мин'), findsNothing);
    await showEta(tester, api, {...picked, 'status': 'completed'}, route);
    expect(find.byKey(const ValueKey('go-courier-eta')), findsNothing);
    await close(tester);
  });
  testWidgets('TM arrival needs no invented zero-minute route', (tester) async {
    final api = EtaApi();
    api.payload['state']['state_kind'] = 'car_at_place';
    api.payload.remove('tracking');
    await showEta(tester, api, order(), (a, b) async {
      fail('No route needed at store');
    });
    expect(find.text('Курьер в магазине'), findsOneWidget);
    await close(tester);
  });
  testWidgets('background clears ETA and stops reads until resumed',
      (tester) async {
    final api = EtaApi();
    await showEta(tester, api, order(), (a, b) async => 180);
    final calls = api.calls;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await tester.pump(const Duration(seconds: 25));
    expect(api.calls, calls);
    // Paused apps do not paint a new frame. Check the cleared presentation on
    // resume while the next real location response is still pending.
    api.deferred = Completer<dynamic>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('≈ 3 мин'), findsNothing);
    api.deferred!.complete(api.payload);
    await tester.pumpAndSettle();
    expect(api.calls, calls + 1);
    expect(find.text('≈ 3 мин'), findsOneWidget);
    await close(tester);
  });
  testWidgets(
      'coordinate expiry cancels a slow route and ignores its late result',
      (tester) async {
    final api = EtaApi(), pending = Completer<int?>();
    api.payload['tracking']['location_age_seconds'] = 119;
    await showEta(tester, api, order(), (a, b) => pending.future);
    await tester.pump(const Duration(seconds: 2));
    pending.complete(300);
    await tester.pumpAndSettle();
    expect(find.text('≈ 5 мин'), findsNothing);
    expect(find.text('Время уточняется'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets('changed assignment invalidates pending route result',
      (tester) async {
    final api = EtaApi(), pending = Completer<int?>(), o = order();
    await showEta(tester, api, o, (a, b) => pending.future);
    await showEta(
        tester, api, {...o, 'crew_id': 7, 'driver_id': 8}, (a, b) async => 1);
    pending.complete(300);
    await tester.pumpAndSettle();
    expect(find.text('≈ 5 мин'), findsNothing);
    await close(tester);
  });
  testWidgets(
      'failed routing shows no invented estimate on a narrow accessible screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
                body: GoCourierEta(
                    api: EtaApi(),
                    order: order(),
                    lang: 'ru',
                    routeSeconds: (a, b) async => null)))));
    await tester.pumpAndSettle();
    expect(find.text('Время уточняется'), findsOneWidget);
    expect(find.textContaining('≈'), findsNothing);
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets(
      'purchase detail reloads authoritative order and stops ETA after completion',
      (tester) async {
    final api = DetailApi();
    await tester.pumpWidget(MaterialApp(
        home: GoPurchaseDetails(api: api, lang: 'ru', orderId: 'TEST-order')));
    await tester.pumpAndSettle();
    expect(api.reads, 1);
    expect(find.text('assigned'), findsOneWidget);
    api.detail['status'] = 'completed';
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(api.reads, 2);
    expect(find.text('completed'), findsOneWidget);
    expect(find.byKey(const ValueKey('go-courier-eta')), findsNothing);
    await close(tester);
  });
}
