part of 'main.dart';

typedef GoRouteSeconds = Future<int?> Function(Place source, Place target);

class GoEtaObservation {
  const GoEtaObservation(this.leg, {this.source, this.target, this.age = 0});
  final String leg;
  final Place? source, target;
  final int age;
}

// Own server tracking metadata is required; raw coordinates on an older server
// do not establish freshness. No guessed speed or local fare calculation.
GoEtaObservation? readGoEtaObservation(Map order, dynamic payload) {
  if (payload is! Map || payload['state'] is! Map) return null;
  final state = payload['state'] as Map;
  final crew = order['crew_id'], driver = order['driver_id'];
  if (crew is! int ||
      crew <= 0 ||
      driver is! int ||
      driver <= 0 ||
      state['crew_id'] != crew ||
      state['driver_id'] != driver ||
      (state['order_id'] != null &&
          state['order_id'] != order['transport_order_id'])) return null;
  final pickedUp = order['status'] == 'picked_up';
  if (!pickedUp && !['assigned', 'accepted'].contains(order['status']))
    return null;
  if (pickedUp) {
    if (state['state_kind'] != 'client_inside') return null;
    if (order['cash'] is Map && order['cash']['client_arrived'] == true)
      return const GoEtaObservation('at_customer');
  } else {
    if (state['state_kind'] == 'car_at_place')
      return const GoEtaObservation('at_store');
    if (state['state_kind'] != 'driver_assigned') return null;
  }
  final location = payload['location'], tracking = payload['tracking'];
  if (location is! Map ||
      location['crew_id'] != crew ||
      tracking is! Map ||
      tracking['source'] != 'TaxiMaster' ||
      tracking['available'] != true) return null;
  final age = tracking['location_age_seconds'];
  if (age is! int || age < 0 || age > 120) return null;
  Place? point(dynamic value) {
    if (value is! Map) return null;
    final lat = value['lat'], lon = value['lon'];
    if (lat is! num ||
        lon is! num ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) return null;
    return Place(
        (value['address'] ?? '').toString(), lat.toDouble(), lon.toDouble());
  }

  final source = point(location),
      target = point(order[pickedUp ? 'destination' : 'pickup']);
  if (source == null || target == null) return null;
  return GoEtaObservation(pickedUp ? 'to_customer' : 'to_store',
      source: source, target: target, age: age);
}

class _GoMapKitDuration {
  final yd.DrivingRouter _router = yd.DirectionsFactory.instance
      .createDrivingRouter(yd.DrivingRouterType.Combined);
  yd.DrivingSession? _session;
  Completer<int?>? _pending;
  void cancel() {
    _session?.cancel();
    _session = null;
    if (_pending != null && !_pending!.isCompleted) _pending!.complete(null);
    _pending = null;
  }

  Future<int?> seconds(Place source, Place target) async {
    cancel();
    final result = Completer<int?>();
    _pending = result;
    final listener = yd.DrivingSessionRouteListener(onDrivingRoutes: (routes) {
      if (result.isCompleted) return;
      final value = routes.isEmpty
          ? null
          : routes.first.metadata.weight.timeWithTraffic.value;
      result.complete(
          value != null && value.isFinite && value >= 0 ? value.ceil() : null);
    }, onDrivingRoutesError: (_) {
      if (!result.isCompleted) result.complete(null);
    });
    _session = _router.requestRoutes(const yd.DrivingOptions(routesCount: 1),
        const yd.DrivingVehicleOptions(), listener,
        points: [
          ym.RequestPoint(
              source.point, ym.RequestPointType.Waypoint, null, null, null),
          ym.RequestPoint(
              target.point, ym.RequestPointType.Waypoint, null, null, null)
        ]);
    return result.future.timeout(const Duration(seconds: 12), onTimeout: () {
      if (identical(_pending, result)) cancel();
      return null;
    });
  }
}

class GoCourierEta extends StatefulWidget {
  const GoCourierEta(
      {super.key,
      required this.api,
      required this.order,
      required this.lang,
      this.enabled = true,
      this.routeSeconds});
  final ApiClient api;
  final Map<String, dynamic> order;
  final String lang;
  final bool enabled;
  // Injected by tests only; production uses installed Yandex MapKit directly.
  final GoRouteSeconds? routeSeconds;
  @override
  State<GoCourierEta> createState() => _GoCourierEtaState();
}

class _GoCourierEtaState extends State<GoCourierEta>
    with WidgetsBindingObserver {
  Timer? _poll, _expiry;
  _GoMapKitDuration? _native;
  GoEtaObservation? _observation;
  int? _seconds;
  int _generation = 0;
  bool _busy = false, _foreground = true;
  late String _signature;
  String _key() => jsonEncode([
        widget.enabled,
        widget.order['id'],
        widget.order['status'],
        widget.order['transport_order_id'],
        widget.order['crew_id'],
        widget.order['driver_id'],
        widget.order['pickup'],
        widget.order['destination'],
        (widget.order['cash'] as Map?)?['client_arrived']
      ]);
  bool get _active =>
      widget.enabled &&
      _foreground &&
      ['assigned', 'accepted', 'picked_up'].contains(widget.order['status']);
  @override
  void initState() {
    super.initState();
    _signature = _key();
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(
        const Duration(seconds: 20), (_) => unawaited(_refresh()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  void _clear() {
    _generation++;
    _busy = false;
    _expiry?.cancel();
    _native?.cancel();
    _seconds = null;
    _observation = null;
  }

  @override
  void didUpdateWidget(covariant GoCourierEta oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_key() != _signature) {
      _signature = _key();
      _clear();
      unawaited(_refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    setState(_clear);
    if (_foreground) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_busy || !mounted) return;
    if (!_active || ModalRoute.of(context)?.isCurrent == false) {
      if (_observation != null) setState(_clear);
      return;
    }
    final id = widget.order['transport_order_id'];
    if (id is! int || id <= 0) return;
    _busy = true;
    final generation = ++_generation, elapsed = Stopwatch()..start();
    try {
      final raw = await widget.api
          .get('/api/orders/$id/driver-location')
          .timeout(const Duration(seconds: 15));
      if (!mounted || generation != _generation) return;
      final observation = readGoEtaObservation(widget.order, raw);
      if (observation == null) throw StateError('Tracking unavailable');
      int? seconds;
      if (observation.source != null && observation.target != null) {
        final remaining = 120 - observation.age - elapsed.elapsed.inSeconds;
        if (remaining <= 0) throw StateError('Coordinate expired');
        _expiry?.cancel();
        _expiry = Timer(Duration(seconds: remaining), () {
          if (mounted) setState(_clear);
        });
        final provider = widget.routeSeconds;
        if (provider != null)
          seconds = await provider(observation.source!, observation.target!);
        else if (yandexMapKitApiKey.isNotEmpty) {
          _native ??= _GoMapKitDuration();
          seconds =
              await _native!.seconds(observation.source!, observation.target!);
        }
        if (seconds == null ||
            seconds < 0 ||
            observation.age + elapsed.elapsed.inSeconds >= 120)
          throw StateError('Route unavailable or coordinate expired');
      }
      if (!mounted || generation != _generation) return;
      _expiry?.cancel();
      setState(() {
        _observation = observation;
        _seconds = seconds;
      });
      final lifetime = seconds == null
          ? 30
          : 120 - observation.age - elapsed.elapsed.inSeconds;
      _expiry = Timer(Duration(seconds: lifetime), () {
        if (mounted) setState(_clear);
      });
    } catch (_) {
      if (mounted && generation == _generation) setState(_clear);
    } finally {
      if (generation == _generation) _busy = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (['completed', 'cancelled', 'rejected'].contains(widget.order['status']))
      return const SizedBox.shrink();
    final uz = widget.lang == 'uz', leg = _observation?.leg;
    final title = switch (leg) {
      'at_store' => uz ? 'Kuryer do‘konda' : 'Курьер в магазине',
      'at_customer' => uz ? 'Kuryer yetib keldi' : 'Курьер прибыл',
      'to_store' => uz ? 'Kuryer do‘kongacha' : 'Курьер до магазина',
      'to_customer' => uz ? 'Sizgacha yo‘l' : 'Путь до вас',
      _ => uz ? 'Vaqt aniqlanmoqda' : 'Время уточняется',
    };
    return Card(
        key: const ValueKey('go-courier-eta'),
        child: ListTile(
            leading: const Icon(Icons.route_outlined),
            title: Text(title),
            subtitle: Text(_seconds != null
                ? (uz
                    ? 'Yo‘l va tirbandliklar bo‘yicha. Tayyorlash vaqti kiritilmagan.'
                    : 'По маршруту с учётом пробок. Подготовка заказа не включена.')
                : (leg == null
                    ? (uz
                        ? 'Joriy kuryer va yangi koordinatalar kerak'
                        : 'Нужны назначенный курьер и актуальные координаты')
                    : '')),
            trailing: _seconds == null
                ? null
                : Text(
                    '≈ ${math.max(1, (_seconds! / 60).ceil())} ${uz ? 'daq' : 'мин'}',
                    style: Theme.of(context).textTheme.titleMedium)));
  }
}
