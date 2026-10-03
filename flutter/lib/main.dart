import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:yandex_maps_mapkit/init.dart' as yandex_init;
import 'package:yandex_maps_mapkit/mapkit.dart' as ym;
import 'package:yandex_maps_mapkit/ui_view.dart' as yv;
import 'package:yandex_maps_mapkit/mapkit_factory.dart' as ym_factory;
import 'package:yandex_maps_mapkit/search.dart' as ys;
import 'package:yandex_maps_mapkit/yandex_map.dart' as ym_widget;

const defaultLat = 41.3111;
const defaultLon = 69.2797;

const yandexMapKitApiKey = String.fromEnvironment('MAPKIT_API_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (yandexMapKitApiKey.isNotEmpty) {
    await yandex_init.initMapkit(apiKey: yandexMapKitApiKey);
  }
  runApp(const YangiTaxiApp());
}

const words = <String, Map<String, String>>{
  'ru': {
    'app': 'Yangi Taxi',
    'login': 'Войти',
    'register': 'Регистрация',
    'name': 'Имя',
    'phone': 'Телефон',
    'password': 'Пароль',
    'order': 'Заказ',
    'ride': 'Поездка',
    'history': 'История',
    'profile': 'Профиль',
    'from': 'Откуда',
    'to': 'Куда',
    'estimate': 'Рассчитать стоимость',
    'book': 'Заказать',
    'price': 'Стоимость',
    'cancel': 'Отменить заказ',
    'logout': 'Выйти',
    'backend': 'Backend',
    'demo': 'Демо-режим',
    'empty': 'Нет активного заказа',
    'searching': 'Ищем машину',
    'assigned': 'Водитель назначен',
    'arrived': 'Машина подана',
    'trip': 'Вы в пути',
    'finished': 'Поездка завершена',
    'aborted': 'Заказ отменён',
    'address': 'Поиск адреса',
    'serverHelp': 'Оставьте demo для демонстрации. Для реальной работы укажите адрес Yangi Taxi backend.',
  },
  'uz': {
    'app': 'Yangi Taxi',
    'login': 'Kirish',
    'register': 'Ro‘yxatdan o‘tish',
    'name': 'Ism',
    'phone': 'Telefon',
    'password': 'Parol',
    'order': 'Buyurtma',
    'ride': 'Safar',
    'history': 'Tarix',
    'profile': 'Profil',
    'from': 'Qayerdan',
    'to': 'Qayerga',
    'estimate': 'Narxni hisoblash',
    'book': 'Buyurtma berish',
    'price': 'Narx',
    'cancel': 'Buyurtmani bekor qilish',
    'logout': 'Chiqish',
    'backend': 'Backend',
    'demo': 'Demo rejimi',
    'empty': 'Faol buyurtma yo‘q',
    'searching': 'Mashina qidirilmoqda',
    'assigned': 'Haydovchi tayinlandi',
    'arrived': 'Mashina yetib keldi',
    'trip': 'Yo‘ldasiz',
    'finished': 'Safar tugadi',
    'aborted': 'Buyurtma bekor qilindi',
    'address': 'Manzil qidirish',
    'serverHelp': 'Demo uchun demo qoldiring. Haqiqiy ishlash uchun Yangi Taxi backend manzilini kiriting.',
  },
};

String tx(String lang, String key) => words[lang]?[key] ?? words['ru']?[key] ?? key;

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ApiClient {
  ApiClient(this.baseUrl);
  String baseUrl;
  String? token;
  Map<String, dynamic>? _demoOrder;
  DateTime? _demoStarted;
  final List<Map<String, dynamic>> _demoHistory = [];
  final List<Map<String, dynamic>> _demoCards = <Map<String, dynamic>>[
    <String, dynamic>{
      'cardId': 9001,
      'maskedPan': '986009******4364',
      'expiry': '2802',
      'holder': 'DEMO USER',
      'isDefault': true,
    },
  ];

  bool get isDemo => baseUrl.trim().isEmpty || baseUrl.toLowerCase() == 'demo';

  void setBaseUrl(String value) {
    var v = value.trim();
    if (v.isEmpty || v.toLowerCase() == 'demo') {
      baseUrl = 'demo';
    } else {
      if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'http://' + v;
      while (v.endsWith('/')) {
        v = v.substring(0, v.length - 1);
      }
      baseUrl = v;
    }
    token = null;
  }

  Map<String, String> get headers => <String, String>{
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer ' + token!,
      };

  Future<Map<String, dynamic>> health() async {
    if (isDemo) return <String, dynamic>{'ok': true, 'tmApi': 'demo'};
    try {
      final r = await http.get(Uri.parse(baseUrl + '/health')).timeout(const Duration(seconds: 10));
      final b = jsonDecode(r.body);
      if (b is! Map || b['ok'] != true) throw ApiException('Backend недоступен');
      return Map<String, dynamic>.from(b as Map);
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException('Нет соединения с backend: ' + e.toString());
    }
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    if (isDemo) return _demoGet(path, query ?? const <String, String>{});
    final uri = Uri.parse(baseUrl + path).replace(queryParameters: query);
    final r = await http.get(uri, headers: headers).timeout(const Duration(seconds: 15));
    return _decode(r);
  }

  Future<dynamic> post(String path, Map<String, dynamic> body) async {
    if (isDemo) return _demoPost(path, body);
    final r = await http
        .post(Uri.parse(baseUrl + path), headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    return _decode(r);
  }

  dynamic _decode(http.Response r) {
    dynamic b;
    try {
      b = jsonDecode(r.body);
    } catch (_) {
      throw ApiException('Сервер вернул некорректный ответ');
    }
    if (r.statusCode < 200 || r.statusCode >= 300 || b is! Map || b['ok'] != true) {
      var message = 'Ошибка сервера';
      if (b is Map && b['error'] is Map && b['error']['message'] != null) {
        message = b['error']['message'].toString();
      }
      throw ApiException(message);
    }
    return b['data'];
  }

  Map<String, dynamic> get demoMe => <String, dynamic>{
        'client_id': 501,
        'name': 'Yangi Taxi Demo',
        'phones': <dynamic>[<String, dynamic>{'phone': '+998901234567'}],
        'bonus_balance': 12000,
      };

  List<Map<String, dynamic>> get demoAddresses => <Map<String, dynamic>>[
        <String, dynamic>{'label': 'Amir Temur xiyoboni, Toshkent', 'lat': 41.3111, 'lon': 69.2797, 'source': 'demo'},
        <String, dynamic>{'label': 'Toshkent xalqaro aeroporti', 'lat': 41.2579, 'lon': 69.2812, 'source': 'demo'},
        <String, dynamic>{'label': 'Chorsu bozori, Toshkent', 'lat': 41.3265, 'lon': 69.2358, 'source': 'demo'},
        <String, dynamic>{'label': 'Tashkent City Park', 'lat': 41.3160, 'lon': 69.2487, 'source': 'demo'},
        <String, dynamic>{'label': 'Magic City, Toshkent', 'lat': 41.3047, 'lon': 69.2457, 'source': 'demo'},
      ];

  Future<dynamic> _demoGet(String path, Map<String, String> query) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (path == '/api/me') return demoMe;
    if (path == '/api/tariffs') {
      return <Map<String, dynamic>>[
        <String, dynamic>{
          'key': 'start',
          'nameRu': 'Старт',
          'nameUz': 'Start',
          'icon': 'local_taxi',
          'tariffId': 1,
          'tariffName': 'Старт',
          'crewGroupId': 11,
          'crewGroupName': 'Старт',
          'available': true,
          'missing': <String>[],
        },
        <String, dynamic>{
          'key': 'together',
          'nameRu': 'Вместе',
          'nameUz': 'Birga',
          'icon': 'groups',
          'tariffId': 2,
          'tariffName': 'Вместе',
          'crewGroupId': 12,
          'crewGroupName': 'Вместе',
          'available': true,
          'missing': <String>[],
        },
        <String, dynamic>{
          'key': 'comfort',
          'nameRu': 'Комфорт',
          'nameUz': 'Komfort',
          'icon': 'airline_seat_recline_extra',
          'tariffId': 3,
          'tariffName': 'Комфорт',
          'crewGroupId': 13,
          'crewGroupName': 'Комфорт',
          'available': true,
          'missing': <String>[],
        },
        <String, dynamic>{
          'key': 'business',
          'nameRu': 'Бизнес',
          'nameUz': 'Biznes',
          'icon': 'business_center',
          'tariffId': 4,
          'tariffName': 'Бизнес',
          'crewGroupId': 14,
          'crewGroupName': 'Бизнес',
          'available': true,
          'missing': <String>[],
        },
        <String, dynamic>{
          'key': 'delivery',
          'nameRu': 'Доставка',
          'nameUz': 'Yetkazish',
          'icon': 'inventory_2',
          'tariffId': 5,
          'tariffName': 'Доставка',
          'crewGroupId': 15,
          'crewGroupName': 'Доставка',
          'available': true,
          'missing': <String>[],
        },
        <String, dynamic>{
          'key': 'cargo',
          'nameRu': 'Грузовой',
          'nameUz': 'Yuk',
          'icon': 'local_shipping',
          'tariffId': 6,
          'tariffName': 'Грузовой',
          'crewGroupId': 16,
          'crewGroupName': 'Грузовой',
          'available': true,
          'missing': <String>[],
        },
      ];
    }
    if (path == '/api/payments/config') {
      return <String, dynamic>{
        'atmosEnabled': true,
        'provider': 'ATMOS',
        'cardBindingAvailable': true,
        'cardFlow': 'demo-linked-card',
      };
    }
    if (path == '/api/cards') {
      Map<String, dynamic>? defaultCard;
      for (final card in _demoCards) {
        if (card['isDefault'] == true) {
          defaultCard = card;
          break;
        }
      }
      return <String, dynamic>{
        'provider': 'ATMOS',
        'cardBindingAvailable': true,
        'defaultCardId': defaultCard?['cardId'] ?? (_demoCards.isEmpty ? 0 : _demoCards.first['cardId']),
        'cards': _demoCards,
      };
    }
    if (path == '/api/crews/nearby') {
      final lat = double.tryParse(query['lat'] ?? '') ?? defaultLat;
      final lon = double.tryParse(query['lon'] ?? '') ?? defaultLon;
      return <dynamic>[
        <String, dynamic>{'crewId': 71, 'code': '071', 'lat': lat + 0.0021, 'lon': lon - 0.0018, 'distanceKm': 0.28, 'speed': 0, 'direction': 0},
        <String, dynamic>{'crewId': 72, 'code': '072', 'lat': lat - 0.0030, 'lon': lon + 0.0026, 'distanceKm': 0.41, 'speed': 14, 'direction': 90},
        <String, dynamic>{'crewId': 73, 'code': '073', 'lat': lat + 0.0042, 'lon': lon + 0.0032, 'distanceKm': 0.59, 'speed': 0, 'direction': 180},
      ];
    }
    if (path == '/api/addresses/search') {
      final q = (query['q'] ?? '').toLowerCase();
      if (q.isEmpty) return demoAddresses;
      final list = demoAddresses.where((x) => x['label'].toString().toLowerCase().contains(q)).toList();
      return list.isEmpty ? demoAddresses : list;
    }
    if (path == '/api/orders/current') {
      final s = _demoState();
      if (s == null || s['state_kind'] == 'finished' || s['state_kind'] == 'aborted') return <dynamic>[];
      return <dynamic>[s];
    }
    if (path == '/api/orders/history') {
      final out = <Map<String, dynamic>>[..._demoHistory];
      final s = _demoState();
      if (s != null && (s['state_kind'] == 'finished' || s['state_kind'] == 'aborted')) {
        if (!out.any((x) => x['order_id'] == s['order_id'])) out.insert(0, s);
      }
      return out;
    }
    final driverMatch = RegExp(r'^/api/orders/(\d+)/driver-location$').firstMatch(path);
    if (driverMatch != null) {
      final s = _demoState();
      if (s == null) throw ApiException('Заказ не найден');
      final seconds = DateTime.now().difference(_demoStarted!).inSeconds;
      final aLat = (s['source_lat'] as num).toDouble();
      final aLon = (s['source_lon'] as num).toDouble();
      final bLat = (s['destination_lat'] as num).toDouble();
      final bLon = (s['destination_lon'] as num).toDouble();
      final k = math.min(1.0, math.max(0.0, (seconds - 8) / 62));
      final loc = seconds < 8
          ? null
          : <String, dynamic>{
              'lat': aLat + (bLat - aLat) * k,
              'lon': aLon + (bLon - aLon) * k,
              'speed': seconds > 35 && seconds < 70 ? 38 : 0,
            };
      return <String, dynamic>{'state': s, 'location': loc};
    }
    if (RegExp(r'^/api/orders/(\d+)/cancel-penalty$').hasMatch(path)) {
      return <String, dynamic>{'cancel_order_penalty_sum': 0};
    }
    throw ApiException('Demo: неизвестный запрос ' + path);
  }

  Future<dynamic> _demoPost(String path, Map<String, dynamic> body) async {
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (path == '/api/cards/bind/init') {
      return <String, dynamic>{
        'transactionId': 70001,
        'phone': '********4567',
        'expiresIn': 600,
      };
    }
    if (path == '/api/cards/bind/confirm') {
      if ((body['otp'] ?? '').toString() != '111111') {
        throw ApiException('Неверный код подтверждения');
      }
      final id = 9100 + _demoCards.length;
      for (final card in _demoCards) {
        card['isDefault'] = false;
      }
      final suffix = id.toString().padLeft(4, '0');
      final card = <String, dynamic>{
        'cardId': id,
        'maskedPan': '860033******' + suffix.substring(suffix.length - 4),
        'expiry': '2909',
        'holder': 'DEMO USER',
        'isDefault': true,
      };
      _demoCards.add(card);
      return <String, dynamic>{'card': card};
    }
    final demoDefaultMatch = RegExp(r'^/api/cards/(\d+)/default$').firstMatch(path);
    if (demoDefaultMatch != null) {
      final id = int.parse(demoDefaultMatch.group(1)!);
      for (final card in _demoCards) {
        card['isDefault'] = (card['cardId'] as num).toInt() == id;
      }
      return <String, dynamic>{'defaultCardId': id};
    }
    final demoRemoveMatch = RegExp(r'^/api/cards/(\d+)/remove$').firstMatch(path);
    if (demoRemoveMatch != null) {
      final id = int.parse(demoRemoveMatch.group(1)!);
      _demoCards.removeWhere((c) => (c['cardId'] as num).toInt() == id);
      if (_demoCards.isNotEmpty && !_demoCards.any((c) => c['isDefault'] == true)) {
        _demoCards.first['isDefault'] = true;
      }
      return <String, dynamic>{
        'removed': true,
        'defaultCardId': _demoCards.isEmpty ? 0 : _demoCards.first['cardId'],
      };
    }

    if (path == '/api/auth/register/request-code') {
      return <String, dynamic>{
        'expiresIn': 300,
        'resendAfter': 60,
        'debugCode': '123456',
      };
    }
    if (path == '/api/auth/register/verify-code') {
      if ((body['code'] ?? '').toString() != '123456') {
        throw ApiException('Неверный SMS-код');
      }
      token = 'demo-session';
      return <String, dynamic>{'token': token, 'client': demoMe};
    }
    if (path == '/api/auth/login' || path == '/api/auth/register') {
      token = 'demo-session';
      return <String, dynamic>{'token': token, 'client': demoMe};
    }
    if (path == '/api/orders/estimate-options') {
      final a = Map<String, dynamic>.from(body['source'] as Map);
      final b = Map<String, dynamic>.from(body['destination'] as Map);
      final aLat = (a['lat'] as num).toDouble();
      final aLon = (a['lon'] as num).toDouble();
      final bLat = (b['lat'] as num).toDouble();
      final bLon = (b['lon'] as num).toDouble();
      final dist = math.sqrt(math.pow(aLat - bLat, 2) + math.pow(aLon - bLon, 2));
      final baseCost = 12000 + dist * 560000;

      Map<String, dynamic> option({
        required String key,
        required String nameRu,
        required String nameUz,
        required int tariffId,
        required int crewGroupId,
        required double multiplier,
      }) =>
          <String, dynamic>{
            'key': key,
            'nameRu': nameRu,
            'nameUz': nameUz,
            'tariffId': tariffId,
            'crewGroupId': crewGroupId,
            'available': true,
            'cost': (baseCost * multiplier).roundToDouble(),
          };

      return <String, dynamic>{
        'options': <Map<String, dynamic>>[
          option(
            key: 'start',
            nameRu: 'Старт',
            nameUz: 'Start',
            tariffId: 1,
            crewGroupId: 11,
            multiplier: 1.00,
          ),
          <String, dynamic>{
            ...option(
              key: 'together',
              nameRu: 'Вместе',
              nameUz: 'Birga',
              tariffId: 2,
              crewGroupId: 12,
              multiplier: 0.82,
            ),
            'savingVsStart': (baseCost * 0.18).roundToDouble(),
            'savingPercentVsStart': 18,
            'priceBadgeRu': 'На 18% дешевле Старт',
            'priceBadgeUz': 'Startdan 18% arzon',
          },
          option(
            key: 'comfort',
            nameRu: 'Комфорт',
            nameUz: 'Komfort',
            tariffId: 3,
            crewGroupId: 13,
            multiplier: 1.20,
          ),
          option(
            key: 'business',
            nameRu: 'Бизнес',
            nameUz: 'Biznes',
            tariffId: 4,
            crewGroupId: 14,
            multiplier: 1.55,
          ),
          option(
            key: 'delivery',
            nameRu: 'Доставка',
            nameUz: 'Yetkazib berish',
            tariffId: 5,
            crewGroupId: 15,
            multiplier: 1.10,
          ),
          option(
            key: 'cargo',
            nameRu: 'Грузовой',
            nameUz: 'Yuk tashish',
            tariffId: 6,
            crewGroupId: 16,
            multiplier: 1.80,
          ),
        ],
        'route': <String, dynamic>{
          'full_route_coords': <dynamic>[
            <String, dynamic>{'lat': aLat, 'lon': aLon},
            <String, dynamic>{
              'lat': (aLat + bLat) / 2 + 0.003,
              'lon': (aLon + bLon) / 2 - 0.002,
            },
            <String, dynamic>{'lat': bLat, 'lon': bLon},
          ],
        },
      };
    }

    if (path == '/api/orders/estimate') {
      final a = Map<String, dynamic>.from(body['source'] as Map);
      final b = Map<String, dynamic>.from(body['destination'] as Map);
      final aLat = (a['lat'] as num).toDouble();
      final aLon = (a['lon'] as num).toDouble();
      final bLat = (b['lat'] as num).toDouble();
      final bLon = (b['lon'] as num).toDouble();
      final dist = math.sqrt(math.pow(aLat - bLat, 2) + math.pow(aLon - bLon, 2));
      final cost = 12000 + dist * 560000;
      return <String, dynamic>{
        'cost': cost.roundToDouble(),
        'route': <String, dynamic>{
          'full_route_coords': <dynamic>[
            <String, dynamic>{'lat': aLat, 'lon': aLon},
            <String, dynamic>{'lat': (aLat + bLat) / 2 + 0.003, 'lon': (aLon + bLon) / 2 - 0.002},
            <String, dynamic>{'lat': bLat, 'lon': bLon},
          ],
        },
      };
    }
    if (path == '/api/orders') {
      final a = Map<String, dynamic>.from(body['source'] as Map);
      final b = body['destination'] is Map
          ? Map<String, dynamic>.from(body['destination'] as Map)
          : Map<String, dynamic>.from(a);
      final hasDestination = body['destination'] is Map;
      final key = (body['tariffKey'] ?? 'start').toString();
      const tariffIds = <String, int>{
        'start': 1,
        'together': 2,
        'comfort': 3,
        'business': 4,
        'delivery': 5,
        'cargo': 6,
      };
      const groupIds = <String, int>{
        'start': 11,
        'together': 12,
        'comfort': 13,
        'business': 14,
        'delivery': 15,
        'cargo': 16,
      };
      const multipliers = <String, double>{
        'start': 1.00,
        'together': 0.82,
        'comfort': 1.20,
        'business': 1.55,
        'delivery': 1.10,
        'cargo': 1.80,
      };
      final aLat = (a['lat'] as num).toDouble();
      final aLon = (a['lon'] as num).toDouble();
      final bLat = (b['lat'] as num).toDouble();
      final bLon = (b['lon'] as num).toDouble();
      final dist = math.sqrt(math.pow(aLat - bLat, 2) + math.pow(aLon - bLon, 2));
      final baseCost = 12000 + dist * 560000;
      final finalCost = (baseCost * (multipliers[key] ?? 1.0)).roundToDouble();

      final id = 30000 + DateTime.now().millisecondsSinceEpoch.remainder(9000);
      _demoStarted = DateTime.now();
      _demoOrder = <String, dynamic>{
        'order_id': id,
        'tariff_key': key,
        'tariff_id': tariffIds[key] ?? 1,
        'crew_group_id': groupIds[key] ?? 11,
        'state_kind': 'new_order',
        'source': a['address'],
        'destination': hasDestination ? b['address'] : '',
        'source_lat': a['lat'],
        'source_lon': a['lon'],
        'destination_lat': b['lat'],
        'destination_lon': b['lon'],
        'car_mark': 'Chevrolet',
        'car_model': 'Cobalt',
        'car_number': '01 Y 001 TX',
        'total_cost': finalCost,
      };
      return <String, dynamic>{'order_id': id};
    }
    if (RegExp(r'^/api/orders/(\d+)/cancel$').hasMatch(path)) {
      if (_demoOrder != null) _demoOrder!['state_kind'] = 'aborted';
      return <String, dynamic>{'ok': true};
    }
    throw ApiException('Demo: неизвестный запрос ' + path);
  }

  Map<String, dynamic>? _demoState() {
    if (_demoOrder == null || _demoStarted == null) return null;
    final out = Map<String, dynamic>.from(_demoOrder!);
    if (out['state_kind'] == 'aborted') return out;
    final seconds = DateTime.now().difference(_demoStarted!).inSeconds;
    out['state_kind'] = seconds < 8
        ? 'new_order'
        : seconds < 20
            ? 'driver_assigned'
            : seconds < 35
                ? 'car_at_place'
                : seconds < 70
                    ? 'client_inside'
                    : 'finished';
    _demoOrder = out;
    return out;
  }
}

class Place {
  Place(this.address, this.lat, this.lon);
  final String address;
  final double lat;
  final double lon;
  ym.Point get point => ym.Point(latitude: lat, longitude: lon);
  Map<String, dynamic> toJson() => <String, dynamic>{'address': address, 'lat': lat, 'lon': lon};

  factory Place.fromJson(Map<String, dynamic> j) => Place(
        (j['label'] ?? '').toString(),
        (j['lat'] as num).toDouble(),
        (j['lon'] as num).toDouble(),
      );
}

class NearbyCrew {
  NearbyCrew({
    required this.crewId,
    required this.code,
    required this.lat,
    required this.lon,
    required this.distanceKm,
    required this.speed,
    required this.direction,
  });

  final int crewId;
  final String code;
  final double lat;
  final double lon;
  final double distanceKm;
  final double speed;
  final double direction;

  ym.Point get point => ym.Point(latitude: lat, longitude: lon);

  factory NearbyCrew.fromJson(Map<String, dynamic> j) => NearbyCrew(
        crewId: (j['crewId'] as num?)?.toInt() ?? 0,
        code: (j['code'] ?? '').toString(),
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        distanceKm: (j['distanceKm'] as num?)?.toDouble() ?? 0,
        speed: (j['speed'] as num?)?.toDouble() ?? 0,
        direction: (j['direction'] as num?)?.toDouble() ?? -1,
      );
}

class YangiTaxiApp extends StatefulWidget {
  const YangiTaxiApp({super.key});
  @override
  State<YangiTaxiApp> createState() => _YangiTaxiAppState();
}

class _YangiTaxiAppState extends State<YangiTaxiApp> {
  final storage = const FlutterSecureStorage();
  final api = ApiClient('demo');
  bool loading = true;
  bool loggedIn = false;
  String lang = 'ru';
  String themeSetting = 'system';
  String rememberedPhone = '';

  @override
  void initState() {
    super.initState();
    restore();
  }

  Future<void> restore() async {
    final savedUrl = await storage.read(key: 'backend_url');
    final savedLang = await storage.read(key: 'lang');
    final savedTheme = await storage.read(key: 'theme_mode');
    final remember = await storage.read(key: 'remember_me');
    final shouldRemember = remember == 'true';
    final session = shouldRemember ? await storage.read(key: 'session') : null;
    final savedPhone = shouldRemember ? await storage.read(key: 'remembered_phone') : null;
    api.setBaseUrl(savedUrl ?? 'demo');
    if (savedLang == 'uz' || savedLang == 'ru') lang = savedLang!;
    if (savedTheme == 'light' || savedTheme == 'dark' || savedTheme == 'system') {
      themeSetting = savedTheme!;
    }
    rememberedPhone = savedPhone ?? '';

    if (!shouldRemember) {
      await storage.delete(key: 'session');
      await storage.delete(key: 'remembered_phone');
    }

    if (session != null) {
      api.token = session;
      try {
        await api.get('/api/me');
        loggedIn = true;
      } catch (_) {
        api.token = null;
        await storage.delete(key: 'session');
        await storage.delete(key: 'remember_me');
      }
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> saveLang(String value) async {
    lang = value;
    await storage.write(key: 'lang', value: value);
    if (mounted) setState(() {});
  }

  Future<void> saveTheme(String value) async {
    if (value != 'light' && value != 'dark' && value != 'system') return;
    themeSetting = value;
    await storage.write(key: 'theme_mode', value: value);
    if (mounted) setState(() {});
  }

  Future<void> saveBackend(String value) async {
    api.setBaseUrl(value);
    await storage.write(key: 'backend_url', value: api.baseUrl);
    await storage.delete(key: 'session');
    await storage.delete(key: 'remember_me');
    await storage.delete(key: 'remembered_phone');
    rememberedPhone = '';
    loggedIn = false;
    if (mounted) setState(() {});
  }

  Future<void> prepareLocationPermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
        await Geolocator.getLastKnownPosition();
      }
    } catch (_) {
      // Location must never block login. Order screen will retry.
    }
  }

  Future<void> saveToken(String value, bool remember, String phone) async {
    api.token = value;

    if (remember) {
      rememberedPhone = phone.trim();
      await storage.write(key: 'remember_me', value: 'true');
      await storage.write(key: 'session', value: value);
      await storage.write(key: 'remembered_phone', value: rememberedPhone);
    } else {
      rememberedPhone = '';
      await storage.delete(key: 'remember_me');
      await storage.delete(key: 'session');
      await storage.delete(key: 'remembered_phone');
    }

    await prepareLocationPermission();
    if (mounted) setState(() => loggedIn = true);
  }

  Future<void> logout() async {
    api.token = null;
    rememberedPhone = '';
    await storage.delete(key: 'session');
    await storage.delete(key: 'remember_me');
    await storage.delete(key: 'remembered_phone');
    if (mounted) setState(() => loggedIn = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1F8A4C),
      brightness: Brightness.light,
      surface: Colors.white,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5FCF7B),
      brightness: Brightness.dark,
    );
    final resolvedThemeMode = switch (themeSetting) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Yangi Taxi',
      themeMode: resolvedThemeMode,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F5F7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          height: 68,
          backgroundColor: Colors.white,
          indicatorColor: Color(0xFFE5F4EA),
          elevation: 8,
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerLowest,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: darkScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF111315),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF17191C),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          height: 68,
          backgroundColor: Color(0xFF17191C),
          indicatorColor: Color(0xFF263D2E),
          elevation: 8,
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Color(0xFF1B1E21),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: darkScheme.surfaceContainerHighest,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: darkScheme.outlineVariant),
          ),
        ),
      ),
      home: loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : loggedIn
              ? Shell(
                  api: api,
                  lang: lang,
                  themeSetting: themeSetting,
                  onLang: saveLang,
                  onTheme: saveTheme,
                  onBackend: saveBackend,
                  onLogout: logout,
                )
              : LoginScreen(
                  api: api,
                  lang: lang,
                  initialPhone: rememberedPhone,
                  onLang: saveLang,
                  onBackend: saveBackend,
                  onToken: saveToken,
                ),
    );
  }
}

Future<void> backendDialog(BuildContext context, ApiClient api, Future<void> Function(String) onSave) async {
  final c = TextEditingController(text: api.baseUrl);
  final value = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Yangi Taxi backend'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(tx('ru', 'serverHelp')),
          const SizedBox(height: 14),
          TextField(
            controller: c,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Backend URL', hintText: 'demo'),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(d, 'demo'), child: const Text('Demo')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Сохранить')),
      ],
    ),
  );
  c.dispose();
  if (value == null) return;
  await onSave(value);
  if (!context.mounted) return;
  try {
    final h = await api.health();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backend: ' + (h['tmApi'] ?? 'ok').toString())));
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.api,
    required this.lang,
    required this.initialPhone,
    required this.onLang,
    required this.onBackend,
    required this.onToken,
  });
  final ApiClient api;
  final String lang;
  final String initialPhone;
  final ValueChanged<String> onLang;
  final Future<void> Function(String) onBackend;
  final Future<void> Function(String, bool, String) onToken;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController phone;
  final pass = TextEditingController();
  final name = TextEditingController();
  final smsCode = TextEditingController();

  bool register = false;
  bool smsSent = false;
  bool busy = false;
  bool rememberMe = false;
  String? error;
  String? info;

  @override
  void initState() {
    super.initState();
    phone = TextEditingController(text: widget.initialPhone);
    rememberMe = widget.initialPhone.trim().isNotEmpty;
  }

  @override
  void dispose() {
    phone.dispose();
    pass.dispose();
    name.dispose();
    smsCode.dispose();
    super.dispose();
  }

  void toggleMode() {
    setState(() {
      register = !register;
      smsSent = false;
      smsCode.clear();
      error = null;
      info = null;
    });
  }

  Future<void> requestSms() async {
    if (phone.text.trim().isEmpty || name.text.trim().isEmpty || pass.text.length < 6) {
      setState(() => error = widget.lang == 'uz'
          ? 'Ism, telefon va kamida 6 belgili parolni kiriting'
          : 'Введите имя, телефон и пароль минимум из 6 символов');
      return;
    }

    setState(() {
      busy = true;
      error = null;
      info = null;
    });

    try {
      final data = await widget.api.post('/api/auth/register/request-code', <String, dynamic>{
        'phone': phone.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        smsSent = true;
        info = widget.lang == 'uz'
            ? 'SMS-kod ${phone.text.trim()} raqamiga yuborildi'
            : 'SMS-код отправлен на ${phone.text.trim()}';
        if (widget.api.isDemo && data['debugCode'] != null) {
          smsCode.text = data['debugCode'].toString();
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> verifySmsAndRegister() async {
    if (smsCode.text.trim().length < 4) {
      setState(() => error = widget.lang == 'uz' ? 'SMS-kodni kiriting' : 'Введите код из SMS');
      return;
    }

    setState(() {
      busy = true;
      error = null;
    });

    try {
      final data = await widget.api.post('/api/auth/register/verify-code', <String, dynamic>{
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        'password': pass.text,
        'code': smsCode.text.trim(),
      });
      await widget.onToken(data['token'].toString(), rememberMe, phone.text.trim());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> login() async {
    setState(() {
      busy = true;
      error = null;
      info = null;
    });
    try {
      final data = await widget.api.post('/api/auth/login', <String, dynamic>{
        'phone': phone.text.trim(),
        'password': pass.text,
      });
      await widget.onToken(data['token'].toString(), rememberMe, phone.text.trim());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    if (!register) return login();
    if (!smsSent) return requestSms();
    return verifySmsAndRegister();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Card(
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(15),
                              ),
                              child: const Icon(Icons.local_taxi, color: Colors.white),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Yangi Taxi',
                                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: busy ? null : () => backendDialog(context, widget.api, widget.onBackend),
                              icon: const Icon(Icons.settings_outlined),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Chip(
                                avatar: Icon(widget.api.isDemo ? Icons.science_outlined : Icons.cloud_done_outlined, size: 18),
                                label: Text(
                                  widget.api.isDemo ? tx(widget.lang, 'demo') : widget.api.baseUrl,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SegmentedButton<String>(
                              segments: const <ButtonSegment<String>>[
                                ButtonSegment<String>(value: 'ru', label: Text('RU')),
                                ButtonSegment<String>(value: 'uz', label: Text('UZ')),
                              ],
                              selected: <String>{widget.lang},
                              onSelectionChanged: busy ? null : (x) => widget.onLang(x.first),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        if (register) ...<Widget>[
                          TextField(
                            controller: name,
                            enabled: !smsSent && !busy,
                            decoration: InputDecoration(labelText: tx(widget.lang, 'name')),
                          ),
                          const SizedBox(height: 12),
                        ],
                        TextField(
                          controller: phone,
                          enabled: !smsSent && !busy,
                          keyboardType: TextInputType.phone,
                          decoration: InputDecoration(labelText: tx(widget.lang, 'phone')),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: pass,
                          enabled: !smsSent && !busy,
                          obscureText: true,
                          onSubmitted: (_) => submit(),
                          decoration: InputDecoration(labelText: tx(widget.lang, 'password')),
                        ),
                        const SizedBox(height: 6),
                        CheckboxListTile(
                          value: rememberMe,
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            widget.lang == 'uz' ? 'Meni eslab qolish' : 'Запомнить меня',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          subtitle: Text(
                            widget.lang == 'uz'
                                ? 'Parol saqlanmaydi — faqat himoyalangan sessiya'
                                : 'Пароль не сохраняется — только защищённая сессия',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onChanged: busy || smsSent ? null : (value) => setState(() => rememberMe = value ?? false),
                        ),
                        if (register && smsSent) ...<Widget>[
                          const SizedBox(height: 12),
                          TextField(
                            controller: smsCode,
                            autofocus: true,
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            onSubmitted: (_) => submit(),
                            decoration: InputDecoration(
                              counterText: '',
                              labelText: widget.lang == 'uz' ? 'SMS-kod' : 'Код из SMS',
                              prefixIcon: const Icon(Icons.sms_outlined),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: busy ? null : () {
                                setState(() {
                                  smsSent = false;
                                  smsCode.clear();
                                  info = null;
                                });
                                requestSms();
                              },
                              child: Text(widget.lang == 'uz' ? 'Kodni qayta yuborish' : 'Отправить код ещё раз'),
                            ),
                          ),
                        ],
                        if (info != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(info!, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                          ),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                          ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          onPressed: busy ? null : submit,
                          icon: busy
                              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : Icon(
                                  register
                                      ? (smsSent ? Icons.verified_user_outlined : Icons.sms_outlined)
                                      : Icons.login,
                                ),
                          label: Text(
                            !register
                                ? tx(widget.lang, 'login')
                                : (smsSent
                                    ? (widget.lang == 'uz' ? 'SMS-kodni tasdiqlash' : 'Подтвердить SMS')
                                    : (widget.lang == 'uz' ? 'SMS-kod olish' : 'Получить SMS-код')),
                          ),
                        ),
                        TextButton(
                          onPressed: busy ? null : toggleMode,
                          child: Text(register ? tx(widget.lang, 'login') : tx(widget.lang, 'register')),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}


const yangiLime = Color(0xFFA6FF00);
const yangiGraphite = Color(0xFF0F1111);
const yangiSoftGray = Color(0xFFF2F4F5);
const yangiGreen = Color(0xFF13A83E);

class YangiWordmark extends StatelessWidget {
  const YangiWordmark({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 18.0 : 26.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'Yangi',
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.8,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(width: 4),
        Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 9, vertical: compact ? 3 : 5),
          decoration: BoxDecoration(
            color: yangiLime,
            borderRadius: BorderRadius.circular(compact ? 8 : 11),
          ),
          child: Text(
            'Taxi',
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.8,
              color: yangiGraphite,
              height: 0.95,
            ),
          ),
        ),
      ],
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.api,
    required this.lang,
    required this.themeSetting,
    required this.onLang,
    required this.onTheme,
    required this.onBackend,
    required this.onLogout,
    this.onMenu,
  });
  final ApiClient api;
  final String lang;
  final String themeSetting;
  final ValueChanged<String> onLang;
  final Future<void> Function(String) onTheme;
  final Future<void> Function(String) onBackend;
  final VoidCallback onLogout;
  final VoidCallback? onMenu;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final GlobalKey<ScaffoldState> shellKey = GlobalKey<ScaffoldState>();
  int tab = 0;
  int? activeId;

  void openMenu() => shellKey.currentState?.openDrawer();

  void selectTab(int value) {
    Navigator.of(context).maybePop();
    if (mounted) setState(() => tab = value);
  }

  void orderCreated(int id) {
    setState(() {
      activeId = id;
      tab = 1;
    });
  }

  Widget menuSection(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        child: Text(
          title,
          style: const TextStyle(
            color: Color(0xFF8B8F97),
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.0,
          ),
        ),
      );

  Widget menuItem({
    required int index,
    required IconData icon,
    required String title,
    String? subtitle,
  }) {
    final selected = tab == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: ListTile(
        selected: selected,
        selectedTileColor: const Color(0xFFE8F5EC),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        leading: Icon(icon, color: selected ? const Color(0xFF1F8A4C) : null),
        title: Text(title, style: TextStyle(fontWeight: selected ? FontWeight.w900 : FontWeight.w700)),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: selected ? const Icon(Icons.chevron_right_rounded, size: 20) : null,
        onTap: () => selectTab(index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      OrderScreen(api: widget.api, lang: widget.lang, onOrder: orderCreated, onMenu: openMenu),
      RideScreen(api: widget.api, lang: widget.lang, orderId: activeId, onMenu: openMenu),
      HistoryScreen(api: widget.api, lang: widget.lang, onMenu: openMenu),
      CardsScreen(
        api: widget.api,
        lang: widget.lang,
        onMenu: openMenu,
        onDone: () => selectTab(0),
      ),
      SettingsScreen(
        api: widget.api,
        lang: widget.lang,
        themeSetting: widget.themeSetting,
        onLang: widget.onLang,
        onTheme: widget.onTheme,
        onBackend: widget.onBackend,
        onMenu: openMenu,
      ),
      ProfileScreen(
        api: widget.api,
        lang: widget.lang,
        onLang: widget.onLang,
        onBackend: widget.onBackend,
        onLogout: widget.onLogout,
        onMenu: openMenu,
      ),
    ];

    return Scaffold(
      key: shellKey,
      drawer: Drawer(
        backgroundColor: Colors.white,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: yangiLime,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: const Icon(Icons.local_taxi_rounded, color: yangiGraphite),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          YangiWordmark(compact: true),
                          SizedBox(height: 3),
                          Text('Движение ближе к вам', style: TextStyle(color: Color(0xFF8B8F97), fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 18),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    menuSection(widget.lang == 'uz' ? 'SAFARLAR' : 'ПОЕЗДКИ'),
                    menuItem(index: 0, icon: Icons.route_rounded, title: widget.lang == 'uz' ? 'Yangi buyurtma' : 'Новая поездка'),
                    menuItem(index: 1, icon: Icons.local_taxi_rounded, title: widget.lang == 'uz' ? 'Joriy safar' : 'Текущая поездка'),
                    menuItem(index: 2, icon: Icons.history_rounded, title: widget.lang == 'uz' ? 'Safarlar tarixi' : 'История поездок'),
                    menuSection(widget.lang == 'uz' ? 'TO‘LOV' : 'ОПЛАТА'),
                    menuItem(
                      index: 3,
                      icon: Icons.account_balance_wallet_rounded,
                      title: widget.lang == 'uz' ? 'To‘lov usullari' : 'Способы оплаты',
                      subtitle: widget.lang == 'uz' ? 'Kartalar va naqd' : 'Карты и наличные',
                    ),
                    menuSection(widget.lang == 'uz' ? 'AKKAUNT' : 'АККАУНТ'),
                    menuItem(index: 5, icon: Icons.person_rounded, title: widget.lang == 'uz' ? 'Profil' : 'Профиль'),
                    menuItem(index: 4, icon: Icons.settings_rounded, title: widget.lang == 'uz' ? 'Sozlamalar' : 'Настройки'),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  leading: const Icon(Icons.logout_rounded),
                  title: Text(widget.lang == 'uz' ? 'Chiqish' : 'Выйти'),
                  onTap: widget.onLogout,
                ),
              ),
            ],
          ),
        ),
      ),
      body: IndexedStack(index: tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab == 0
            ? 0
            : tab == 1
                ? 1
                : tab == 2
                    ? 2
                    : 3,
        onDestinationSelected: (index) {
          final target = switch (index) {
            0 => 0,
            1 => 1,
            2 => 2,
            _ => 5,
          };
          if (mounted) setState(() => tab = target);
        },
        destinations: <NavigationDestination>[
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home_rounded),
            label: widget.lang == 'uz' ? 'Asosiy' : 'Главная',
          ),
          NavigationDestination(
            icon: const Icon(Icons.local_taxi_outlined),
            selectedIcon: const Icon(Icons.local_taxi_rounded),
            label: widget.lang == 'uz' ? 'Safar' : 'Поездка',
          ),
          NavigationDestination(
            icon: const Icon(Icons.history_rounded),
            selectedIcon: const Icon(Icons.history_toggle_off_rounded),
            label: widget.lang == 'uz' ? 'Tarix' : 'История',
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline_rounded),
            selectedIcon: const Icon(Icons.person_rounded),
            label: widget.lang == 'uz' ? 'Profil' : 'Профиль',
          ),
        ],
      ),
    );
  }
}


const _yangiLightMapStyle = '''
[
  {"stylers":{"saturation":-0.20,"lightness":0.05}},
  {"tags":{"all":["poi"]},"elements":"label.icon","stylers":{"scale":0.78,"opacity":0.72}},
  {"tags":{"all":["poi"]},"elements":"label.text.fill","stylers":{"color":"#676B72"}},
  {"tags":{"all":["road"]},"elements":"geometry","stylers":{"saturation":-0.35,"lightness":0.10}},
  {"tags":{"all":["park"]},"elements":"geometry.fill","stylers":{"color":"#E8F2E6"}},
  {"tags":{"all":["water"]},"elements":"geometry.fill","stylers":{"color":"#DCEBF1"}},
  {"tags":{"all":["building"]},"elements":"geometry.fill","stylers":{"color":"#ECEBE7"}}
]
''';

const _yangiDarkMapStyle = '''
[
  {"stylers":{"saturation":-0.38,"lightness":-0.12}},
  {"tags":{"all":["poi"]},"elements":"label.icon","stylers":{"scale":0.75,"opacity":0.62}},
  {"tags":{"all":["road"]},"elements":"geometry","stylers":{"saturation":-0.45}},
  {"tags":{"all":["park"]},"elements":"geometry.fill","stylers":{"color":"#1D3025"}},
  {"tags":{"all":["water"]},"elements":"geometry.fill","stylers":{"color":"#152A33"}}
]
''';

void _applyYangiMapAppearance(ym.Map map, bool dark) {
  map.mapType = ym.MapType.VectorMap;
  map.mode = ym.MapMode.Driving;
  map.set2DMode(true);
  map.hdModeEnabled = true;
  map.nightModeEnabled = dark;
  map.poiLimit = 28;
  map.fastTapEnabled = true;
  map.rotateGesturesEnabled = false;
  map.tiltGesturesEnabled = false;
  map.setMapStyle(dark ? _yangiDarkMapStyle : _yangiLightMapStyle);
}

class _MapPinMarker extends StatelessWidget {
  const _MapPinMarker({required this.pickup});
  final bool pickup;

  @override
  Widget build(BuildContext context) {
    final fill = pickup ? const Color(0xFFFFD900) : const Color(0xFF17191C);
    final center = pickup ? const Color(0xFF17191C) : Colors.white;
    return SizedBox(
      width: 44,
      height: 58,
      child: Stack(
        alignment: Alignment.topCenter,
        children: <Widget>[
          Positioned(
            top: 3,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: fill,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const <BoxShadow>[
                  BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 4)),
                ],
              ),
              child: Center(
                child: Container(
                  width: 13,
                  height: 13,
                  decoration: BoxDecoration(
                    color: center,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: pickup ? fill : const Color(0xFF17191C),
                      width: 3,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 39,
            child: Transform.rotate(
              angle: math.pi / 4,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: fill,
                  border: const Border(
                    right: BorderSide(color: Colors.white, width: 2),
                    bottom: BorderSide(color: Colors.white, width: 2),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapCarMarker extends StatelessWidget {
  const _MapCarMarker({required this.kind, this.driver = false});
  final String kind;
  final bool driver;

  Color get accent {
    if (driver) return const Color(0xFF17191C);
    switch (kind) {
      case 'business':
        return const Color(0xFF25272B);
      case 'comfort':
        return const Color(0xFFBFC5CC);
      case 'delivery':
        return const Color(0xFFFFD900);
      case 'cargo':
        return const Color(0xFF2F3338);
      case 'together':
        return const Color(0xFFFFC400);
      default:
        return const Color(0xFFFFD900);
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = switch (kind) {
      'delivery' => Icons.local_shipping_rounded,
      'cargo' => Icons.fire_truck_rounded,
      'business' => Icons.time_to_leave_rounded,
      'comfort' => Icons.directions_car_filled_rounded,
      'together' => Icons.people_alt_rounded,
      _ => Icons.local_taxi_rounded,
    };
    return Container(
      width: driver ? 44 : 38,
      height: driver ? 44 : 38,
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white, width: 2.2),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 3)),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Icon(
            icon,
            size: driver ? 26 : 22,
            color: kind == 'comfort' ? const Color(0xFF1D2329) : Colors.white,
          ),
          if (driver)
            const Positioned(
              right: 3,
              top: 3,
              child: CircleAvatar(radius: 4, backgroundColor: Color(0xFFFFD900)),
            ),
        ],
      ),
    );
  }
}

class _TariffVehicleArt extends StatelessWidget {
  const _TariffVehicleArt({required this.kind, required this.selected, required this.available});
  final String kind;
  final bool selected;
  final bool available;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: available ? 1 : 0.36,
      child: CustomPaint(
        painter: _TariffVehiclePainter(kind: kind, selected: selected),
        size: const Size(112, 48),
      ),
    );
  }
}

class _TariffVehiclePainter extends CustomPainter {
  const _TariffVehiclePainter({required this.kind, required this.selected});
  final String kind;
  final bool selected;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 112;
    final sy = size.height / 48;
    canvas.save();
    canvas.scale(sx, sy);

    canvas.drawOval(const Rect.fromLTWH(12, 38, 91, 7), Paint()..color = const Color(0x22000000));

    final body = Paint()..color = _bodyColor(kind);
    final dark = Paint()..color = const Color(0xFF252A30);
    final glass = Paint()..color = const Color(0xFF4B5864);
    final wheel = Paint()..color = const Color(0xFF151719);
    final rim = Paint()..color = const Color(0xFFAEB4BB);
    final yellow = Paint()..color = const Color(0xFFFFD900);

    if (kind == 'cargo') {
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(13, 13, 61, 25), const Radius.circular(3)),
        yellow,
      );
      final cab = Path()
        ..moveTo(74, 20)
        ..lineTo(91, 20)
        ..lineTo(104, 30)
        ..lineTo(104, 38)
        ..lineTo(74, 38)
        ..close();
      canvas.drawPath(cab, dark);
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(83, 23, 13, 8), const Radius.circular(2)),
        glass,
      );
      _wheel(canvas, 30, 39, wheel, rim);
      _wheel(canvas, 87, 39, wheel, rim);
    } else if (kind == 'delivery') {
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(20, 13, 65, 25), const Radius.circular(7)),
        yellow,
      );
      final nose = Path()
        ..moveTo(85, 23)
        ..lineTo(98, 25)
        ..lineTo(106, 33)
        ..lineTo(106, 38)
        ..lineTo(84, 38)
        ..close();
      canvas.drawPath(nose, yellow);
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(90, 26, 10, 6), const Radius.circular(2)),
        glass,
      );
      canvas.drawRect(const Rect.fromLTWH(44, 18, 15, 13), Paint()..color = Colors.white);
      final boxLine = Paint()..color = const Color(0x99252A30)..strokeWidth = 1.2;
      canvas.drawLine(const Offset(51.5, 18), const Offset(51.5, 31), boxLine);
      canvas.drawLine(const Offset(44, 24.5), const Offset(59, 24.5), boxLine);
      _wheel(canvas, 34, 39, wheel, rim);
      _wheel(canvas, 89, 39, wheel, rim);
    } else {
      final compact = kind == 'start' || kind == 'together';
      final premium = kind == 'business';
      final path = Path()
        ..moveTo(8, 35)
        ..lineTo(16, 27)
        ..lineTo(compact ? 34 : 31, compact ? 19 : 17)
        ..lineTo(compact ? 68 : 73, compact ? 19 : 17)
        ..lineTo(86, 24)
        ..lineTo(104, 33)
        ..lineTo(106, 38)
        ..lineTo(10, 38)
        ..close();
      canvas.drawPath(path, body);
      final frontWindow = Path()
        ..moveTo(compact ? 38 : 35, compact ? 21 : 19)
        ..lineTo(54, compact ? 21 : 19)
        ..lineTo(54, 29)
        ..lineTo(31, 29)
        ..close();
      canvas.drawPath(frontWindow, glass);
      final rearWindow = Path()
        ..moveTo(57, compact ? 21 : 19)
        ..lineTo(compact ? 68 : 72, compact ? 21 : 19)
        ..lineTo(82, 28)
        ..lineTo(57, 29)
        ..close();
      canvas.drawPath(rearWindow, glass);
      if (premium) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(47, 33, 20, 1.8), const Radius.circular(1)),
          Paint()..color = const Color(0xFFC8A44D),
        );
      }
      if (kind == 'comfort') {
        final accent = Path()
          ..moveTo(23, 31)
          ..lineTo(36, 22)
          ..lineTo(42, 31)
          ..close();
        canvas.drawPath(accent, yellow);
      }
      if (kind == 'together') {
        canvas.drawCircle(const Offset(64, 24), 2.2, yellow);
        canvas.drawCircle(const Offset(71, 24), 2.2, yellow);
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(60, 27, 15, 4), const Radius.circular(2)),
          yellow,
        );
      }
      _wheel(canvas, 28, 39, wheel, rim);
      _wheel(canvas, 83, 39, wheel, rim);
    }

    canvas.restore();
  }

  void _wheel(Canvas canvas, double x, double y, Paint wheel, Paint rim) {
    canvas.drawCircle(Offset(x, y), 7, wheel);
    canvas.drawCircle(Offset(x, y), 3.5, rim);
    canvas.drawCircle(Offset(x, y), 1.4, Paint()..color = const Color(0xFF555B62));
  }

  Color _bodyColor(String key) {
    switch (key) {
      case 'comfort':
        return const Color(0xFFD9DEE3);
      case 'business':
        return const Color(0xFF202328);
      default:
        return const Color(0xFFFFD900);
    }
  }

  @override
  bool shouldRepaint(covariant _TariffVehiclePainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.selected != selected;
}

class _TariffGlyph extends StatelessWidget {
  const _TariffGlyph({required this.kind, required this.selected});
  final String kind;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final icon = switch (kind) {
      'together' => Icons.people_alt_rounded,
      'comfort' => Icons.airline_seat_recline_extra_rounded,
      'business' => Icons.workspace_premium_rounded,
      'delivery' => Icons.inventory_2_rounded,
      'cargo' => Icons.local_shipping_rounded,
      _ => Icons.local_taxi_rounded,
    };
    return Container(
      width: 29,
      height: 29,
      decoration: BoxDecoration(
        color: selected ? Colors.white.withValues(alpha: 0.78) : Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 17, color: const Color(0xFF17191C)),
    );
  }
}

class TaxiYandexMap extends StatefulWidget {
  const TaxiYandexMap({
    super.key,
    required this.center,
    this.route = const <ym.Point>[],
    this.from,
    this.to,
    this.driver,
    this.nearbyCars = const <NearbyCrew>[],
    this.vehicleKind = 'start',
    this.zoom = 14,
  });
  final ym.Point center;
  final List<ym.Point> route;
  final ym.Point? from;
  final ym.Point? to;
  final ym.Point? driver;
  final List<NearbyCrew> nearbyCars;
  final String vehicleKind;
  final double zoom;

  @override
  State<TaxiYandexMap> createState() => _TaxiYandexMapState();
}

class _TaxiYandexMapState extends State<TaxiYandexMap> {
  ym.MapWindow? mapWindow;
  bool darkMode = false;
  final Map<String, yv.ViewProvider> _providers = <String, yv.ViewProvider>{};

  yv.ViewProvider _pinProvider(bool pickup) => _providers.putIfAbsent(
        'pin-' + (pickup ? 'pickup' : 'destination'),
        () => yv.ViewProvider(
          id: 'yangi-pin-' + (pickup ? 'pickup' : 'destination'),
          cacheable: true,
          builder: () => _MapPinMarker(pickup: pickup),
        ),
      );

  yv.ViewProvider _carProvider(String kind, {bool driver = false}) => _providers.putIfAbsent(
        'car-' + kind + '-' + driver.toString(),
        () => yv.ViewProvider(
          id: 'yangi-car-' + kind + '-' + driver.toString(),
          cacheable: true,
          builder: () => _MapCarMarker(kind: kind, driver: driver),
        ),
      );

  @override
  void initState() {
    super.initState();
    if (yandexMapKitApiKey.isNotEmpty) ym_factory.mapkit.onStart();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextDark = Theme.of(context).brightness == Brightness.dark;
    if (nextDark != darkMode) {
      darkMode = nextDark;
      final window = mapWindow;
      if (window != null) {
        _applyYangiMapAppearance(window.map, darkMode);
        _render(focusRoute: false);
      }
    }
  }

  @override
  void didUpdateWidget(covariant TaxiYandexMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (mapWindow != null) _render(focusRoute: false);
  }

  @override
  void dispose() {
    if (yandexMapKitApiKey.isNotEmpty) ym_factory.mapkit.onStop();
    super.dispose();
  }

  void _render({bool focusRoute = true}) {
    final window = mapWindow;
    if (window == null) return;
    final map = window.map;
    map.mapObjects.clear();

    if (widget.route.length > 1) {
      final polyline = ym.Polyline(widget.route);
      map.mapObjects.addPolylineWithGeometry(polyline)
        ..strokeWidth = 7.5
        ..setStrokeColor(darkMode ? const Color(0xCC121416) : const Color(0xCCFFFFFF));
      map.mapObjects.addPolylineWithGeometry(polyline)
        ..strokeWidth = 4.5
        ..setStrokeColor(const Color(0xFF18B66A));
      if (focusRoute) {
        map.move(map.cameraPositionForGeometry(ym.Geometry.fromPolyline(polyline)));
      }
    }

    if (widget.from != null) {
      map.mapObjects.addPlacemark()
        ..geometry = widget.from!
        ..setViewWithStyle(
          _pinProvider(true),
          const ym.IconStyle(
            anchor: math.Point<double>(0.5, 1.0),
            scale: 0.82,
            zIndex: 22,
          ),
        );
    }

    if (widget.to != null) {
      map.mapObjects.addPlacemark()
        ..geometry = widget.to!
        ..setViewWithStyle(
          _pinProvider(false),
          const ym.IconStyle(
            anchor: math.Point<double>(0.5, 1.0),
            scale: 0.82,
            zIndex: 23,
          ),
        );
    }

    for (final car in widget.nearbyCars) {
      final placemark = map.mapObjects.addPlacemark()
        ..geometry = car.point
        ..direction = car.direction >= 0 ? car.direction : 0;
      placemark.setViewWithStyle(
        _carProvider(widget.vehicleKind),
        const ym.IconStyle(
          anchor: math.Point<double>(0.5, 0.5),
          scale: 0.82,
          zIndex: 15,
        ),
      );
    }

    if (widget.driver != null) {
      map.mapObjects.addPlacemark()
        ..geometry = widget.driver!
        ..setViewWithStyle(
          _carProvider(widget.vehicleKind, driver: true),
          const ym.IconStyle(
            anchor: math.Point<double>(0.5, 0.5),
            scale: 0.92,
            zIndex: 30,
          ),
        );
    }

    if (!focusRoute || widget.route.length < 2) {
      map.move(ym.CameraPosition(widget.center, zoom: widget.zoom, azimuth: 0, tilt: 0));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (yandexMapKitApiKey.isEmpty) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.map_outlined, size: 46),
            SizedBox(height: 10),
            Text(
              'Для отображения карты нужен Yandex MapKit API-ключ.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return ym_widget.YandexMap(
      onMapCreated: (window) {
        mapWindow = window;
        _applyYangiMapAppearance(window.map, darkMode);
        _render();
      },
    );
  }
}

class OrderScreen extends StatefulWidget {
  const OrderScreen({
    super.key,
    required this.api,
    required this.lang,
    required this.onOrder,
    required this.onMenu,
  });
  final ApiClient api;
  final String lang;
  final ValueChanged<int> onOrder;
  final VoidCallback onMenu;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  Place? from;
  Place? to;
  double? cost;
  List<ym.Point> route = <ym.Point>[];
  bool busy = false;
  bool locating = false;
  String? error;
  String? locationHint;
  ym.Point? currentLocation;
  List<NearbyCrew> nearbyCars = <NearbyCrew>[];
  Timer? nearbyCarsTimer;
  bool loadingNearbyCars = false;
  bool estimating = false;
  Timer? estimateTimer;
  int estimateGeneration = 0;
  List<Map<String, dynamic>> tariffCatalog = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> tariffOptions = <Map<String, dynamic>>[];
  String selectedTariffKey = 'start';
  String paymentMethod = 'cash';
  bool atmosEnabled = false;
  bool cardBindingAvailable = false;
  List<Map<String, dynamic>> cards = <Map<String, dynamic>>[];
  int selectedCardId = 0;
  late final ys.SearchManager locationSearchManager;
  ys.SearchSession? locationSearchSession;

  @override
  void initState() {
    super.initState();
    locationSearchManager = ys.SearchFactory.instance.createSearchManager(ys.SearchManagerType.Online);
    loadPaymentConfig();
    loadCards();
    loadTariffCatalog();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      detectMyLocation(auto: true);
    });
    nearbyCarsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      loadNearbyCars();
    });
  }

  @override
  void dispose() {
    nearbyCarsTimer?.cancel();
    estimateTimer?.cancel();
    locationSearchSession?.cancel();
    super.dispose();
  }

  Future<Place?> selectAddress(String title, Place? initial) => showModalBottomSheet<Place>(
        context: context,
        isScrollControlled: true,
        builder: (_) => AddressSheet(api: widget.api, lang: widget.lang, title: title, initial: initial),
      );

  Future<void> ensurePickupFromCurrentLocation() async {
    if (from != null) return;
    if (currentLocation == null) {
      await detectMyLocation(auto: false);
      if (from != null) return;
    }
    final point = currentLocation;
    if (point == null) return;
    final place = await reverseCurrentLocation(point);
    if (!mounted) return;
    setState(() {
      from = place;
      cost = null;
      route = <ym.Point>[];
    });
    await loadNearbyCars();
  }

  Future<void> pickRoutePointOnMap({required bool pickup}) async {
    if (!pickup) await ensurePickupFromCurrentLocation();
    final title = pickup ? tx(widget.lang, 'from') : tx(widget.lang, 'to');
    final initial = pickup
        ? (from ?? (currentLocation == null
            ? null
            : Place(
                widget.lang == 'uz' ? 'Joriy joylashuv' : 'Текущее местоположение',
                currentLocation!.latitude,
                currentLocation!.longitude,
              )))
        : (to ?? from ?? (currentLocation == null
            ? null
            : Place(
                widget.lang == 'uz' ? 'Joriy joylashuv' : 'Текущее местоположение',
                currentLocation!.latitude,
                currentLocation!.longitude,
              )));

    final place = await Navigator.of(context).push<Place>(
      MaterialPageRoute(
        builder: (_) => MapPointPickerScreen(
          title: title,
          lang: widget.lang,
          initial: initial,
        ),
      ),
    );
    if (place == null || !mounted) return;

    setState(() {
      if (pickup) {
        from = place;
      } else {
        to = place;
      }
      cost = null;
      route = <ym.Point>[];
      error = null;
    });

    if (pickup) await loadNearbyCars();
    scheduleEstimate();
  }

  Future<void> loadPaymentConfig() async {
    try {
      final data = await widget.api.get('/api/payments/config');
      if (!mounted || data is! Map) return;
      setState(() {
        atmosEnabled = data['atmosEnabled'] == true;
        cardBindingAvailable = data['cardBindingAvailable'] == true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          atmosEnabled = false;
          cardBindingAvailable = false;
        });
      }
    }
  }

  Future<void> loadCards() async {
    try {
      final data = await widget.api.get('/api/cards');
      if (!mounted || data is! Map) return;
      final raw = data['cards'];
      final loaded = raw is List
          ? raw.whereType<Map>().map((x) => Map<String, dynamic>.from(x)).toList()
          : <Map<String, dynamic>>[];
      final defaultId = (data['defaultCardId'] as num?)?.toInt() ?? 0;
      setState(() {
        cards = loaded;
        cardBindingAvailable = data['cardBindingAvailable'] == true || cardBindingAvailable;
        if (!loaded.any((c) => (c['cardId'] as num?)?.toInt() == selectedCardId)) {
          selectedCardId = defaultId > 0
              ? defaultId
              : (loaded.isEmpty ? 0 : ((loaded.first['cardId'] as num?)?.toInt() ?? 0));
        }
      });
    } catch (_) {
      if (mounted) setState(() => cards = <Map<String, dynamic>>[]);
    }
  }

  Future<void> loadTariffCatalog() async {
    try {
      final data = await widget.api.get('/api/tariffs');
      if (!mounted || data is! List) return;
      final loaded = data
          .whereType<Map>()
          .map((x) => Map<String, dynamic>.from(x))
          .toList();
      if (loaded.isEmpty) return;

      String nextKey = selectedTariffKey;
      final currentAvailable = loaded.any(
        (x) => (x['key'] ?? '').toString() == selectedTariffKey && x['available'] == true,
      );
      if (!currentAvailable) {
        for (final item in loaded) {
          if (item['available'] == true) {
            nextKey = (item['key'] ?? 'start').toString();
            break;
          }
        }
      }

      setState(() {
        tariffCatalog = loaded;
        selectedTariffKey = nextKey;
      });
    } catch (_) {
      // Older backends may not expose /api/tariffs. Route estimates still work.
    }
  }

  List<Map<String, dynamic>> get visibleTariffs =>
      tariffOptions.isNotEmpty ? tariffOptions : tariffCatalog;

  Map<String, dynamic>? get selectedCard {
    for (final card in cards) {
      if ((card['cardId'] as num?)?.toInt() == selectedCardId) return card;
    }
    return cards.isEmpty ? null : cards.first;
  }

  Future<void> openCardsManager() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CardsScreen(api: widget.api, lang: widget.lang),
      ),
    );
    await loadCards();
    if (cards.isNotEmpty && mounted) {
      setState(() => paymentMethod = 'card');
    }
  }

  Map<String, dynamic>? get selectedTariff {
    for (final option in visibleTariffs) {
      if ((option['key'] ?? '').toString() == selectedTariffKey && option['available'] == true) {
        return option;
      }
    }
    for (final option in visibleTariffs) {
      if (option['available'] == true) return option;
    }
    return null;
  }

  IconData tariffIcon(String key) {
    switch (key) {
      case 'together':
        return Icons.groups_rounded;
      case 'comfort':
        return Icons.airline_seat_recline_extra_rounded;
      case 'business':
        return Icons.business_center_rounded;
      case 'delivery':
        return Icons.inventory_2_rounded;
      case 'cargo':
        return Icons.local_shipping_rounded;
      default:
        return Icons.local_taxi_rounded;
    }
  }

  void selectTariff(String key) {
    Map<String, dynamic>? option;
    for (final item in visibleTariffs) {
      if ((item['key'] ?? '').toString() == key) {
        option = item;
        break;
      }
    }
    if (option == null || option['available'] != true) return;
    setState(() {
      selectedTariffKey = key;
      cost = (option!['cost'] as num?)?.toDouble();
    });
  }

  String get selectedServiceMode {
    if (selectedTariffKey == 'together') return 'together';
    if (selectedTariffKey == 'delivery') return 'delivery';
    if (selectedTariffKey == 'cargo') return 'cargo';
    return 'taxi';
  }

  void selectServiceMode(String mode) {
    final target = switch (mode) {
      'together' => 'together',
      'delivery' => 'delivery',
      'cargo' => 'cargo',
      _ => 'start',
    };

    Map<String, dynamic>? option;
    for (final item in visibleTariffs) {
      if ((item['key'] ?? '').toString() == target) {
        option = item;
        break;
      }
    }

    setState(() {
      selectedTariffKey = target;
      cost = option != null && option['available'] == true
          ? (option['cost'] as num?)?.toDouble()
          : null;
      error = null;
    });

    if (from != null && to != null) {
      scheduleEstimate(delay: Duration.zero);
    }
  }

  List<Map<String, dynamic>> get serviceTariffs {
    final mode = selectedServiceMode;
    return visibleTariffs.where((item) {
      final key = (item['key'] ?? '').toString();
      if (mode == 'taxi') return key == 'start' || key == 'comfort' || key == 'business';
      return key == mode;
    }).toList();
  }

  void scheduleEstimate({Duration delay = const Duration(milliseconds: 250)}) {
    estimateTimer?.cancel();
    if (from == null || to == null) {
      if (mounted) {
        setState(() {
          estimating = false;
          cost = null;
          tariffOptions = <Map<String, dynamic>>[];
          route = <ym.Point>[];
        });
      }
      return;
    }
    final generation = ++estimateGeneration;
    if (mounted) {
      setState(() {
        estimating = true;
        cost = null;
        error = null;
      });
    }
    estimateTimer = Timer(delay, () => estimate(generation: generation));
  }

  Future<void> loadNearbyCars() async {
    if (loadingNearbyCars) return;
    final center = from?.point ?? currentLocation;
    if (center == null) return;

    loadingNearbyCars = true;
    try {
      final data = await widget.api.get(
        '/api/crews/nearby',
        query: <String, String>{
          'lat': center.latitude.toStringAsFixed(7),
          'lon': center.longitude.toStringAsFixed(7),
          'radius': '15',
          'limit': '15',
        },
      );
      final cars = (data as List)
          .whereType<Map>()
          .map((x) => NearbyCrew.fromJson(Map<String, dynamic>.from(x)))
          .toList();
      if (mounted) setState(() => nearbyCars = cars);
    } catch (_) {
      // Nearby cars are a convenience layer. Keep ordering usable if the endpoint is unavailable.
    } finally {
      loadingNearbyCars = false;
    }
  }

  Future<Place> reverseCurrentLocation(ym.Point point) async {
    final completer = Completer<Place>();
    final listener = ys.SearchSessionSearchListener(
      onSearchResponse: (response) {
        String label = '';
        for (final item in response.collection.children) {
          final object = item.asGeoObject();
          if (object == null) continue;
          final name = object.name?.trim() ?? '';
          final description = object.descriptionText?.trim() ?? '';
          label = description.isEmpty || description == name
              ? name
              : (name.isEmpty ? description : '$name, $description');
          if (label.isNotEmpty) break;
        }
        if (label.isEmpty) {
          label = widget.lang == 'uz' ? 'Joriy joylashuv' : 'Текущее местоположение';
        }
        if (!completer.isCompleted) {
          completer.complete(Place(label, point.latitude, point.longitude));
        }
      },
      onSearchError: (_) {
        if (!completer.isCompleted) {
          completer.complete(
            Place(
              widget.lang == 'uz' ? 'Joriy joylashuv' : 'Текущее местоположение',
              point.latitude,
              point.longitude,
            ),
          );
        }
      },
    );

    locationSearchSession?.cancel();
    locationSearchSession = locationSearchManager.submitPoint(
      point,
      const ys.SearchOptions(
        searchTypes: ys.SearchType.Geo,
        resultPageSize: 5,
      ),
      listener,
      zoom: 17,
    );

    return completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => Place(
        widget.lang == 'uz' ? 'Joriy joylashuv' : 'Текущее местоположение',
        point.latitude,
        point.longitude,
      ),
    );
  }

  Future<void> applyQuickLocation(Position position) async {
    final point = ym.Point(latitude: position.latitude, longitude: position.longitude);
    if (mounted) setState(() => currentLocation = point);
    try {
      final place = await reverseCurrentLocation(point);
      if (!mounted) return;
      if (from == null) {
        setState(() {
          from = place;
          cost = null;
          route = <ym.Point>[];
        });
      }
      await loadNearbyCars();
      if (to != null) scheduleEstimate();
    } catch (_) {}
  }

  Future<void> detectMyLocation({bool auto = false}) async {
    if (locating) return;
    if (mounted) {
      setState(() {
        locating = true;
        locationHint = null;
        if (!auto) error = null;
      });
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            locationHint = widget.lang == 'uz'
                ? 'Geolokatsiyani yoqing'
                : 'Включите геолокацию на телефоне';
          });
        }
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        if (mounted) {
          setState(() {
            locationHint = widget.lang == 'uz'
                ? 'Joylashuvga ruxsat berilmadi'
                : 'Доступ к геолокации не разрешён';
          });
        }
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            locationHint = widget.lang == 'uz'
                ? 'Joylashuv ruxsati sozlamalarda o‘chirilgan'
                : 'Геолокация запрещена в настройках приложения';
          });
        }
        return;
      }

      if (auto) {
        final lastPosition = await Geolocator.getLastKnownPosition();
        if (lastPosition != null) {
          await applyQuickLocation(lastPosition);
        }
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      final point = ym.Point(
        latitude: position.latitude,
        longitude: position.longitude,
      );

      if (mounted) {
        setState(() {
          currentLocation = point;
        });
      }

      final place = await reverseCurrentLocation(point);
      if (!mounted) return;

      if (!auto || from == null) {
        setState(() {
          from = place;
          cost = null;
          route = <ym.Point>[];
          locationHint = position.accuracy > 100
              ? (widget.lang == 'uz'
                  ? 'Joylashuv aniqligi taxminan ${position.accuracy.toStringAsFixed(0)} m'
                  : 'Точность геолокации около ${position.accuracy.toStringAsFixed(0)} м')
              : null;
        });
      }
      await loadNearbyCars();
      if (to != null) scheduleEstimate();
    } catch (_) {
      if (mounted) {
        setState(() {
          locationHint = widget.lang == 'uz'
              ? 'Joylashuvni aniqlab bo‘lmadi'
              : 'Не удалось определить местоположение';
        });
      }
    } finally {
      if (mounted) setState(() => locating = false);
    }
  }

  Future<void> openLocationSettings() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      await Geolocator.openLocationSettings();
      return;
    }
    await Geolocator.openAppSettings();
  }

  Future<void> estimate({int? generation}) async {
    if (from == null || to == null) return;
    final currentGeneration = generation ?? ++estimateGeneration;
    final source = from!;
    final destination = to!;
    if (mounted) {
      setState(() {
        estimating = true;
        error = null;
      });
    }

    try {
      final data = await widget.api.post('/api/orders/estimate-options', <String, dynamic>{
        'source': source.toJson(),
        'destination': destination.toJson(),
      });
      if (currentGeneration != estimateGeneration || !mounted) return;

      final mapData = data['route'];
      final points = <ym.Point>[];
      if (mapData is Map && mapData['full_route_coords'] is List) {
        for (final dynamic x in mapData['full_route_coords'] as List) {
          if (x is Map && x['lat'] != null && x['lon'] != null) {
            points.add(
              ym.Point(
                latitude: (x['lat'] as num).toDouble(),
                longitude: (x['lon'] as num).toDouble(),
              ),
            );
          }
        }
      }

      final rawOptions = data['options'];
      final options = rawOptions is List
          ? rawOptions
              .whereType<Map>()
              .map((x) => Map<String, dynamic>.from(x))
              .toList()
          : <Map<String, dynamic>>[];

      Map<String, dynamic>? active;
      for (final item in options) {
        if ((item['key'] ?? '').toString() == selectedTariffKey && item['available'] == true) {
          active = item;
          break;
        }
      }
      active ??= options.cast<Map<String, dynamic>?>().firstWhere(
            (item) => item?['available'] == true,
            orElse: () => null,
          );

      setState(() {
        tariffOptions = options;
        route = points;
        if (active != null) {
          selectedTariffKey = (active!['key'] ?? 'start').toString();
          cost = (active!['cost'] as num?)?.toDouble();
        } else {
          cost = null;
          error = widget.lang == 'uz'
              ? 'TaxiMasterda ilova uchun mavjud tariflar sozlanmagan'
              : 'В TaxiMaster не настроены доступные тарифы и группы экипажей';
        }
      });
    } catch (e) {
      if (currentGeneration == estimateGeneration && mounted) {
        setState(() {
          cost = null;
          tariffOptions = <Map<String, dynamic>>[];
          error = e.toString();
        });
      }
    } finally {
      if (currentGeneration == estimateGeneration && mounted) {
        setState(() => estimating = false);
      }
    }
  }

  Future<int?> checkAtmosPayment(String checkoutId) async {
    final data = await widget.api.get('/api/payments/' + Uri.encodeComponent(checkoutId) + '/status');
    if (data is! Map) return null;
    final orderId = (data['orderId'] as num?)?.toInt();
    if (orderId != null && orderId > 0) return orderId;

    final status = (data['status'] ?? '').toString();
    if (status == 'failed') {
      throw ApiException(widget.lang == 'uz' ? 'To‘lov amalga oshmadi' : 'Оплата не прошла');
    }
    return null;
  }

  Future<int?> showAtmosPaymentDialog({
    required String checkoutId,
    required String paymentUrl,
    required double amount,
  }) async {
    final uri = Uri.tryParse(paymentUrl);
    if (uri == null) throw ApiException('ATMOS вернул некорректную ссылку оплаты');

    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      throw ApiException(widget.lang == 'uz'
          ? 'ATMOS to‘lov sahifasini ochib bo‘lmadi'
          : 'Не удалось открыть страницу оплаты ATMOS');
    }
    if (!mounted) return null;

    bool checking = false;
    String message = widget.lang == 'uz'
        ? 'ATMOS sahifasida to‘lovni yakunlang, so‘ng tekshiring.'
        : 'Завершите оплату на странице ATMOS, затем проверьте её статус.';

    return showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: const Icon(Icons.verified_user_outlined, size: 34),
          title: Text(widget.lang == 'uz' ? 'ATMOS orqali to‘lov' : 'Оплата через ATMOS'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                amount.toStringAsFixed(0) + ' UZS',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: checking ? null : () => Navigator.pop(dialogContext),
              child: Text(widget.lang == 'uz' ? 'Keyinroq' : 'Позже'),
            ),
            TextButton.icon(
              onPressed: checking
                  ? null
                  : () async {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    },
              icon: const Icon(Icons.open_in_new),
              label: Text(widget.lang == 'uz' ? 'ATMOSni ochish' : 'Открыть ATMOS'),
            ),
            FilledButton.icon(
              onPressed: checking
                  ? null
                  : () async {
                      setDialogState(() {
                        checking = true;
                        message = widget.lang == 'uz' ? 'To‘lov tekshirilmoqda…' : 'Проверяем оплату…';
                      });
                      try {
                        final orderId = await checkAtmosPayment(checkoutId);
                        if (!dialogContext.mounted) return;
                        if (orderId != null) {
                          Navigator.pop(dialogContext, orderId);
                          return;
                        }
                        setDialogState(() {
                          checking = false;
                          message = widget.lang == 'uz'
                              ? 'To‘lov hali tasdiqlanmadi. ATMOSda to‘lovni yakunlab, yana tekshiring.'
                              : 'Оплата пока не подтверждена. Завершите её в ATMOS и проверьте ещё раз.';
                        });
                      } catch (e) {
                        if (!dialogContext.mounted) return;
                        setDialogState(() {
                          checking = false;
                          message = e.toString();
                        });
                      }
                    },
              icon: checking
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(widget.lang == 'uz' ? 'To‘lovni tekshirish' : 'Проверить оплату'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> createOrder() async {
    final deliveryWithoutDestination = selectedTariffKey == 'delivery' && to == null;
    if (from == null || (to == null && !deliveryWithoutDestination)) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await widget.api.post('/api/orders', <String, dynamic>{
        'source': from!.toJson(),
        if (to != null) 'destination': to!.toJson(),
        'tariffKey': selectedTariffKey,
        'paymentMethod': paymentMethod,
        if (paymentMethod == 'card' && selectedCardId > 0) 'cardId': selectedCardId,
      });

      if (data is Map && data['paymentRequired'] == true) {
        final checkoutId = (data['checkoutId'] ?? '').toString();
        final paymentUrl = (data['paymentUrl'] ?? '').toString();
        final amount = (data['amount'] as num?)?.toDouble() ?? cost ?? 0;
        if (checkoutId.isEmpty || paymentUrl.isEmpty) {
          throw ApiException('ATMOS не вернул данные для оплаты');
        }

        if (mounted) setState(() => busy = false);
        final orderId = await showAtmosPaymentDialog(
          checkoutId: checkoutId,
          paymentUrl: paymentUrl,
          amount: amount,
        );
        if (orderId != null && mounted) {
          widget.onOrder(orderId);
        }
        return;
      }

      final orderId = data is Map ? (data['order_id'] as num?)?.toInt() : null;
      if (orderId == null || orderId <= 0) {
        throw ApiException('TaxiMaster не вернул номер заказа');
      }
      widget.onOrder(orderId);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted && busy) setState(() => busy = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    final center = from?.point ?? currentLocation ?? const ym.Point(latitude: defaultLat, longitude: defaultLon);
    final canUseCard = atmosEnabled && cardBindingAvailable;
    final destinationReady = to != null;
    final destinationOptional = selectedTariffKey == 'delivery';
    final routeReadyForOrder = from != null && (destinationReady || destinationOptional);
    final tariffs = serviceTariffs;
    final serviceMode = selectedServiceMode;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F5F2),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: TaxiYandexMap(
              center: center,
              route: route,
              from: from?.point,
              to: to?.point,
              nearbyCars: nearbyCars,
              vehicleKind: selectedTariffKey,
              zoom: destinationReady ? 13 : 15,
            ),
          ),
          Positioned(
            top: 10,
            left: 12,
            right: 12,
            child: SafeArea(
              bottom: false,
              child: Row(
                children: <Widget>[
                  _roundMapButton(icon: Icons.menu_rounded, onTap: widget.onMenu, tooltip: 'Yangi Taxi'),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(color: Color(0x24000000), blurRadius: 16, offset: Offset(0, 4)),
                      ],
                    ),
                    child: const Text('Yangi Taxi', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                  ),
                  const Spacer(),
                  _roundMapButton(
                    icon: locating ? Icons.more_horiz_rounded : Icons.my_location_rounded,
                    onTap: locating ? null : () => detectMyLocation(),
                    tooltip: widget.lang == 'uz' ? 'Mening joylashuvim' : 'Моё местоположение',
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 14,
            bottom: MediaQuery.of(context).size.height * 0.34,
            child: SafeArea(
              child: _roundMapButton(
                icon: Icons.near_me_rounded,
                onTap: locating ? null : () => detectMyLocation(),
                tooltip: widget.lang == 'uz' ? 'Mening joylashuvim' : 'Моё местоположение',
                large: true,
              ),
            ),
          ),
          DraggableScrollableSheet(
            initialChildSize: destinationReady ? 0.54 : 0.38,
            minChildSize: 0.29,
            maxChildSize: 0.76,
            snap: true,
            snapSizes: const <double>[0.38, 0.54, 0.76],
            builder: (context, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(color: Color(0x26000000), blurRadius: 24, offset: Offset(0, -7)),
                  ],
                ),
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                  children: <Widget>[
                    Center(
                      child: Container(
                        width: 42,
                        height: 5,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD2D3D6),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    const SizedBox(height: 13),
                    if (!destinationReady)
                      Text(
                        widget.lang == 'uz' ? 'Qayerga boramiz?' : 'Куда поедем?',
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: -0.5),
                      )
                    else
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              widget.lang == 'uz' ? 'Safar tafsilotlari' : 'Детали поездки',
                              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, letterSpacing: -0.4),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F2F4),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const Icon(Icons.schedule_rounded, size: 16),
                                const SizedBox(width: 5),
                                Text(
                                  widget.lang == 'uz' ? 'Hozir' : 'Сейчас',
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 13),
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        children: <Widget>[
                          _addressLine(
                            pickup: true,
                            title: widget.lang == 'uz' ? 'Qayerdan' : 'Откуда',
                            value: from?.address ??
                                (locating
                                    ? (widget.lang == 'uz' ? 'Joylashuv aniqlanmoqda…' : 'Определяем местоположение…')
                                    : (widget.lang == 'uz' ? 'Joriy joylashuv' : 'Текущее местоположение')),
                            onTap: () async {
                              final p = await selectAddress(tx(widget.lang, 'from'), from);
                              if (p != null && mounted) {
                                setState(() {
                                  from = p;
                                  cost = null;
                                  route = <ym.Point>[];
                                });
                                await loadNearbyCars();
                                scheduleEstimate();
                              }
                            },
                            onMapTap: () => pickRoutePointOnMap(pickup: true),
                          ),
                          const Divider(height: 1, indent: 44, endIndent: 12),
                          _addressLine(
                            pickup: false,
                            title: selectedTariffKey == 'delivery'
                                ? (widget.lang == 'uz' ? 'Qayerga — ixtiyoriy' : 'Куда — необязательно')
                                : (widget.lang == 'uz' ? 'Qayerga' : 'Куда'),
                            value: to?.address ??
                                (selectedTariffKey == 'delivery'
                                    ? (widget.lang == 'uz' ? 'Keyinroq ko‘rsatish mumkin' : 'Можно указать позже')
                                    : (widget.lang == 'uz' ? 'Manzilni tanlang' : 'Выберите адрес')),
                            onTap: () async {
                              await ensurePickupFromCurrentLocation();
                              if (!mounted) return;
                              final p = await selectAddress(tx(widget.lang, 'to'), to);
                              if (p != null && mounted) {
                                setState(() {
                                  to = p;
                                  cost = null;
                                  route = <ym.Point>[];
                                });
                                scheduleEstimate();
                              }
                            },
                            onMapTap: () async {
                              await ensurePickupFromCurrentLocation();
                              if (!mounted) return;
                              await pickRoutePointOnMap(pickup: false);
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 44,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: <Widget>[
                          _serviceModeChip(
                            label: widget.lang == 'uz' ? 'Taksi' : 'Такси',
                            icon: Icons.local_taxi_rounded,
                            selected: serviceMode == 'taxi',
                            onTap: () => selectServiceMode('taxi'),
                          ),
                          _serviceModeChip(
                            label: widget.lang == 'uz' ? 'Birga' : 'Вместе',
                            icon: Icons.groups_rounded,
                            selected: serviceMode == 'together',
                            onTap: () => selectServiceMode('together'),
                          ),
                          _serviceModeChip(
                            label: widget.lang == 'uz' ? 'Yetkazish' : 'Доставка',
                            icon: Icons.inventory_2_rounded,
                            selected: serviceMode == 'delivery',
                            onTap: () => selectServiceMode('delivery'),
                          ),
                          _serviceModeChip(
                            label: widget.lang == 'uz' ? 'Yuk' : 'Грузовой',
                            icon: Icons.local_shipping_rounded,
                            selected: serviceMode == 'cargo',
                            onTap: () => selectServiceMode('cargo'),
                          ),
                        ],
                      ),
                    ),
                    if (estimating && from != null && to != null) ...<Widget>[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF8D8),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          children: <Widget>[
                            const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            ),
                            const SizedBox(width: 11),
                            Text(
                              widget.lang == 'uz' ? 'Narx hisoblanmoqda…' : 'Рассчитываем стоимость…',
                              style: const TextStyle(fontWeight: FontWeight.w900),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (tariffs.isNotEmpty && !estimating) ...<Widget>[
                      const SizedBox(height: 14),
                      SizedBox(
                        height: serviceMode == 'taxi' ? 142 : 136,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: tariffs.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final option = tariffs[index];
                            final key = (option['key'] ?? '').toString();
                            final available = option['available'] == true;
                            final selected = available && key == selectedTariffKey;
                            final price = (option['cost'] as num?)?.toDouble();
                            final title = widget.lang == 'uz'
                                ? (option['nameUz'] ?? option['nameRu'] ?? key).toString()
                                : (option['nameRu'] ?? key).toString();
                            final saving = (option['savingVsStart'] as num?)?.toDouble() ?? 0;
                            final savingPercent = (option['savingPercentVsStart'] as num?)?.toInt() ?? 0;

                            return SizedBox(
                              width: serviceMode == 'taxi' ? 126 : 164,
                              child: Material(
                                color: selected
                                    ? const Color(0xFFFFD900)
                                    : Theme.of(context).colorScheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(22),
                                child: InkWell(
                                  onTap: available ? () => selectTariff(key) : null,
                                  borderRadius: BorderRadius.circular(22),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: <Widget>[
                                        SizedBox(
                                          height: 52,
                                          width: double.infinity,
                                          child: Stack(
                                            children: <Widget>[
                                              Positioned(
                                                right: -1,
                                                bottom: 0,
                                                child: _TariffVehicleArt(
                                                  kind: key,
                                                  selected: selected,
                                                  available: available,
                                                ),
                                              ),
                                              Align(
                                                alignment: Alignment.topLeft,
                                                child: _TariffGlyph(kind: key, selected: selected),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const Spacer(),
                                        Text(
                                          title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w900,
                                            color: available
                                                ? (selected
                                                    ? const Color(0xFF111111)
                                                    : Theme.of(context).colorScheme.onSurface)
                                                : const Color(0xFF9CA3AF),
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          price != null
                                              ? '${price.toStringAsFixed(0)} UZS'
                                              : (available
                                                  ? (widget.lang == 'uz' ? 'Manzilni tanlang' : 'Выберите маршрут')
                                                  : (widget.lang == 'uz' ? 'Mavjud emas' : 'Недоступен')),
                                          maxLines: 1,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFF62666D),
                                          ),
                                        ),
                                        if (key == 'together' && savingPercent > 0) ...<Widget>[
                                          const SizedBox(height: 4),
                                          Text(
                                            widget.lang == 'uz'
                                                ? 'Startdan $savingPercent% arzon • ${saving.toStringAsFixed(0)} UZS'
                                                : 'На $savingPercent% дешевле • −${saving.toStringAsFixed(0)} UZS',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w900,
                                              color: Color(0xFF137A3D),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                    if (selectedTariffKey == 'together' && selectedTariff != null) ...<Widget>[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0FAF4),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.groups_rounded, color: Color(0xFF15803D)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                (() {
                                  final x = selectedTariff!;
                                  final pct = (x['savingPercentVsStart'] as num?)?.toInt() ?? 0;
                                  final sum = (x['savingVsStart'] as num?)?.toDouble() ?? 0;
                                  if (pct <= 0) {
                                    return widget.lang == 'uz'
                                        ? 'Birga — boshqa yo‘lovchilar bilan tejamkor safar.'
                                        : 'Вместе — выгодная поездка с другими пассажирами.';
                                  }
                                  return widget.lang == 'uz'
                                      ? 'Startdan $pct% arzon • ${sum.toStringAsFixed(0)} UZS tejash'
                                      : 'На $pct% дешевле Старт • экономия ${sum.toStringAsFixed(0)} UZS';
                                })(),
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    _actionRow(
                      icon: paymentMethod == 'card' ? Icons.credit_card_rounded : Icons.payments_rounded,
                      title: paymentMethod == 'card'
                          ? (selectedCard == null ? 'ATMOS' : (selectedCard!['maskedPan'] ?? 'ATMOS').toString())
                          : (widget.lang == 'uz' ? 'Naqd' : 'Наличные'),
                      subtitle: widget.lang == 'uz' ? 'To‘lov usuli' : 'Способ оплаты',
                      onTap: () => _showPaymentSheet(canUseCard),
                    ),
                    const SizedBox(height: 8),
                    _actionRow(
                      icon: Icons.tune_rounded,
                      title: widget.lang == 'uz' ? 'Safar sozlamalari' : 'Пожелания к поездке',
                      subtitle: widget.lang == 'uz'
                          ? 'Izoh, bagaj, bolalar o‘rindig‘i'
                          : 'Комментарий, багаж, детское кресло',
                      onTap: _showRideOptionsSheet,
                    ),
                    if (locationHint != null) ...<Widget>[
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: openLocationSettings,
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: <Widget>[
                              const Icon(Icons.location_searching_rounded, size: 18),
                              const SizedBox(width: 7),
                              Expanded(child: Text(locationHint!, style: const TextStyle(fontSize: 12))),
                              const Icon(Icons.settings_outlined, size: 17),
                            ],
                          ),
                        ),
                      ),
                    ],
                    if (error != null) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
                    ],
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: busy || estimating || !routeReadyForOrder
                            ? null
                            : (destinationOptional && !destinationReady
                                ? createOrder
                                : (cost == null
                                    ? () => scheduleEstimate(delay: Duration.zero)
                                    : createOrder)),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFFFE500),
                          foregroundColor: const Color(0xFF111111),
                          disabledBackgroundColor: const Color(0xFFE5E7EB),
                          disabledForegroundColor: const Color(0xFF9CA3AF),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                          elevation: 0,
                        ),
                        child: busy
                            ? const SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.2),
                              )
                            : Text(
                                estimating
                                    ? (widget.lang == 'uz' ? 'Narx hisoblanmoqda…' : 'Считаем стоимость…')
                                    : (destinationOptional && !destinationReady)
                                        ? (widget.lang == 'uz' ? 'Yetkazishni buyurtma qilish' : 'Заказать доставку')
                                        : cost == null
                                            ? (widget.lang == 'uz' ? 'Narxni hisoblash' : 'Рассчитать стоимость')
                                            : (widget.lang == 'uz'
                                                ? 'Buyurtma berish • ${cost!.toStringAsFixed(0)} UZS'
                                                : 'Заказать • ${cost!.toStringAsFixed(0)} UZS'),
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                              ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _roundMapButton({
    required IconData icon,
    required VoidCallback? onTap,
    required String tooltip,
    bool large = false,
  }) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 6,
      shadowColor: const Color(0x26000000),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: large ? 52 : 44,
            height: large ? 52 : 44,
            child: Icon(icon, size: large ? 25 : 22),
          ),
        ),
      ),
    );
  }

  Widget _addressLine({
    required bool pickup,
    required String title,
    required String value,
    required VoidCallback onTap,
    required VoidCallback onMapTap,
  }) {
    return SizedBox(
      height: 64,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 13),
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: pickup ? Colors.white : const Color(0xFF111111),
              shape: BoxShape.circle,
              border: Border.all(
                color: pickup ? const Color(0xFF1F8A4C) : const Color(0xFF111111),
                width: 3,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(fontSize: 10, color: Color(0xFF8A8D93), fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onMapTap,
            icon: const Icon(Icons.map_outlined, size: 17),
            label: Text(widget.lang == 'uz' ? 'Xarita' : 'Карта'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF111111),
              textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _serviceModeChip({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? const Color(0xFF17191C) : Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            child: Row(
              children: <Widget>[
                Icon(
                  icon,
                  size: 17,
                  color: selected ? Colors.white : Theme.of(context).colorScheme.onSurface,
                ),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: selected ? Colors.white : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 19),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
                    Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF777B82))),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPaymentSheet(bool canUseCard) async {
    await loadCards();
    if (!mounted) return;

    String draftMethod = paymentMethod;
    int draftCardId = selectedCardId;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF3F3F3),
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Center(
                  child: Text(
                    widget.lang == 'uz' ? 'To‘lov usullari' : 'Способы оплаты',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.lang == 'uz' ? 'Kartalar va hisoblar' : 'Карты и счета',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 9),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    children: <Widget>[
                      ...cards.map((card) {
                        final id = (card['cardId'] as num?)?.toInt() ?? 0;
                        final selected = draftMethod == 'card' && draftCardId == id;
                        return Column(
                          children: <Widget>[
                            ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
                              leading: const Icon(Icons.credit_card_rounded, size: 30),
                              title: Text(
                                (card['maskedPan'] ?? 'ATMOS').toString(),
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                              subtitle: Text(widget.lang == 'uz' ? 'ATMOS karta' : 'Карта ATMOS'),
                              trailing: Icon(
                                selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                color: selected ? const Color(0xFFFFD900) : const Color(0xFFD1D5DB),
                                size: 30,
                              ),
                              onTap: () {
                                setSheetState(() {
                                  draftCardId = id;
                                  draftMethod = 'card';
                                });
                              },
                            ),
                            const Divider(height: 1, indent: 14, endIndent: 14),
                          ],
                        );
                      }),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                        leading: Container(
                          width: 42,
                          height: 32,
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFF9CA3AF)),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: const Icon(Icons.add_rounded),
                        ),
                        title: Text(
                          widget.lang == 'uz' ? 'Kartani bog‘lash' : 'Привязать карту',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: !canUseCard
                            ? null
                            : () async {
                                Navigator.pop(sheetContext);
                                await openCardsManager();
                              },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  widget.lang == 'uz' ? 'Boshqa to‘lov usullari' : 'Другие способы оплаты',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 9),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    leading: const Icon(Icons.payments_rounded, color: Color(0xFF60C83D), size: 32),
                    title: Text(
                      widget.lang == 'uz' ? 'Naqd' : 'Наличные',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                    ),
                    trailing: Icon(
                      draftMethod == 'cash' ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      color: draftMethod == 'cash' ? const Color(0xFFFFD900) : const Color(0xFFD1D5DB),
                      size: 30,
                    ),
                    onTap: () => setSheetState(() => draftMethod = 'cash'),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: () {
                      setState(() {
                        paymentMethod = draftMethod;
                        if (draftMethod == 'card') selectedCardId = draftCardId;
                      });
                      Navigator.pop(sheetContext);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFFD900),
                      foregroundColor: Colors.black,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    child: Text(
                      widget.lang == 'uz' ? 'Tayyor' : 'Готово',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showRideOptionsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                widget.lang == 'uz' ? 'Safar sozlamalari' : 'Пожелания к поездке',
                style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline_rounded),
                title: Text(widget.lang == 'uz' ? 'Haydovchiga izoh' : 'Комментарий водителю'),
              ),
              ListTile(
                leading: const Icon(Icons.person_add_alt_1_rounded),
                title: Text(widget.lang == 'uz' ? 'Boshqa odam uchun' : 'Заказ другому человеку'),
              ),
              ListTile(
                leading: const Icon(Icons.pets_rounded),
                title: Text(widget.lang == 'uz' ? 'Uy hayvoni bilan' : 'С питомцем'),
              ),
              ListTile(
                leading: const Icon(Icons.child_care_rounded),
                title: Text(widget.lang == 'uz' ? 'Bolalar o‘rindig‘i' : 'Детское кресло'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget routeAddressRow(
    BuildContext context, {
    required bool pickup,
    required String label,
    required VoidCallback onAddressTap,
    required VoidCallback onMapTap,
  }) {
    final accent = pickup ? const Color(0xFF1F8A4C) : const Color(0xFF111827);
    final mapLabel = widget.lang == 'uz' ? 'Xarita' : 'Карта';

    return SizedBox(
      height: 58,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
        Expanded(
          child: Material(
            color: const Color(0xFFF2F3F5),
            borderRadius: BorderRadius.circular(17),
            child: InkWell(
              onTap: onAddressTap,
              borderRadius: BorderRadius.circular(17),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: pickup ? Colors.white : accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: accent, width: 3),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: pickup || from != null || to != null ? FontWeight.w700 : FontWeight.w600,
                          color: const Color(0xFF111827),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: const Color(0xFFF2F3F5),
          borderRadius: BorderRadius.circular(17),
          child: InkWell(
            onTap: onMapTap,
            borderRadius: BorderRadius.circular(17),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const Icon(Icons.map_outlined, size: 20),
                  const SizedBox(height: 2),
                  Text(
                    mapLabel,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ),
        ),
        ],
      ),
    );
  }

  Widget _paymentChoice(
    BuildContext context, {
    required String value,
    required IconData icon,
    required String title,
    required bool enabled,
    String? subtitle,
    FutureOr<void> Function()? onTap,
  }) {
    final selected = paymentMethod == value;
    return InkWell(
      onTap: enabled
          ? () async {
              if (onTap != null) {
                await onTap();
              } else {
                setState(() => paymentMethod = value);
              }
            }
          : null,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE4F3E9) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? const Color(0xFF1F8A4C) : Colors.transparent,
            width: 1.3,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              size: 20,
              color: enabled ? const Color(0xFF111827) : const Color(0xFF9CA3AF),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: enabled ? null : const Color(0xFF9CA3AF),
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 10, color: Color(0xFF8B8F97)),
                    ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle_rounded, size: 18, color: Color(0xFF1F8A4C)),
          ],
        ),
      ),
    );
  }
}

class AddressSheet extends StatefulWidget {
  const AddressSheet({super.key, required this.api, required this.lang, required this.title, this.initial});
  final ApiClient api;
  final String lang;
  final String title;
  final Place? initial;

  @override
  State<AddressSheet> createState() => _AddressSheetState();
}

class _AddressSheetState extends State<AddressSheet> {
  final c = TextEditingController();
  Timer? timer;
  late final ys.SearchManager searchManager;
  late final ys.SearchSuggestSession suggestSession;
  List<Place> results = <Place>[];
  bool busy = false;
  String? error;

  static const tashkentWindow = ym.BoundingBox(
    ym.Point(latitude: 40.95, longitude: 68.95),
    ym.Point(latitude: 41.60, longitude: 69.75),
  );

  @override
  void initState() {
    super.initState();
    searchManager = ys.SearchFactory.instance.createSearchManager(ys.SearchManagerType.Online);
    suggestSession = searchManager.createSuggestSession();
  }

  void change(String value) {
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 280), () => search(value));
  }

  Future<void> search(String value) async {
    final q = value.trim();
    if (q.length < 2) {
      if (mounted) setState(() { results = <Place>[]; error = null; });
      return;
    }

    if (mounted) setState(() { busy = true; error = null; });

    try {
      // Prefer TaxiMaster search. Backend can ask TaxiMaster to search its own
      // database and Yandex, so selected addresses can follow TaxiMaster's
      // normal online-address workflow.
      final tmResults = await _searchTaxiMaster(q);
      if (tmResults.isNotEmpty) {
        if (mounted) setState(() => results = tmResults);
        return;
      }

      if (yandexMapKitApiKey.isEmpty) {
        if (mounted) setState(() {
          results = <Place>[];
          error = 'Адрес не найден';
        });
        return;
      }

      final completer = Completer<List<Place>>();
      final listener = ys.SearchSuggestSessionSuggestListener(
        onResponse: (response) {
          final places = <Place>[];
          for (final item in response.items.take(15)) {
            final p = item.center;
            if (p == null) continue;
            final title = item.title.text.trim();
            final subtitle = item.subtitle?.text.trim() ?? '';
            final label = subtitle.isEmpty || subtitle == title ? title : '$title, $subtitle';
            places.add(Place(label, p.latitude, p.longitude));
          }
          if (!completer.isCompleted) completer.complete(places);
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(<Place>[]);
        },
      );

      suggestSession.suggest(
        tashkentWindow,
        ys.SuggestOptions(
          suggestTypes: ys.SuggestType.Geo | ys.SuggestType.Biz,
          userPosition: const ym.Point(latitude: defaultLat, longitude: defaultLon),
          strictBounds: false,
        ),
        listener,
        text: q,
      );

      final found = await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => <Place>[],
      );
      if (mounted) {
        setState(() {
          results = found;
          error = found.isEmpty ? 'Адрес не найден' : null;
        });
      }
    } catch (_) {
      if (mounted) setState(() {
        results = <Place>[];
        error = 'Адрес не найден';
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<List<Place>> _searchTaxiMaster(String q) async {
    try {
      final data = await widget.api.get('/api/addresses/search', query: <String, String>{'q': q});
      return (data as List)
          .map((x) => Place.fromJson(Map<String, dynamic>.from(x as Map)))
          .where((p) => p.lat.abs() > 0.000001 || p.lon.abs() > 0.000001)
          .toList();
    } catch (_) {
      return <Place>[];
    }
  }

  Future<void> pickOnMap() async {
    FocusScope.of(context).unfocus();
    final place = await Navigator.of(context).push<Place>(
      MaterialPageRoute(
        builder: (_) => MapPointPickerScreen(
          title: widget.title,
          lang: widget.lang,
          initial: widget.initial,
        ),
      ),
    );
    if (place != null && mounted) Navigator.pop(context, place);
  }

  @override
  void dispose() {
    timer?.cancel();
    suggestSession.reset();
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.viewInsetsOf(context).bottom + 16),
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .72,
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
                    IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                  ],
                ),
                TextField(
                  controller: c,
                  autofocus: true,
                  onChanged: change,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.search),
                    labelText: tx(widget.lang, 'address'),
                    helperText: yandexMapKitApiKey.isNotEmpty ? 'Поиск Яндекс' : 'Поиск TaxiMaster',
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: pickOnMap,
                    icon: const Icon(Icons.my_location),
                    label: Text(widget.lang == 'uz' ? 'Xaritada ko‘rsatish' : 'Указать на карте'),
                  ),
                ),
                if (busy) const LinearProgressIndicator(),
                if (error != null) Padding(padding: const EdgeInsets.all(8), child: Text(error!)),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (_, i) {
                      final item = results[i];
                      return ListTile(
                        leading: const Icon(Icons.location_on_outlined),
                        title: Text(item.address),
                        subtitle: const Text('TaxiMaster / Яндекс'),
                        onTap: () => Navigator.pop(context, item),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class MapPointPickerScreen extends StatefulWidget {
  const MapPointPickerScreen({
    super.key,
    required this.title,
    required this.lang,
    this.initial,
  });

  final String title;
  final String lang;
  final Place? initial;

  @override
  State<MapPointPickerScreen> createState() => _MapPointPickerScreenState();
}

class _MapPointPickerScreenState extends State<MapPointPickerScreen> {
  ym.MapWindow? mapWindow;
  late final ys.SearchManager searchManager;
  ys.SearchSession? reverseSession;
  bool resolving = false;
  String? error;

  @override
  void initState() {
    super.initState();
    searchManager = ys.SearchFactory.instance.createSearchManager(ys.SearchManagerType.Online);
  }

  @override
  void dispose() {
    reverseSession?.cancel();
    super.dispose();
  }

  Future<Place> reverseGeocode(ym.Point point) async {
    final completer = Completer<Place>();
    final listener = ys.SearchSessionSearchListener(
      onSearchResponse: (response) {
        String label = '';
        for (final item in response.collection.children) {
          final object = item.asGeoObject();
          if (object == null) continue;
          final name = object.name?.trim() ?? '';
          final description = object.descriptionText?.trim() ?? '';
          label = description.isEmpty || description == name
              ? name
              : (name.isEmpty ? description : '$name, $description');
          if (label.isNotEmpty) break;
        }
        if (label.isEmpty) {
          label = '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}';
        }
        if (!completer.isCompleted) {
          completer.complete(Place(label, point.latitude, point.longitude));
        }
      },
      onSearchError: (_) {
        if (!completer.isCompleted) {
          completer.complete(
            Place(
              '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
              point.latitude,
              point.longitude,
            ),
          );
        }
      },
    );

    reverseSession = searchManager.submitPoint(
      point,
      const ys.SearchOptions(
        searchTypes: ys.SearchType.Geo,
        resultPageSize: 5,
      ),
      listener,
      zoom: 17,
    );
    return completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => Place(
        '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
        point.latitude,
        point.longitude,
      ),
    );
  }

  Future<void> confirm() async {
    final window = mapWindow;
    if (window == null || resolving) return;
    final point = window.map.cameraPosition.target;
    setState(() {
      resolving = true;
      error = null;
    });
    try {
      final place = await reverseGeocode(point);
      if (mounted) Navigator.pop(context, place);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.initial?.point ??
        const ym.Point(latitude: defaultLat, longitude: defaultLon);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.lang == 'uz' ? 'Xaritada belgilang' : 'Укажите на карте',
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
            ),
            Text(
              widget.title,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ],
        ),
      ),
      body: Stack(
        children: <Widget>[
          if (yandexMapKitApiKey.isEmpty)
            const Center(child: Text('Для выбора точки нужен Yandex MapKit API-ключ.'))
          else
            ym_widget.YandexMap(
              onMapCreated: (window) {
                mapWindow = window;
                _applyYangiMapAppearance(
                  window.map,
                  Theme.of(context).brightness == Brightness.dark,
                );
                window.map.move(
                  ym.CameraPosition(initial, zoom: 16, azimuth: 0, tilt: 0),
                );
              },
            ),
          IgnorePointer(
            child: Center(
              child: Transform.translate(
                offset: const Offset(0, -34),
                child: const _MapPinMarker(pickup: false),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: SafeArea(
              top: false,
              child: Card(
                elevation: 10,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        widget.lang == 'uz'
                            ? 'Xaritani belgi ostida kerakli nuqtaga suring'
                            : 'Передвиньте карту так, чтобы булавка была в нужной точке',
                        textAlign: TextAlign.center,
                      ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                        ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: resolving ? null : confirm,
                          icon: resolving
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.check),
                          label: Text(
                            widget.lang == 'uz' ? 'Shu nuqtani tanlash' : 'Выбрать эту точку',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class RideScreen extends StatefulWidget {
  const RideScreen({
    super.key,
    required this.api,
    required this.lang,
    required this.orderId,
    required this.onMenu,
  });
  final ApiClient api;
  final String lang;
  final int? orderId;
  final VoidCallback onMenu;

  @override
  State<RideScreen> createState() => _RideScreenState();
}

class _RideScreenState extends State<RideScreen> {
  Timer? timer;
  Map<String, dynamic>? order;
  ym.Point? driver;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 4), (_) => refresh());
  }

  @override
  void didUpdateWidget(covariant RideScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.orderId != widget.orderId) refresh();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      var id = widget.orderId;
      if (id == null) {
        final current = await widget.api.get('/api/orders/current') as List;
        if (current.isEmpty) {
          if (mounted) setState(() {
            order = null;
            driver = null;
            loading = false;
          });
          return;
        }
        id = (current.first['order_id'] as num).toInt();
      }
      final data = await widget.api.get('/api/orders/' + id.toString() + '/driver-location');
      final state = Map<String, dynamic>.from(data['state'] as Map);
      ym.Point? d;
      final loc = data['location'];
      if (loc is Map && loc['lat'] != null && loc['lon'] != null) {
        d = ym.Point(latitude: (loc['lat'] as num).toDouble(), longitude: (loc['lon'] as num).toDouble());
      }
      if (mounted) setState(() {
        order = state;
        driver = d;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  String stateLabel(String state) {
    if (state == 'new_order') return tx(widget.lang, 'searching');
    if (state == 'driver_assigned') return tx(widget.lang, 'assigned');
    if (state == 'car_at_place') return tx(widget.lang, 'arrived');
    if (state == 'client_inside') return tx(widget.lang, 'trip');
    if (state == 'finished') return tx(widget.lang, 'finished');
    if (state == 'aborted') return tx(widget.lang, 'aborted');
    return state;
  }

  ym.Point? point(dynamic lat, dynamic lon) {
    final a = double.tryParse(lat?.toString() ?? '');
    final b = double.tryParse(lon?.toString() ?? '');
    return a == null || b == null ? null : ym.Point(latitude: a, longitude: b);
  }

  Future<Map<String, String>?> cancellationSurvey(num penalty) async {
    final reasons = widget.lang == 'uz'
        ? <String>[
            'Haydovchi juda uzoq',
            'Juda uzoq kutdim',
            'Manzilni xato ko‘rsatdim',
            'Rejalarim o‘zgardi',
            'Boshqa mashina topdim',
            'Boshqa sabab',
          ]
        : <String>[
            'Водитель слишком далеко',
            'Слишком долго ждать',
            'Ошибся адресом',
            'Изменились планы',
            'Нашёл другую машину',
            'Другая причина',
          ];
    String selected = reasons.first;
    final details = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(widget.lang == 'uz' ? 'Nega buyurtmani bekor qilyapsiz?' : 'Почему отменяете заказ?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (penalty > 0)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      (widget.lang == 'uz' ? 'Bekor qilish jarimasi: ' : 'Штраф за отмену: ') +
                          penalty.toString() +
                          ' UZS',
                    ),
                  ),
                ...reasons.map(
                  (reason) => RadioListTile<String>(
                    value: reason,
                    groupValue: selected,
                    contentPadding: EdgeInsets.zero,
                    title: Text(reason),
                    onChanged: (value) => setDialogState(() => selected = value ?? selected),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: details,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: widget.lang == 'uz' ? 'Izoh (ixtiyoriy)' : 'Комментарий (необязательно)',
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(widget.lang == 'uz' ? 'Ortga' : 'Назад'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, <String, String>{
                'reason': selected,
                'details': details.text.trim(),
              }),
              child: Text(widget.lang == 'uz' ? 'Buyurtmani bekor qilish' : 'Отменить заказ'),
            ),
          ],
        ),
      ),
    );
    details.dispose();
    return result;
  }

  Future<void> cancel() async {
    final o = order;
    if (o == null) return;
    final id = (o['order_id'] as num).toInt();
    try {
      final p = await widget.api.get('/api/orders/' + id.toString() + '/cancel-penalty');
      final sum = (p['cancel_order_penalty_sum'] as num?) ?? 0;
      if (!mounted) return;
      final answer = await cancellationSurvey(sum);
      if (answer == null) return;
      await widget.api.post('/api/orders/' + id.toString() + '/cancel', <String, dynamic>{
        'reason': answer['reason'] ?? '',
        'details': answer['details'] ?? '',
      });
      await refresh();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (order == null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(onPressed: widget.onMenu, icon: const Icon(Icons.menu_rounded)),
          title: Text(tx(widget.lang, 'ride')),
        ),
        body: Center(child: Text(tx(widget.lang, 'empty'))),
      );
    }
    final o = order!;
    final state = (o['state_kind'] ?? '').toString();
    final from = point(o['source_lat'], o['source_lon']);
    final to = point(o['destination_lat'], o['destination_lon']);
    final center = driver ?? from ?? const ym.Point(latitude: defaultLat, longitude: defaultLon);
    final car = <String>[o['car_mark']?.toString() ?? '', o['car_model']?.toString() ?? ''].where((x) => x.isNotEmpty).join(' ');
    final number = (o['car_number'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(onPressed: widget.onMenu, icon: const Icon(Icons.menu_rounded)),
        title: Text(stateLabel(state), style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: TaxiYandexMap(
              center: center,
              from: from,
              to: to,
              driver: driver,
              zoom: 14,
            ),
          ),
          Expanded(
            flex: 2,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Text(stateLabel(state), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                if (car.isNotEmpty || number.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text((car + ' • ' + number).trim(), style: Theme.of(context).textTheme.titleMedium),
                ],
                const SizedBox(height: 14),
                Text('● ' + (o['source'] ?? '').toString()),
                const SizedBox(height: 7),
                Text('● ' + (o['destination'] ?? '').toString()),
                if (o['total_cost'] != null) ...<Widget>[
                  const Divider(height: 24),
                  Text(tx(widget.lang, 'price') + ': ' + o['total_cost'].toString() + ' UZS'),
                ],
                if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!)),
                const SizedBox(height: 12),
                if (state != 'finished' && state != 'aborted' && state != 'client_inside')
                  OutlinedButton.icon(onPressed: cancel, icon: const Icon(Icons.close), label: Text(tx(widget.lang, 'cancel'))),
                if (state == 'finished')
                  FilledButton.icon(
                    onPressed: () => showDriverRatingDialog(
                      context,
                      widget.api,
                      widget.lang,
                      (o['order_id'] as num).toInt(),
                      driverName: (o['driver_name'] ?? '').toString(),
                    ),
                    icon: const Icon(Icons.star_outline),
                    label: Text(widget.lang == 'uz' ? 'Haydovchini baholash' : 'Оценить водителя'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showDriverRatingDialog(
  BuildContext context,
  ApiClient api,
  String lang,
  int orderId, {
  String driverName = '',
}) async {
  int rating = 5;
  final comment = TextEditingController();
  final submit = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(lang == 'uz' ? 'Safarni baholang' : 'Оцените поездку'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (driverName.trim().isNotEmpty) ...<Widget>[
              Text(driverName, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List<Widget>.generate(
                5,
                (i) => IconButton(
                  onPressed: () => setDialogState(() => rating = i + 1),
                  iconSize: 36,
                  icon: Icon(i < rating ? Icons.star : Icons.star_border),
                  color: const Color(0xFFFFB300),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: comment,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: lang == 'uz' ? 'Izoh' : 'Комментарий',
                hintText: lang == 'uz'
                    ? 'Haydovchi va safar haqida fikringiz'
                    : 'Что понравилось или можно улучшить',
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(lang == 'uz' ? 'Keyinroq' : 'Позже'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.send),
            label: Text(lang == 'uz' ? 'Yuborish' : 'Отправить'),
          ),
        ],
      ),
    ),
  );
  if (submit != true) {
    comment.dispose();
    return;
  }

  try {
    await api.post('/api/orders/' + orderId.toString() + '/feedback', <String, dynamic>{
      'rating': rating,
      'text': comment.text.trim(),
    });
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(lang == 'uz' ? 'Bahoyingiz yuborildi' : 'Спасибо! Оценка отправлена')),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  } finally {
    comment.dispose();
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.api, required this.lang, required this.onMenu});
  final ApiClient api;
  final String lang;
  final VoidCallback onMenu;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<dynamic> orders = <dynamic>[];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final data = await widget.api.get('/api/orders/history');
      if (mounted) setState(() {
        orders = data as List;
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: IconButton(onPressed: widget.onMenu, icon: const Icon(Icons.menu_rounded)),
          title: Text(tx(widget.lang, 'history'), style: const TextStyle(fontWeight: FontWeight.w800)),
          actions: <Widget>[IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: load,
                child: orders.isEmpty
                    ? ListView(children: <Widget>[const SizedBox(height: 180), Center(child: Text(tx(widget.lang, 'history')))])
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: orders.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final o = Map<String, dynamic>.from(orders[i] as Map);
                          final state = (o['state_kind'] ?? '').toString();
                          final orderId = (o['order_id'] as num?)?.toInt() ?? 0;
                          return Card(
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Column(
                                children: <Widget>[
                                  ListTile(
                                    leading: CircleAvatar(
                                      child: Icon(state == 'finished' ? Icons.check : state == 'aborted' ? Icons.close : Icons.local_taxi),
                                    ),
                                    title: Text(
                                      (o['source'] ?? '').toString() + ' → ' + (o['destination'] ?? '').toString(),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text('#' + orderId.toString() + ' • ' + state),
                                    trailing: o['total_cost'] == null
                                        ? null
                                        : Text(o['total_cost'].toString() + ' UZS', style: const TextStyle(fontWeight: FontWeight.w700)),
                                  ),
                                  if (state == 'finished' && orderId > 0)
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: TextButton.icon(
                                        onPressed: () => showDriverRatingDialog(
                                          context,
                                          widget.api,
                                          widget.lang,
                                          orderId,
                                          driverName: (o['driver_name'] ?? '').toString(),
                                        ),
                                        icon: const Icon(Icons.star_outline),
                                        label: Text(widget.lang == 'uz' ? 'Baholash' : 'Оценить'),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
      );
}

class CardsScreen extends StatefulWidget {
  const CardsScreen({
    super.key,
    required this.api,
    required this.lang,
    this.onMenu,
    this.onDone,
  });
  final ApiClient api;
  final String lang;
  final VoidCallback? onMenu;
  final VoidCallback? onDone;

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  bool loading = true;
  bool cardBindingAvailable = false;
  List<Map<String, dynamic>> cards = <Map<String, dynamic>>[];
  int defaultCardId = 0;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) setState(() { loading = true; error = null; });
    try {
      final data = await widget.api.get('/api/cards');
      final map = Map<String, dynamic>.from(data as Map);
      final list = (map['cards'] as List? ?? const <dynamic>[])
          .whereType<Map>()
          .map((x) => Map<String, dynamic>.from(x))
          .toList();
      if (mounted) {
        setState(() {
          cards = list;
          defaultCardId = (map['defaultCardId'] as num?)?.toInt() ?? 0;
          cardBindingAvailable = map['cardBindingAvailable'] == true;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { loading = false; error = e.toString(); });
    }
  }

  String formatExpiry(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 4) return value;
    return digits.substring(2, 4) + '/' + digits.substring(0, 2);
  }

  Future<void> addCard() async {
    final number = TextEditingController();
    final expiry = TextEditingController();

    final submit = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(widget.lang == 'uz' ? 'Karta qo‘shish' : 'Добавить карту'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              widget.lang == 'uz'
                  ? 'Karta ATMOS orqali tokenlashtiriladi. Yangi Taxi karta raqamini saqlamaydi.'
                  : 'Карта токенизируется через ATMOS. Yangi Taxi не сохраняет номер карты.',
              style: const TextStyle(color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: number,
              keyboardType: TextInputType.number,
              autofillHints: const <String>[AutofillHints.creditCardNumber],
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(19),
              ],
              decoration: InputDecoration(
                labelText: widget.lang == 'uz' ? 'Karta raqami' : 'Номер карты',
                prefixIcon: const Icon(Icons.credit_card_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: expiry,
              keyboardType: TextInputType.datetime,
              autofillHints: const <String>[AutofillHints.creditCardExpirationDate],
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[0-9/]')),
                LengthLimitingTextInputFormatter(5),
              ],
              decoration: const InputDecoration(
                labelText: 'MM/YY',
                prefixIcon: Icon(Icons.calendar_month_outlined),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(widget.lang == 'uz' ? 'Bekor' : 'Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(widget.lang == 'uz' ? 'Davom etish' : 'Продолжить')),
        ],
      ),
    );

    if (submit != true) {
      number.dispose();
      expiry.dispose();
      return;
    }

    final pan = number.text.replaceAll(RegExp(r'\D'), '');
    final expDigits = expiry.text.replaceAll(RegExp(r'\D'), '');
    number.dispose();
    expiry.dispose();

    if (pan.length < 16 || expDigits.length != 4) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.lang == 'uz' ? 'Karta ma’lumotlarini tekshiring' : 'Проверьте номер карты и срок действия')),
        );
      }
      return;
    }

    final mm = expDigits.substring(0, 2);
    final yy = expDigits.substring(2, 4);

    try {
      final init = await widget.api.post('/api/cards/bind/init', <String, dynamic>{
        'cardNumber': pan,
        'expiry': yy + mm,
      });
      if (!mounted) return;

      final transactionId = (init['transactionId'] as num).toInt();
      final maskedPhone = (init['phone'] ?? '').toString();
      final otp = TextEditingController();

      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          title: Text(widget.lang == 'uz' ? 'SMS orqali tasdiqlash' : 'Подтверждение по SMS'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                maskedPhone.isEmpty
                    ? (widget.lang == 'uz' ? 'ATMOS yuborgan kodni kiriting' : 'Введите код, отправленный ATMOS')
                    : (widget.lang == 'uz' ? 'Kod ' + maskedPhone + ' raqamiga yuborildi' : 'Код отправлен на ' + maskedPhone),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: otp,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                decoration: InputDecoration(
                  counterText: '',
                  labelText: widget.lang == 'uz' ? 'SMS-kod' : 'Код из SMS',
                  prefixIcon: const Icon(Icons.sms_outlined),
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(widget.lang == 'uz' ? 'Bekor' : 'Отмена')),
            FilledButton(
              onPressed: () async {
                try {
                  await widget.api.post('/api/cards/bind/confirm', <String, dynamic>{
                    'transactionId': transactionId,
                    'otp': otp.text.trim(),
                  });
                  if (c.mounted) Navigator.pop(c, true);
                } catch (e) {
                  if (c.mounted) {
                    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(e.toString())));
                  }
                }
              },
              child: Text(widget.lang == 'uz' ? 'Tasdiqlash' : 'Подтвердить'),
            ),
          ],
        ),
      );
      otp.dispose();

      if (confirmed == true) {
        await load();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(widget.lang == 'uz' ? 'Karta qo‘shildi' : 'Карта добавлена')),
          );
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> makeDefault(int id) async {
    try {
      await widget.api.post('/api/cards/' + id.toString() + '/default', const <String, dynamic>{});
      await load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> removeCard(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(widget.lang == 'uz' ? 'Kartani o‘chirish?' : 'Удалить карту?'),
        content: Text(widget.lang == 'uz'
            ? 'Bu karta bilan keyingi to‘lovlar amalga oshirilmaydi.'
            : 'После удаления этой картой нельзя будет оплачивать поездки.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(widget.lang == 'uz' ? 'Bekor' : 'Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(widget.lang == 'uz' ? 'O‘chirish' : 'Удалить')),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await widget.api.post('/api/cards/' + id.toString() + '/remove', const <String, dynamic>{});
      await load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFFF3F3F3),
        appBar: AppBar(
          leading: widget.onMenu == null
              ? null
              : IconButton(onPressed: widget.onMenu, icon: const Icon(Icons.menu_rounded)),
          centerTitle: true,
          title: Text(
            widget.lang == 'uz' ? 'To‘lov usullari' : 'Способы оплаты',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          actions: <Widget>[IconButton(onPressed: load, icon: const Icon(Icons.refresh_rounded))],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 30),
                children: <Widget>[
                  Text(
                    widget.lang == 'uz' ? 'Kartalar va hisoblar' : 'Карты и счета',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Column(
                      children: <Widget>[
                        ...cards.map((card) {
                          final id = (card['cardId'] as num?)?.toInt() ?? 0;
                          final isDefault = id == defaultCardId || card['isDefault'] == true;
                          final masked = (card['maskedPan'] ?? '••••').toString();
                          return Column(
                            children: <Widget>[
                              ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                leading: Container(
                                  width: 44,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF3F4F6),
                                    borderRadius: BorderRadius.circular(7),
                                    border: Border.all(color: const Color(0xFFD1D5DB)),
                                  ),
                                  child: const Icon(Icons.credit_card_rounded, size: 22),
                                ),
                                title: Text(masked, style: const TextStyle(fontWeight: FontWeight.w800)),
                                subtitle: Text(
                                  isDefault
                                      ? (widget.lang == 'uz' ? 'Asosiy karta' : 'Основная карта')
                                      : (widget.lang == 'uz' ? 'Saqlangan karta' : 'Сохранённая карта'),
                                ),
                                trailing: isDefault
                                    ? const Icon(Icons.check_circle_rounded, color: Color(0xFFFFD900), size: 29)
                                    : IconButton(
                                        icon: const Icon(Icons.radio_button_unchecked_rounded),
                                        onPressed: () => makeDefault(id),
                                      ),
                                onLongPress: () => removeCard(id),
                              ),
                              const Divider(height: 1, indent: 16, endIndent: 16),
                            ],
                          );
                        }),
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                          leading: Container(
                            width: 44,
                            height: 34,
                            decoration: BoxDecoration(
                              border: Border.all(color: const Color(0xFF9CA3AF)),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: const Icon(Icons.add_rounded),
                          ),
                          title: Text(
                            widget.lang == 'uz' ? 'Kartani bog‘lash' : 'Привязать карту',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: cardBindingAvailable ? addCard : null,
                        ),
                      ],
                    ),
                  ),
                  if (error != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 14),
                  Text(
                    widget.lang == 'uz' ? 'Boshqa to‘lov usullari' : 'Другие способы оплаты',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      leading: const Icon(Icons.payments_rounded, color: Color(0xFF60C83D), size: 34),
                      title: Text(
                        widget.lang == 'uz' ? 'Naqd' : 'Наличные',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                      ),
                      trailing: const Icon(Icons.check_circle_rounded, color: Color(0xFFFFD900), size: 31),
                    ),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 56,
                    child: FilledButton(
                      onPressed: () {
                        if (widget.onDone != null) {
                          widget.onDone!();
                        } else {
                          Navigator.maybePop(context);
                        }
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFFD900),
                        foregroundColor: Colors.black,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      ),
                      child: Text(
                        widget.lang == 'uz' ? 'Tayyor' : 'Готово',
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    widget.lang == 'uz'
                        ? 'Kartalar ATMOS orqali tokenlashtiriladi. Yangi Taxi PAN va CVV ni saqlamaydi.'
                        : 'Карты токенизируются через ATMOS. Yangi Taxi не хранит PAN и CVV.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF8B8F97)),
                  ),
                ],
              ),
      );

}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.api,
    required this.lang,
    required this.themeSetting,
    required this.onLang,
    required this.onTheme,
    required this.onBackend,
    required this.onMenu,
  });

  final ApiClient api;
  final String lang;
  final String themeSetting;
  final ValueChanged<String> onLang;
  final Future<void> Function(String) onTheme;
  final Future<void> Function(String) onBackend;
  final VoidCallback onMenu;

  Future<void> locationSettings() async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
    } else {
      await Geolocator.openLocationSettings();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          leading: IconButton(onPressed: onMenu, icon: const Icon(Icons.menu_rounded)),
          title: Text(lang == 'uz' ? 'Sozlamalar' : 'Настройки', style: const TextStyle(fontWeight: FontWeight.w900)),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: <Widget>[
            Text(lang == 'uz' ? 'ILOVA' : 'ПРИЛОЖЕНИЕ', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF8B8F97))),
            const SizedBox(height: 8),
            Card(
              elevation: 0,
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.language_rounded),
                    title: const Text('Язык / Til'),
                    trailing: SegmentedButton<String>(
                      segments: const <ButtonSegment<String>>[
                        ButtonSegment<String>(value: 'ru', label: Text('RU')),
                        ButtonSegment<String>(value: 'uz', label: Text('UZ')),
                      ],
                      selected: <String>{lang},
                      onSelectionChanged: (x) => onLang(x.first),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.brightness_6_rounded),
                    title: Text(lang == 'uz' ? 'Mavzu' : 'Тема'),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SegmentedButton<String>(
                        segments: <ButtonSegment<String>>[
                          ButtonSegment<String>(
                            value: 'system',
                            icon: const Icon(Icons.phone_android_rounded, size: 17),
                            label: Text(lang == 'uz' ? 'Tizim' : 'Система'),
                          ),
                          ButtonSegment<String>(
                            value: 'light',
                            icon: const Icon(Icons.light_mode_rounded, size: 17),
                            label: Text(lang == 'uz' ? 'Yorug‘' : 'Светлая'),
                          ),
                          ButtonSegment<String>(
                            value: 'dark',
                            icon: const Icon(Icons.dark_mode_rounded, size: 17),
                            label: Text(lang == 'uz' ? 'Qorong‘i' : 'Тёмная'),
                          ),
                        ],
                        selected: <String>{themeSetting},
                        onSelectionChanged: (x) => onTheme(x.first),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.my_location_rounded),
                    title: Text(lang == 'uz' ? 'Geolokatsiya' : 'Геолокация'),
                    subtitle: Text(lang == 'uz' ? 'Ruxsat va GPS sozlamalari' : 'Разрешения и настройки GPS'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: locationSettings,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(lang == 'uz' ? 'XIZMAT' : 'СЕРВИС', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF8B8F97))),
            const SizedBox(height: 8),
            Card(
              elevation: 0,
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.support_agent_rounded),
                    title: Text(lang == 'uz' ? 'Yordam' : 'Поддержка'),
                    subtitle: Text(lang == 'uz' ? 'Yangi Taxi yordam markazi' : 'Центр поддержки Yangi Taxi'),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded),
                    title: Text(lang == 'uz' ? 'Ilova haqida' : 'О приложении'),
                    subtitle: const Text('Yangi Taxi 1.6.2'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(lang == 'uz' ? 'DIAGNOSTIKA' : 'ДИАГНОСТИКА', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF8B8F97))),
            const SizedBox(height: 8),
            Card(
              elevation: 0,
              child: ListTile(
                leading: Icon(api.isDemo ? Icons.science_outlined : Icons.dns_outlined),
                title: const Text('Backend'),
                subtitle: Text(api.baseUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => backendDialog(context, api, onBackend),
              ),
            ),
          ],
        ),
      );
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.api,
    required this.lang,
    required this.onLang,
    required this.onBackend,
    required this.onLogout,
    this.onMenu,
  });
  final ApiClient api;
  final String lang;
  final ValueChanged<String> onLang;
  final Future<void> Function(String) onBackend;
  final VoidCallback onLogout;
  final VoidCallback? onMenu;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? me;
  List<dynamic> orders = <dynamic>[];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final values = await Future.wait<dynamic>(<Future<dynamic>>[
        widget.api.get('/api/me'),
        widget.api.get('/api/orders/history'),
      ]);
      if (mounted) {
        setState(() {
          me = Map<String, dynamic>.from(values[0] as Map);
          orders = values[1] as List;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  String get phone {
    final phones = me?['phones'];
    if (phones is List && phones.isNotEmpty) {
      final first = phones.first;
      if (first is Map) return (first['phone'] ?? '').toString();
      return first.toString();
    }
    return '';
  }

  int get completed => orders.where((x) => x is Map && x['state_kind'] == 'finished').length;
  int get cancelled => orders.where((x) => x is Map && x['state_kind'] == 'aborted').length;

  double get totalSpend {
    double sum = 0;
    for (final x in orders) {
      if (x is Map && x['state_kind'] == 'finished') {
        sum += double.tryParse((x['total_cost'] ?? '0').toString()) ?? 0;
      }
    }
    return sum;
  }

  Widget metric(BuildContext context, IconData icon, String value, String label) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: <Widget>[
              Icon(icon),
              const SizedBox(height: 6),
              Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              Text(label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );

  Widget infoRow(IconData icon, String title, String value) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(value.isEmpty ? '—' : value),
        dense: true,
      );

  @override
  Widget build(BuildContext context) {
    final rating = me?['rating']?.toString() ?? '—';
    final email = (me?['email'] ?? '').toString();
    final birthday = (me?['birthday'] ?? '').toString();
    final address = (me?['address'] ?? '').toString();
    final contract = (me?['number'] ?? '').toString();
    final balance = (me?['balance'] ?? 0).toString();
    final bonus = (me?['bonus_balance'] ?? 0).toString();

    return Scaffold(
      appBar: AppBar(
        leading: widget.onMenu == null
            ? null
            : IconButton(onPressed: widget.onMenu, icon: const Icon(Icons.menu_rounded)),
        title: Text(tx(widget.lang, 'profile'), style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: <Widget>[IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: <Color>[
                        Theme.of(context).colorScheme.primaryContainer,
                        Theme.of(context).colorScheme.secondaryContainer,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    children: <Widget>[
                      CircleAvatar(
                        radius: 34,
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        child: Text(
                          ((me?['name'] ?? 'Y').toString().trim().isEmpty ? 'Y' : (me?['name'] ?? 'Y').toString().trim()[0]).toUpperCase(),
                          style: const TextStyle(fontSize: 26, color: Colors.white, fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              (me?['name'] ?? 'Yangi Taxi').toString(),
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 3),
                            Text(phone),
                            if (contract.isNotEmpty) Text('№ ' + contract, style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ),
                      Column(
                        children: <Widget>[
                          const Icon(Icons.star, color: Color(0xFFFFB300)),
                          Text(rating, style: const TextStyle(fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    metric(context, Icons.check_circle_outline, completed.toString(), widget.lang == 'uz' ? 'Safarlar' : 'Поездки'),
                    const SizedBox(width: 8),
                    metric(context, Icons.close, cancelled.toString(), widget.lang == 'uz' ? 'Bekor' : 'Отмены'),
                    const SizedBox(width: 8),
                    metric(context, Icons.payments_outlined, totalSpend.toStringAsFixed(0), 'UZS'),
                  ],
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: <Widget>[
                      infoRow(Icons.phone_outlined, widget.lang == 'uz' ? 'Telefon' : 'Телефон', phone),
                      infoRow(Icons.email_outlined, 'E-mail', email),
                      infoRow(Icons.cake_outlined, widget.lang == 'uz' ? 'Tug‘ilgan sana' : 'Дата рождения', birthday),
                      infoRow(Icons.home_outlined, widget.lang == 'uz' ? 'Manzil' : 'Домашний адрес', address),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  child: Column(
                    children: <Widget>[
                      ListTile(
                        leading: const Icon(Icons.account_balance_wallet_outlined),
                        title: Text(widget.lang == 'uz' ? 'Asosiy balans' : 'Основной баланс'),
                        trailing: Text(balance + ' UZS', style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      ListTile(
                        leading: const Icon(Icons.savings_outlined),
                        title: const Text('Бонусы / Bonuslar'),
                        trailing: Text(bonus, style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      ListTile(
                        leading: const Icon(Icons.credit_card),
                        title: Text(widget.lang == 'uz' ? 'To‘lov usullari' : 'Способы оплаты'),
                        subtitle: Text(widget.lang == 'uz'
                            ? 'Naqd pul • ATMOS orqali xavfsiz karta to‘lovi'
                            : 'Наличные • безопасная оплата картой через ATMOS'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text(widget.lang == 'uz' ? 'ATMOS to‘lovi' : 'Оплата ATMOS'),
                            content: Text(widget.lang == 'uz'
                                ? 'Karta orqali to‘lov ATMOSning himoyalangan sahifasida amalga oshiriladi. Yangi Taxi karta raqami va CVVni saqlamaydi. Safar tugagach to‘langan summa haydovchining TaxiMaster/TMDriver asosiy balansiga avtomatik tushadi; komissiya va pul yechish TaxiMaster qoidalarida qoladi.'
                                : 'Оплата картой выполняется на защищённой странице ATMOS. Yangi Taxi не хранит номер карты и CVV. После завершения оплаченной поездки сумма автоматически зачисляется на основной баланс водителя в TaxiMaster/TMDriver; комиссия и вывод средств остаются по вашим правилам TaxiMaster.'),
                            actions: <Widget>[
                              FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK')),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  child: Column(
                    children: <Widget>[
                      ListTile(
                        leading: const Icon(Icons.language),
                        title: const Text('Язык / Til'),
                        trailing: SegmentedButton<String>(
                          segments: const <ButtonSegment<String>>[
                            ButtonSegment<String>(value: 'ru', label: Text('RU')),
                            ButtonSegment<String>(value: 'uz', label: Text('UZ')),
                          ],
                          selected: <String>{widget.lang},
                          onSelectionChanged: (x) => widget.onLang(x.first),
                        ),
                      ),
                      ListTile(
                        leading: Icon(widget.api.isDemo ? Icons.science_outlined : Icons.dns_outlined),
                        title: Text(tx(widget.lang, 'backend')),
                        subtitle: Text(widget.api.baseUrl),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => backendDialog(context, widget.api, widget.onBackend),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: widget.onLogout,
                  icon: const Icon(Icons.logout),
                  label: Text(tx(widget.lang, 'logout')),
                ),
              ],
            ),
    );
  }
}
