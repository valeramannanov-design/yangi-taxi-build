part of 'main.dart';

class GoPickupSummary extends StatelessWidget {
  const GoPickupSummary({super.key, required this.order, required this.lang});
  final Map<String, dynamic> order;
  final String lang;
  @override
  Widget build(BuildContext context) {
    final uz = lang == 'uz',
        ready = order['status'] == 'ready',
        complete = order['status'] == 'completed',
        expected = order['ready_expected_at'];
    final events = (order['pickup_cash'] as Map?)?['events'] as List? ?? [];
    final paid = events.any((e) => e is Map && e['kind'] == 'cash_received');
    String? time;
    if (expected is int) {
      final d = DateTime.fromMillisecondsSinceEpoch(expected).toLocal();
      time =
          '${d.day}.${d.month}, ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return Card(
        key: const ValueKey('go-pickup-summary'),
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  complete
                      ? (uz ? 'Olib ketildi' : 'Заказ получен')
                      : ready
                          ? (uz
                              ? 'Buyurtma olib ketishga tayyor'
                              : 'Заказ готов к самовывозу')
                          : (uz ? 'Olib ketish' : 'Самовывоз'),
                  style: Theme.of(context).textTheme.titleMedium),
              Text('${(order['pickup'] as Map?)?['address'] ?? ''}'),
              if (!ready && !complete)
                Text(time == null
                    ? (uz
                        ? 'Do‘kon tayyor bo‘lish vaqtini tasdiqlaydi'
                        : 'Магазин подтвердит время готовности')
                    : '${uz ? 'Taxminiy tayyorlik' : 'Ожидаемая готовность'}: $time'),
              Text(paid
                  ? (uz
                      ? 'Do‘kon naqd to‘lovni tasdiqladi'
                      : 'Наличные подтверждены магазином')
                  : (uz
                      ? 'Do‘konda naqd to‘lov'
                      : 'Оплата наличными в магазине')),
            ])));
  }
}

class GoReadyAlerts extends StatefulWidget {
  const GoReadyAlerts(
      {super.key,
      required this.api,
      required this.lang,
      required this.isActive,
      required this.onOrder});
  final ApiClient api;
  final String lang;
  final bool isActive;
  final ValueChanged<String> onOrder;
  @override
  State<GoReadyAlerts> createState() => _GoReadyAlertsState();
}

class _GoReadyAlertsState extends State<GoReadyAlerts>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _rows = [];
  Timer? _poll;
  bool _busy = false, _reading = false, _foreground = true;
  int _generation = 0;
  final Map<int, String> _keys = {};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _poll =
        Timer.periodic(const Duration(seconds: 30), (_) => unawaited(_load()));
    if (widget.isActive) unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant GoReadyAlerts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive || widget.api != oldWidget.api) {
      _generation++;
      _busy = false;
      _rows = [];
      if (widget.isActive) unawaited(_load());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _generation++;
    _busy = false;
    if (mounted) setState(() => _rows = []);
    if (_foreground) unawaited(_load());
  }

  Future<void> _load() async {
    if (_busy || !widget.isActive || !_foreground) return;
    _busy = true;
    final generation = ++_generation;
    try {
      final data = await widget.api
          .deliveryGet('/customer/notifications')
          .timeout(const Duration(seconds: 15));
      if (mounted && generation == _generation)
        setState(() => _rows = (data as List)
            .whereType<Map>()
            .where((n) =>
                n['kind'] == 'pickup_ready' &&
                n['status'] == 'ready' &&
                n['read_at'] == null &&
                n['id'] is int &&
                n['order_id'] is String)
            .map((n) => Map<String, dynamic>.from(n))
            .take(3)
            .toList());
    } catch (_) {
      /* Optional on older servers; never invent readiness notifications. */
      if (mounted && generation == _generation) setState(() => _rows = []);
    } finally {
      if (generation == _generation) _busy = false;
    }
  }

  Future<void> _open(Map<String, dynamic> notice) async {
    if (_reading) return;
    setState(() => _reading = true);
    final id = notice['id'] as int;
    try {
      await widget.api.deliveryPost('/customer/notifications/$id/read', {},
          idempotencyKey: _keys.putIfAbsent(id, deliveryRequestKey));
      if (mounted) setState(() => _rows.removeWhere((n) => n['id'] == id));
    } catch (_) {/* Retain unread state for retry. */} finally {
      if (mounted) setState(() => _reading = false);
    }
    if (mounted) widget.onOrder(notice['order_id'] as String);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        for (final n in _rows)
          Card(
              key: ValueKey('go-ready-${n['id']}'),
              child: ListTile(
                  leading: const Icon(Icons.takeout_dining_outlined),
                  title: Text(widget.lang == 'uz'
                      ? 'Buyurtma olib ketishga tayyor'
                      : 'Заказ готов к самовывозу'),
                  subtitle: Text(
                      '${n['shop_name']} · ${(n['pickup'] as Map?)?['address'] ?? ''}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _reading ? null : () => _open(n)))
      ]);
}
