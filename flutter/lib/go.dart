part of 'main.dart';

int? _readOrderId(dynamic raw) {
  if (raw is! Map) return null;
  final value = raw['order_id'] ?? raw['orderId'] ?? raw['id'];
  final id =
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
  return id != null && id > 0 ? id : null;
}

enum GoService { taxi, parcel, food, market }

extension GoServiceView on GoService {
  String label(String lang) => (lang == 'uz'
      ? const ['TAKSI', 'YETKAZISH', 'TAOM', 'MARKET']
      : const ['ТАКСИ', 'ДОСТАВКА', 'ЕДА', 'МАРКЕТ'])[index];
  IconData get icon => const [
        Icons.local_taxi_rounded,
        Icons.inventory_2_rounded,
        Icons.restaurant_rounded,
        Icons.shopping_basket_rounded
      ][index];
  String? get shoppingKind => this == GoService.food
      ? 'food'
      : this == GoService.market
          ? 'market'
          : null;
}

class GoHomeScreen extends StatelessWidget {
  const GoHomeScreen(
      {super.key,
      required this.api,
      required this.lang,
      required this.isActive,
      required this.onService,
      required this.onProfile,
      required this.onOrders,
      required this.onAddresses,
      required this.onCards,
      required this.onTaxiOrder,
      required this.onPurchaseOrder});
  final ApiClient api;
  final String lang;
  final bool isActive;
  final ValueChanged<GoService> onService;
  final VoidCallback onProfile, onOrders, onAddresses, onCards;
  final ValueChanged<int> onTaxiOrder;
  final ValueChanged<Map<String, dynamic>> onPurchaseOrder;
  @override
  Widget build(BuildContext context) => Theme(
      data: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFFD43B),
              brightness: Brightness.light)),
      child: Scaffold(
          backgroundColor: const Color(0xFFF6F6F2),
          appBar: AppBar(
              backgroundColor: const Color(0xFFF6F6F2),
              title: const Text('Yangi Taxi GO',
                  style: TextStyle(fontWeight: FontWeight.w900)),
              actions: [
                IconButton(
                    key: const ValueKey('go-profile'),
                    onPressed: onProfile,
                    tooltip: lang == 'uz' ? 'Profil' : 'Профиль',
                    icon: const Icon(Icons.account_circle_outlined))
              ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text(lang == 'uz' ? 'Bugun nima kerak?' : 'Что нужно сегодня?',
                style:
                    const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            const SizedBox(height: 20),
            LayoutBuilder(
                builder: (context, constraints) => GridView.count(
                    crossAxisCount: constraints.maxWidth >= 600 ? 4 : 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    mainAxisExtent: 156 +
                        math.max(
                                0,
                                MediaQuery.textScalerOf(context).scale(14) -
                                    14) *
                            4,
                    children: GoService.values
                        .map((service) => Material(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(26),
                            child: InkWell(
                                key: ValueKey('go-service-${service.name}'),
                                borderRadius: BorderRadius.circular(26),
                                onTap: () => onService(service),
                                child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                              child: Align(
                                                  alignment:
                                                      Alignment.centerRight,
                                                  child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                              14),
                                                      decoration: BoxDecoration(
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(20),
                                                          gradient:
                                                              const LinearGradient(colors: [
                                                            Color(0xFFFFE887),
                                                            Color(0xFFFFC629)
                                                          ])),
                                                      child: Icon(service.icon,
                                                          size: 38,
                                                          color: const Color(
                                                              0xFF191A1C))))),
                                          const SizedBox(height: 8),
                                          Text(service.label(lang),
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w800)),
                                          if (service == GoService.parcel)
                                            Text(
                                                lang == 'uz'
                                                    ? 'Tayyorlanmoqda'
                                                    : 'Готовим сервис',
                                                style: const TextStyle(
                                                    fontSize: 11)),
                                        ])))))
                        .toList())),
            const SizedBox(height: 20),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ActionChip(
                  label: Text(lang == 'uz' ? 'Buyurtmalar' : 'Мои заказы'),
                  onPressed: onOrders),
              ActionChip(
                  label: Text(lang == 'uz' ? 'Manzillar' : 'Адреса'),
                  onPressed: onAddresses),
              ActionChip(
                  label:
                      Text(lang == 'uz' ? 'To‘lov usullari' : 'Способы оплаты'),
                  onPressed: onCards),
            ]),
            const SizedBox(height: 16),
            GoReadyAlerts(
                api: api,
                lang: lang,
                isActive: isActive,
                onOrder: (id) => onPurchaseOrder({'id': id})),
            Text(lang == 'uz' ? 'Faol buyurtmalar' : 'Активные заказы',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            GoOrdersPanel(
                api: api,
                lang: lang,
                isActive: isActive,
                activeOnly: true,
                onTaxiOrder: onTaxiOrder,
                onPurchaseOrder: onPurchaseOrder),
          ])));
}

class GoOrdersPanel extends StatefulWidget {
  const GoOrdersPanel(
      {super.key,
      required this.api,
      required this.lang,
      required this.isActive,
      required this.activeOnly,
      required this.onTaxiOrder,
      required this.onPurchaseOrder});
  final ApiClient api;
  final String lang;
  final bool isActive, activeOnly;
  final ValueChanged<int> onTaxiOrder;
  final ValueChanged<Map<String, dynamic>> onPurchaseOrder;
  @override
  State<GoOrdersPanel> createState() => _GoOrdersPanelState();
}

class _GoOrdersPanelState extends State<GoOrdersPanel>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _taxi = [], _purchases = [];
  bool _loading = false;
  String? _error;
  String _filter = 'all';
  Timer? _timer;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.isActive) _start();
  }

  @override
  void didUpdateWidget(covariant GoOrdersPanel old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !old.isActive) _start();
    if (!widget.isActive) _timer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && widget.isActive)
      _start();
    else
      _timer?.cancel();
  }

  void _start() {
    _timer?.cancel();
    unawaited(_load());
    if (widget.activeOnly)
      _timer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (widget.isActive && _foreground) unawaited(_load());
      });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final errors = <String>[];
    await Future.wait([
      () async {
        try {
          final data = await widget.api.get(widget.activeOnly
              ? '/api/orders/current'
              : '/api/orders/history');
          if (mounted)
            setState(() => _taxi = (data as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList());
        } catch (_) {
          errors.add('taxi');
        }
      }(),
      () async {
        try {
          final data = await widget.api.deliveryGet('/customer/orders');
          if (mounted)
            setState(() => _purchases = (data as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList());
        } catch (_) {
          errors.add('shopping');
        }
      }(),
    ]);
    if (mounted)
      setState(() {
        _loading = false;
        _error = errors.isEmpty
            ? null
            : (widget.lang == 'uz'
                ? 'Ba’zi buyurtmalar yangilanmadi'
                : 'Часть заказов не обновилась. Повторите запрос.');
      });
  }

  String _title(String state) {
    final ru = {
      'driver_assigned': 'Водитель едет к вам',
      'car_at_place': 'Водитель прибыл',
      'client_inside': 'Поездка выполняется',
      'finished': 'Завершён',
      'aborted': 'Отменён',
      'pending_shop': 'Ожидает заведение',
      'confirmed': 'Подтверждён',
      'ready': 'Готов к выдаче',
      'assigned': 'Курьер назначен',
      'accepted': 'Курьер едет в магазин',
      'picked_up': 'Курьер едет к вам',
      'completed': 'Доставлен',
      'cancelled': 'Отменён',
      'rejected': 'Отклонён'
    };
    final uz = {
      'driver_assigned': 'Haydovchi siz tomon yo‘lda',
      'car_at_place': 'Haydovchi yetib keldi',
      'client_inside': 'Safar davom etmoqda',
      'finished': 'Tugallangan',
      'aborted': 'Bekor qilingan',
      'pending_shop': 'Do‘kon tasdig‘i kutilmoqda',
      'confirmed': 'Tasdiqlangan',
      'ready': 'Olib ketishga tayyor',
      'assigned': 'Kuryer tayinlangan',
      'accepted': 'Kuryer do‘konga bormoqda',
      'picked_up': 'Kuryer siz tomon yo‘lda',
      'completed': 'Yetkazilgan',
      'cancelled': 'Bekor qilingan',
      'rejected': 'Rad etilgan'
    };
    return (widget.lang == 'uz' ? uz : ru)[state] ??
        (widget.lang == 'uz' ? 'Buyurtma holati' : 'Состояние заказа');
  }

  @override
  Widget build(BuildContext context) {
    // A TM transport also appears in taxi history. Display it only once, as its owned shopping order.
    final transports = _purchases
        .map((p) => p['transport_order_id']?.toString())
        .whereType<String>()
        .toSet();
    final taxi = _taxi
        .where((o) =>
            !transports.contains(_readOrderId(o)?.toString()) &&
            (!widget.activeOnly ||
                !const [
                  'finished',
                  'aborted',
                  'completed',
                  'cancelled'
                ].contains(o['state_kind'] ?? o['state_type'] ?? o['state'])))
        .toList();
    final purchases = _purchases
        .where((o) =>
            !widget.activeOnly ||
            !const ['completed', 'cancelled', 'rejected'].contains(o['status']))
        .toList();
    final rows = <Widget>[];
    if (_filter == 'all' || _filter == 'taxi')
      for (final o in taxi) {
        final id = _readOrderId(o);
        if (id == null) continue;
        rows.add(Card(
            child: ListTile(
                leading: const Icon(Icons.local_taxi_rounded),
                title: Text('${GoService.taxi.label(widget.lang)} · #$id'),
                subtitle: Text(_title(
                    '${o['state_kind'] ?? o['state_type'] ?? o['state'] ?? ''}')),
                onTap: () => widget.onTaxiOrder(id))));
      }
    for (final o in purchases) {
      final kind = o['service_kind'];
      if (_filter != 'all' && _filter != kind) continue;
      final label = kind == 'food'
          ? GoService.food.label(widget.lang)
          : kind == 'market'
              ? GoService.market.label(widget.lang)
              : (widget.lang == 'uz' ? 'Xarid' : 'Покупки');
      rows.add(Card(
          child: ListTile(
              leading: const Icon(Icons.shopping_bag_outlined),
              title: Text('$label · ${o['shop_name'] ?? ''}'),
              subtitle: Text(
                  '${o['fulfillment'] == 'pickup' ? (widget.lang == 'uz' ? 'Olib ketish' : 'Самовывоз') : _title('${o['status']}')}\n${o['total_uzs']} сум'),
              isThreeLine: true,
              onTap: () => widget.onPurchaseOrder(o))));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!widget.activeOnly)
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final value in ['all', 'taxi', 'parcel', 'food', 'market'])
                Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                        label: Text(value == 'all'
                            ? (widget.lang == 'uz' ? 'Barchasi' : 'Все')
                            : GoService.values
                                .firstWhere((s) => s.name == value)
                                .label(widget.lang)),
                        selected: _filter == value,
                        onSelected: (_) => setState(() => _filter = value))),
            ])),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null)
        Text(_error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ...rows,
      if (rows.isEmpty && !_loading && _error == null)
        Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
                widget.lang == 'uz' ? 'Buyurtmalar yo‘q' : 'Заказов пока нет')),
      TextButton(
          onPressed: _loading ? null : _load,
          child: Text(widget.lang == 'uz' ? 'Yangilash' : 'Обновить')),
    ]);
  }
}

class GoPurchaseDetails extends StatefulWidget {
  const GoPurchaseDetails(
      {super.key,
      required this.api,
      required this.lang,
      required this.orderId});
  final ApiClient api;
  final String lang, orderId;
  @override
  State<GoPurchaseDetails> createState() => _GoPurchaseDetailsState();
}

class _GoPurchaseDetailsState extends State<GoPurchaseDetails>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _order;
  String? _error;
  Timer? _poll;
  bool _loading = false, _foreground = true;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _poll = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && _foreground && ModalRoute.of(context)?.isCurrent != false)
        unawaited(_load());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void didUpdateWidget(covariant GoPurchaseDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.orderId != oldWidget.orderId) {
      _generation++;
      _loading = false;
      _order = null;
      _error = null;
      unawaited(_load());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _generation++;
    _loading = false;
    setState(() {
      _foreground = state == AppLifecycleState.resumed;
    });
    if (_foreground) unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || !_foreground) return;
    _loading = true;
    final generation = ++_generation;
    try {
      final data = await widget.api
          .deliveryGet('/customer/orders/${widget.orderId}')
          .timeout(const Duration(seconds: 15));
      if (mounted && generation == _generation)
        setState(() {
          _order = Map<String, dynamic>.from(data as Map);
          _error = null;
        });
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() => _error = widget.lang == 'uz'
            ? 'Buyurtma yuklanmadi'
            : 'Не удалось загрузить заказ');
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    return Scaffold(
        appBar: AppBar(title: Text(widget.lang == 'uz' ? 'Buyurtma' : 'Заказ')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (_error != null) Text(_error!),
          if (o == null && _error == null) const LinearProgressIndicator(),
          if (o != null) ...[
            Text('${o['shop_name']}',
                style: Theme.of(context).textTheme.headlineSmall),
            SelectableText('#${o['id']}'),
            Text('${o['status']}'),
            if (o['fulfillment'] == 'pickup')
              GoPickupSummary(order: o, lang: widget.lang)
            else
              GoCourierEta(
                  api: widget.api,
                  order: o,
                  lang: widget.lang,
                  enabled: _error == null && _foreground),
            GoCashHistory(order: o, lang: widget.lang),
            Text('${(o['destination'] as Map?)?['address'] ?? ''}'),
            Text(goAddressDetailsText(
                (o['destination'] as Map?) ?? {}, widget.lang)),
            for (final item in (o['items'] as List))
              ListTile(
                  title: Text(
                      '${item['name']}${item['variant_name'] != null ? ' · ${item['variant_name']}' : ''} × ${item['quantity']}'),
                  trailing: Text('${item['price_uzs']} сум')),
            if (o['coupon'] is Map)
              Text(
                  '${widget.lang == 'uz' ? 'Kupon' : 'Купон'} ${o['coupon']['code']}: −${o['coupon']['discount_uzs']} сум'),
            Text(
                '${widget.lang == 'uz' ? 'Jami' : 'Итого'}: ${o['total_uzs']} сум',
                style: Theme.of(context).textTheme.titleLarge)
          ],
          TextButton(
              onPressed: _load,
              child: Text(widget.lang == 'uz' ? 'Yangilash' : 'Обновить')),
        ]));
  }
}

class GoCashHistory extends StatelessWidget {
  const GoCashHistory({super.key, required this.order, required this.lang});
  final Map<String, dynamic> order;
  final String lang;
  @override
  Widget build(BuildContext context) {
    if (order['cash_model'] != 'courier_buyout_v1')
      return const SizedBox.shrink();
    final names = lang == 'uz'
        ? {
            'shop_paid': 'Kuryer do‘konga to‘ladi',
            'shop_received': 'Do‘kon pulni olganini tasdiqladi',
            'client_arrived': 'Kuryer qabul qiluvchiga yetib keldi',
            'client_cash': 'Mijozdan naqd pul olindi',
            'completed': 'Yakunlash tasdiqlandi'
          }
        : {
            'shop_paid': 'Курьер оплатил товары',
            'shop_received': 'Магазин подтвердил получение денег',
            'client_arrived': 'Курьер у получателя',
            'client_cash': 'Наличные клиента получены',
            'completed': 'Завершение подтверждено'
          };
    final events = (order['cash'] as Map?)?['events'] as List? ?? [];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (order['environment'] == 'TEST') const Text('TEST — тестовые суммы'),
      for (final event in events)
        Text(
            '${names[event['kind']] ?? event['kind']} · ${event['amount_uzs']} сум'),
    ]);
  }
}
