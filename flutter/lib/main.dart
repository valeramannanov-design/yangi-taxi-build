import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:yandex_maps_mapkit/init.dart' as yandex_init;
import 'package:yandex_maps_mapkit/directions.dart' as yd;
import 'package:yandex_maps_mapkit/mapkit.dart' as ym;
import 'package:yandex_maps_mapkit/ui_view.dart' as yv;
import 'package:yandex_maps_mapkit/mapkit_factory.dart' as ym_factory;
import 'package:yandex_maps_mapkit/search.dart' as ys;
import 'package:yandex_maps_mapkit/yandex_map.dart' as ym_widget;

const defaultLat = 41.3111;
const defaultLon = 69.2797;

const yandexMapKitApiKey = String.fromEnvironment('MAPKIT_API_KEY');

String maskedCardLabel(dynamic value) {
  final raw = (value ?? '').toString().trim();
  final match = RegExp(r'(\d{4})(?!.*\d)').firstMatch(raw);
  if (match == null) return raw.isEmpty ? 'ATMOS' : raw;
  return '•••• ' + match.group(1)!;
}

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

const defaultBackendUrl = String.fromEnvironment(
  'BACKEND_URL',
  defaultValue: 'demo',
);

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class ApiClient {
  ApiClient(this.baseUrl);
  String baseUrl;
  String? token;
  Map<String, dynamic>? _demoOrder;
  DateTime? _demoStarted;
  String _demoClientPhoto = '';
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

  Future<dynamic> delete(String path) async {
    if (isDemo) return <String, dynamic>{'removed': true};
    final r = await http
        .delete(Uri.parse(baseUrl + path), headers: headers)
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
      throw ApiException(message, statusCode: r.statusCode);
    }
    return b['data'];
  }

  Map<String, dynamic> get demoMe => <String, dynamic>{
        'client_id': 501,
        'name': 'Yangi Taxi Demo',
        'phones': <dynamic>[<String, dynamic>{'phone': '+998901234567'}],
        'bonus_balance': 12000,
        'client_rating': 4.86,
        'client_rating_count': 27,
        'client_photo': _demoClientPhoto,
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
    if (path == '/api/profile/photo') {
      _demoClientPhoto = (body['photoBase64'] ?? '').toString();
      return <String, dynamic>{'saved': true};
    }
    final demoRatingMatch = RegExp(r'^/api/orders/(\d+)/rating$').firstMatch(path);
    if (demoRatingMatch != null) {
      return <String, dynamic>{
        'saved': true,
        'rating': (body['rating'] as num?)?.toInt() ?? 5,
      };
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
  Place(this.address, this.lat, this.lon, {this.isFavorite = false});
  final String address;
  final double lat;
  final double lon;
  final bool isFavorite;
  ym.Point get point => ym.Point(latitude: lat, longitude: lon);
  Map<String, dynamic> toJson() => <String, dynamic>{'address': address, 'lat': lat, 'lon': lon};

  factory Place.fromJson(Map<String, dynamic> j) => Place(
        (j['label'] ?? '').toString(),
        (j['lat'] as num).toDouble(),
        (j['lon'] as num).toDouble(),
      );
}

const _clientProfileStorage = FlutterSecureStorage();

Future<String> _clientScopedStorageKey(ApiClient api, String prefix) async {
  try {
    final raw = await api.get('/api/me');
    if (raw is Map) {
      final idRaw = raw['client_id'] ?? raw['clientId'] ?? raw['id'];
      final id = idRaw is num ? idRaw.toInt() : int.tryParse(idRaw?.toString() ?? '');
      if (id != null && id > 0) return '${prefix}_client_$id';
    }
  } catch (_) {
    // Local migration/fallback must not block the app if /api/me is unavailable.
  }
  final tokenHash = (api.token ?? 'anonymous').hashCode.abs();
  return '${prefix}_session_$tokenHash';
}

bool _profileEndpointMissing(Object error) =>
    error is ApiException && (error.statusCode == 404 || error.statusCode == 405);

Future<List<Map<String, dynamic>>> _loadLocalFavoriteAddresses(ApiClient api) async {
  final key = await _clientScopedStorageKey(api, 'favorite_addresses_v1');
  final raw = await _clientProfileStorage.read(key: key);
  if (raw == null || raw.trim().isEmpty) return <Map<String, dynamic>>[];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <Map<String, dynamic>>[];
    return decoded
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) =>
            (item['address'] ?? '').toString().trim().isNotEmpty &&
            double.tryParse((item['lat'] ?? '').toString()) != null &&
            double.tryParse((item['lon'] ?? '').toString()) != null)
        .toList();
  } catch (_) {
    return <Map<String, dynamic>>[];
  }
}

Future<void> _cacheFavoriteAddresses(
  ApiClient api,
  List<Map<String, dynamic>> values,
) async {
  final key = await _clientScopedStorageKey(api, 'favorite_addresses_v1');
  await _clientProfileStorage.write(key: key, value: jsonEncode(values));
}

List<Map<String, dynamic>> _favoritesFromPayload(dynamic raw) {
  if (raw is! Map || raw['favorites'] is! List) return <Map<String, dynamic>>[];
  return (raw['favorites'] as List)
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .where((item) =>
          (item['address'] ?? '').toString().trim().isNotEmpty &&
          double.tryParse((item['lat'] ?? '').toString()) != null &&
          double.tryParse((item['lon'] ?? '').toString()) != null)
      .toList();
}

Future<List<Map<String, dynamic>>> _loadFavoriteAddresses(ApiClient api) async {
  final local = await _loadLocalFavoriteAddresses(api);
  if (api.isDemo) return local;

  try {
    var remote = _favoritesFromPayload(await api.get('/api/profile/favorites'));

    // One-time migration from the pre-server version of the app.
    if (remote.isEmpty && local.isNotEmpty) {
      for (final item in local.take(30)) {
        await api.post('/api/profile/favorites', <String, dynamic>{
          'name': (item['name'] ?? '').toString().trim(),
          'address': (item['address'] ?? '').toString().trim(),
          'lat': double.parse(item['lat'].toString()),
          'lon': double.parse(item['lon'].toString()),
        });
      }
      remote = _favoritesFromPayload(await api.get('/api/profile/favorites'));
    }

    await _cacheFavoriteAddresses(api, remote);
    return remote;
  } catch (e) {
    if (_profileEndpointMissing(e)) return local;
    rethrow;
  }
}

Future<List<Map<String, dynamic>>> _saveFavoriteAddresses(
  ApiClient api,
  List<Map<String, dynamic>> values,
) async {
  if (api.isDemo) {
    await _cacheFavoriteAddresses(api, values);
    return values;
  }

  try {
    final existing =
        _favoritesFromPayload(await api.get('/api/profile/favorites'));
    final existingById = <String, Map<String, dynamic>>{
      for (final item in existing)
        if ((item['id'] ?? '').toString().isNotEmpty)
          item['id'].toString(): item,
    };
    final desiredIds = values
        .map((item) => (item['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();

    for (final item in existing) {
      final id = (item['id'] ?? '').toString();
      if (id.isNotEmpty && !desiredIds.contains(id)) {
        await api.delete('/api/profile/favorites/' + Uri.encodeComponent(id));
      }
    }

    for (final item in values.take(30)) {
      final id = (item['id'] ?? '').toString();
      final body = <String, dynamic>{
        'name': (item['name'] ?? '').toString().trim(),
        'address': (item['address'] ?? '').toString().trim(),
        'lat': double.parse(item['lat'].toString()),
        'lon': double.parse(item['lon'].toString()),
      };
      if (id.isNotEmpty && existingById.containsKey(id)) {
        await api.post(
          '/api/profile/favorites/' + Uri.encodeComponent(id),
          body,
        );
      } else {
        await api.post('/api/profile/favorites', body);
      }
    }

    final fresh =
        _favoritesFromPayload(await api.get('/api/profile/favorites'));
    await _cacheFavoriteAddresses(api, fresh);
    return fresh;
  } catch (e) {
    if (_profileEndpointMissing(e)) {
      await _cacheFavoriteAddresses(api, values);
      return values;
    }
    rethrow;
  }
}

Future<String> _loadLocalPromoCode(ApiClient api) async {
  final key = await _clientScopedStorageKey(api, 'promo_code_v1');
  return (await _clientProfileStorage.read(key: key) ?? '').trim();
}

Future<void> _cachePromoCode(ApiClient api, String value) async {
  final key = await _clientScopedStorageKey(api, 'promo_code_v1');
  final normalized = value.trim().toUpperCase();
  if (normalized.isEmpty) {
    await _clientProfileStorage.delete(key: key);
  } else {
    await _clientProfileStorage.write(key: key, value: normalized);
  }
}

Future<String> _loadSavedPromoCode(ApiClient api) async {
  final local = await _loadLocalPromoCode(api);
  if (api.isDemo) return local;

  try {
    final raw = await api.get('/api/profile/promo');
    var code = '';
    if (raw is Map && raw['promo'] is Map) {
      code = ((raw['promo'] as Map)['code'] ?? '').toString().trim().toUpperCase();
    }

    // One-time migration from the local secure-storage implementation.
    if (code.isEmpty && local.isNotEmpty) {
      final saved = await api.post(
        '/api/profile/promo',
        <String, dynamic>{'code': local.toUpperCase()},
      );
      if (saved is Map && saved['promo'] is Map) {
        code = ((saved['promo'] as Map)['code'] ?? local).toString().trim().toUpperCase();
      } else {
        code = local.toUpperCase();
      }
    }

    await _cachePromoCode(api, code);
    return code;
  } catch (e) {
    if (_profileEndpointMissing(e)) return local;
    rethrow;
  }
}

Future<void> _savePromoCode(ApiClient api, String value) async {
  final normalized = value.trim().toUpperCase();
  if (api.isDemo) {
    await _cachePromoCode(api, normalized);
    return;
  }

  try {
    if (normalized.isEmpty) {
      await api.delete('/api/profile/promo');
    } else {
      await api.post(
        '/api/profile/promo',
        <String, dynamic>{'code': normalized},
      );
    }
    await _cachePromoCode(api, normalized);
  } catch (e) {
    if (_profileEndpointMissing(e)) {
      await _cachePromoCode(api, normalized);
      return;
    }
    rethrow;
  }
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
  final api = ApiClient(defaultBackendUrl);
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
    api.setBaseUrl(savedUrl ?? defaultBackendUrl);
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
        final me = await api.get('/api/me');
        await syncProfileSettings(me);
        loggedIn = true;
      } catch (_) {
        api.token = null;
        await storage.delete(key: 'session');
        await storage.delete(key: 'remember_me');
      }
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> syncProfileSettings(dynamic me) async {
    if (api.isDemo || api.token == null) return;
    try {
      String? remoteLang;
      String? remoteTheme;
      if (me is Map && me['yangi_profile'] is Map) {
        final profile = me['yangi_profile'] as Map;
        if (profile['settings'] is Map) {
          final settings = profile['settings'] as Map;
          final l = settings['lang']?.toString();
          final t = settings['theme']?.toString();
          if (l == 'ru' || l == 'uz') remoteLang = l;
          if (t == 'system' || t == 'light' || t == 'dark') remoteTheme = t;
        }
      }

      if (remoteLang != null || remoteTheme != null) {
        if (remoteLang != null) {
          lang = remoteLang;
          await storage.write(key: 'lang', value: remoteLang);
        }
        if (remoteTheme != null) {
          themeSetting = remoteTheme;
          await storage.write(key: 'theme_mode', value: remoteTheme);
        }
      }

      // Fill missing server values from the device on first migration.
      if (remoteLang == null || remoteTheme == null) {
        await api.post('/api/profile/settings', <String, dynamic>{
          'lang': lang,
          'theme': themeSetting,
        });
      }
    } catch (e) {
      // Personal settings are non-critical and must never block login.
      if (!_profileEndpointMissing(e)) {
        debugPrint('Profile settings sync failed: $e');
      }
    }
  }

  Future<void> pushProfileSettings() async {
    if (api.isDemo || api.token == null) return;
    try {
      await api.post('/api/profile/settings', <String, dynamic>{
        'lang': lang,
        'theme': themeSetting,
      });
    } catch (e) {
      if (!_profileEndpointMissing(e)) {
        debugPrint('Profile settings save failed: $e');
      }
    }
  }

  Future<void> saveLang(String value) async {
    lang = value;
    await storage.write(key: 'lang', value: value);
    await pushProfileSettings();
    if (mounted) setState(() {});
  }

  Future<void> saveTheme(String value) async {
    if (value != 'light' && value != 'dark' && value != 'system') return;
    themeSetting = value;
    await storage.write(key: 'theme_mode', value: value);
    await pushProfileSettings();
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

    try {
      final me = await api.get('/api/me');
      await syncProfileSettings(me);
    } catch (_) {
      // Authentication already succeeded; profile sync must not block login.
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
      seedColor: yangiLime,
      brightness: Brightness.light,
      surface: Colors.white,
    ).copyWith(
      primary: yangiGraphite,
      onPrimary: Colors.white,
      secondary: yangiGreen,
      surface: Colors.white,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF1F3F3),
      surfaceContainer: const Color(0xFFEBEEEE),
      surfaceContainerHigh: const Color(0xFFE6E9E9),
      surfaceContainerHighest: const Color(0xFFDDE1E1),
      outline: const Color(0xFF9BA2A2),
      outlineVariant: const Color(0xFFD0D5D5),
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: yangiLime,
      brightness: Brightness.dark,
      surface: const Color(0xFF0B0D0E),
    ).copyWith(
      primary: yangiLime,
      onPrimary: yangiGraphite,
      secondary: yangiGreen,
      surface: const Color(0xFF0B0D0E),
      surfaceContainerLowest: const Color(0xFF090B0C),
      surfaceContainerLow: const Color(0xFF111415),
      surfaceContainer: const Color(0xFF151819),
      surfaceContainerHigh: const Color(0xFF1A1E1F),
      surfaceContainerHighest: const Color(0xFF222627),
      outline: const Color(0xFF747B7D),
      outlineVariant: const Color(0xFF303638),
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
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          height: 68,
          backgroundColor: Colors.white,
          indicatorColor: Color(0xFFDFFF9A),
          elevation: 0,
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(22))),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF7F8F8),
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
        scaffoldBackgroundColor: const Color(0xFF0B0D0E),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0B0D0E),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          height: 68,
          backgroundColor: Color(0xFF0B0D0E),
          indicatorColor: Color(0xFF2E4A00),
          elevation: 0,
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Color(0xFF151819),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(22))),
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
          ? const _YangiSplashScreen()
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

class _YangiSplashScreen extends StatelessWidget {
  const _YangiSplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: Image(
          image: AssetImage('assets/yangi_splash_ref.webp'),
          fit: BoxFit.cover,
          alignment: Alignment.center,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
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
  bool passwordVisible = false;
  bool passwordStep = false;
  String? error;
  String? info;

  @override
  void initState() {
    super.initState();
    final initialDigits = widget.initialPhone.replaceAll(RegExp(r'\\D'), '');
    final localPhone = initialDigits.length == 12 && initialDigits.startsWith('998')
        ? initialDigits.substring(3)
        : widget.initialPhone;
    phone = TextEditingController(text: localPhone);
    rememberMe = true;
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
      passwordStep = false;
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
        'phone': _authPhone(),
      });
      if (!mounted) return;
      setState(() {
        smsSent = true;
        info = widget.lang == 'uz'
            ? 'SMS-kod ${_authPhone()} raqamiga yuborildi'
            : 'SMS-код отправлен на ${_authPhone()}';
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
        'phone': _authPhone(),
        'password': pass.text,
        'code': smsCode.text.trim(),
      });
      await widget.onToken(data['token'].toString(), rememberMe, _authPhone());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> login() async {
    if (phone.text.trim().isEmpty || pass.text.isEmpty) {
      setState(() {
        error = widget.lang == 'uz'
            ? 'Telefon va parolni kiriting'
            : 'Введите телефон и пароль';
        info = null;
      });
      return;
    }

    setState(() {
      busy = true;
      error = null;
      info = null;
    });
    try {
      final data = await widget.api.post('/api/auth/login', <String, dynamic>{
        'phone': _authPhone(),
        'password': pass.text,
      });
      await widget.onToken(data['token'].toString(), rememberMe, _authPhone());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _authPhone() {
    final raw = phone.text.trim();
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 9) return '+998' + digits;
    if (digits.length == 12 && digits.startsWith('998')) return '+' + digits;
    return raw;
  }

  Future<void> submit() async {
    if (!register && !passwordStep) {
      if (phone.text.trim().isEmpty) {
        setState(() => error = widget.lang == 'uz'
            ? 'Telefon raqamingizni kiriting'
            : 'Введите номер телефона');
        return;
      }
      setState(() {
        passwordStep = true;
        error = null;
        info = null;
      });
      return;
    }
    if (!register) return login();
    if (!smsSent) return requestSms();
    return verifySmsAndRegister();
  }

  @override
  Widget build(BuildContext context) {
    const pageBg = Color(0xFF080A08);
    const panel = Color(0xD9161918);
    const panelBorder = Color(0xFF626761);
    const muted = Color(0xFFB9BDB8);

    InputDecoration darkField({
      required String hint,
      Widget? prefix,
      Widget? suffix,
    }) {
      return InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          color: Color(0xFF777C78),
          fontSize: 17,
          fontWeight: FontWeight.w500,
        ),
        prefixIcon: prefix,
        suffixIcon: suffix,
        filled: true,
        fillColor: panel,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: panelBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: panelBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: yangiLime, width: 1.6),
        ),
      );
    }

    void socialUnavailable(String provider) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.lang == 'uz'
                ? provider + ' orqali kirish tez orada qo‘shiladi'
                : 'Вход через ' + provider + ' будет подключён позже',
          ),
        ),
      );
    }

    Widget socialButton({
      required Widget leading,
      required String label,
      required VoidCallback onTap,
    }) {
      return Material(
        color: panel,
        borderRadius: BorderRadius.circular(17),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: const Color(0xFF4D524E)),
            ),
            child: Row(
              children: <Widget>[
                SizedBox(width: 34, child: Center(child: leading)),
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(
                  width: 34,
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFFD8DBD8),
                    size: 25,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: pageBg,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Image.asset(
              'assets/yangi_auth_bg.webp',
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.black.withValues(alpha: 0.26),
                    Colors.black.withValues(alpha: 0.42),
                    Colors.black.withValues(alpha: 0.76),
                    Colors.black.withValues(alpha: 0.94),
                  ],
                  stops: const <double>[0, 0.34, 0.68, 1],
                ),
              ),
            ),
          ),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 26),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const Spacer(),
                          Material(
                            color: Colors.black.withValues(alpha: 0.28),
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              onTap: busy
                                  ? null
                                  : () => widget.onLang(
                                        widget.lang == 'uz' ? 'ru' : 'uz',
                                      ),
                              borderRadius: BorderRadius.circular(16),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 11,
                                  vertical: 7,
                                ),
                                child: Text(
                                  widget.lang.toUpperCase(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.7,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      GestureDetector(
                        onLongPress: busy
                            ? null
                            : () => backendDialog(
                                  context,
                                  widget.api,
                                  widget.onBackend,
                                ),
                        child: Center(
                          child: Image.asset(
                            'assets/yangi_brand_lockup.webp',
                            width: 290,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.high,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.lang == 'uz'
                            ? (register
                                ? 'Ro‘yxatdan o‘ting'
                                : passwordStep
                                    ? 'Parolingizni kiriting'
                                    : 'Xush kelibsiz')
                            : (register
                                ? 'Регистрация'
                                : passwordStep
                                    ? 'Введите пароль'
                                    : 'Добро пожаловать'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 31,
                          height: 1.04,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.9,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.lang == 'uz'
                            ? (register
                                ? 'Yangi Taxi akkauntingizni yarating'
                                : passwordStep
                                    ? 'Telefon raqamingiz uchun parolni kiriting'
                                    : 'Telefon raqamingiz orqali tizimga kiring')
                            : (register
                                ? 'Создайте аккаунт Yangi Taxi'
                                : passwordStep
                                    ? 'Введите пароль для вашего номера'
                                    : 'Войдите по номеру телефона'),
                        style: const TextStyle(
                          color: muted,
                          fontSize: 15,
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 22),
                      TextField(
                        controller: phone,
                        enabled: !smsSent && !busy && !passwordStep,
                        keyboardType: TextInputType.phone,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: darkField(
                          hint: '90 123 45 67',
                          prefix: SizedBox(
                            width: 128,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                const Text(
                                  '🇺🇿',
                                  style: TextStyle(fontSize: 21),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: muted,
                                  size: 19,
                                ),
                                const SizedBox(width: 10),
                                Container(
                                  width: 1,
                                  height: 28,
                                  color: const Color(0xFF5A5F5B),
                                ),
                                const SizedBox(width: 14),
                                const Text(
                                  '+998',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Container(
                                  width: 1,
                                  height: 28,
                                  color: const Color(0xFF5A5F5B),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (register) ...<Widget>[
                        const SizedBox(height: 11),
                        TextField(
                          controller: name,
                          enabled: !smsSent && !busy,
                          textCapitalization: TextCapitalization.words,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: darkField(
                            hint: widget.lang == 'uz'
                                ? 'Ismingiz'
                                : 'Ваше имя',
                            prefix: const Icon(
                              Icons.person_outline_rounded,
                              color: muted,
                            ),
                          ),
                        ),
                      ],
                      if (passwordStep || register) ...<Widget>[
                        const SizedBox(height: 11),
                        TextField(
                          controller: pass,
                          enabled: !smsSent && !busy,
                          obscureText: !passwordVisible,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          onSubmitted: (_) => submit(),
                          decoration: darkField(
                            hint: widget.lang == 'uz'
                                ? 'Parol'
                                : 'Пароль',
                            prefix: const Icon(
                              Icons.lock_outline_rounded,
                              color: muted,
                            ),
                            suffix: IconButton(
                              onPressed: busy || smsSent
                                  ? null
                                  : () => setState(
                                        () => passwordVisible =
                                            !passwordVisible,
                                      ),
                              icon: Icon(
                                passwordVisible
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                color: muted,
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (register && smsSent) ...<Widget>[
                        const SizedBox(height: 11),
                        TextField(
                          controller: smsCode,
                          autofocus: true,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 3,
                          ),
                          onSubmitted: (_) => submit(),
                          decoration: darkField(
                            hint: widget.lang == 'uz'
                                ? 'SMS-kod'
                                : 'Код из SMS',
                            prefix: const Icon(
                              Icons.sms_outlined,
                              color: muted,
                            ),
                          ).copyWith(counterText: ''),
                        ),
                      ],
                      const SizedBox(height: 10),
                      if (!passwordStep && !register)
                        Text(
                          widget.lang == 'uz'
                              ? 'Tasdiqlash kodi SMS orqali yuboriladi'
                              : 'Для входа понадобится ваш пароль',
                          style: const TextStyle(
                            color: muted,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      if (info != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            info!,
                            style: const TextStyle(
                              color: yangiLime,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            error!,
                            style: const TextStyle(
                              color: Color(0xFFFF7A7A),
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 60,
                        child: FilledButton(
                          onPressed: busy ? null : submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: yangiLime,
                            foregroundColor: yangiGraphite,
                            disabledBackgroundColor:
                                yangiLime.withValues(alpha: 0.36),
                            disabledForegroundColor:
                                yangiGraphite.withValues(alpha: 0.70),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            elevation: 8,
                            shadowColor:
                                yangiLime.withValues(alpha: 0.30),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              if (busy) ...<Widget>[
                                const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: yangiGraphite,
                                  ),
                                ),
                                const SizedBox(width: 10),
                              ],
                              Flexible(
                                child: Text(
                                  !register
                                      ? (passwordStep
                                          ? (widget.lang == 'uz'
                                              ? 'Kirish'
                                              : 'Войти')
                                          : (widget.lang == 'uz'
                                              ? 'Davom etish'
                                              : 'Продолжить'))
                                      : (smsSent
                                          ? (widget.lang == 'uz'
                                              ? 'Tasdiqlash'
                                              : 'Подтвердить')
                                          : (widget.lang == 'uz'
                                              ? 'SMS-kod olish'
                                              : 'Получить SMS-код')),
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              if (!busy) ...<Widget>[
                                const SizedBox(width: 14),
                                const Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 25,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (passwordStep && !register)
                        Align(
                          alignment: Alignment.center,
                          child: TextButton(
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                      passwordStep = false;
                                      pass.clear();
                                      error = null;
                                    }),
                            child: Text(
                              widget.lang == 'uz'
                                  ? 'Telefon raqamini o‘zgartirish'
                                  : 'Изменить номер телефона',
                              style: const TextStyle(
                                color: yangiLime,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 13),
                      Row(
                        children: <Widget>[
                          const Expanded(
                            child: Divider(color: Color(0xFF737873)),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                            ),
                            child: Text(
                              widget.lang == 'uz' ? 'yoki' : 'или',
                              style: const TextStyle(
                                color: muted,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          const Expanded(
                            child: Divider(color: Color(0xFF737873)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 13),
                      socialButton(
                        leading: const Text(
                          'G',
                          style: TextStyle(
                            color: Color(0xFF4285F4),
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        label: widget.lang == 'uz'
                            ? 'Google orqali'
                            : 'Войти через Google',
                        onTap: () => socialUnavailable('Google'),
                      ),
                      const SizedBox(height: 10),
                      socialButton(
                        leading: const Icon(
                          Icons.apple,
                          color: Colors.white,
                          size: 27,
                        ),
                        label: widget.lang == 'uz'
                            ? 'Apple orqali'
                            : 'Войти через Apple',
                        onTap: () => socialUnavailable('Apple'),
                      ),
                      const SizedBox(height: 15),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            width: 23,
                            height: 23,
                            decoration: BoxDecoration(
                              color: yangiLime,
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: const Icon(
                              Icons.check_rounded,
                              color: yangiGraphite,
                              size: 17,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: RichText(
                              text: TextSpan(
                                style: const TextStyle(
                                  color: muted,
                                  fontSize: 11.5,
                                  height: 1.45,
                                  fontWeight: FontWeight.w500,
                                ),
                                children: <InlineSpan>[
                                  TextSpan(
                                    text: widget.lang == 'uz'
                                        ? 'Davom etish orqali siz '
                                        : 'Продолжая, вы соглашаетесь с ',
                                  ),
                                  TextSpan(
                                    text: widget.lang == 'uz'
                                        ? 'Foydalanish shartlari'
                                        : 'условиями использования',
                                    style: const TextStyle(
                                      color: yangiLime,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  TextSpan(
                                    text: widget.lang == 'uz'
                                        ? ' va '
                                        : ' и ',
                                  ),
                                  TextSpan(
                                    text: widget.lang == 'uz'
                                        ? 'Maxfiylik siyosatiga'
                                        : 'политикой конфиденциальности',
                                    style: const TextStyle(
                                      color: yangiLime,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  TextSpan(
                                    text: widget.lang == 'uz'
                                        ? ' rozilik bildirasiz'
                                        : '.',
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Center(
                        child: TextButton(
                          onPressed: busy ? null : toggleMode,
                          child: Text(
                            register
                                ? (widget.lang == 'uz'
                                    ? 'Akkauntingiz bormi? Kirish'
                                    : 'Уже есть аккаунт? Войти')
                                : (widget.lang == 'uz'
                                    ? 'Akkaunt yo‘qmi? Ro‘yxatdan o‘tish'
                                    : 'Нет аккаунта? Регистрация'),
                            style: const TextStyle(
                              color: yangiLime,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      Center(
                        child: TextButton(
                          onPressed: () => socialUnavailable(
                            widget.lang == 'uz' ? 'Yordam' : 'Помощь',
                          ),
                          child: Text(
                            widget.lang == 'uz'
                                ? 'Yordam kerakmi?'
                                : 'Нужна помощь?',
                            style: const TextStyle(
                              color: yangiLime,
                              decoration: TextDecoration.underline,
                              decorationColor: yangiLime,
                              fontWeight: FontWeight.w700,
                            ),
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


const yangiLime = Color(0xFFA6FF00);
const yangiGraphite = Color(0xFF0F1111);
const yangiSoftGray = Color(0xFFF2F4F5);
const yangiGreen = Color(0xFF13A83E);

class ExitConfirmScope extends StatelessWidget {
  const ExitConfirmScope({super.key, required this.lang, required this.child});
  final String lang;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) return;
          final shouldExit = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              icon: const Icon(Icons.exit_to_app_rounded, size: 34),
              title: Text(lang == 'uz' ? 'Ilovadan chiqasizmi?' : 'Выйти из приложения?'),
              content: Text(
                lang == 'uz'
                    ? 'Yangi Taxi ilovasini yopmoqchimisiz?'
                    : 'Вы действительно хотите закрыть Yangi Taxi?',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(lang == 'uz' ? 'Bekor' : 'Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: yangiLime,
                    foregroundColor: yangiGraphite,
                  ),
                  child: Text(lang == 'uz' ? 'Chiqish' : 'Выйти'),
                ),
              ],
            ),
          );
          if (shouldExit == true) SystemNavigator.pop();
        },
        child: child,
      );
}

class YangiWordmark extends StatelessWidget {
  const YangiWordmark({
    super.key,
    this.compact = false,
    this.onDarkSurface = false,
  });
  final bool compact;
  final bool onDarkSurface;

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
            color: onDarkSurface ? Colors.white : Theme.of(context).colorScheme.onSurface,
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
  int orderFormGeneration = 0;
  bool _exitDialogOpen = false;

  @override
  void initState() {
    super.initState();
    restoreActiveOrder();
  }

  Future<void> restoreActiveOrder() async {
    try {
      final data = await widget.api.get('/api/orders/current');
      if (!mounted || data is! List || data.isEmpty) return;

      final raw = data.first;
      if (raw is! Map) return;
      final rawId = raw['order_id'];
      final id = rawId is num ? rawId.toInt() : int.tryParse(rawId?.toString() ?? '');
      if (id == null || id <= 0) return;

      setState(() {
        activeId = id;
        tab = 1;
      });
    } catch (_) {
      // A failed restore must not block the home screen.
    }
  }

  void openMenu() => shellKey.currentState?.openDrawer();

  Future<void> handleAndroidBack() async {
    final scaffold = shellKey.currentState;
    if (scaffold?.isDrawerOpen == true) {
      scaffold!.closeDrawer();
      return;
    }
    if (tab != 0) {
      selectTab(0);
      return;
    }
    if (_exitDialogOpen || !mounted) return;

    _exitDialogOpen = true;
    try {
      final shouldExit = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.exit_to_app_rounded, size: 34),
          title: Text(widget.lang == 'uz' ? 'Ilovadan chiqasizmi?' : 'Выйти из приложения?'),
          content: Text(
            widget.lang == 'uz'
                ? 'Yangi Taxi ilovasini yopmoqchimisiz?'
                : 'Вы действительно хотите закрыть Yangi Taxi?',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(widget.lang == 'uz' ? 'Bekor' : 'Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: FilledButton.styleFrom(
                backgroundColor: yangiLime,
                foregroundColor: yangiGraphite,
              ),
              child: Text(widget.lang == 'uz' ? 'Chiqish' : 'Выйти'),
            ),
          ],
        ),
      );
      if (shouldExit == true) SystemNavigator.pop();
    } finally {
      _exitDialogOpen = false;
    }
  }

  void selectTab(int value) {
    final scaffold = shellKey.currentState;
    if (scaffold?.isDrawerOpen == true) {
      scaffold!.closeDrawer();
    }
    if (mounted && tab != value) {
      setState(() => tab = value);
    }
  }

  void startNewTrip() {
    final scaffold = shellKey.currentState;
    if (scaffold?.isDrawerOpen == true) {
      scaffold!.closeDrawer();
    }
    if (!mounted) return;
    setState(() {
      activeId = null;
      orderFormGeneration += 1;
      tab = 0;
    });
  }

  void orderCreated(int id) {
    setState(() {
      activeId = id;
      tab = 1;
    });
  }

  Future<void> openDrawerPage(Widget page) async {
    final scaffold = shellKey.currentState;
    if (scaffold?.isDrawerOpen == true) {
      scaffold!.closeDrawer();
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => page),
    );
    if (mounted) selectTab(0);
  }

  void openDrawerSettings() {
    final scaffold = shellKey.currentState;
    if (scaffold?.isDrawerOpen == true) {
      scaffold!.closeDrawer();
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => SettingsScreen(
          api: widget.api,
          lang: widget.lang,
          themeSetting: widget.themeSetting,
          onLang: widget.onLang,
          onTheme: widget.onTheme,
          onBackend: widget.onBackend,
          onMenu: () => Navigator.pop(routeContext),
          backButton: true,
        ),
      ),
    );
  }

  void showHelpFromDrawer() {
    final scaffold = shellKey.currentState;
    if (scaffold?.isDrawerOpen == true) {
      scaffold!.closeDrawer();
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.lang == 'uz'
              ? 'Yordam keyingi bosqichda ulanadi'
              : 'Помощь будет подключена на следующем этапе',
        ),
      ),
    );
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
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final selectedBg = Color.alphaBlend(
      yangiLime.withValues(alpha: dark ? 0.17 : 0.14),
      theme.colorScheme.surface,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: selected ? selectedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          leading: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: selected
                  ? yangiLime
                  : theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              size: 20,
              color: selected ? yangiGraphite : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          title: Text(
            title,
            style: TextStyle(
              color: theme.colorScheme.onSurface,
              fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
            ),
          ),
          subtitle: subtitle == null
              ? null
              : Text(
                  subtitle,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
          trailing: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: selected
                ? Icon(
                    Icons.chevron_right_rounded,
                    key: const ValueKey<String>('selected'),
                    size: 20,
                    color: theme.colorScheme.onSurface,
                  )
                : const SizedBox(key: ValueKey<String>('idle'), width: 20),
          ),
          onTap: () => index == 0 ? startNewTrip() : selectTab(index),
        ),
      ),
    );
  }

  Widget menuActionItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      icon,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      OrderScreen(
        key: ValueKey<int>(orderFormGeneration),
        api: widget.api,
        lang: widget.lang,
        onOrder: orderCreated,
        onMenu: openMenu,
        isActive: tab == 0,
      ),
      RideScreen(
        api: widget.api,
        lang: widget.lang,
        orderId: activeId,
        onMenu: openMenu,
        onNewTrip: startNewTrip,
        isActive: tab == 1,
      ),
      HistoryScreen(api: widget.api, lang: widget.lang, onMenu: startNewTrip),
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
        themeSetting: widget.themeSetting,
        onTheme: widget.onTheme,
        onBackend: widget.onBackend,
        onLogout: widget.onLogout,
        onMenu: () => selectTab(0),
      ),
    ];

    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(handleAndroidBack());
      },
      child: Scaffold(
        key: shellKey,
      drawerScrimColor: Colors.black.withValues(alpha: dark ? 0.58 : 0.34),
      drawerEdgeDragWidth: 44,
      drawer: Drawer(
        width: math.min(352.0, MediaQuery.sizeOf(context).width * 0.88),
        elevation: 22,
        backgroundColor: theme.colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(32)),
        ),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutQuart,
          builder: (context, value, child) => Opacity(
            opacity: value,
            child: Transform.translate(
              offset: Offset(-18 * (1 - value), 0),
              child: Transform.scale(
                scale: 0.985 + 0.015 * value,
                alignment: Alignment.centerLeft,
                child: child,
              ),
            ),
          ),
          child: SafeArea(
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 13, 8, 13),
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(
                        yangiLime.withValues(alpha: dark ? 0.13 : 0.18),
                        theme.colorScheme.surface,
                      ),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: yangiLime.withValues(alpha: dark ? 0.22 : 0.35),
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: yangiLime,
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: const Icon(
                            Icons.local_taxi_rounded,
                            color: yangiGraphite,
                            size: 25,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const YangiWordmark(compact: true),
                              const SizedBox(height: 4),
                              Text(
                                widget.lang == 'uz'
                                    ? 'Barcha bo‘limlar bir joyda'
                                    : 'Все разделы в одном меню',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => shellKey.currentState?.closeDrawer(),
                          icon: const Icon(Icons.close_rounded),
                          tooltip: widget.lang == 'uz' ? 'Yopish' : 'Закрыть',
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 8),
                    children: <Widget>[
                      menuSection(widget.lang == 'uz' ? 'SAFARLAR' : 'ПОЕЗДКИ'),
                      menuItem(
                        index: 0,
                        icon: Icons.add_road_rounded,
                        title: widget.lang == 'uz' ? 'Yangi safar' : 'Новая поездка',
                      ),
                      menuItem(
                        index: 1,
                        icon: Icons.local_taxi_outlined,
                        title: widget.lang == 'uz' ? 'Joriy safar' : 'Текущая поездка',
                      ),
                      menuItem(
                        index: 2,
                        icon: Icons.receipt_long_outlined,
                        title: widget.lang == 'uz' ? 'Mening safarlarim' : 'Мои поездки',
                      ),
                      menuSection(widget.lang == 'uz' ? 'AKKAUNT' : 'АККАУНТ'),
                      menuItem(
                        index: 5,
                        icon: Icons.person_outline_rounded,
                        title: widget.lang == 'uz' ? 'Profil' : 'Профиль',
                      ),
                      menuItem(
                        index: 3,
                        icon: Icons.credit_card_rounded,
                        title: widget.lang == 'uz' ? 'To‘lov usullari' : 'Способы оплаты',
                      ),
                      menuActionItem(
                        icon: Icons.location_on_outlined,
                        title: widget.lang == 'uz' ? 'Sevimli manzillar' : 'Любимые адреса',
                        onTap: () => openDrawerPage(
                          FavoriteAddressesScreen(api: widget.api, lang: widget.lang),
                        ),
                      ),
                      menuActionItem(
                        icon: Icons.local_offer_outlined,
                        title: widget.lang == 'uz' ? 'Promokodlar' : 'Промокоды',
                        onTap: () => openDrawerPage(
                          PromoCodesScreen(api: widget.api, lang: widget.lang),
                        ),
                      ),
                      menuItem(
                        index: 4,
                        icon: Icons.settings_outlined,
                        title: widget.lang == 'uz' ? 'Sozlamalar' : 'Настройки',
                      ),
                      menuActionItem(
                        icon: Icons.help_outline_rounded,
                        title: widget.lang == 'uz' ? 'Yordam' : 'Помощь',
                        onTap: showHelpFromDrawer,
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: theme.colorScheme.outlineVariant),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      onTap: widget.onLogout,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.errorContainer.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.logout_rounded,
                                color: theme.colorScheme.error,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              widget.lang == 'uz' ? 'Chiqish' : 'Выйти',
                              style: TextStyle(
                                color: theme.colorScheme.error,
                                fontWeight: FontWeight.w900,
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
          ),
        ),
      ),
        body: IndexedStack(index: tab, children: pages),
        bottomNavigationBar: null,
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
  const _MapPinMarker({
    required this.pickup,
    this.label = '',
    this.caption = '',
  });

  final bool pickup;
  final String label;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final fill = pickup ? yangiGreen : yangiGraphite;
    final markerAccent = pickup ? yangiGreen : yangiLime;
    final hasLabel = label.trim().isNotEmpty;

    Widget pin() => SizedBox(
          width: 54,
          height: 68,
          child: Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[
              Positioned(
                top: 4,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: fill.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                top: 10,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: fill,
                    shape: BoxShape.circle,
                    border: Border.all(color: pickup ? Colors.white : yangiLime, width: 3),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(color: Color(0x30000000), blurRadius: 7, offset: Offset(0, 3)),
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: pickup ? Colors.white : yangiLime,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(top: 41, child: Container(width: 4, height: 14, color: markerAccent)),
              Positioned(
                top: 53,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: markerAccent, width: 3),
                  ),
                ),
              ),
            ],
          ),
        );

    if (!hasLabel) return pin();

    final theme = Theme.of(context);
    final card = Container(
      width: 174,
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55)),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x28000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: markerAccent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  caption.isNotEmpty ? caption : (pickup ? 'Откуда' : 'Куда'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.1,
                    fontWeight: FontWeight.w900,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return SizedBox(
      width: 228,
      height: 72,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          if (pickup) ...<Widget>[
            Positioned(left: 0, bottom: 0, child: pin()),
            Positioned(left: 42, top: 4, child: card),
          ] else ...<Widget>[
            Positioned(right: 0, bottom: 0, child: pin()),
            Positioned(right: 42, top: 4, child: card),
          ],
        ],
      ),
    );
  }
}

class _VehicleSprite extends StatelessWidget {
  const _VehicleSprite({
    required this.kind,
    this.fit = BoxFit.contain,
  });

  final String kind;
  final BoxFit fit;

  int get _index => switch (kind.toLowerCase()) {
        'comfort' => 1,
        'business' => 2,
        'xl' || 'minivan' || 'miniven' => 3,
        'electro' || 'electric' || 'ev' => 4,
        'delivery' => 5,
        'cargo' => 6,
        'map' || 'map_marker' || 'marker' => 7,
        // Together deliberately uses Start/Economy, per the design pack mapping.
        _ => 0,
      };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 160.0;
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : width / 1.6;
        final spriteWidth = width * 8;
        final alignmentX = -1.0 + (2.0 * _index / 7.0);

        return ClipRect(
          child: SizedBox(
            width: width,
            height: height,
            child: OverflowBox(
              alignment: Alignment(alignmentX, 0),
              minWidth: spriteWidth,
              maxWidth: spriteWidth,
              minHeight: height,
              maxHeight: height,
              child: Image.asset(
                'assets/yangi_vehicle_sprite.webp',
                width: spriteWidth,
                height: height,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MapCarMarker extends StatelessWidget {
  const _MapCarMarker({required this.kind, this.driver = false});
  final String kind;
  final bool driver;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: driver ? 48 : 40,
      height: driver ? 48 : 40,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: <Widget>[
          const Positioned.fill(
            child: _VehicleSprite(kind: 'map_marker'),
          ),
          if (driver)
            Positioned(
              right: -1,
              top: -1,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: yangiLime,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(color: Color(0x33000000), blurRadius: 4),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TariffVehicleArt extends StatelessWidget {
  const _TariffVehicleArt({
    required this.kind,
    required this.selected,
    required this.available,
  });

  final String kind;
  final bool selected;
  final bool available;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: available ? 1 : 0.42,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          if (selected)
            Positioned(
              left: 8,
              right: 8,
              bottom: 5,
              child: Container(
                height: 24,
                decoration: BoxDecoration(
                  color: yangiLime.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          Positioned.fill(
            child: _VehicleSprite(kind: kind),
          ),
        ],
      ),
    );
  }
}

class _DriverAssignedVehicleArt extends StatelessWidget {
  const _DriverAssignedVehicleArt({required this.kind});
  final String kind;

  @override
  Widget build(BuildContext context) {
    return _VehicleSprite(kind: kind);
  }
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
    this.fromLabel = '',
    this.toLabel = '',
    this.fromCaption = 'Откуда',
    this.toCaption = 'Куда',
    this.driver,
    this.nearbyCars = const <NearbyCrew>[],
    this.vehicleKind = 'start',
    this.zoom = 14,
  });
  final ym.Point center;
  final List<ym.Point> route;
  final ym.Point? from;
  final ym.Point? to;
  final String fromLabel;
  final String toLabel;
  final String fromCaption;
  final String toCaption;
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

  yv.ViewProvider _pinProvider(bool pickup, String label, String caption) {
    final cleanLabel = label.trim();
    final cleanCaption = caption.trim();
    final key = 'pin-' +
        (pickup ? 'pickup' : 'destination') +
        '-' +
        cleanLabel.hashCode.toString() +
        '-' +
        cleanCaption.hashCode.toString();
    return _providers.putIfAbsent(
      key,
      () => yv.ViewProvider(
        id: 'yangi-' + key,
        cacheable: cleanLabel.isEmpty,
        builder: () => _MapPinMarker(
          pickup: pickup,
          label: cleanLabel,
          caption: cleanCaption,
        ),
      ),
    );
  }

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

  bool _samePoint(ym.Point? a, ym.Point? b) {
    if (a == null || b == null) return a == null && b == null;
    return (a.latitude - b.latitude).abs() < 0.0000001 &&
        (a.longitude - b.longitude).abs() < 0.0000001;
  }

  bool _sameRoute(List<ym.Point> a, List<ym.Point> b) {
    if (a.length != b.length) return false;
    if (a.isEmpty) return true;
    for (var i = 0; i < a.length; i++) {
      if (!_samePoint(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  void didUpdateWidget(covariant TaxiYandexMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (mapWindow == null) return;

    final routeChanged = !_sameRoute(oldWidget.route, widget.route);
    final endpointsChanged =
        !_samePoint(oldWidget.from, widget.from) ||
        !_samePoint(oldWidget.to, widget.to);
    final centerChanged = !_samePoint(oldWidget.center, widget.center);

    _render(
      focusRoute: widget.route.length > 1 && (routeChanged || endpointsChanged),
      moveCamera: routeChanged || endpointsChanged || centerChanged,
    );
  }

  @override
  void dispose() {
    if (yandexMapKitApiKey.isNotEmpty) ym_factory.mapkit.onStop();
    super.dispose();
  }

  void _render({bool focusRoute = true, bool moveCamera = true}) {
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
        final width = window.width().toDouble();
        final height = window.height().toDouble();
        final routeFocus = width > 0 && height > 0
            ? ym.ScreenRect(
                ym.ScreenPoint(x: width * 0.06, y: height * 0.12),
                ym.ScreenPoint(x: width * 0.94, y: height * 0.53),
              )
            : null;
        window.focusRect = routeFocus;
        final fit = map.cameraPositionForGeometry(
          ym.Geometry.fromPolyline(polyline),
          focusRect: routeFocus,
          azimuth: 0,
          tilt: 0,
        );
        map.move(
          ym.CameraPosition(
            fit.target,
            zoom: math.max(10.0, fit.zoom - 0.18),
            azimuth: 0,
            tilt: 0,
          ),
        );
      }
    }

    if (widget.from != null) {
      map.mapObjects.addPlacemark()
        ..geometry = widget.from!
        ..setViewWithStyle(
          _pinProvider(true, widget.fromLabel, widget.fromCaption),
          ym.IconStyle(
            anchor: widget.fromLabel.trim().isEmpty
                ? const math.Point<double>(0.5, 1.0)
                : const math.Point<double>(0.115, 1.0),
            scale: widget.fromLabel.trim().isEmpty ? 0.82 : 0.88,
            zIndex: 22,
          ),
        );
    }

    if (widget.to != null) {
      map.mapObjects.addPlacemark()
        ..geometry = widget.to!
        ..setViewWithStyle(
          _pinProvider(false, widget.toLabel, widget.toCaption),
          ym.IconStyle(
            anchor: widget.toLabel.trim().isEmpty
                ? const math.Point<double>(0.5, 1.0)
                : const math.Point<double>(0.885, 1.0),
            scale: widget.toLabel.trim().isEmpty ? 0.82 : 0.88,
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
          scale: 0.92,
          zIndex: 15,
          rotationType: ym.RotationType.Rotate,
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
            scale: 1.00,
            zIndex: 30,
            rotationType: ym.RotationType.Rotate,
          ),
        );
    }

    if (moveCamera && widget.route.length < 2) {
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

class _TariffSpecPill extends StatelessWidget {
  const _TariffSpecPill({
    required this.icon,
    required this.value,
    required this.selected,
  });

  final IconData icon;
  final String value;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final foreground = selected
        ? const Color(0xFFD5DADB)
        : scheme.onSurfaceVariant;

    return Container(
      height: 27,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: 0.08)
            : (dark
                ? Colors.white.withValues(alpha: 0.05)
                : const Color(0xFFF3F5F5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              color: foreground,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
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
    required this.isActive,
  });
  final ApiClient api;
  final String lang;
  final ValueChanged<int> onOrder;
  final VoidCallback onMenu;
  final bool isActive;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  Place? from;
  Place? to;
  double? cost;
  List<ym.Point> route = <ym.Point>[];
  double? routeDistanceKm;
  int? routeMinutes;
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
  String promoCode = '';
  bool pickupPinnedByUser = false;
  late final ys.SearchManager locationSearchManager;
  ys.SearchSession? locationSearchSession;
  yd.DrivingRouter? drivingRouter;
  yd.DrivingSession? drivingSession;

  @override
  void initState() {
    super.initState();
    locationSearchManager = ys.SearchFactory.instance.createSearchManager(ys.SearchManagerType.Online);
    if (yandexMapKitApiKey.isNotEmpty) {
      drivingRouter = yd.DirectionsFactory.instance.createDrivingRouter(yd.DrivingRouterType.Combined);
    }
    loadPaymentConfig();
    loadCards();
    loadTariffCatalog();
    loadPromoCode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      detectMyLocation(auto: true);
    });
    nearbyCarsTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (widget.isActive) loadNearbyCars();
    });
  }

  @override
  void dispose() {
    nearbyCarsTimer?.cancel();
    estimateTimer?.cancel();
    locationSearchSession?.cancel();
    drivingSession?.cancel();
    super.dispose();
  }

  Future<Place?> selectAddress(String title, Place? initial) async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return null;
    return showModalBottomSheet<Place>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddressSheet(api: widget.api, lang: widget.lang, title: title, initial: initial),
    );
  }

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
      routeDistanceKm = null;
      routeMinutes = null;
    });
    await loadNearbyCars();
  }

  Future<void> pickRoutePointOnMap({required bool pickup}) async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
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
        pickupPinnedByUser = true;
      } else {
        to = place;
      }
      cost = null;
      route = <ym.Point>[];
      routeDistanceKm = null;
      routeMinutes = null;
      error = null;
    });

    if (pickup) await loadNearbyCars();
    scheduleEstimate();
  }

  Future<void> loadPromoCode() async {
    final value = await _loadSavedPromoCode(widget.api);
    if (mounted) setState(() => promoCode = value);
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

  List<Map<String, dynamic>> _validateEstimatedTariffs(dynamic rawOptions) {
    if (rawOptions is! List) return <Map<String, dynamic>>[];

    const order = <String>[
      'start',
      'together',
      'comfort',
      'business',
      'delivery',
      'cargo',
    ];
    final byKey = <String, Map<String, dynamic>>{};

    for (final raw in rawOptions.whereType<Map>()) {
      final item = Map<String, dynamic>.from(raw);
      final key = (item['key'] ?? '').toString().trim().toLowerCase();
      if (!order.contains(key)) continue;

      final price = _routeNumber(item['cost']);
      final tariffId = item['tariffId'] is num
          ? (item['tariffId'] as num).toInt()
          : int.tryParse((item['tariffId'] ?? '').toString());
      final crewGroupId = item['crewGroupId'] is num
          ? (item['crewGroupId'] as num).toInt()
          : int.tryParse((item['crewGroupId'] ?? '').toString());

      final mappingValid =
          (tariffId == null || tariffId > 0) &&
          (crewGroupId == null || crewGroupId > 0);
      final validPrice = price != null && price.isFinite && price > 0;

      item['key'] = key;
      item['available'] =
          item['available'] == true && mappingValid && validPrice;
      if (price != null && price.isFinite) item['cost'] = price;

      byKey[key] = item;
    }

    final result = <Map<String, dynamic>>[
      for (final key in order)
        if (byKey[key] != null) byKey[key]!,
    ];

    Map<String, dynamic>? start;
    Map<String, dynamic>? together;
    for (final item in result) {
      if (item['key'] == 'start') start = item;
      if (item['key'] == 'together') together = item;
    }
    final startCost = _routeNumber(start?['cost']);
    final togetherCost = _routeNumber(together?['cost']);
    if (startCost != null && startCost > 0 && togetherCost != null && togetherCost > 0) {
      final saving = ((startCost - togetherCost) / startCost * 100).clamp(-999.0, 999.0);
      together!['effectiveSavingPercentVsStart'] = saving;
    }

    return result;
  }

  Map<String, dynamic>? get selectedCard {
    for (final card in cards) {
      if ((card['cardId'] as num?)?.toInt() == selectedCardId) return card;
    }
    return cards.isEmpty ? null : cards.first;
  }

  Future<void> openCardsManager() async {
    String? nextMethod;
    int? nextCardId;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CardsScreen(
          api: widget.api,
          lang: widget.lang,
          initialPaymentMethod: paymentMethod,
          initialCardId: selectedCardId,
          onPaymentChanged: (method, cardId) {
            nextMethod = method;
            nextCardId = cardId;
          },
        ),
      ),
    );
    await loadCards();
    if (!mounted || nextMethod == null) return;
    setState(() {
      paymentMethod = nextMethod!;
      if (nextMethod == 'card' && nextCardId != null && nextCardId! > 0) {
        selectedCardId = nextCardId!;
      }
    });
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

  String tariffAsset(String key) => switch (key) {
        'together' => 'assets/map_car_together.webp',
        'comfort' => 'assets/map_car_comfort.webp',
        'business' => 'assets/map_car_business.webp',
        'delivery' => 'assets/map_car_delivery.webp',
        'cargo' => 'assets/map_car_cargo.webp',
        _ => 'assets/map_car_start.webp',
      };

  int tariffPassengers(String key) {
    switch (key) {
      case 'cargo':
      case 'delivery':
        return 2;
      case 'xl':
      case 'minivan':
      case 'miniven':
        return 6;
      default:
        return 4;
    }
  }

  int tariffBaggage(String key) {
    switch (key) {
      case 'business':
      case 'comfort':
        return 3;
      case 'cargo':
        return 6;
      case 'delivery':
        return 1;
      case 'xl':
      case 'minivan':
      case 'miniven':
        return 4;
      default:
        return 2;
    }
  }

  String tariffDescription(String key) {
    if (widget.lang == 'uz') {
      return switch (key) {
        'together' => 'Birga borish — yanada tejamkor',
        'comfort' => 'Ko‘proq joy va qulaylik',
        'business' => 'Premium xizmat va avtomobil',
        'xl' || 'minivan' || 'miniven' => '6 yo‘lovchigacha keng miniven',
        'electro' || 'electric' || 'ev' => 'Sokin va zamonaviy elektromobil',
        'delivery' => 'Posilka va kichik yuklar uchun',
        'cargo' => 'Katta yuklarni tashish uchun',
        _ => 'Har kun uchun tez va qulay',
      };
    }
    return switch (key) {
      'together' => 'Выгоднее для совместной поездки',
      'comfort' => 'Больше пространства и комфорта',
      'business' => 'Премиальный сервис и автомобиль',
      'xl' || 'minivan' || 'miniven' => 'Просторный минивэн до 6 пассажиров',
      'electro' || 'electric' || 'ev' => 'Тихий современный электромобиль',
      'delivery' => 'Для посылок и небольших грузов',
      'cargo' => 'Для перевозки крупных грузов',
      _ => 'Быстро и выгодно на каждый день',
    };
  }

  String moneyLabel(num? value) {
    if (value == null) return '—';
    final digits = value.round().toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(' ');
      out.write(digits[i]);
    }
    return out.toString() + (widget.lang == 'uz' ? ' so‘m' : ' сум');
  }

  void swapRoutePoints() {
    if (from == null || to == null) return;
    setState(() {
      final oldFrom = from;
      from = to;
      to = oldFrom;
      pickupPinnedByUser = true;
      cost = null;
      route = <ym.Point>[];
      routeDistanceKm = null;
      routeMinutes = null;
      error = null;
    });
    loadNearbyCars();
    scheduleEstimate(delay: Duration.zero);
  }

  void clearDestination() {
    if (to == null) return;
    setState(() {
      to = null;
      cost = null;
      route = <ym.Point>[];
      tariffOptions = <Map<String, dynamic>>[];
      routeDistanceKm = null;
      routeMinutes = null;
      error = null;
    });
  }

  double _distanceBetween(ym.Point a, ym.Point b) {
    const earthKm = 6371.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * earthKm * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
  }

  double _polylineDistance(List<ym.Point> points) {
    if (points.length < 2) return 0;
    double total = 0;
    for (var i = 1; i < points.length; i++) {
      total += _distanceBetween(points[i - 1], points[i]);
    }
    return total;
  }

  double? _routeNumber(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) {
      return double.tryParse(value.trim().replaceAll(',', '.'));
    }
    return null;
  }

  bool _validCoordinate(double lat, double lon) =>
      lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;

  ym.Point? _routePointFromRaw(dynamic raw, Place source, Place destination) {
    double? lat;
    double? lon;

    if (raw is Map) {
      final coords = raw['coords'];
      if (coords is Map) {
        lat = _routeNumber(coords['lat'] ?? coords['latitude'] ?? coords['y']);
        lon = _routeNumber(coords['lon'] ?? coords['lng'] ?? coords['longitude'] ?? coords['x']);
      }
      lat ??= _routeNumber(raw['lat'] ?? raw['latitude'] ?? raw['y']);
      lon ??= _routeNumber(raw['lon'] ?? raw['lng'] ?? raw['longitude'] ?? raw['x']);
    } else if (raw is List && raw.length >= 2) {
      final a = _routeNumber(raw[0]);
      final b = _routeNumber(raw[1]);
      if (a != null && b != null) {
        final midpoint = ym.Point(
          latitude: (source.lat + destination.lat) / 2,
          longitude: (source.lon + destination.lon) / 2,
        );
        final first = _validCoordinate(a, b) ? ym.Point(latitude: a, longitude: b) : null;
        final swapped = _validCoordinate(b, a) ? ym.Point(latitude: b, longitude: a) : null;
        if (first != null && swapped != null) {
          return _distanceBetween(first, midpoint) <= _distanceBetween(swapped, midpoint)
              ? first
              : swapped;
        }
        return first ?? swapped;
      }
    } else if (raw is String) {
      final pieces = raw
          .trim()
          .split(RegExp(r'[;,\s]+'))
          .where((x) => x.isNotEmpty)
          .toList();
      if (pieces.length >= 2) {
        final a = _routeNumber(pieces[0]);
        final b = _routeNumber(pieces[1]);
        if (a != null && b != null) {
          if (_validCoordinate(a, b)) {
            lat = a;
            lon = b;
          } else if (_validCoordinate(b, a)) {
            lat = b;
            lon = a;
          }
        }
      }
    }

    if (lat == null || lon == null || !_validCoordinate(lat, lon)) return null;
    return ym.Point(latitude: lat, longitude: lon);
  }

  List<ym.Point> _normalizeRoutePoints(
    dynamic routeData,
    Place source,
    Place destination,
  ) {
    dynamic rawPoints;
    if (routeData is Map) {
      final root = routeData['data'] is Map ? routeData['data'] as Map : routeData;
      rawPoints = root['full_route_coords'] ??
          root['route_coords'] ??
          root['coords'] ??
          root['points'] ??
          root['geometry'];
      if (rawPoints is Map) {
        rawPoints = rawPoints['points'] ?? rawPoints['coordinates'] ?? rawPoints['coords'];
      }
    } else {
      rawPoints = routeData;
    }

    final points = <ym.Point>[];
    if (rawPoints is List) {
      for (final raw in rawPoints) {
        final p = _routePointFromRaw(raw, source, destination);
        if (p == null) continue;
        if (points.isEmpty || _distanceBetween(points.last, p) > 0.003) {
          points.add(p);
        }
      }
    }

    final sourcePoint = source.point;
    final destinationPoint = destination.point;

    if (points.length >= 2) {
      final normalScore =
          _distanceBetween(points.first, sourcePoint) +
          _distanceBetween(points.last, destinationPoint);
      final reversedScore =
          _distanceBetween(points.first, destinationPoint) +
          _distanceBetween(points.last, sourcePoint);
      if (reversedScore + 0.05 < normalScore) {
        final reversed = points.reversed.toList();
        points
          ..clear()
          ..addAll(reversed);
      }
    }

    if (points.isEmpty) {
      return <ym.Point>[];
    }

    if (_distanceBetween(points.first, sourcePoint) > 0.15) {
      points.insert(0, sourcePoint);
    } else {
      points[0] = sourcePoint;
    }

    if (_distanceBetween(points.last, destinationPoint) > 0.15) {
      points.add(destinationPoint);
    } else {
      points[points.length - 1] = destinationPoint;
    }

    return points;
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
          routeDistanceKm = null;
          routeMinutes = null;
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
      if (!pickupPinnedByUser) {
        setState(() {
          from = place;
          cost = null;
          route = <ym.Point>[];
          routeDistanceKm = null;
          routeMinutes = null;
        });
      }
      await loadNearbyCars();
      if (to != null) scheduleEstimate();
    } catch (_) {}
  }

  Future<void> detectMyLocation({bool auto = false}) async {
    if (locating) return;
    if (!auto) pickupPinnedByUser = false;
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

      if (!pickupPinnedByUser) {
        setState(() {
          from = place;
          cost = null;
          route = <ym.Point>[];
          routeDistanceKm = null;
          routeMinutes = null;
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

  bool _routeLooksLikeRoadGeometry(List<ym.Point> points) {
    if (points.length < 6) return false;
    final direct = _distanceBetween(points.first, points.last);
    final along = _polylineDistance(points);
    if (direct < 0.08) return true;
    return along >= direct * 1.008;
  }

  void _logLiveRoute(Place source, Place destination, List<ym.Point> points, String sourceName) {
    if (widget.api.isDemo) return;
    String p(ym.Point x) =>
        x.latitude.toStringAsFixed(6) + ',' + x.longitude.toStringAsFixed(6);
    final first = points.take(3).map(p).join(' | ');
    final last = points.reversed.take(3).toList().reversed.map(p).join(' | ');
    debugPrint(
      '[Yangi route] source=' + p(source.point) +
      ' destination=' + p(destination.point) +
      ' sourceName=' + sourceName +
      ' points=' + points.length.toString() +
      ' first=[' + first + '] last=[' + last + ']',
    );
  }

  Future<List<ym.Point>> _buildYandexDrivingRoute(
    Place source,
    Place destination,
  ) async {
    final router = drivingRouter;
    if (router == null) return <ym.Point>[];

    final completer = Completer<List<ym.Point>>();
    drivingSession?.cancel();

    final listener = yd.DrivingSessionRouteListener(
      onDrivingRoutes: (routes) {
        if (completer.isCompleted) return;
        if (routes.isEmpty) {
          completer.complete(<ym.Point>[]);
          return;
        }
        completer.complete(routes.first.geometry.points);
      },
      onDrivingRoutesError: (_) {
        if (!completer.isCompleted) completer.complete(<ym.Point>[]);
      },
    );

    drivingSession = router.requestRoutes(
      const yd.DrivingOptions(routesCount: 1),
      const yd.DrivingVehicleOptions(),
      listener,
      points: <ym.RequestPoint>[
        ym.RequestPoint(source.point, ym.RequestPointType.Waypoint, null, null, null),
        ym.RequestPoint(destination.point, ym.RequestPointType.Waypoint, null, null, null),
      ],
    );

    return completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        drivingSession?.cancel();
        return <ym.Point>[];
      },
    );
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
      final taxiMasterPoints = _normalizeRoutePoints(mapData, source, destination);
      _logLiveRoute(source, destination, taxiMasterPoints, 'TaxiMaster');

      var points = <ym.Point>[];
      final roadPoints = await _buildYandexDrivingRoute(source, destination);
      if (currentGeneration != estimateGeneration || !mounted) return;
      if (roadPoints.length > 1) {
        points = roadPoints;
        _logLiveRoute(source, destination, points, 'YandexDrivingRouter');
      } else if (_routeLooksLikeRoadGeometry(taxiMasterPoints)) {
        points = taxiMasterPoints;
        _logLiveRoute(source, destination, points, 'TaxiMasterFallback');
      } else {
        _logLiveRoute(source, destination, points, 'unavailable');
      }

      final rawOptions = data['options'];
      final options = _validateEstimatedTariffs(rawOptions);

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

      double? distanceFromApi;
      if (mapData is Map) {
        final explicitDistance =
            _routeNumber(mapData['distance_km'] ?? mapData['distanceKm'] ?? mapData['distance']);
        final cityDistance = _routeNumber(mapData['city_dist']) ?? 0;
        final countryDistance = _routeNumber(mapData['country_dist']) ?? 0;
        final taxiMasterDistance = cityDistance + countryDistance;
        distanceFromApi = explicitDistance ?? (taxiMasterDistance > 0 ? taxiMasterDistance : null);
      }
      final minutesFromApi = mapData is Map
          ? ((mapData['duration_minutes'] ?? mapData['duration_min'] ?? mapData['time_min'] ?? mapData['minutes']) as num?)?.toInt()
          : null;
      final computedDistance = distanceFromApi ?? _polylineDistance(points);
      final computedMinutes = minutesFromApi ??
          (computedDistance > 0 ? math.max(1, (computedDistance / 28 * 60).round()) : null);

      setState(() {
        tariffOptions = options;
        route = points;
        routeDistanceKm = computedDistance > 0 ? computedDistance : null;
        routeMinutes = computedMinutes;
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
          routeDistanceKm = null;
          routeMinutes = null;
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
        if (promoCode.isNotEmpty) 'promoCode': promoCode,
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



  Future<void> _editPickupPremium() async {
    final p = await selectAddress(tx(widget.lang, 'from'), from);
    if (p == null || !mounted) return;
    setState(() {
      from = p;
      pickupPinnedByUser = true;
      cost = null;
      route = <ym.Point>[];
      routeDistanceKm = null;
      routeMinutes = null;
    });
    await loadNearbyCars();
    scheduleEstimate();
  }

  Future<void> applyDestination(Place p) async {
    if (!mounted) return;
    setState(() {
      to = p;
      cost = null;
      route = <ym.Point>[];
      routeDistanceKm = null;
      routeMinutes = null;
      error = null;
    });

    if (p.isFavorite) {
      pickupPinnedByUser = false;
      await detectMyLocation(auto: false);
      if (!mounted) return;
    }

    scheduleEstimate();
  }

  Future<void> _editDestinationPremium() async {
    final p = await selectAddress(tx(widget.lang, 'to'), to ?? from);
    if (p == null || !mounted) return;
    await applyDestination(p);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final center = from?.point ?? currentLocation ?? const ym.Point(latitude: defaultLat, longitude: defaultLon);
    final canUseCard = atmosEnabled && cardBindingAvailable;
    final destinationReady = to != null;
    final destinationOptional = selectedTariffKey == 'delivery';
    final routeReadyForOrder = from != null && (destinationReady || destinationOptional);
    final tariffs = visibleTariffs;
    final activeTariff = selectedTariff;
    final activeTariffAvailable = activeTariff?['available'] == true;
    final selectedPrice = (activeTariff?['cost'] as num?)?.toDouble() ?? cost;

    String orderButtonLabel() {
      if (busy) {
        return widget.lang == 'uz' ? 'Buyurtma yaratilmoqda…' : 'Создаём заказ…';
      }
      if (from == null) {
        return widget.lang == 'uz' ? 'Joylashuv aniqlanmoqda…' : 'Определяем местоположение…';
      }
      if (!destinationReady && !destinationOptional) {
        return widget.lang == 'uz' ? 'Manzilni tanlang' : 'Выберите адрес назначения';
      }
      if (!activeTariffAvailable) {
        return widget.lang == 'uz' ? 'Tarif mavjud emas' : 'Тариф недоступен';
      }
      if (destinationReady && cost == null) {
        return widget.lang == 'uz' ? 'Narxni hisoblash' : 'Рассчитать стоимость';
      }
      return widget.lang == 'uz' ? 'Yangi Taxi buyurtma qilish' : 'Заказать Yangi Taxi';
    }
    final distanceLabel = routeDistanceKm == null ? '—' : '${routeDistanceKm!.toStringAsFixed(1)} ${widget.lang == 'uz' ? 'km' : 'км'}';
    final minutesLabel = routeMinutes == null ? '—' : '${routeMinutes!} ${widget.lang == 'uz' ? 'daq' : 'мин'}';

    Widget metric(IconData icon, String value, String label) {
      return Expanded(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF202425) : Colors.white,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 19, color: scheme.onSurface),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    value,
                    maxLines: 1,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Stack(
        children: <Widget>[
          if (widget.isActive)
            Positioned.fill(
              child: TaxiYandexMap(
              center: center,
              route: route,
              from: from?.point,
              to: to?.point,
              fromLabel: from?.address ?? '',
              toLabel: to?.address ?? '',
              fromCaption: widget.lang == 'uz' ? 'Qayerdan' : 'Откуда',
              toCaption: widget.lang == 'uz' ? 'Qayerga' : 'Куда',
              nearbyCars: nearbyCars,
              vehicleKind: selectedTariffKey,
              zoom: destinationReady ? 13.7 : 15,
            ),
          ),

          Positioned(
            top: 10,
            left: 14,
            right: 14,
            child: SafeArea(
              bottom: false,
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      _roundMapButton(
                        icon: Icons.menu_rounded,
                        onTap: widget.onMenu,
                        tooltip: widget.lang == 'uz' ? 'Menyu' : 'Меню',
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Material(
                          color: dark
                              ? const Color(0xED121516)
                              : Colors.white.withValues(alpha: 0.97),
                          borderRadius: BorderRadius.circular(22),
                          elevation: dark ? 0 : 8,
                          shadowColor: const Color(0x26000000),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: _editPickupPremium,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
                              child: Row(
                                children: <Widget>[
                                  Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: yangiLime,
                                      borderRadius: BorderRadius.circular(11),
                                    ),
                                    child: const Icon(
                                      Icons.my_location_rounded,
                                      color: yangiGraphite,
                                      size: 19,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        Text(
                                          widget.lang == 'uz' ? 'Mashina keladi' : 'Подача машины',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            height: 1,
                                            color: scheme.onSurfaceVariant,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          from?.address ??
                                              (locating
                                                  ? (widget.lang == 'uz'
                                                      ? 'Joylashuv aniqlanmoqda…'
                                                      : 'Определяем местоположение…')
                                                  : (widget.lang == 'uz'
                                                      ? 'Joriy joylashuv'
                                                      : 'Текущее местоположение')),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 13.5,
                                            height: 1,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: -0.2,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    Icons.expand_more_rounded,
                                    color: scheme.onSurfaceVariant,
                                    size: 22,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          Positioned(
            right: 18,
            bottom: MediaQuery.of(context).size.height * (destinationReady ? 0.62 : 0.42),
            child: SafeArea(
              child: _roundMapButton(
                icon: Icons.my_location_rounded,
                onTap: locating ? null : () => detectMyLocation(),
                tooltip: widget.lang == 'uz' ? 'Mening joylashuvim' : 'Моё местоположение',
                large: true,
              ),
            ),
          ),

          DraggableScrollableSheet(
            initialChildSize: destinationReady ? 0.61 : 0.40,
            minChildSize: destinationReady ? 0.47 : 0.31,
            maxChildSize: 0.92,
            snap: true,
            snapSizes: destinationReady
                ? const <double>[0.47, 0.61, 0.92]
                : const <double>[0.31, 0.40, 0.92],
            builder: (context, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: dark ? const Color(0xFF101314) : const Color(0xFFF4F5F3),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                  border: Border(
                    top: BorderSide(
                      color: dark ? const Color(0xFF24292A) : const Color(0x0F000000),
                    ),
                  ),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(color: Color(0x30000000), blurRadius: 28, offset: Offset(0, -8)),
                  ],
                ),
                child: Column(
                  children: <Widget>[
                    const SizedBox(height: 8),
                    Container(
                      width: 43,
                      height: 5,
                      decoration: BoxDecoration(
                        color: const Color(0xFFD1D5DB),
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 5, 16, 12),
                        children: <Widget>[
                          if (!destinationReady) ...<Widget>[
                            const SizedBox(height: 2),
                            Text(
                              widget.lang == 'uz' ? 'Qayerga boramiz?' : 'Куда поедем?',
                              style: const TextStyle(
                                fontSize: 29,
                                height: 1,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1.0,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              widget.lang == 'uz'
                                  ? 'Manzilni tanlang — narx va mashina darhol ko‘rinadi'
                                  : 'Выберите адрес — сразу покажем цену и машину',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Material(
                              color: const Color(0xFF101719),
                              borderRadius: BorderRadius.circular(22),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: _editDestinationPremium,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(17, 15, 12, 15),
                                  child: Row(
                                    children: <Widget>[
                                      const Icon(Icons.search_rounded, color: Colors.white, size: 25),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          widget.lang == 'uz' ? 'Manzilni kiriting' : 'Введите адрес',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: -0.35,
                                          ),
                                        ),
                                      ),
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: const BoxDecoration(
                                          color: yangiLime,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.arrow_forward_rounded,
                                          color: yangiGraphite,
                                          size: 24,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            SizedBox(
                              height: 66,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                children: <Widget>[
                                  _premiumQuickDestination(
                                    icon: Icons.home_rounded,
                                    title: widget.lang == 'uz' ? 'Uy' : 'Дом',
                                    subtitle: widget.lang == 'uz' ? 'Tanlash' : 'Выбрать',
                                    onTap: _editDestinationPremium,
                                  ),
                                  _premiumQuickDestination(
                                    icon: Icons.work_rounded,
                                    title: widget.lang == 'uz' ? 'Ish' : 'Работа',
                                    subtitle: widget.lang == 'uz' ? 'Tanlash' : 'Выбрать',
                                    onTap: _editDestinationPremium,
                                  ),
                                  _premiumQuickDestination(
                                    icon: Icons.flight_takeoff_rounded,
                                    title: widget.lang == 'uz' ? 'Aeroport' : 'Аэропорт',
                                    subtitle: widget.lang == 'uz' ? 'Tez yo‘l' : 'Быстрый выбор',
                                    onTap: _editDestinationPremium,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    widget.lang == 'uz' ? 'Tezkor manzillar' : 'Быстрые адреса',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: _editDestinationPremium,
                                  child: Text(widget.lang == 'uz' ? 'Hammasi' : 'Все'),
                                ),
                              ],
                            ),
                            _premiumDestinationRow(
                              icon: Icons.location_on_rounded,
                              title: widget.lang == 'uz' ? 'Manzilni xaritadan tanlash' : 'Выбрать место на карте',
                              subtitle: widget.lang == 'uz'
                                  ? 'Nuqtani aniq belgilang'
                                  : 'Укажите точную точку подачи или назначения',
                              onTap: () => pickRoutePointOnMap(pickup: false),
                            ),
                            const SizedBox(height: 8),
                            _premiumDestinationRow(
                              icon: Icons.search_rounded,
                              title: widget.lang == 'uz' ? 'Manzil bo‘yicha qidirish' : 'Поиск по адресу',
                              subtitle: widget.lang == 'uz'
                                  ? 'Ko‘cha, uy yoki joy nomi'
                                  : 'Улица, дом или название места',
                              onTap: _editDestinationPremium,
                            ),
                          ],
                          if (destinationReady) ...<Widget>[
                          Text(
                            destinationReady
                                ? (widget.lang == 'uz'
                                    ? 'Safar tafsilotlari'
                                    : 'Детали поездки')
                                : (widget.lang == 'uz'
                                    ? 'Safarni buyurtma qiling'
                                    : 'Заказать поездку'),
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.9,
                              height: 1.05,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            widget.lang == 'uz'
                                ? 'Manzillarni buyurtmagacha istalgan payt o‘zgartirish mumkin'
                                : 'Адреса можно изменить в любой момент до заказа',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: dark ? const Color(0xFF191D1E) : Colors.white,
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: dark
                                          ? const Color(0xFF2A3031)
                                          : const Color(0x10000000),
                                    ),
                                    boxShadow: dark
                                        ? const <BoxShadow>[]
                                        : const <BoxShadow>[
                                            BoxShadow(
                                              color: Color(0x10000000),
                                              blurRadius: 18,
                                              offset: Offset(0, 7),
                                            ),
                                          ],
                                  ),
                                  child: Column(
                                    children: <Widget>[
                                      _addressLine(
                                        pickup: true,
                                        title: widget.lang == 'uz' ? 'Qayerdan' : 'Откуда',
                                        value: from?.address ??
                                            (locating
                                                ? (widget.lang == 'uz'
                                                    ? 'Joylashuv aniqlanmoqda…'
                                                    : 'Определяем местоположение…')
                                                : (widget.lang == 'uz'
                                                    ? 'Joriy joylashuv'
                                                    : 'Текущее местоположение')),
                                        onTap: () async {
                                          final p = await selectAddress(tx(widget.lang, 'from'), from);
                                          if (p != null && mounted) {
                                            setState(() {
                                              from = p;
                                              pickupPinnedByUser = true;
                                              cost = null;
                                              route = <ym.Point>[];
                                              routeDistanceKm = null;
                                              routeMinutes = null;
                                            });
                                            await loadNearbyCars();
                                            scheduleEstimate();
                                          }
                                        },
                                        onMapTap: () => pickRoutePointOnMap(pickup: true),
                                      ),
                                      Divider(
                                        height: 1,
                                        indent: 45,
                                        endIndent: 12,
                                        color: scheme.outlineVariant.withValues(alpha: 0.65),
                                      ),
                                      _addressLine(
                                        pickup: false,
                                        title: selectedTariffKey == 'delivery'
                                            ? (widget.lang == 'uz'
                                                ? 'Qayerga — ixtiyoriy'
                                                : 'Куда — необязательно')
                                            : (widget.lang == 'uz' ? 'Qayerga' : 'Куда'),
                                        value: to?.address ??
                                            (selectedTariffKey == 'delivery'
                                                ? (widget.lang == 'uz'
                                                    ? 'Keyinroq ko‘rsatish mumkin'
                                                    : 'Можно указать позже')
                                                : (widget.lang == 'uz'
                                                    ? 'Manzilni tanlang'
                                                    : 'Выберите адрес')),
                                        onTap: () async {
                                          final p = await selectAddress(
                                            tx(widget.lang, 'to'),
                                            to ?? from,
                                          );
                                          if (p != null && mounted) {
                                            await applyDestination(p);
                                          }
                                        },
                                        onMapTap: () => pickRoutePointOnMap(pickup: false),
                                        onClear: to == null ? null : clearDestination,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (destinationReady) ...<Widget>[
                                const SizedBox(width: 9),
                                Material(
                                  color: scheme.surfaceContainerHigh,
                                  borderRadius: BorderRadius.circular(20),
                                  child: InkWell(
                                    onTap: swapRoutePoints,
                                    borderRadius: BorderRadius.circular(20),
                                    child: SizedBox(
                                      width: 48,
                                      height: 133,
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: <Widget>[
                                          Icon(
                                            Icons.swap_vert_rounded,
                                            color: scheme.onSurface,
                                            size: 25,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            widget.lang == 'uz' ? 'Almash' : 'Поменять',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              fontSize: 8.5,
                                              color: scheme.onSurfaceVariant,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (destinationReady) ...<Widget>[
                            const SizedBox(height: 10),
                            Container(
                              height: 68,
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              decoration: BoxDecoration(
                                color: dark ? const Color(0xFF191D1E) : Colors.white,
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: dark ? const Color(0xFF2A3031) : const Color(0x10000000),
                                ),
                              ),
                              child: Row(
                                children: <Widget>[
                                  metric(
                                    Icons.route_rounded,
                                    distanceLabel,
                                    widget.lang == 'uz' ? 'Masofa' : 'Расстояние',
                                  ),
                                  Container(
                                    width: 1,
                                    height: 34,
                                    color: scheme.outlineVariant.withValues(alpha: 0.7),
                                  ),
                                  metric(
                                    Icons.schedule_rounded,
                                    minutesLabel,
                                    widget.lang == 'uz' ? 'Vaqt' : 'В пути',
                                  ),
                                  Container(
                                    width: 1,
                                    height: 34,
                                    color: scheme.outlineVariant.withValues(alpha: 0.7),
                                  ),
                                  metric(
                                    Icons.navigation_rounded,
                                    widget.lang == 'uz' ? 'Eng tez' : 'Быстрый',
                                    widget.lang == 'uz' ? 'Yo‘nalish' : 'Маршрут',
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),

                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  widget.lang == 'uz' ? 'Tarifni tanlang' : 'Выберите тариф',
                                  style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900, letterSpacing: -0.55),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: _showTariffComparisonSheet,
                                icon: const Icon(Icons.tune_rounded, size: 18),
                                label: Text(widget.lang == 'uz' ? 'Taqqoslash' : 'Сравнить'),
                                style: TextButton.styleFrom(
                                  foregroundColor: yangiGreen,
                                  textStyle: const TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),

                          if (estimating && destinationReady)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 26),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    const CircularProgressIndicator(strokeWidth: 2.5),
                                    const SizedBox(height: 10),
                                    Text(
                                      widget.lang == 'uz'
                                          ? 'TaxiMaster narxlarni hisoblamoqda'
                                          : 'TaxiMaster рассчитывает цены',
                                      style: TextStyle(
                                        color: scheme.onSurfaceVariant,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            ...tariffs.map((option) {
                              final key = (option['key'] ?? '').toString();
                              final available = option['available'] == true;
                              final isSelected =
                                  available && key == selectedTariffKey;
                              final price = (option['cost'] as num?)?.toDouble();
                              final title = widget.lang == 'uz'
                                  ? (option['nameUz'] ??
                                          option['nameRu'] ??
                                          key)
                                      .toString()
                                  : (option['nameRu'] ?? key).toString();
                              final saving =
                                  (option['effectiveSavingPercentVsStart']
                                          as num?)
                                      ?.toDouble();

                              final selectedBg = dark
                                  ? yangiLime.withValues(alpha: 0.10)
                                  : const Color(0xFFF2FFE8);
                              final idleBg = dark
                                  ? const Color(0xFF171B1C)
                                  : Colors.white;

                              return Padding(
                                padding: const EdgeInsets.only(bottom: 9),
                                child: Opacity(
                                  opacity: available ? 1 : 0.48,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    curve: Curves.easeOutCubic,
                                    decoration: BoxDecoration(
                                      color: isSelected ? selectedBg : idleBg,
                                      borderRadius: BorderRadius.circular(22),
                                      border: Border.all(
                                        color: isSelected
                                            ? yangiLime
                                            : (dark
                                                ? const Color(0xFF303638)
                                                : const Color(0xFFE6E9E9)),
                                        width: isSelected ? 2.1 : 1,
                                      ),
                                      boxShadow: dark
                                          ? const <BoxShadow>[]
                                          : const <BoxShadow>[
                                              BoxShadow(
                                                color: Color(0x0C000000),
                                                blurRadius: 14,
                                                offset: Offset(0, 5),
                                              ),
                                            ],
                                    ),
                                    child: Material(
                                      color: Colors.transparent,
                                      borderRadius: BorderRadius.circular(21),
                                      clipBehavior: Clip.antiAlias,
                                      child: InkWell(
                                        onTap: available
                                            ? () => selectTariff(key)
                                            : null,
                                        child: Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            11,
                                            10,
                                            12,
                                            10,
                                          ),
                                          child: Row(
                                            children: <Widget>[
                                              SizedBox(
                                                width: 104,
                                                height: 68,
                                                child: _TariffVehicleArt(
                                                  kind: key,
                                                  selected: isSelected,
                                                  available: available,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: <Widget>[
                                                    Row(
                                                      children: <Widget>[
                                                        Flexible(
                                                          child: Text(
                                                            title,
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                const TextStyle(
                                                              fontSize: 17,
                                                              height: 1,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w900,
                                                              letterSpacing:
                                                                  -0.35,
                                                            ),
                                                          ),
                                                        ),
                                                        if (saving != null &&
                                                            saving > 0) ...<
                                                            Widget>[
                                                          const SizedBox(
                                                              width: 6),
                                                          Container(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                              horizontal: 7,
                                                              vertical: 3,
                                                            ),
                                                            decoration:
                                                                BoxDecoration(
                                                              color: yangiLime,
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                          9),
                                                            ),
                                                            child: Text(
                                                              '−' +
                                                                  saving
                                                                      .round()
                                                                      .toString() +
                                                                  '%',
                                                              style:
                                                                  const TextStyle(
                                                                color:
                                                                    yangiGraphite,
                                                                fontSize: 9.5,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w900,
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                    const SizedBox(height: 6),
                                                    Row(
                                                      children: <Widget>[
                                                        Icon(
                                                          Icons.person_rounded,
                                                          size: 14,
                                                          color: scheme
                                                              .onSurfaceVariant,
                                                        ),
                                                        const SizedBox(width: 3),
                                                        Text(
                                                          tariffPassengers(key)
                                                              .toString(),
                                                          style: TextStyle(
                                                            color: scheme
                                                                .onSurfaceVariant,
                                                            fontSize: 11,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                          ),
                                                        ),
                                                        const SizedBox(width: 9),
                                                        Icon(
                                                          key == 'delivery' ||
                                                                  key == 'cargo'
                                                              ? Icons
                                                                  .inventory_2_outlined
                                                              : Icons
                                                                  .luggage_rounded,
                                                          size: 13,
                                                          color: scheme
                                                              .onSurfaceVariant,
                                                        ),
                                                        const SizedBox(width: 3),
                                                        Text(
                                                          tariffBaggage(key)
                                                              .toString(),
                                                          style: TextStyle(
                                                            color: scheme
                                                                .onSurfaceVariant,
                                                            fontSize: 11,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 5),
                                                    Text(
                                                      tariffDescription(key),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                        fontSize: 10.5,
                                                        height: 1.15,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 9),
                                              ConstrainedBox(
                                                constraints:
                                                    const BoxConstraints(
                                                  minWidth: 74,
                                                  maxWidth: 92,
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.end,
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: <Widget>[
                                                    Text(
                                                      !available
                                                          ? (widget.lang == 'uz'
                                                              ? 'Mavjud emas'
                                                              : 'Недоступен')
                                                          : price != null
                                                              ? moneyLabel(
                                                                  price)
                                                              : '—',
                                                      textAlign:
                                                          TextAlign.right,
                                                      maxLines: 2,
                                                      style: TextStyle(
                                                        color: available
                                                            ? scheme.onSurface
                                                            : scheme
                                                                .onSurfaceVariant,
                                                        fontSize: 14.5,
                                                        height: 1.05,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                      ),
                                                    ),
                                                    if (destinationReady &&
                                                        routeMinutes != null) ...<
                                                        Widget>[
                                                      const SizedBox(height: 4),
                                                      Text(
                                                        '~ ' +
                                                            routeMinutes!
                                                                .toString() +
                                                            (widget.lang == 'uz'
                                                                ? ' daq'
                                                                : ' мин'),
                                                        style: TextStyle(
                                                          color: scheme
                                                              .onSurfaceVariant,
                                                          fontSize: 9.5,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                      ),
                                                    ],
                                                    const SizedBox(height: 6),
                                                    AnimatedContainer(
                                                      duration: const Duration(
                                                          milliseconds: 180),
                                                      width: 27,
                                                      height: 27,
                                                      decoration: BoxDecoration(
                                                        color: isSelected
                                                            ? yangiLime
                                                            : Colors
                                                                .transparent,
                                                        shape: BoxShape.circle,
                                                        border: Border.all(
                                                          color: isSelected
                                                              ? yangiLime
                                                              : scheme.outline,
                                                          width: 1.6,
                                                        ),
                                                      ),
                                                      child: isSelected
                                                          ? const Icon(
                                                              Icons
                                                                  .check_rounded,
                                                              size: 18,
                                                              color:
                                                                  yangiGraphite,
                                                            )
                                                          : null,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }),

                          const SizedBox(height: 10),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  widget.lang == 'uz' ? 'To‘lov usuli' : 'Способ оплаты',
                                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                                ),
                              ),
                              TextButton(
                                onPressed: () => _showPaymentSheet(canUseCard),
                                child: Text(
                                  widget.lang == 'uz' ? 'O‘zgartirish' : 'Изменить',
                                  style: const TextStyle(color: yangiGreen, fontWeight: FontWeight.w900),
                                ),
                              ),
                            ],
                          ),
                          Material(
                            color: scheme.surfaceContainerLow,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                              side: BorderSide(
                                color: scheme.outlineVariant.withValues(alpha: 0.65),
                              ),
                            ),
                            child: InkWell(
                              onTap: () => _showPaymentSheet(canUseCard),
                              borderRadius: BorderRadius.circular(20),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                                child: Row(
                                  children: <Widget>[
                                    Container(
                                      width: 44,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        gradient: paymentMethod == 'card'
                                            ? const LinearGradient(
                                                colors: <Color>[Color(0xFF07110A), Color(0xFF13A83E)],
                                              )
                                            : null,
                                        color: paymentMethod == 'cash' ? const Color(0xFF65C83C) : null,
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: Icon(
                                        paymentMethod == 'card' ? Icons.credit_card_rounded : Icons.payments_rounded,
                                        color: Colors.white,
                                        size: 22,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: <Widget>[
                                          Text(
                                            paymentMethod == 'card'
                                                ? maskedCardLabel(selectedCard?['maskedPan'])
                                                : (widget.lang == 'uz' ? 'Naqd' : 'Наличные'),
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                          Text(
                                            paymentMethod == 'card'
                                                ? (widget.lang == 'uz'
                                                    ? 'ATMOS orqali xavfsiz to‘lov'
                                                    : 'Безопасная оплата через ATMOS')
                                                : (widget.lang == 'uz'
                                                    ? 'Haydovchiga safardan keyin'
                                                    : 'Оплата водителю после поездки'),
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: scheme.onSurfaceVariant,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      Icons.chevron_right_rounded,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 9),
                          Material(
                            color: scheme.surfaceContainerLow,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                              side: BorderSide(
                                color: scheme.outlineVariant.withValues(alpha: 0.65),
                              ),
                            ),
                            child: InkWell(
                              onTap: _showRideOptionsSheet,
                              borderRadius: BorderRadius.circular(20),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                child: Row(
                                  children: <Widget>[
                                    const Icon(Icons.chat_bubble_outline_rounded, size: 23),
                                    const SizedBox(width: 11),
                                    Expanded(
                                      child: Text(
                                        widget.lang == 'uz'
                                            ? 'Haydovchiga izoh (ixtiyoriy)'
                                            : 'Комментарий для водителя (необязательно)',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                    const Icon(Icons.add_rounded, size: 28),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          ],
                          if (error != null) ...<Widget>[
                            const SizedBox(height: 8),
                            Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                          ],
                        ],
                      ),
                    ),

                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        12,
                        6,
                        12,
                        math.max(10, MediaQuery.of(context).padding.bottom),
                      ),
                      child: SizedBox(
                        height: 62,
                        child: FilledButton(
                          onPressed: busy ||
                                  estimating ||
                                  !routeReadyForOrder ||
                                  !activeTariffAvailable
                              ? null
                              : (destinationOptional && !destinationReady
                                  ? createOrder
                                  : (cost == null
                                      ? () => scheduleEstimate(delay: Duration.zero)
                                      : createOrder)),
                          style: FilledButton.styleFrom(
                            backgroundColor: yangiGraphite,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Color.alphaBlend(
                              Theme.of(context).colorScheme.onSurface.withValues(
                                    alpha: Theme.of(context).brightness == Brightness.dark ? 0.10 : 0.06,
                                  ),
                              Theme.of(context).colorScheme.surfaceContainerHigh,
                            ),
                            disabledForegroundColor: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.74),
                            elevation: 0,
                            shadowColor: yangiLime.withValues(alpha: 0.22),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          ),
                          child: busy
                              ? const SizedBox.square(
                                  dimension: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2.2),
                                )
                              : Row(
                                  children: <Widget>[
                                    Expanded(
                                      flex: 5,
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          orderButtonLabel(),
                                          maxLines: 1,
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: -0.25,
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (selectedPrice != null) ...<Widget>[
                                      Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: <Widget>[
                                          Text(
                                            moneyLabel(selectedPrice),
                                            style: const TextStyle(
                                              color: yangiLime,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                          Text(
                                            '${routeMinutes ?? '—'} мин • ${routeDistanceKm?.toStringAsFixed(1) ?? '—'} км',
                                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(width: 10),
                                      Container(width: 1, height: 34, color: const Color(0x33FFFFFF)),
                                      const SizedBox(width: 10),
                                    ],
                                    const Icon(Icons.arrow_forward_rounded, size: 28, color: yangiLime),
                                  ],
                                ),
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

  Widget _premiumQuickDestination({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(right: 9),
      child: Material(
        color: dark ? const Color(0xFF191D1E) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            width: 128,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: dark ? const Color(0xFF2A3031) : const Color(0x11000000),
              ),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, size: 18, color: scheme.onSurface),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _premiumDestinationRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: dark ? const Color(0xFF191D1E) : Colors.white,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 20),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roundMapButton({
    required IconData icon,
    required VoidCallback? onTap,
    required String tooltip,
    bool large = false,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark
        ? const Color(0xE6111314)
        : Colors.white.withValues(alpha: 0.96);
    return Material(
      color: fill,
      elevation: dark ? 0 : 8,
      shadowColor: const Color(0x26000000),
      shape: CircleBorder(
        side: BorderSide(
          color: dark ? const Color(0xFF303638) : const Color(0x16000000),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: large ? 54 : 46,
            height: large ? 54 : 46,
            child: Icon(
              icon,
              size: large ? 26 : 22,
              color: dark ? Colors.white : yangiGraphite,
            ),
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
    VoidCallback? onClear,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 70,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 14),
          Container(
            width: 17,
            height: 17,
            decoration: BoxDecoration(
              color: pickup ? scheme.surface : yangiGraphite,
              shape: BoxShape.circle,
              border: Border.all(
                color: pickup ? yangiGreen : scheme.onSurface,
                width: 3.5,
              ),
              boxShadow: pickup
                  ? <BoxShadow>[
                      BoxShadow(
                        color: yangiLime.withValues(alpha: 0.28),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.25,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (onClear != null)
            IconButton(
              onPressed: onClear,
              tooltip: widget.lang == 'uz' ? 'Tozalash' : 'Очистить',
              icon: Icon(Icons.close_rounded, size: 20, color: scheme.onSurfaceVariant),
            )
          else
            IconButton(
              onPressed: onTap,
              tooltip: widget.lang == 'uz' ? 'Tahrirlash' : 'Изменить',
              icon: Icon(Icons.edit_rounded, size: 18, color: scheme.onSurfaceVariant),
            ),
          IconButton(
            onPressed: onMapTap,
            tooltip: widget.lang == 'uz' ? 'Xaritada tanlash' : 'Выбрать на карте',
            icon: Icon(Icons.map_outlined, size: 20, color: scheme.onSurface),
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

  Future<void> _showTariffComparisonSheet() async {
    final items = visibleTariffs;
    if (items.isEmpty || !mounted || ModalRoute.of(context)?.isCurrent != true) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return FractionallySizedBox(
          heightFactor: 0.82,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        widget.lang == 'uz' ? 'Tariflarni solishtirish' : 'Сравнение тарифов',
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.45,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 9),
                  itemBuilder: (context, index) {
                    final option = items[index];
                    final key = (option['key'] ?? '').toString();
                    final available = option['available'] == true;
                    final selected = available && key == selectedTariffKey;
                    final price = (option['cost'] as num?)?.toDouble();
                    final title = widget.lang == 'uz'
                        ? (option['nameUz'] ?? option['nameRu'] ?? key).toString()
                        : (option['nameRu'] ?? key).toString();

                    return Opacity(
                      opacity: available ? 1 : 0.55,
                      child: Material(
                        color: selected
                            ? Color.alphaBlend(
                                yangiLime.withValues(alpha: 0.10),
                                scheme.surfaceContainerHigh,
                              )
                            : scheme.surfaceContainerLow,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22),
                          side: BorderSide(
                            color: selected ? yangiLime : scheme.outlineVariant,
                            width: selected ? 2 : 1,
                          ),
                        ),
                        child: InkWell(
                          onTap: available
                              ? () {
                                  selectTariff(key);
                                  Navigator.pop(sheetContext);
                                }
                              : null,
                          borderRadius: BorderRadius.circular(22),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                            child: Row(
                              children: <Widget>[
                                SizedBox(
                                  width: 100,
                                  height: 68,
                                  child: _TariffVehicleArt(
                                    kind: key,
                                    selected: selected,
                                    available: available,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Row(
                                        children: <Widget>[
                                          Expanded(
                                            child: Text(
                                              title,
                                              style: const TextStyle(
                                                fontSize: 17,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                          ),
                                          if (selected)
                                            const Icon(
                                              Icons.check_circle_rounded,
                                              color: yangiLime,
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        tariffDescription(key),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: scheme.onSurfaceVariant,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: <Widget>[
                                          Icon(
                                            Icons.person_rounded,
                                            size: 15,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                          const SizedBox(width: 3),
                                          Text(
                                            tariffPassengers(key).toString(),
                                            style: TextStyle(
                                              color: scheme.onSurfaceVariant,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Icon(
                                            Icons.luggage_rounded,
                                            size: 15,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                          const SizedBox(width: 3),
                                          Text(
                                            tariffBaggage(key).toString(),
                                            style: TextStyle(
                                              color: scheme.onSurfaceVariant,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const Spacer(),
                                          Text(
                                            !available
                                                ? (widget.lang == 'uz' ? 'Mavjud emas' : 'Недоступен')
                                                : price == null
                                                    ? (widget.lang == 'uz' ? 'Hisoblanadi' : 'Рассчитаем')
                                                    : moneyLabel(price),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
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
          ),
        );
      },
    );
  }

  Future<void> _showPaymentSheet(bool canUseCard) async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    await loadCards();
    if (!mounted) return;

    String draftMethod = paymentMethod;
    int draftCardId = selectedCardId;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        final sheetTheme = Theme.of(sheetContext);
        final scheme = sheetTheme.colorScheme;
        final selectedFill = Color.alphaBlend(
          yangiLime.withValues(alpha: sheetTheme.brightness == Brightness.dark ? 0.18 : 0.12),
          scheme.surfaceContainerHigh,
        );

        Widget selectIcon(bool selected) => AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: selected ? yangiLime : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? yangiLime : scheme.outlineVariant,
                  width: 2,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check_rounded, size: 20, color: yangiGraphite)
                  : null,
            );

        return StatefulBuilder(
          builder: (context, setSheetState) => SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              14,
              0,
              14,
              math.max(18, MediaQuery.paddingOf(context).bottom + 10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Center(
                  child: Text(
                    widget.lang == 'uz' ? 'To‘lov usullari' : 'Способы оплаты',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  widget.lang == 'uz' ? 'Kartalar va hisoblar' : 'Карты и счета',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 9),
                Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.65)),
                  ),
                  child: Column(
                    children: <Widget>[
                      ...cards.asMap().entries.map((entry) {
                        final card = entry.value;
                        final id = (card['cardId'] as num?)?.toInt() ?? 0;
                        final selected = draftMethod == 'card' && draftCardId == id;
                        return Column(
                          children: <Widget>[
                            Material(
                              color: selected ? selectedFill : Colors.transparent,
                              borderRadius: BorderRadius.circular(18),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                                leading: Container(
                                  width: 46,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: <Color>[Color(0xFF07110A), Color(0xFF19A94B)],
                                    ),
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                  child: const Icon(Icons.credit_card_rounded, color: Colors.white, size: 23),
                                ),
                                title: Text(
                                  maskedCardLabel(card['maskedPan']),
                                  style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w900),
                                ),
                                subtitle: Text(
                                  widget.lang == 'uz' ? 'ATMOS karta' : 'Карта ATMOS',
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                ),
                                trailing: selectIcon(selected),
                                onTap: () {
                                  setSheetState(() {
                                    draftCardId = id;
                                    draftMethod = 'card';
                                  });
                                },
                              ),
                            ),
                            if (entry.key != cards.length - 1)
                              Divider(height: 1, indent: 14, endIndent: 14, color: scheme.outlineVariant),
                          ],
                        );
                      }),
                      if (cards.isNotEmpty)
                        Divider(height: 1, indent: 14, endIndent: 14, color: scheme.outlineVariant),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                        leading: Container(
                          width: 46,
                          height: 34,
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            border: Border.all(color: scheme.outline),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Icon(Icons.add_rounded, color: scheme.onSurface),
                        ),
                        title: Text(
                          widget.lang == 'uz' ? 'Kartani bog‘lash' : 'Привязать карту',
                          style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w900),
                        ),
                        trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
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
                const SizedBox(height: 15),
                Text(
                  widget.lang == 'uz' ? 'Boshqa to‘lov usullari' : 'Другие способы оплаты',
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 9),
                Material(
                  color: draftMethod == 'cash' ? selectedFill : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(22),
                  child: InkWell(
                    onTap: () => setSheetState(() => draftMethod = 'cash'),
                    borderRadius: BorderRadius.circular(22),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      child: Row(
                        children: <Widget>[
                          Container(
                            width: 46,
                            height: 36,
                            decoration: BoxDecoration(
                              color: const Color(0xFF5DD63F),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.payments_rounded, color: Colors.white, size: 25),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              widget.lang == 'uz' ? 'Naqd' : 'Наличные',
                              style: TextStyle(color: scheme.onSurface, fontSize: 17, fontWeight: FontWeight.w900),
                            ),
                          ),
                          selectIcon(draftMethod == 'cash'),
                        ],
                      ),
                    ),
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
                      backgroundColor: yangiLime,
                      foregroundColor: yangiGraphite,
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
        );
      },
    );
  }

  Future<void> _showRideOptionsSheet() async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
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
  List<Map<String, dynamic>> favoriteAddresses = <Map<String, dynamic>>[];
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
    unawaited(loadFavoriteAddresses());
  }

  Future<void> loadFavoriteAddresses() async {
    final values = await _loadFavoriteAddresses(widget.api);
    if (mounted) setState(() => favoriteAddresses = values);
  }

  void change(String value) {
    if (mounted) setState(() {});
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final empty = c.text.trim().isEmpty;

    Widget quickRow(IconData icon, String title, String subtitle, {VoidCallback? onTap}) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap ?? pickOnMap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Row(
              children: <Widget>[
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: dark ? const Color(0xFF1B1F20) : const Color(0xFFF1F3F3),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 19, color: scheme.onSurface),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10.5),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 8,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .84,
          child: Column(
            children: <Widget>[
              Container(
                width: 42,
                height: 5,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: dark ? const Color(0xFF171A1B) : const Color(0xFFF1F2F3),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: TextField(
                        controller: c,
                        autofocus: true,
                        onChanged: change,
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search_rounded, size: 21),
                          hintText: widget.lang == 'uz' ? 'Qayerga boramiz?' : 'Куда поедем?',
                          border: InputBorder.none,
                          filled: false,
                          contentPadding: const EdgeInsets.symmetric(vertical: 14),
                          suffixIcon: c.text.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () {
                                    c.clear();
                                    change('');
                                    setState(() {});
                                  },
                                  icon: const Icon(Icons.close_rounded, size: 19),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(widget.lang == 'uz' ? 'Bekor' : 'Отмена'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (empty) ...<Widget>[
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                  decoration: BoxDecoration(
                    color: dark ? const Color(0xFF151819) : Colors.white,
                    borderRadius: BorderRadius.circular(17),
                    border: Border.all(
                      color: dark ? const Color(0xFF2A3031) : const Color(0xFFE8EAEA),
                    ),
                  ),
                  child: Column(
                    children: <Widget>[
                      quickRow(
                        Icons.my_location_rounded,
                        widget.lang == 'uz' ? 'Joriy joylashuv' : 'Текущее местоположение',
                        widget.initial?.address ??
                            (widget.lang == 'uz' ? 'GPS bo‘yicha aniqlash' : 'Определить по GPS'),
                        onTap: widget.initial == null
                            ? pickOnMap
                            : () => Navigator.pop(context, widget.initial),
                      ),
                      Divider(height: 1, color: scheme.outlineVariant),
                      quickRow(
                        Icons.map_outlined,
                        widget.lang == 'uz' ? 'Xaritada tanlash' : 'Выбрать на карте',
                        widget.lang == 'uz'
                            ? 'Nuqtani aniq belgilang'
                            : 'Укажите точку прямо на карте',
                        onTap: pickOnMap,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (favoriteAddresses.isNotEmpty) ...<Widget>[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.lang == 'uz' ? 'Sevimli manzillar' : 'Любимые адреса',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...favoriteAddresses.take(5).map((item) {
                    final address = (item['address'] ?? '').toString();
                    final label = (item['name'] ?? '').toString().trim();
                    final lat = double.tryParse((item['lat'] ?? '').toString()) ?? 0;
                    final lon = double.tryParse((item['lon'] ?? '').toString()) ?? 0;
                    return quickRow(
                      Icons.star_rounded,
                      label.isEmpty
                          ? (widget.lang == 'uz' ? 'Sevimli manzil' : 'Любимый адрес')
                          : label,
                      address,
                      onTap: () => Navigator.pop(
                        context,
                        Place(address, lat, lon, isFavorite: true),
                      ),
                    );
                  }),
                  const SizedBox(height: 10),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.lang == 'uz' ? 'Tezkor tanlov' : 'Быстрый выбор',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(height: 6),
                quickRow(
                  Icons.home_rounded,
                  widget.lang == 'uz' ? 'Uy' : 'Дом',
                  widget.lang == 'uz' ? 'Manzilni tanlang' : 'Выберите домашний адрес',
                  onTap: () {
                    c.text = widget.lang == 'uz' ? 'Uy' : 'Дом';
                    change(c.text);
                  },
                ),
                quickRow(
                  Icons.work_rounded,
                  widget.lang == 'uz' ? 'Ish' : 'Работа',
                  widget.lang == 'uz' ? 'Manzilni tanlang' : 'Выберите рабочий адрес',
                  onTap: () {
                    c.text = widget.lang == 'uz' ? 'Ish' : 'Работа';
                    change(c.text);
                  },
                ),
                quickRow(
                  Icons.flight_takeoff_rounded,
                  widget.lang == 'uz' ? 'Toshkent aeroporti' : 'Аэропорт Ташкент',
                  widget.lang == 'uz' ? 'Aeroport bo‘yicha qidirish' : 'Найти аэропорт',
                  onTap: () {
                    c.text = widget.lang == 'uz' ? 'Toshkent aeroporti' : 'Аэропорт Ташкент';
                    change(c.text);
                  },
                ),
              ] else ...<Widget>[
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        error!,
                        style: TextStyle(color: scheme.error, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                Expanded(
                  child: results.isEmpty && !busy
                      ? Center(
                          child: Text(
                            widget.lang == 'uz' ? 'Hech narsa topilmadi' : 'Ничего не найдено',
                            style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
                          ),
                        )
                      : ListView.separated(
                          itemCount: results.length,
                          separatorBuilder: (_, __) => Divider(height: 1, color: scheme.outlineVariant),
                          itemBuilder: (_, index) {
                            final item = results[index];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
                              leading: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: dark ? const Color(0xFF1B1F20) : const Color(0xFFF1F3F3),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.location_on_outlined, size: 19),
                              ),
                              title: Text(
                                item.address,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
                              ),
                              subtitle: Text(
                                'TaxiMaster / Яндекс',
                                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
                              ),
                              trailing: Icon(Icons.north_west_rounded, size: 17, color: scheme.onSurfaceVariant),
                              onTap: () => Navigator.pop(context, item),
                            );
                          },
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

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
    required this.onNewTrip,
    required this.isActive,
  });
  final ApiClient api;
  final String lang;
  final int? orderId;
  final VoidCallback onMenu;
  final VoidCallback onNewTrip;
  final bool isActive;

  @override
  State<RideScreen> createState() => _RideScreenState();
}

class _RideScreenState extends State<RideScreen> {
  Timer? timer;
  Map<String, dynamic>? order;
  ym.Point? driver;
  bool loading = true;
  String? error;
  int? feedbackPromptedOrderId;
  List<ym.Point> roadRoute = <ym.Point>[];
  yd.DrivingRouter? drivingRouter;
  yd.DrivingSession? drivingSession;
  bool routeRequestInFlight = false;
  bool refreshInFlight = false;
  ym.Point? lastRouteStart;
  ym.Point? lastRouteEnd;

  @override
  void initState() {
    super.initState();
    if (yandexMapKitApiKey.isNotEmpty) {
      drivingRouter = yd.DirectionsFactory.instance.createDrivingRouter(
        yd.DrivingRouterType.Combined,
      );
    }
    if (widget.isActive) refresh();
    timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (widget.isActive) refresh();
    });
  }

  @override
  void didUpdateWidget(covariant RideScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.orderId != widget.orderId) {
      setState(() {
        order = null;
        driver = null;
        error = null;
        roadRoute = <ym.Point>[];
        loading = true;
      });
      if (widget.isActive) refresh();
    } else if (!oldWidget.isActive && widget.isActive) {
      refresh();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    drivingSession?.cancel();
    super.dispose();
  }

  double _routeDistanceKm(ym.Point a, ym.Point b) {
    const earthKm = 6371.0;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * earthKm * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
  }

  bool _sameRoadEndpoints(ym.Point start, ym.Point end) {
    final lastStart = lastRouteStart;
    final lastEnd = lastRouteEnd;
    if (lastStart == null || lastEnd == null) return false;
    return _routeDistanceKm(lastStart, start) < 0.08 &&
        _routeDistanceKm(lastEnd, end) < 0.03;
  }

  Future<List<ym.Point>> _requestRoadRoute(
    ym.Point start,
    ym.Point end,
  ) async {
    final router = drivingRouter;
    if (router == null) return <ym.Point>[];
    final completer = Completer<List<ym.Point>>();
    drivingSession?.cancel();
    final listener = yd.DrivingSessionRouteListener(
      onDrivingRoutes: (routes) {
        if (completer.isCompleted) return;
        completer.complete(
          routes.isEmpty ? <ym.Point>[] : routes.first.geometry.points,
        );
      },
      onDrivingRoutesError: (_) {
        if (!completer.isCompleted) completer.complete(<ym.Point>[]);
      },
    );
    drivingSession = router.requestRoutes(
      const yd.DrivingOptions(routesCount: 1),
      const yd.DrivingVehicleOptions(),
      listener,
      points: <ym.RequestPoint>[
        ym.RequestPoint(
          start,
          ym.RequestPointType.Waypoint,
          null,
          null,
          null,
        ),
        ym.RequestPoint(
          end,
          ym.RequestPointType.Waypoint,
          null,
          null,
          null,
        ),
      ],
    );
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        drivingSession?.cancel();
        return <ym.Point>[];
      },
    );
  }

  Future<void> _refreshRoadRoute(
    Map<String, dynamic> state,
    ym.Point? driverPoint,
  ) async {
    if (routeRequestInFlight || !mounted) return;
    final stateKind = (state['state_kind'] ?? '').toString();
    final pickup = point(state['source_lat'], state['source_lon']);
    final destination = point(
      state['destination_lat'],
      state['destination_lon'],
    );

    ym.Point? start;
    ym.Point? end;
    if (stateKind == 'driver_assigned' || stateKind == 'car_at_place') {
      start = driverPoint;
      end = pickup;
    } else if (stateKind == 'client_inside') {
      start = driverPoint ?? pickup;
      end = destination;
    } else if (stateKind == 'new_order') {
      start = pickup;
      end = destination;
    }

    if (start == null || end == null) {
      if (roadRoute.isNotEmpty && mounted) {
        setState(() => roadRoute = <ym.Point>[]);
      }
      return;
    }
    if (roadRoute.length > 1 && _sameRoadEndpoints(start, end)) return;

    routeRequestInFlight = true;
    try {
      final points = await _requestRoadRoute(start, end);
      if (!mounted) return;
      setState(() {
        roadRoute = points.length > 1 ? points : <ym.Point>[];
        lastRouteStart = start;
        lastRouteEnd = end;
      });
    } finally {
      routeRequestInFlight = false;
    }
  }

  Future<void> refresh() async {
    if (!widget.isActive || refreshInFlight) return;
    refreshInFlight = true;
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
      final stateKind = (state['state_kind'] ?? '').toString();
      final resolvedOrderId = (state['order_id'] as num?)?.toInt() ?? id;
      final shouldAskRating =
          stateKind == 'finished' && feedbackPromptedOrderId != resolvedOrderId;
      if (mounted) {
        setState(() {
          order = state;
          driver = d;
          loading = false;
          error = null;
        });
        unawaited(_refreshRoadRoute(state, d));
        if (shouldAskRating && widget.isActive) {
          final driverName = (state['driver_name'] ?? '').toString();
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted || !widget.isActive) return;
            if (ModalRoute.of(context)?.isCurrent != true) return;
            if (feedbackPromptedOrderId == resolvedOrderId) return;
            feedbackPromptedOrderId = resolvedOrderId;
            await showDriverRatingDialog(
              context,
              widget.api,
              widget.lang,
              resolvedOrderId,
              driverName: driverName,
            );
          });
        }
      }
    } catch (e) {
      final message = e.toString().trim();
      final normalized = message.toLowerCase();
      final orderMissing = normalized.contains('order not found') ||
          normalized.contains('заказ не найден') ||
          normalized == 'not found';

      if (mounted) {
        if (orderMissing) {
          setState(() {
            order = <String, dynamic>{
              ...?order,
              'order_id': widget.orderId ?? order?['order_id'] ?? 0,
              'state_kind': 'aborted',
            };
            driver = null;
            roadRoute = <ym.Point>[];
            lastRouteStart = null;
            lastRouteEnd = null;
            loading = false;
            error = null;
          });
        } else {
          setState(() {
            loading = false;
            error = message;
          });
        }
      }
    } finally {
      refreshInFlight = false;
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    if (loading) {
      return const Scaffold(
        body: Center(
          child: SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }

    if (order == null) {
      return Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: <Widget>[
                    _rideCircleButton(
                      icon: Icons.menu_rounded,
                      onTap: widget.onMenu,
                      tooltip: widget.lang == 'uz' ? 'Menyu' : 'Меню',
                    ),
                    const Spacer(),
                    const YangiWordmark(compact: true),
                    const Spacer(),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              const Spacer(),
              Container(
                width: 86,
                height: 86,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.local_taxi_rounded, size: 42, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              Text(
                widget.lang == 'uz' ? 'Faol safar yo‘q' : 'Нет активной поездки',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: -0.5),
              ),
              const SizedBox(height: 7),
              Text(
                widget.lang == 'uz' ? 'Yangi safarni asosiy ekrandan buyurtma qiling' : 'Закажите новую поездку на главном экране',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
              ),
              const Spacer(),
            ],
          ),
        ),
      );
    }

    final o = order!;
    final rawState = (o['state_kind'] ?? '').toString();
    final pickup = point(o['source_lat'], o['source_lon']);
    final destinationPoint = point(o['destination_lat'], o['destination_lon']);
    final center = driver ?? pickup ?? const ym.Point(latitude: defaultLat, longitude: defaultLon);
    final car = <String>[
      o['car_mark']?.toString() ?? '',
      o['car_model']?.toString() ?? '',
    ].where((x) => x.trim().isNotEmpty).join(' ');
    final number = (o['car_number'] ?? '').toString().trim();
    final driverName = (o['driver_name'] ?? '').toString().trim();
    final driverPhone = (o['driver_phone'] ?? o['phone'] ?? '').toString().trim();
    final rating = (o['driver_rating'] ?? o['rating'] ?? '').toString().trim();
    final crewId = int.tryParse((o['crew_id'] ?? '').toString()) ?? 0;
    final hasAssignedCrew =
        crewId > 0 || driver != null || driverName.isNotEmpty;
    final state = ((rawState == 'driver_assigned' || rawState == 'car_at_place') &&
            !hasAssignedCrew)
        ? 'new_order'
        : rawState;
    final tariffKey = (o['tariff_key'] ?? 'start').toString();
    final source = (o['source'] ?? '').toString().trim();
    final destination = (o['destination'] ?? '').toString().trim();
    final cost = o['total_cost'];
    final orderId = (o['order_id'] as num?)?.toInt() ?? widget.orderId ?? 0;

    final searching = state == 'new_order';
    final driverAssigned = state == 'driver_assigned';
    final atPlace = state == 'car_at_place';
    final activeRide = state == 'client_inside';
    final finished = state == 'finished';
    final aborted = state == 'aborted';

    final etaRaw = o['eta_minutes'] ?? o['driver_eta_min'] ?? o['arrival_minutes'];
    final eta = etaRaw == null ? '' : etaRaw.toString();
    final distanceRaw = o['distance_km'] ?? o['driver_distance_km'] ?? o['remaining_distance_km'];
    final distance = distanceRaw == null ? '' : distanceRaw.toString();

    String money(dynamic raw) {
      final value = double.tryParse(raw?.toString() ?? '');
      if (value == null) return '—';
      final plain = value.round().toString();
      final chars = plain.split('').reversed.toList();
      final out = <String>[];
      for (var i = 0; i < chars.length; i++) {
        if (i > 0 && i % 3 == 0) out.add(' ');
        out.add(chars[i]);
      }
      return out.reversed.join() + (widget.lang == 'uz' ? ' so‘m' : ' сум');
    }

    Future<void> callDriver() async {
      if (driverPhone.isEmpty) return;
      await launchUrl(Uri(scheme: 'tel', path: driverPhone));
    }

    Future<void> messageDriver() async {
      if (driverPhone.isEmpty) return;
      await launchUrl(Uri(scheme: 'sms', path: driverPhone));
    }

    Future<void> shareTrip() async {
      final text = <String>[
        'Yangi Taxi',
        if (driverName.isNotEmpty) (widget.lang == 'uz' ? 'Haydovchi: ' : 'Водитель: ') + driverName,
        if (car.isNotEmpty) car + (number.isEmpty ? '' : ' • ' + number),
        if (destination.isNotEmpty) (widget.lang == 'uz' ? 'Manzil: ' : 'Куда: ') + destination,
      ].join('\n');
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.lang == 'uz' ? 'Safar ma’lumoti nusxalandi' : 'Данные поездки скопированы'),
        ),
      );
    }

    String title() {
      if (searching) return widget.lang == 'uz' ? 'Mashina qidiryapmiz…' : 'Ищем машину…';
      if (driverAssigned) return widget.lang == 'uz' ? 'Haydovchi tayinlandi' : 'Водитель назначен';
      if (atPlace) return widget.lang == 'uz' ? 'Mashina yetib keldi' : 'Машина подъехала';
      if (activeRide) return widget.lang == 'uz' ? 'Yo‘lda' : 'В пути';
      if (finished) return widget.lang == 'uz' ? 'Safar tugadi' : 'Поездка завершена';
      if (aborted) return widget.lang == 'uz' ? 'Buyurtma bekor qilindi' : 'Заказ отменен';
      return stateLabel(state);
    }

    String subtitle() {
      if (searching) {
        return widget.lang == 'uz'
            ? 'Odatda yaqin haydovchini topish bir daqiqagacha vaqt oladi'
            : 'Обычно это занимает до 1 минуты';
      }
      if (driverAssigned) {
        return eta.isEmpty
            ? (widget.lang == 'uz' ? 'Mashina siz tomon yo‘lda' : 'Машина уже едет к вам')
            : (widget.lang == 'uz' ? 'Mashina taxminan $eta daqiqada' : 'Машина будет примерно через $eta мин');
      }
      if (atPlace) {
        return widget.lang == 'uz' ? 'Haydovchi sizni kutmoqda' : 'Водитель ожидает вас';
      }
      if (activeRide) {
        final parts = <String>[
          if (eta.isNotEmpty) (widget.lang == 'uz' ? '$eta daq' : '$eta мин'),
          if (distance.isNotEmpty) '$distance км',
        ];
        return parts.isEmpty
            ? (widget.lang == 'uz' ? 'Manzil tomon ketmoqdasiz' : 'Едем к месту назначения')
            : parts.join(' • ');
      }
      if (finished) return widget.lang == 'uz' ? 'Yangi Taxi bilan safaringiz uchun rahmat' : 'Спасибо, что выбрали Yangi Taxi';
      if (aborted) {
        return widget.lang == 'uz'
            ? 'Bu buyurtma endi faol emas'
            : 'Этот заказ больше не активен';
      }
      return widget.lang == 'uz' ? 'Safar faol emas' : 'Поездка больше не активна';
    }

    Widget driverBlock() {
      final initial = driverName.isEmpty ? 'Y' : driverName.characters.first.toUpperCase();
      return Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF171A1B) : const Color(0xFFF5F6F6),
          borderRadius: BorderRadius.circular(21),
        ),
        child: Row(
          children: <Widget>[
            CircleAvatar(
              radius: 27,
              backgroundColor: yangiLime,
              child: Text(
                initial,
                style: const TextStyle(
                  color: yangiGraphite,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    driverName.isEmpty
                        ? (widget.lang == 'uz' ? 'Yangi Taxi haydovchisi' : 'Водитель Yangi Taxi')
                        : driverName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: <Widget>[
                      if (rating.isNotEmpty) ...<Widget>[
                        const Icon(Icons.star_rounded, size: 16, color: Color(0xFFFFB300)),
                        const SizedBox(width: 3),
                        Text(
                          rating,
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                        ),
                      ],
                      if (rating.isNotEmpty && car.isNotEmpty)
                        Text('  •  ', style: TextStyle(color: scheme.onSurfaceVariant)),
                      if (car.isNotEmpty)
                        Flexible(
                          child: Text(
                            car,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11.5),
                          ),
                        ),
                    ],
                  ),
                  if (number.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: dark ? const Color(0xFF242829) : Colors.white,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Text(
                        number,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.5),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(
              width: 112,
              height: 62,
              child: _DriverAssignedVehicleArt(kind: tariffKey),
            ),
          ],
        ),
      );
    }

    Widget actionButton(IconData icon, String label, VoidCallback? onTap, {bool danger = false}) {
      return Expanded(
        child: Material(
          color: danger
              ? scheme.errorContainer.withValues(alpha: 0.72)
              : (dark ? const Color(0xFF171A1B) : const Color(0xFFF5F6F6)),
          borderRadius: BorderRadius.circular(17),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(17),
            child: SizedBox(
              height: 62,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(icon, size: 20, color: danger ? scheme.error : scheme.onSurface),
                  const SizedBox(height: 5),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: danger ? scheme.error : scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    Widget bodyPanel() {
      if (searching) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(title(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -0.7)),
            const SizedBox(height: 6),
            Text(subtitle(), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: const LinearProgressIndicator(
                minHeight: 7,
                backgroundColor: Color(0xFFE9ECEC),
                color: yangiLime,
              ),
            ),
            const SizedBox(height: 17),
            _rideProgressRow(
              active: true,
              label: widget.lang == 'uz' ? 'Eng yaqin haydovchilarni qidiryapmiz' : 'Ищем ближайших водителей',
            ),
            _rideProgressRow(
              active: false,
              label: widget.lang == 'uz' ? 'So‘rov yuborilmoqda' : 'Отправляем запросы',
            ),
            _rideProgressRow(
              active: false,
              label: widget.lang == 'uz' ? 'Javobni kutyapmiz' : 'Ждём ответ',
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: cancel,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              child: Text(widget.lang == 'uz' ? 'Buyurtmani bekor qilish' : 'Отменить заказ'),
            ),
          ],
        );
      }

      if (finished) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: yangiLime.withValues(alpha: 0.20),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_rounded, color: yangiGreen, size: 36),
              ),
            ),
            const SizedBox(height: 13),
            Text(
              title(),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900, letterSpacing: -0.55),
            ),
            const SizedBox(height: 7),
            Text(
              money(cost),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: -0.9),
            ),
            const SizedBox(height: 5),
            Text(
              car.isEmpty ? subtitle() : car + (number.isEmpty ? '' : ' • ' + number),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 17),
            FilledButton.icon(
              onPressed: orderId <= 0
                  ? null
                  : () => showDriverRatingDialog(
                        context,
                        widget.api,
                        widget.lang,
                        orderId,
                        driverName: driverName,
                      ),
              icon: const Icon(Icons.star_rounded),
              label: Text(widget.lang == 'uz' ? 'Haydovchini baholash' : 'Оценить поездку'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF101719),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: widget.onNewTrip,
              icon: const Icon(Icons.arrow_back_rounded),
              label: Text(widget.lang == 'uz' ? 'Yangi safarga qaytish' : 'Назад'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
              ),
            ),
          ],
        );
      }

      if (aborted) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Center(
              child: Text(
                '😔',
                style: TextStyle(fontSize: 48, height: 1),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.70),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.close_rounded, color: scheme.error, size: 34),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.6,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              subtitle(),
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
            ),
            const SizedBox(height: 17),
            FilledButton.icon(
              onPressed: widget.onNewTrip,
              icon: const Icon(Icons.arrow_back_rounded),
              label: Text(widget.lang == 'uz' ? 'Yangi safarga qaytish' : 'Назад к новой поездке'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF101719),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
              ),
            ),
          ],
        );
      }

      if (driverAssigned || atPlace) {
        final foundTitle = atPlace
            ? (widget.lang == 'uz'
                ? 'Mashina yetib keldi'
                : 'Машина подъехала')
            : (widget.lang == 'uz'
                ? 'Haydovchi topildi'
                : 'Водитель найден');
        final foundSubtitle = atPlace
            ? (widget.lang == 'uz'
                ? 'Haydovchi sizni kutmoqda'
                : 'Водитель ожидает вас')
            : (widget.lang == 'uz'
                ? 'Haydovchi siz tomon yo‘l olmoqda'
                : 'Водитель уже едет к вам');

        Widget contactButton(
          IconData icon,
          String label,
          VoidCallback? onTap,
        ) {
          return Material(
            color: dark
                ? const Color(0xFF1A1E1F)
                : const Color(0xFFF4F6F6),
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                width: 70,
                height: 58,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(icon, size: 20),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        foundTitle,
                        style: const TextStyle(
                          fontSize: 24,
                          height: 1,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.65,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        foundSubtitle,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                if (eta.isNotEmpty || distance.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: yangiLime.withValues(alpha: dark ? 0.12 : 0.18),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        if (eta.isNotEmpty)
                          Text(
                            eta +
                                (widget.lang == 'uz'
                                    ? ' daqiqa'
                                    : ' мин'),
                            style: const TextStyle(
                              color: yangiGreen,
                              fontSize: 16,
                              height: 1,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        if (distance.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            distance + ' км',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 17),
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 29,
                  backgroundColor: yangiLime,
                  child: Text(
                    driverName.isEmpty
                        ? 'Y'
                        : driverName.characters.first.toUpperCase(),
                    style: const TextStyle(
                      color: yangiGraphite,
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        driverName.isEmpty
                            ? (widget.lang == 'uz'
                                ? 'Yangi Taxi haydovchisi'
                                : 'Водитель Yangi Taxi')
                            : driverName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: <Widget>[
                          if (rating.isNotEmpty) ...<Widget>[
                            const Icon(
                              Icons.star_rounded,
                              size: 16,
                              color: Color(0xFFFFB300),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              rating,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                          if (car.isNotEmpty) ...<Widget>[
                            if (rating.isNotEmpty)
                              Text(
                                '  •  ',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            Flexible(
                              child: Text(
                                car,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                contactButton(
                  Icons.call_rounded,
                  widget.lang == 'uz' ? 'Qo‘ng‘iroq' : 'Звонок',
                  driverPhone.isEmpty ? null : callDriver,
                ),
                const SizedBox(width: 7),
                contactButton(
                  Icons.chat_bubble_outline_rounded,
                  widget.lang == 'uz' ? 'Xabar' : 'Чат',
                  driverPhone.isEmpty ? null : messageDriver,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: scheme.outlineVariant),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                SizedBox(
                  width: 146,
                  height: 88,
                  child: _DriverAssignedVehicleArt(kind: tariffKey),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        car.isEmpty
                            ? (widget.lang == 'uz'
                                ? 'Yangi Taxi avtomobili'
                                : 'Автомобиль Yangi Taxi')
                            : car,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (number.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: dark
                                ? const Color(0xFF222728)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: scheme.outlineVariant,
                            ),
                          ),
                          child: Text(
                            number,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: cancel,
              icon: const Icon(Icons.close_rounded),
              label: Text(
                widget.lang == 'uz'
                    ? 'Buyurtmani bekor qilish'
                    : 'Отменить заказ',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: dark
                    ? const Color(0xFF3A1518)
                    : const Color(0xFFFFE9EA),
                foregroundColor: const Color(0xFFD71920),
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(17),
                ),
              ),
            ),
          ],
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title(),
                      style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900, letterSpacing: -0.6),
                    ),
                    const SizedBox(height: 5),
                    Text(subtitle(), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
                  ],
                ),
              ),
              if (atPlace)
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF101719), width: 3),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    eta.isEmpty ? '2\nмин' : '$eta\nмин',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, height: 1.0),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (activeRide)
            Container(
              padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF171A1B) : const Color(0xFFF5F6F6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: <Widget>[
                  _rideAddressLine(true, source.isEmpty ? (widget.lang == 'uz' ? 'Jo‘nash nuqtasi' : 'Точка отправления') : source),
                  const SizedBox(height: 9),
                  _rideAddressLine(false, destination.isEmpty ? (widget.lang == 'uz' ? 'Manzil' : 'Место назначения') : destination),
                ],
              ),
            ),
          if (hasAssignedCrew) ...<Widget>[
            driverBlock(),
            const SizedBox(height: 10),
          ],
          Row(
            children: <Widget>[
              actionButton(Icons.call_rounded, widget.lang == 'uz' ? 'Qo‘ng‘iroq' : 'Позвонить', driverPhone.isEmpty ? null : callDriver),
              const SizedBox(width: 8),
              actionButton(Icons.chat_bubble_rounded, widget.lang == 'uz' ? 'Chat' : 'Чат', driverPhone.isEmpty ? null : messageDriver),
              const SizedBox(width: 8),
              if (activeRide)
                actionButton(Icons.shield_rounded, widget.lang == 'uz' ? 'Xavfsizlik' : 'Безопасность', shareTrip)
              else
                actionButton(Icons.close_rounded, widget.lang == 'uz' ? 'Bekor' : 'Отмена', cancel, danger: true),
            ],
          ),
          if (activeRide) ...<Widget>[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: shareTrip,
              icon: const Icon(Icons.ios_share_rounded),
              label: Text(widget.lang == 'uz' ? 'Safarni ulashish' : 'Поделиться поездкой'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ],
        ],
      );
    }

    final showMap = widget.isActive && !finished && !aborted;
    return Scaffold(
      backgroundColor: dark ? const Color(0xFF0C0E0F) : Colors.white,
      body: Stack(
        children: <Widget>[
          if (showMap)
            Positioned.fill(
              bottom: 300,
              child: TaxiYandexMap(
                center: center,
                route: roadRoute,
                from: pickup,
                to: destinationPoint,
                fromLabel: source,
                toLabel: destination,
                fromCaption: widget.lang == 'uz' ? 'Qayerdan' : 'Откуда',
                toCaption: widget.lang == 'uz' ? 'Qayerga' : 'Куда',
                driver: driver,
                vehicleKind: tariffKey,
                zoom: activeRide ? 13.5 : 14.2,
              ),
            ),
          if (showMap)
            Positioned(
              left: 14,
              top: 10,
              child: SafeArea(
                child: _rideCircleButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: widget.onMenu,
                  tooltip: widget.lang == 'uz' ? 'Menyu' : 'Меню',
                ),
              ),
            ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Container(
                width: double.infinity,
                constraints: BoxConstraints(
                  maxWidth: 720,
                  maxHeight: showMap ? MediaQuery.sizeOf(context).height * 0.56 : double.infinity,
                ),
                padding: EdgeInsets.fromLTRB(
                  18,
                  10,
                  18,
                  math.max(18, MediaQuery.paddingOf(context).bottom + 10),
                ),
                decoration: BoxDecoration(
                  color: dark ? const Color(0xFF101314) : Colors.white,
                  borderRadius: showMap
                      ? const BorderRadius.vertical(top: Radius.circular(30))
                      : BorderRadius.zero,
                  boxShadow: showMap
                      ? const <BoxShadow>[
                          BoxShadow(color: Color(0x28000000), blurRadius: 28, offset: Offset(0, -7)),
                        ]
                      : null,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (showMap) ...<Widget>[
                        Center(
                          child: Container(
                            width: 42,
                            height: 4,
                            decoration: BoxDecoration(
                              color: const Color(0xFFD5D9DA),
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (error != null) ...<Widget>[
                        Container(
                          padding: const EdgeInsets.all(10),
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: scheme.errorContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(error!, style: TextStyle(color: scheme.onErrorContainer)),
                        ),
                      ],
                      bodyPanel(),
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

  Widget _rideCircleButton({
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: dark ? const Color(0xED111415) : Colors.white.withValues(alpha: 0.97),
      elevation: dark ? 0 : 7,
      shadowColor: const Color(0x26000000),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, size: 23),
          ),
        ),
      ),
    );
  }

  Widget _rideProgressRow({required bool active, required String label}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: active ? yangiLime : scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Icon(
              active ? Icons.check_rounded : Icons.more_horiz_rounded,
              size: 14,
              color: active ? yangiGraphite : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: active ? scheme.onSurface : scheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rideAddressLine(bool pickup, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            color: pickup ? yangiLime : const Color(0xFF101719),
            shape: BoxShape.circle,
            border: Border.all(
              color: pickup ? yangiGreen : const Color(0xFF101719),
              width: 2,
            ),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
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
  final selectedTags = <String>{};
  final comment = TextEditingController();

  String ratingText(int value) {
    if (lang == 'uz') {
      return switch (value) {
        1 => 'Yaxshi emas',
        2 => 'Qoniqarsiz',
        3 => 'Yaxshi',
        4 => 'Juda yaxshi',
        _ => 'A’lo',
      };
    }
    return switch (value) {
      1 => 'Не понравилось',
      2 => 'Можно лучше',
      3 => 'Хорошо',
      4 => 'Очень хорошо',
      _ => 'Отлично',
    };
  }

  final tags = <MapEntry<String, String>>[
    MapEntry<String, String>('clean', lang == 'uz' ? 'Toza' : 'Чисто'),
    MapEntry<String, String>('polite', lang == 'uz' ? 'Xushmuomala' : 'Вежливо'),
    MapEntry<String, String>('safe', lang == 'uz' ? 'Xavfsiz' : 'Безопасно'),
    MapEntry<String, String>('comfortable', lang == 'uz' ? 'Qulay' : 'Комфортно'),
  ];

  final submit = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) {
        final scheme = Theme.of(context).colorScheme;
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: Container(
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF101314) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 42,
                    height: 5,
                    decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: 62,
                    height: 62,
                    decoration: BoxDecoration(
                      color: yangiLime.withValues(alpha: 0.20),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check_rounded, size: 34, color: yangiGreen),
                  ),
                  const SizedBox(height: 13),
                  Text(
                    lang == 'uz' ? 'Safarni baholang' : 'Оцените поездку',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.55,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    driverName.trim().isEmpty
                        ? (lang == 'uz'
                            ? 'Fikringiz Yangi Taxi xizmatini yaxshilaydi'
                            : 'Ваш отзыв помогает улучшать Yangi Taxi')
                        : (lang == 'uz'
                            ? driverName.trim() + ' bilan safar'
                            : 'Поездка с ' + driverName.trim()),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
                  ),
                  const SizedBox(height: 17),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List<Widget>.generate(
                      5,
                      (index) => IconButton(
                        onPressed: () => setSheetState(() => rating = index + 1),
                        iconSize: 38,
                        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                        icon: Icon(
                          index < rating ? Icons.star_rounded : Icons.star_outline_rounded,
                          color: index < rating ? const Color(0xFFFFB300) : scheme.outline,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    ratingText(rating),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 17),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: tags.map((tag) {
                        final selected = selectedTags.contains(tag.key);
                        return ChoiceChip(
                          selected: selected,
                          showCheckmark: false,
                          selectedColor: yangiLime,
                          label: Text(
                            tag.value,
                            style: TextStyle(
                              color: selected ? yangiGraphite : scheme.onSurface,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          onSelected: (_) => setSheetState(() {
                            if (selected) {
                              selectedTags.remove(tag.key);
                            } else {
                              selectedTags.add(tag.key);
                            }
                          }),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: comment,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: lang == 'uz'
                          ? 'Izoh yozing (ixtiyoriy)'
                          : 'Напишите отзыв (необязательно)',
                    ),
                  ),
                  const SizedBox(height: 15),
                  FilledButton(
                    onPressed: () => Navigator.pop(sheetContext, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF101719),
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(54),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
                    ),
                    child: Text(lang == 'uz' ? 'Tayyor' : 'Готово'),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext, false),
                    child: Text(lang == 'uz' ? 'Keyinroq' : 'Позже'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  if (submit != true) {
    comment.dispose();
    return;
  }

  try {
    await api.post('/api/orders/' + orderId.toString() + '/rating', <String, dynamic>{
      'rating': rating,
      'tags': selectedTags.toList(),
      'comment': comment.text.trim(),
    });
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(lang == 'uz' ? 'Bahoyingiz yuborildi' : 'Спасибо! Оценка отправлена'),
        ),
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
  String filter = 'finished';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final data = await widget.api.get('/api/orders/history');
      if (mounted) {
        setState(() {
          orders = data as List;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  String historyState(Map<dynamic, dynamic> raw) {
    final value =
        raw['state_kind'] ??
        raw['state_type'] ??
        raw['state'] ??
        raw['status'] ??
        '';
    final state = value.toString().trim().toLowerCase();
    if (state.contains('finish') ||
        state.contains('complet') ||
        state == 'done') {
      return 'finished';
    }
    if (state.contains('abort') ||
        state.contains('cancel')) {
      return 'aborted';
    }
    return state;
  }

  String stateTitle(String state) {
    if (state == 'finished') return widget.lang == 'uz' ? 'Tugallangan' : 'Завершена';
    if (state == 'aborted') return widget.lang == 'uz' ? 'Bekor qilingan' : 'Отменена';
    if (state == 'client_inside') return widget.lang == 'uz' ? 'Yo‘lda' : 'В пути';
    if (state == 'car_at_place') return widget.lang == 'uz' ? 'Mashina keldi' : 'Машина приехала';
    if (state == 'driver_assigned') return widget.lang == 'uz' ? 'Haydovchi tayinlandi' : 'Водитель назначен';
    return widget.lang == 'uz' ? 'Buyurtma' : 'Заказ';
  }

  IconData stateIcon(String state) {
    if (state == 'finished') return Icons.check_rounded;
    if (state == 'aborted') return Icons.close_rounded;
    if (state == 'client_inside') return Icons.navigation_rounded;
    if (state == 'car_at_place') return Icons.location_on_rounded;
    return Icons.local_taxi_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    final filtered = orders.where((raw) {
      if (raw is! Map) return false;
      final state = historyState(raw);
      if (filter == 'finished') return state == 'finished';
      if (filter == 'aborted') return state == 'aborted';
      return true;
    }).toList();

    String money(dynamic raw) {
      final value = double.tryParse(raw?.toString() ?? '');
      if (value == null) return '—';
      final plain = value.round().toString();
      final chars = plain.split('').reversed.toList();
      final out = <String>[];
      for (var i = 0; i < chars.length; i++) {
        if (i > 0 && i % 3 == 0) out.add(' ');
        out.add(chars[i]);
      }
      return out.reversed.join() + (widget.lang == 'uz' ? ' so‘m' : ' сум');
    }

    Widget filterButton(String key, String label) {
      final selected = filter == key;
      return Expanded(
        child: Material(
          color: selected
              ? (dark ? const Color(0xFFF2F4F4) : const Color(0xFF101719))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          child: InkWell(
            onTap: () => setState(() => filter = key),
            borderRadius: BorderRadius.circular(11),
            child: SizedBox(
              height: 38,
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? (dark ? yangiGraphite : Colors.white)
                        : scheme.onSurfaceVariant,
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: dark ? const Color(0xFF0B0D0E) : Colors.white,
      appBar: AppBar(
        backgroundColor: dark ? const Color(0xFF0B0D0E) : Colors.white,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          onPressed: widget.onMenu,
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        ),
        centerTitle: true,
        title: Text(
          widget.lang == 'uz' ? 'Mening safarlarim' : 'Мои поездки',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        actions: <Widget>[
          IconButton(onPressed: load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.3))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: RefreshIndicator(
                  onRefresh: load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(15, 8, 15, 30),
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: dark ? const Color(0xFF181B1C) : const Color(0xFFF1F2F3),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: <Widget>[
                            filterButton('finished', widget.lang == 'uz' ? 'Tugallangan' : 'Завершённые'),
                            filterButton('aborted', widget.lang == 'uz' ? 'Bekor' : 'Отменённые'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 17),
                      if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 70),
                          child: Column(
                            children: <Widget>[
                              Icon(Icons.route_rounded, size: 54, color: scheme.outline),
                              const SizedBox(height: 13),
                              Text(
                                widget.lang == 'uz' ? 'Safarlar topilmadi' : 'Поездок не найдено',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                              ),
                            ],
                          ),
                        )
                      else
                        ...filtered.map((raw) {
                          final o = Map<String, dynamic>.from(raw as Map);
                          final state = historyState(o);
                          final tariffKey = (o['tariff_key'] ?? 'start').toString();
                          final source = (o['source'] ?? '').toString().trim();
                          final destination = (o['destination'] ?? '').toString().trim();
                          final total = o['total_cost'];
                          final orderId = (o['order_id'] as num?)?.toInt() ?? 0;
                          final finished = state == 'finished';

                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.fromLTRB(13, 12, 10, 12),
                            decoration: BoxDecoration(
                              color: dark ? const Color(0xFF151819) : Colors.white,
                              borderRadius: BorderRadius.circular(19),
                              border: Border.all(
                                color: dark ? const Color(0xFF2A3031) : const Color(0xFFE8EAEA),
                              ),
                            ),
                            child: Row(
                              children: <Widget>[
                                SizedBox(
                                  width: 72,
                                  height: 52,
                                  child: _TariffVehicleArt(
                                    kind: tariffKey,
                                    selected: false,
                                    available: true,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        source.isEmpty
                                            ? (widget.lang == 'uz' ? 'Jo‘nash nuqtasi' : 'Точка отправления')
                                            : source,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        destination.isEmpty
                                            ? (widget.lang == 'uz' ? 'Manzil ko‘rsatilmagan' : 'Без конечного адреса')
                                            : destination,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: scheme.onSurfaceVariant,
                                          fontSize: 10.5,
                                        ),
                                      ),
                                      const SizedBox(height: 7),
                                      Row(
                                        children: <Widget>[
                                          Text(
                                            money(total),
                                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w900),
                                          ),
                                          const SizedBox(width: 8),
                                          Icon(
                                            finished ? Icons.star_rounded : stateIcon(state),
                                            size: 15,
                                            color: finished ? const Color(0xFFFFB300) : scheme.onSurfaceVariant,
                                          ),
                                          const SizedBox(width: 3),
                                          Text(
                                            finished ? '5.0' : stateTitle(state),
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: scheme.onSurfaceVariant,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: finished && orderId > 0
                                      ? () => showDriverRatingDialog(
                                            context,
                                            widget.api,
                                            widget.lang,
                                            orderId,
                                            driverName: (o['driver_name'] ?? '').toString(),
                                          )
                                      : null,
                                  icon: const Icon(Icons.chevron_right_rounded),
                                ),
                              ],
                            ),
                          );
                        }),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class CardsScreen extends StatefulWidget {
  const CardsScreen({
    super.key,
    required this.api,
    required this.lang,
    this.onMenu,
    this.onDone,
    this.initialPaymentMethod,
    this.initialCardId,
    this.onPaymentChanged,
  });
  final ApiClient api;
  final String lang;
  final VoidCallback? onMenu;
  final VoidCallback? onDone;
  final String? initialPaymentMethod;
  final int? initialCardId;
  final void Function(String method, int cardId)? onPaymentChanged;

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  bool loading = true;
  bool cardBindingAvailable = false;
  List<Map<String, dynamic>> cards = <Map<String, dynamic>>[];
  int defaultCardId = 0;
  String selectedMethod = 'cash';
  int selectedPaymentCardId = 0;
  bool selectionInitialized = false;
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
          if (!selectionInitialized) {
            final initialId = widget.initialCardId ?? 0;
            selectedPaymentCardId = list.any((card) => (card['cardId'] as num?)?.toInt() == initialId)
                ? initialId
                : defaultCardId;
            selectedMethod = widget.initialPaymentMethod == 'card' && selectedPaymentCardId > 0
                ? 'card'
                : (widget.initialPaymentMethod == 'cash'
                    ? 'cash'
                    : (selectedPaymentCardId > 0 ? 'card' : 'cash'));
            selectionInitialized = true;
          } else if (!list.any((card) => (card['cardId'] as num?)?.toInt() == selectedPaymentCardId)) {
            selectedPaymentCardId = defaultCardId;
            if (selectedPaymentCardId <= 0) selectedMethod = 'cash';
          }
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
    if (mounted) {
      setState(() {
        selectedMethod = 'card';
        selectedPaymentCardId = id;
      });
    }
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectedFill = Color.alphaBlend(
      yangiLime.withValues(alpha: theme.brightness == Brightness.dark ? 0.18 : 0.12),
      scheme.surfaceContainerHigh,
    );

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        leading: widget.onMenu == null
            ? null
            : IconButton(onPressed: widget.onMenu, icon: const Icon(Icons.menu_rounded)),
        centerTitle: true,
        title: Text(
          widget.lang == 'uz' ? 'To‘lov usullari' : 'Способы оплаты',
          style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w900),
        ),
        actions: <Widget>[IconButton(onPressed: load, icon: const Icon(Icons.refresh_rounded))],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 30),
              children: <Widget>[
                Text(
                  widget.lang == 'uz' ? 'Kartalar va hisoblar' : 'Карты и счета',
                  style: TextStyle(color: scheme.onSurface, fontSize: 22, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.65)),
                  ),
                  child: Column(
                    children: <Widget>[
                      ...cards.asMap().entries.map((entry) {
                        final card = entry.value;
                        final id = (card['cardId'] as num?)?.toInt() ?? 0;
                        final isSelected = selectedMethod == 'card' && id == selectedPaymentCardId;
                        final isDefault = id == defaultCardId || card['isDefault'] == true;
                        final masked = maskedCardLabel(card['maskedPan']);
                        return Column(
                          children: <Widget>[
                            Material(
                              color: isSelected ? selectedFill : Colors.transparent,
                              borderRadius: BorderRadius.circular(18),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                                leading: Container(
                                  width: 46,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: <Color>[Color(0xFF07110A), Color(0xFF19A94B)],
                                    ),
                                    borderRadius: BorderRadius.circular(9),
                                  ),
                                  child: const Icon(Icons.credit_card_rounded, color: Colors.white, size: 23),
                                ),
                                title: Text(
                                  masked,
                                  style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w900),
                                ),
                                subtitle: Text(
                                  isDefault
                                      ? (widget.lang == 'uz' ? 'Asosiy karta' : 'Основная карта')
                                      : (widget.lang == 'uz' ? 'Saqlangan karta' : 'Сохранённая карта'),
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                ),
                                trailing: Icon(
                                  isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                  color: isSelected ? yangiLime : scheme.outline,
                                  size: 30,
                                ),
                                onTap: () => makeDefault(id),
                                onLongPress: () => removeCard(id),
                              ),
                            ),
                            if (entry.key != cards.length - 1)
                              Divider(height: 1, indent: 16, endIndent: 16, color: scheme.outlineVariant),
                          ],
                        );
                      }),
                      if (cards.isNotEmpty)
                        Divider(height: 1, indent: 16, endIndent: 16, color: scheme.outlineVariant),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                        leading: Container(
                          width: 46,
                          height: 34,
                          decoration: BoxDecoration(
                            color: scheme.surface,
                            border: Border.all(color: scheme.outline),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Icon(Icons.add_rounded, color: scheme.onSurface),
                        ),
                        title: Text(
                          widget.lang == 'uz' ? 'Kartani bog‘lash' : 'Привязать карту',
                          style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w900),
                        ),
                        subtitle: Text(
                          cardBindingAvailable
                              ? (widget.lang == 'uz'
                                  ? 'ATMOS orqali xavfsiz tokenlash'
                                  : 'Безопасная токенизация через ATMOS')
                              : (widget.lang == 'uz'
                                  ? 'ATMOS karta bog‘lash hozir mavjud emas'
                                  : 'Привязка карты ATMOS сейчас недоступна'),
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        trailing: Icon(
                          cardBindingAvailable ? Icons.chevron_right_rounded : Icons.lock_outline_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                        onTap: cardBindingAvailable ? addCard : null,
                      ),
                    ],
                  ),
                ),
                if (error != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(error!, style: TextStyle(color: scheme.error)),
                ],
                const SizedBox(height: 16),
                Text(
                  widget.lang == 'uz' ? 'Boshqa to‘lov usullari' : 'Другие способы оплаты',
                  style: TextStyle(color: scheme.onSurface, fontSize: 22, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: selectedMethod == 'cash' ? selectedFill : scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.65)),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    leading: Container(
                      width: 46,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF5DD63F),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.payments_rounded, color: Colors.white, size: 25),
                    ),
                    title: Text(
                      widget.lang == 'uz' ? 'Naqd' : 'Наличные',
                      style: TextStyle(color: scheme.onSurface, fontSize: 17, fontWeight: FontWeight.w900),
                    ),
                    subtitle: Text(
                      widget.lang == 'uz' ? 'Barcha safarlarda mavjud' : 'Доступно для всех поездок',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    trailing: Icon(
                      selectedMethod == 'cash'
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: selectedMethod == 'cash' ? yangiLime : scheme.outline,
                      size: 30,
                    ),
                    onTap: () => setState(() => selectedMethod = 'cash'),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: () {
                      widget.onPaymentChanged?.call(selectedMethod, selectedPaymentCardId);
                      if (widget.onDone != null) {
                        widget.onDone!();
                      } else {
                        Navigator.maybePop(context);
                      }
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: yangiLime,
                      foregroundColor: yangiGraphite,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    child: Text(
                      widget.lang == 'uz' ? 'Tayyor' : 'Готово',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  widget.lang == 'uz'
                      ? 'Kartalar ATMOS orqali tokenlashtiriladi. Yangi Taxi PAN va CVV ni saqlamaydi.'
                      : 'Карты токенизируются через ATMOS. Yangi Taxi не хранит PAN и CVV.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
    );
  }
}


class FavoriteAddressesScreen extends StatefulWidget {
  const FavoriteAddressesScreen({
    super.key,
    required this.api,
    required this.lang,
  });

  final ApiClient api;
  final String lang;

  @override
  State<FavoriteAddressesScreen> createState() => _FavoriteAddressesScreenState();
}

class _FavoriteAddressesScreenState extends State<FavoriteAddressesScreen> {
  List<Map<String, dynamic>> values = <Map<String, dynamic>>[];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final loaded = await _loadFavoriteAddresses(widget.api);
      if (mounted) {
        setState(() {
          values = loaded;
          loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> addFavorite() async {
    final place = await showModalBottomSheet<Place>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddressSheet(
        api: widget.api,
        lang: widget.lang,
        title: widget.lang == 'uz' ? 'Sevimli manzil' : 'Любимый адрес',
      ),
    );
    if (place == null || !mounted) return;

    final controller = TextEditingController(
      text: values.isEmpty
          ? (widget.lang == 'uz' ? 'Uy' : 'Дом')
          : values.length == 1
              ? (widget.lang == 'uz' ? 'Ish' : 'Работа')
              : (widget.lang == 'uz' ? 'Sevimli joy' : 'Любимое место'),
    );
    final label = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(widget.lang == 'uz' ? 'Manzil nomi' : 'Название адреса'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: widget.lang == 'uz' ? 'Masalan: Uy' : 'Например: Дом',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(widget.lang == 'uz' ? 'Bekor' : 'Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(widget.lang == 'uz' ? 'Saqlash' : 'Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (label == null || label.trim().isEmpty || !mounted) return;

    final next = <Map<String, dynamic>>[
      ...values.where((item) =>
          (item['address'] ?? '').toString().trim().toLowerCase() !=
          place.address.trim().toLowerCase()),
      <String, dynamic>{
        'name': label.trim(),
        'address': place.address,
        'lat': place.lat,
        'lon': place.lon,
      },
    ];
    try {
      final saved = await _saveFavoriteAddresses(widget.api, next);
      if (mounted) setState(() => values = saved);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
  }

  Future<void> removeFavorite(int index) async {
    final next = <Map<String, dynamic>>[...values]..removeAt(index);
    try {
      final saved = await _saveFavoriteAddresses(widget.api, next);
      if (mounted) setState(() => values = saved);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        ),
        title: Text(widget.lang == 'uz' ? 'Sevimli manzillar' : 'Любимые адреса'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: addFavorite,
        icon: const Icon(Icons.add_location_alt_rounded),
        label: Text(widget.lang == 'uz' ? 'Qo‘shish' : 'Добавить'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.3))
          : values.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.star_outline_rounded, size: 58, color: scheme.outline),
                        const SizedBox(height: 12),
                        Text(
                          widget.lang == 'uz'
                              ? 'Hali sevimli manzillar yo‘q'
                              : 'Любимых адресов пока нет',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          widget.lang == 'uz'
                              ? 'Manzil qo‘shing — u buyurtma berishda tezkor tanlovda ko‘rinadi.'
                              : 'Добавьте адрес — он появится в быстром выборе при заказе.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 100),
                  itemCount: values.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, index) {
                    final item = values[index];
                    return Card(
                      elevation: 0,
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: yangiLime,
                          child: Icon(Icons.star_rounded, color: yangiGraphite),
                        ),
                        title: Text(
                          (item['name'] ?? '').toString(),
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        subtitle: Text(
                          (item['address'] ?? '').toString(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: widget.lang == 'uz' ? 'O‘chirish' : 'Удалить',
                          onPressed: () => removeFavorite(index),
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class PromoCodesScreen extends StatefulWidget {
  const PromoCodesScreen({
    super.key,
    required this.api,
    required this.lang,
  });

  final ApiClient api;
  final String lang;

  @override
  State<PromoCodesScreen> createState() => _PromoCodesScreenState();
}

class _PromoCodesScreenState extends State<PromoCodesScreen> {
  final controller = TextEditingController();
  bool loading = true;
  bool saving = false;
  String activeCode = '';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final value = await _loadSavedPromoCode(widget.api);
    controller.text = value;
    if (mounted) {
      setState(() {
        activeCode = value;
        loading = false;
      });
    }
  }

  Future<void> save() async {
    final value = controller.text.trim().toUpperCase();
    setState(() => saving = true);
    try {
      await _savePromoCode(widget.api, value);
      if (!mounted) return;
      controller.text = value;
      setState(() => activeCode = value);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value.isEmpty
                ? (widget.lang == 'uz' ? 'Promokod olib tashlandi' : 'Промокод удалён')
                : (widget.lang == 'uz' ? 'Promokod saqlandi' : 'Промокод сохранён'),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        ),
        title: Text(widget.lang == 'uz' ? 'Promokodlar' : 'Промокоды'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.3))
          : ListView(
              padding: const EdgeInsets.all(18),
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        widget.lang == 'uz' ? 'Promokodni kiriting' : 'Введите промокод',
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        widget.lang == 'uz'
                            ? 'Katta-kichik harflar muhim. Kod aynan berilgan ko‘rinishda kiritilishi kerak.'
                            : 'Регистр символов важен. Вводите код точно в том виде, в котором он выдан.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: controller,
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.local_offer_outlined),
                          hintText: 'PROMO2026',
                          suffixIcon: controller.text.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () => setState(controller.clear),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: saving ? null : save,
                        child: Text(
                          saving
                              ? (widget.lang == 'uz' ? 'Saqlanmoqda…' : 'Сохраняем…')
                              : (widget.lang == 'uz' ? 'Saqlash' : 'Сохранить'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (activeCode.isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      backgroundColor: yangiLime,
                      child: Icon(Icons.check_rounded, color: yangiGraphite),
                    ),
                    title: Text(
                      activeCode,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    subtitle: Text(
                      widget.lang == 'uz'
                          ? 'Yangi Taxi serverida saqlangan'
                          : 'Сохранён на сервере Yangi Taxi',
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  widget.lang == 'uz'
                      ? 'Kod saqlanadi, lekin TaxiMaster chegirmasi hozircha qo‘llanmaydi.'
                      : 'Код сохраняется, но скидка TaxiMaster пока не применяется.',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
    );
  }
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
    this.backButton = false,
  });

  final ApiClient api;
  final String lang;
  final String themeSetting;
  final ValueChanged<String> onLang;
  final Future<void> Function(String) onTheme;
  final Future<void> Function(String) onBackend;
  final VoidCallback onMenu;
  final bool backButton;

  Future<void> locationSettings() async {
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
    } else {
      await Geolocator.openLocationSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    Widget sectionTitle(String text) {
      return Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.8,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    Widget leadingIcon(IconData icon) {
      return Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: yangiLime.withValues(alpha: dark ? 0.14 : 0.22),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          icon,
          size: 21,
          color: dark ? yangiLime : yangiGraphite,
        ),
      );
    }

    Widget premiumCard(Widget child) {
      return Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.65),
          ),
        ),
        child: child,
      );
    }

    Widget themeChip(String value, IconData icon, String label) {
      final selected = themeSetting == value;
      return ChoiceChip(
        selected: selected,
        showCheckmark: false,
        avatar: Icon(
          icon,
          size: 17,
          color: selected
              ? yangiGraphite
              : scheme.onSurfaceVariant,
        ),
        label: Text(
          label,
          style: TextStyle(
            color: selected ? yangiGraphite : scheme.onSurface,
            fontWeight: FontWeight.w800,
          ),
        ),
        selectedColor: yangiLime,
        backgroundColor: scheme.surfaceContainerHigh,
        side: BorderSide(
          color: selected
              ? yangiLime
              : scheme.outlineVariant.withValues(alpha: 0.8),
        ),
        onSelected: (_) => onTheme(value),
      );
    }

    Widget languageChip(String value, String label) {
      final selected = lang == value;
      return ChoiceChip(
        selected: selected,
        showCheckmark: false,
        label: Text(
          label,
          style: TextStyle(
            color: selected ? yangiGraphite : scheme.onSurface,
            fontWeight: FontWeight.w900,
          ),
        ),
        selectedColor: yangiLime,
        backgroundColor: scheme.surfaceContainerHigh,
        side: BorderSide(
          color: selected
              ? yangiLime
              : scheme.outlineVariant.withValues(alpha: 0.8),
        ),
        onSelected: (_) => onLang(value),
      );
    }

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          onPressed: onMenu,
          icon: Icon(backButton ? Icons.arrow_back_ios_new_rounded : Icons.menu_rounded),
        ),
        centerTitle: true,
        title: const YangiWordmark(compact: true),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final horizontal = constraints.maxWidth >= 720 ? 24.0 : 14.0;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 30),
                children: <Widget>[
                  Text(
                    lang == 'uz' ? 'Sozlamalar' : 'Настройки',
                    style: const TextStyle(
                      fontSize: 28,
                      height: 1.0,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    lang == 'uz'
                        ? 'Ilovani o‘zingizga moslang'
                        : 'Настройте приложение под себя',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 20),

                  sectionTitle(lang == 'uz' ? 'ILOVA' : 'ПРИЛОЖЕНИЕ'),
                  premiumCard(
                    Column(
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              leadingIcon(Icons.language_rounded),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      lang == 'uz' ? 'Ilova tili' : 'Язык приложения',
                                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      lang == 'uz'
                                          ? 'Ruscha yoki o‘zbekcha interfeys'
                                          : 'Русский или узбекский интерфейс',
                                      style: TextStyle(
                                        color: scheme.onSurfaceVariant,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: <Widget>[
                                        languageChip('ru', 'RU'),
                                        languageChip('uz', 'UZ'),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, indent: 14, endIndent: 14, color: scheme.outlineVariant),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              leadingIcon(Icons.brightness_6_rounded),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      lang == 'uz' ? 'Mavzu' : 'Тема',
                                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      lang == 'uz'
                                          ? 'Tizim, yorug‘ yoki qorong‘i'
                                          : 'Системная, светлая или тёмная',
                                      style: TextStyle(
                                        color: scheme.onSurfaceVariant,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: <Widget>[
                                        themeChip(
                                          'system',
                                          Icons.phone_android_rounded,
                                          lang == 'uz' ? 'Tizim' : 'Система',
                                        ),
                                        themeChip(
                                          'light',
                                          Icons.light_mode_rounded,
                                          lang == 'uz' ? 'Yorug‘' : 'Светлая',
                                        ),
                                        themeChip(
                                          'dark',
                                          Icons.dark_mode_rounded,
                                          lang == 'uz' ? 'Qorong‘i' : 'Тёмная',
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1, indent: 14, endIndent: 14, color: scheme.outlineVariant),
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          leading: leadingIcon(Icons.my_location_rounded),
                          title: Text(
                            lang == 'uz' ? 'Geolokatsiya' : 'Геолокация',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          subtitle: Text(
                            lang == 'uz'
                                ? 'Ruxsat va GPS sozlamalari'
                                : 'Разрешения и настройки GPS',
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: locationSettings,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  sectionTitle(lang == 'uz' ? 'XIZMAT' : 'СЕРВИС'),
                  premiumCard(
                    Column(
                      children: <Widget>[
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          leading: leadingIcon(Icons.support_agent_rounded),
                          title: Text(
                            lang == 'uz' ? 'Yordam' : 'Поддержка',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          subtitle: Text(
                            lang == 'uz'
                                ? 'Yangi Taxi yordam markazi'
                                : 'Центр поддержки Yangi Taxi',
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                        ),
                        Divider(height: 1, indent: 14, endIndent: 14, color: scheme.outlineVariant),
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          leading: leadingIcon(Icons.info_outline_rounded),
                          title: Text(
                            lang == 'uz' ? 'Ilova haqida' : 'О приложении',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          subtitle: const Text('Yangi Taxi 1.9.4'),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                            decoration: BoxDecoration(
                              color: yangiLime.withValues(alpha: dark ? 0.14 : 0.20),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'v1.9.4',
                              style: TextStyle(
                                color: dark ? yangiLime : yangiGraphite,
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),
                  sectionTitle(lang == 'uz' ? 'DIAGNOSTIKA' : 'ДИАГНОСТИКА'),
                  premiumCard(
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      leading: leadingIcon(api.isDemo ? Icons.science_outlined : Icons.dns_outlined),
                      title: const Text('Backend', style: TextStyle(fontWeight: FontWeight.w900)),
                      subtitle: Text(
                        api.baseUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => backendDialog(context, api, onBackend),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.api,
    required this.lang,
    required this.onLang,
    required this.themeSetting,
    required this.onTheme,
    required this.onBackend,
    required this.onLogout,
    this.onMenu,
  });
  final ApiClient api;
  final String lang;
  final ValueChanged<String> onLang;
  final String themeSetting;
  final Future<void> Function(String) onTheme;
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

  double get bonusBalance {
    final raw = me?['bonus_balance'] ??
        me?['bonusBalance'] ??
        me?['bonus_sum'] ??
        me?['bonusSum'] ??
        me?['bonuses'] ??
        0;
    return double.tryParse(raw.toString().replaceAll(',', '.')) ?? 0;
  }

  String bonusBalanceLabel() {
    final rounded = bonusBalance.round().toString();
    final chars = rounded.split('').reversed.toList();
    final out = <String>[];
    for (var i = 0; i < chars.length; i++) {
      if (i > 0 && i % 3 == 0) out.add(' ');
      out.add(chars[i]);
    }
    return out.reversed.join() + (widget.lang == 'uz' ? ' bonus' : ' бонусов');
  }

  double? get clientRating {
    final raw = me?['client_rating'] ??
        me?['clientRating'] ??
        me?['rating_value'] ??
        me?['rating'];
    final value = raw == null ? null : double.tryParse(raw.toString());
    return value != null && value > 0 && value <= 5 ? value : null;
  }

  int? get clientRatingCount {
    final raw = me?['client_rating_count'] ??
        me?['clientRatingCount'] ??
        me?['rating_count'] ??
        me?['ratings_count'];
    return raw == null ? null : int.tryParse(raw.toString());
  }

  Uint8List? get clientPhotoBytes {
    var raw = (me?['client_photo'] ?? '').toString().trim();
    if (raw.isEmpty) return null;
    raw = raw.replaceFirst(RegExp(r'^data:image/[^;]+;base64,'), '');
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> chooseProfilePhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: Text(widget.lang == 'uz' ? 'Galereyadan tanlash' : 'Выбрать из галереи'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: Text(widget.lang == 'uz' ? 'Kamera bilan olish' : 'Сделать фото'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1000,
        maxHeight: 1000,
        imageQuality: 82,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.length > 3 * 1024 * 1024) {
        throw ApiException(
          widget.lang == 'uz'
              ? 'Rasm hajmi 3 MB dan kichik bo‘lishi kerak'
              : 'Фото должно быть меньше 3 МБ',
        );
      }
      final encoded = base64Encode(bytes);
      await widget.api.post('/api/profile/photo', <String, dynamic>{
        'photoBase64': encoded,
      });
      if (!mounted) return;
      setState(() {
        me = <String, dynamic>{...?me, 'client_photo': encoded};
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.lang == 'uz'
                ? 'Profil rasmi saqlandi'
                : 'Фото профиля сохранено',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
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
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final name = (me?['name'] ?? 'Yangi Taxi').toString().trim();

    return Scaffold(
      backgroundColor: dark ? const Color(0xFF0B0D0E) : Colors.white,
      appBar: AppBar(
        backgroundColor: dark ? const Color(0xFF0B0D0E) : Colors.white,
        surfaceTintColor: Colors.transparent,
        leading: widget.onMenu == null
            ? null
            : IconButton(
                onPressed: widget.onMenu,
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              ),
        title: Text(
          widget.lang == 'uz' ? 'Profil' : 'Профиль',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        centerTitle: true,
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.3))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: 0.65),
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          GestureDetector(
                            onTap: chooseProfilePhoto,
                            child: CircleAvatar(
                              radius: 36,
                              backgroundColor: yangiLime,
                              child: clientPhotoBytes == null
                                  ? Text(
                                      name.isEmpty ? 'Y' : name.substring(0, 1).toUpperCase(),
                                      style: const TextStyle(
                                        color: yangiGraphite,
                                        fontSize: 26,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    )
                                  : ClipOval(
                                      child: Image.memory(
                                        clientPhotoBytes!,
                                        width: 72,
                                        height: 72,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  name.isEmpty ? 'Yangi Taxi' : name,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.45,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  phone.isEmpty ? '—' : phone,
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: chooseProfilePhoto,
                            tooltip: widget.lang == 'uz' ? 'Rasmni o‘zgartirish' : 'Изменить фото',
                            icon: const Icon(Icons.edit_outlined, size: 20),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      decoration: BoxDecoration(
                        color: yangiLime.withValues(alpha: dark ? 0.14 : 0.20),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: yangiLime.withValues(alpha: dark ? 0.30 : 0.45),
                        ),
                      ),
                      child: Row(
                        children: <Widget>[
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: yangiLime,
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: const Icon(Icons.stars_rounded, color: yangiGraphite),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  widget.lang == 'uz' ? 'Bonus balansi' : 'Бонусный баланс',
                                  style: TextStyle(
                                    color: scheme.onSurfaceVariant,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  bonusBalanceLabel(),
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: load,
                            tooltip: widget.lang == 'uz' ? 'Yangilash' : 'Обновить',
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.menu_open_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              widget.lang == 'uz'
                                  ? 'Safarlar, to‘lovlar, sevimli manzillar, promokodlar va sozlamalar chap menyuda.'
                                  : 'Поездки, оплата, любимые адреса, промокоды и настройки находятся в левом меню.',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
