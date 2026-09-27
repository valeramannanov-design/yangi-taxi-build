import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:yandex_maps_mapkit/init.dart' as yandex_init;
import 'package:yandex_maps_mapkit/mapkit.dart' as ym;
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
    if (path == '/api/auth/login' || path == '/api/auth/register') {
      token = 'demo-session';
      return <String, dynamic>{'token': token, 'client': demoMe};
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
      final b = Map<String, dynamic>.from(body['destination'] as Map);
      final id = 30000 + DateTime.now().millisecondsSinceEpoch.remainder(9000);
      _demoStarted = DateTime.now();
      _demoOrder = <String, dynamic>{
        'order_id': id,
        'state_kind': 'new_order',
        'source': a['address'],
        'destination': b['address'],
        'source_lat': a['lat'],
        'source_lon': a['lon'],
        'destination_lat': b['lat'],
        'destination_lon': b['lon'],
        'car_mark': 'Chevrolet',
        'car_model': 'Cobalt',
        'car_number': '01 Y 001 TX',
        'total_cost': 28000,
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

  @override
  void initState() {
    super.initState();
    restore();
  }

  Future<void> restore() async {
    final savedUrl = await storage.read(key: 'backend_url');
    final savedLang = await storage.read(key: 'lang');
    final session = await storage.read(key: 'session');
    api.setBaseUrl(savedUrl ?? 'demo');
    if (savedLang == 'uz' || savedLang == 'ru') lang = savedLang!;
    if (session != null) {
      api.token = session;
      try {
        await api.get('/api/me');
        loggedIn = true;
      } catch (_) {
        api.token = null;
        await storage.delete(key: 'session');
      }
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> saveLang(String value) async {
    lang = value;
    await storage.write(key: 'lang', value: value);
    if (mounted) setState(() {});
  }

  Future<void> saveBackend(String value) async {
    api.setBaseUrl(value);
    await storage.write(key: 'backend_url', value: api.baseUrl);
    await storage.delete(key: 'session');
    loggedIn = false;
    if (mounted) setState(() {});
  }

  Future<void> saveToken(String value) async {
    api.token = value;
    await storage.write(key: 'session', value: value);
    if (mounted) setState(() => loggedIn = true);
  }

  Future<void> logout() async {
    api.token = null;
    await storage.delete(key: 'session');
    if (mounted) setState(() => loggedIn = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF238B45));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Yangi Taxi',
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7F8F4),
      ),
      home: loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : loggedIn
              ? Shell(api: api, lang: lang, onLang: saveLang, onBackend: saveBackend, onLogout: logout)
              : LoginScreen(api: api, lang: lang, onLang: saveLang, onBackend: saveBackend, onToken: saveToken),
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
    required this.onLang,
    required this.onBackend,
    required this.onToken,
  });
  final ApiClient api;
  final String lang;
  final ValueChanged<String> onLang;
  final Future<void> Function(String) onBackend;
  final Future<void> Function(String) onToken;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final phone = TextEditingController(text: '+998901234567');
  final pass = TextEditingController(text: '123456');
  final name = TextEditingController();
  bool register = false;
  bool busy = false;
  String? error;

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = register
          ? await widget.api.post('/api/auth/register', <String, dynamic>{
              'name': name.text.trim(),
              'phone': phone.text.trim(),
              'password': pass.text,
            })
          : await widget.api.post('/api/auth/login', <String, dynamic>{
              'phone': phone.text.trim(),
              'password': pass.text,
            });
      await widget.onToken(data['token'].toString());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
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
                            Chip(
                              avatar: Icon(widget.api.isDemo ? Icons.science_outlined : Icons.cloud_done_outlined, size: 18),
                              label: Text(widget.api.isDemo ? tx(widget.lang, 'demo') : widget.api.baseUrl),
                            ),
                            const Spacer(),
                            SegmentedButton<String>(
                              segments: const <ButtonSegment<String>>[
                                ButtonSegment<String>(value: 'ru', label: Text('RU')),
                                ButtonSegment<String>(value: 'uz', label: Text('UZ')),
                              ],
                              selected: <String>{widget.lang},
                              onSelectionChanged: (x) => widget.onLang(x.first),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        if (register) ...<Widget>[
                          TextField(
                            controller: name,
                            decoration: InputDecoration(border: const OutlineInputBorder(), labelText: tx(widget.lang, 'name')),
                          ),
                          const SizedBox(height: 12),
                        ],
                        TextField(
                          controller: phone,
                          keyboardType: TextInputType.phone,
                          decoration: InputDecoration(border: const OutlineInputBorder(), labelText: tx(widget.lang, 'phone')),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: pass,
                          obscureText: true,
                          onSubmitted: (_) => submit(),
                          decoration: InputDecoration(border: const OutlineInputBorder(), labelText: tx(widget.lang, 'password')),
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
                              : const Icon(Icons.login),
                          label: Text(register ? tx(widget.lang, 'register') : tx(widget.lang, 'login')),
                        ),
                        TextButton(
                          onPressed: busy ? null : () => setState(() => register = !register),
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

class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.api,
    required this.lang,
    required this.onLang,
    required this.onBackend,
    required this.onLogout,
  });
  final ApiClient api;
  final String lang;
  final ValueChanged<String> onLang;
  final Future<void> Function(String) onBackend;
  final VoidCallback onLogout;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  int? activeId;

  void orderCreated(int id) {
    setState(() {
      activeId = id;
      tab = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      OrderScreen(api: widget.api, lang: widget.lang, onOrder: orderCreated),
      RideScreen(api: widget.api, lang: widget.lang, orderId: activeId),
      HistoryScreen(api: widget.api, lang: widget.lang),
      ProfileScreen(
        api: widget.api,
        lang: widget.lang,
        onLang: widget.onLang,
        onBackend: widget.onBackend,
        onLogout: widget.onLogout,
      ),
    ];
    return Scaffold(
      body: IndexedStack(index: tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (x) => setState(() => tab = x),
        destinations: <NavigationDestination>[
          NavigationDestination(icon: const Icon(Icons.route_outlined), selectedIcon: const Icon(Icons.route), label: tx(widget.lang, 'order')),
          NavigationDestination(icon: const Icon(Icons.local_taxi_outlined), selectedIcon: const Icon(Icons.local_taxi), label: tx(widget.lang, 'ride')),
          NavigationDestination(icon: const Icon(Icons.history), label: tx(widget.lang, 'history')),
          NavigationDestination(icon: const Icon(Icons.person_outline), selectedIcon: const Icon(Icons.person), label: tx(widget.lang, 'profile')),
        ],
      ),
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
    this.zoom = 14,
  });
  final ym.Point center;
  final List<ym.Point> route;
  final ym.Point? from;
  final ym.Point? to;
  final ym.Point? driver;
  final double zoom;

  @override
  State<TaxiYandexMap> createState() => _TaxiYandexMapState();
}

class _TaxiYandexMapState extends State<TaxiYandexMap> {
  ym.MapWindow? mapWindow;

  @override
  void initState() {
    super.initState();
    if (yandexMapKitApiKey.isNotEmpty) ym_factory.mapkit.onStart();
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

    void addTextPlacemark(ym.Point point, String text) {
      map.mapObjects.addPlacemark()
        ..geometry = point
        ..setText(text);
    }

    if (widget.route.length > 1) {
      final polyline = ym.Polyline(widget.route);
      map.mapObjects.addPolylineWithGeometry(polyline)
        ..strokeWidth = 5.0
        ..setStrokeColor(const Color(0xFF238B45));
      if (focusRoute) {
        map.move(map.cameraPositionForGeometry(ym.Geometry.fromPolyline(polyline)));
      }
    }
    if (widget.from != null) addTextPlacemark(widget.from!, '●');
    if (widget.to != null) addTextPlacemark(widget.to!, '📍');
    if (widget.driver != null) addTextPlacemark(widget.driver!, '🚕');

    if (!focusRoute || widget.route.length < 2) {
      map.move(ym.CameraPosition(widget.center, zoom: widget.zoom, azimuth: 0, tilt: 0));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (yandexMapKitApiKey.isEmpty) {
      return Container(
        color: const Color(0xFFEAF4EE),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.map_outlined, size: 52),
            SizedBox(height: 12),
            Text('Яндекс Карты подключены. Для отображения карты нужен MapKit API-ключ.', textAlign: TextAlign.center),
          ],
        ),
      );
    }
    return ym_widget.YandexMap(
      onMapCreated: (window) {
        mapWindow = window;
        _render();
      },
    );
  }
}

class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.api, required this.lang, required this.onOrder});
  final ApiClient api;
  final String lang;
  final ValueChanged<int> onOrder;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  Place? from;
  Place? to;
  double? cost;
  List<ym.Point> route = <ym.Point>[];
  bool busy = false;
  String? error;

  Future<Place?> selectAddress(String title, Place? initial) => showModalBottomSheet<Place>(
        context: context,
        isScrollControlled: true,
        builder: (_) => AddressSheet(api: widget.api, lang: widget.lang, title: title, initial: initial),
      );

  Future<void> estimate() async {
    if (from == null || to == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await widget.api.post('/api/orders/estimate', <String, dynamic>{
        'source': from!.toJson(),
        'destination': to!.toJson(),
      });
      final points = <ym.Point>[];
      final mapData = data['route'];
      if (mapData is Map && mapData['full_route_coords'] is List) {
        for (final dynamic x in mapData['full_route_coords'] as List) {
          if (x is Map && x['lat'] != null && x['lon'] != null) {
            points.add(ym.Point(latitude: (x['lat'] as num).toDouble(), longitude: (x['lon'] as num).toDouble()));
          }
        }
      }
      if (mounted) {
        setState(() {
          cost = (data['cost'] as num).toDouble();
          route = points;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> createOrder() async {
    if (from == null || to == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await widget.api.post('/api/orders', <String, dynamic>{
        'source': from!.toJson(),
        'destination': to!.toJson(),
      });
      widget.onOrder((data['order_id'] as num).toInt());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final center = from?.point ?? const ym.Point(latitude: defaultLat, longitude: defaultLon);
    return Scaffold(
      appBar: AppBar(title: const Text('Yangi Taxi', style: TextStyle(fontWeight: FontWeight.w800))),
      body: Stack(
        children: <Widget>[
          TaxiYandexMap(
            center: center,
            route: route,
            from: from?.point,
            to: to?.point,
            zoom: 13,
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              minimum: const EdgeInsets.all(12),
              child: Card(
                elevation: 8,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      addressButton(
                        context,
                        Icons.radio_button_checked,
                        from?.address ?? tx(widget.lang, 'from'),
                        () async {
                          final p = await selectAddress(tx(widget.lang, 'from'), from);
                          if (p != null) {
                            setState(() {
                              from = p;
                              cost = null;
                              route = <ym.Point>[];
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                      addressButton(
                        context,
                        Icons.location_on,
                        to?.address ?? tx(widget.lang, 'to'),
                        () async {
                          final p = await selectAddress(tx(widget.lang, 'to'), to);
                          if (p != null) {
                            setState(() {
                              to = p;
                              cost = null;
                              route = <ym.Point>[];
                            });
                          }
                        },
                      ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                        ),
                      if (cost != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: <Widget>[
                              Text(tx(widget.lang, 'price')),
                              Text(
                                cost!.toStringAsFixed(0) + ' UZS',
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: busy || from == null || to == null ? null : (cost == null ? estimate : createOrder),
                          icon: busy
                              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : Icon(cost == null ? Icons.calculate_outlined : Icons.local_taxi),
                          label: Text(cost == null ? tx(widget.lang, 'estimate') : tx(widget.lang, 'book')),
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

  Widget addressButton(BuildContext context, IconData icon, String label, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: <Widget>[
              Icon(icon),
              const SizedBox(width: 10),
              Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis)),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      );
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
    if (yandexMapKitApiKey.isEmpty) {
      await _searchTaxiMaster(q);
      return;
    }
    if (mounted) setState(() { busy = true; error = null; });
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
      onError: (e) {
        if (!completer.isCompleted) completer.completeError(Exception('Yandex search error'));
      },
    );
    try {
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
      final found = await completer.future.timeout(const Duration(seconds: 8));
      if (mounted) setState(() => results = found);
    } catch (_) {
      await _searchTaxiMaster(q);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _searchTaxiMaster(String q) async {
    try {
      final data = await widget.api.get('/api/addresses/search', query: <String, String>{'q': q});
      final list = (data as List).map((x) => Place.fromJson(Map<String, dynamic>.from(x as Map))).toList();
      if (mounted) setState(() { results = list; error = null; });
    } catch (_) {
      if (mounted) setState(() { results = <Place>[]; error = 'Адрес не найден'; });
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
                        subtitle: const Text('Яндекс Карты'),
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
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: <Widget>[
          if (yandexMapKitApiKey.isEmpty)
            const Center(child: Text('Для выбора точки нужен Yandex MapKit API-ключ.'))
          else
            ym_widget.YandexMap(
              onMapCreated: (window) {
                mapWindow = window;
                window.map.move(
                  ym.CameraPosition(initial, zoom: 16, azimuth: 0, tilt: 0),
                );
              },
            ),
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 44),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      widget.title == tx(widget.lang, 'from')
                          ? Icons.radio_button_checked
                          : Icons.location_on,
                      size: 48,
                      color: const Color(0xFF238B45),
                    ),
                    Container(width: 3, height: 22, color: const Color(0xFF238B45)),
                  ],
                ),
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
                            ? 'Xaritani marker ostida kerakli nuqtaga suring'
                            : 'Передвиньте карту так, чтобы стрелка была в нужной точке',
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
                            widget.lang == 'uz' ? 'Shu joyni tanlash' : 'Указать здесь',
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
  const RideScreen({super.key, required this.api, required this.lang, required this.orderId});
  final ApiClient api;
  final String lang;
  final int? orderId;

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

  Future<void> cancel() async {
    final o = order;
    if (o == null) return;
    final id = (o['order_id'] as num).toInt();
    try {
      final p = await widget.api.get('/api/orders/' + id.toString() + '/cancel-penalty');
      final sum = (p['cancel_order_penalty_sum'] as num?) ?? 0;
      if (!mounted) return;
      final yes = await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(tx(widget.lang, 'cancel')),
              content: Text(sum > 0 ? 'Штраф: ' + sum.toString() + ' UZS' : 'Подтвердить отмену заказа?'),
              actions: <Widget>[
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Нет')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Да')),
              ],
            ),
          ) ??
          false;
      if (yes) {
        await widget.api.post('/api/orders/' + id.toString() + '/cancel', <String, dynamic>{});
        await refresh();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (order == null) {
      return Scaffold(appBar: AppBar(title: Text(tx(widget.lang, 'ride'))), body: Center(child: Text(tx(widget.lang, 'empty'))));
    }
    final o = order!;
    final state = (o['state_kind'] ?? '').toString();
    final from = point(o['source_lat'], o['source_lon']);
    final to = point(o['destination_lat'], o['destination_lon']);
    final center = driver ?? from ?? const ym.Point(latitude: defaultLat, longitude: defaultLon);
    final car = <String>[o['car_mark']?.toString() ?? '', o['car_model']?.toString() ?? ''].where((x) => x.isNotEmpty).join(' ');
    final number = (o['car_number'] ?? '').toString();
    return Scaffold(
      appBar: AppBar(title: Text(stateLabel(state), style: const TextStyle(fontWeight: FontWeight.w800))),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.api, required this.lang});
  final ApiClient api;
  final String lang;

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
                          return Card(
                            child: ListTile(
                              leading: CircleAvatar(child: Icon(state == 'finished' ? Icons.check : Icons.close)),
                              title: Text(
                                (o['source'] ?? '').toString() + ' → ' + (o['destination'] ?? '').toString(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text('#' + (o['order_id'] ?? '').toString() + ' • ' + state),
                              trailing: o['total_cost'] == null ? null : Text(o['total_cost'].toString()),
                            ),
                          );
                        },
                      ),
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
  });
  final ApiClient api;
  final String lang;
  final ValueChanged<String> onLang;
  final Future<void> Function(String) onBackend;
  final VoidCallback onLogout;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Map<String, dynamic>? me;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final data = await widget.api.get('/api/me');
      if (mounted) setState(() => me = Map<String, dynamic>.from(data as Map));
    } catch (_) {}
  }

  String get phone {
    if (me?['phones'] is List && (me!['phones'] as List).isNotEmpty) {
      final x = (me!['phones'] as List).first;
      if (x is Map) return (x['phone'] ?? '').toString();
    }
    return '';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tx(widget.lang, 'profile'), style: const TextStyle(fontWeight: FontWeight.w800))),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Card(
              child: ListTile(
                leading: const CircleAvatar(radius: 28, child: Icon(Icons.person)),
                title: Text((me?['name'] ?? 'Yangi Taxi').toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(phone),
              ),
            ),
            Card(
              child: ListTile(
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
            ),
            Card(
              child: ListTile(
                leading: Icon(widget.api.isDemo ? Icons.science_outlined : Icons.dns_outlined),
                title: Text(tx(widget.lang, 'backend')),
                subtitle: Text(widget.api.baseUrl),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => backendDialog(context, widget.api, widget.onBackend),
              ),
            ),
            if (me?['bonus_balance'] != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.savings_outlined),
                  title: const Text('Бонусы / Bonuslar'),
                  trailing: Text(me!['bonus_balance'].toString()),
                ),
              ),
            const SizedBox(height: 18),
            OutlinedButton.icon(onPressed: widget.onLogout, icon: const Icon(Icons.logout), label: Text(tx(widget.lang, 'logout'))),
          ],
        ),
      );
}
