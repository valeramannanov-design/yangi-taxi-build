part of 'main.dart';

String deliveryRequestKey() {
  final random = math.Random.secure();
  return List.generate(
      24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class DeliveryScreen extends StatefulWidget {
  const DeliveryScreen(
      {super.key,
      required this.api,
      required this.lang,
      required this.isActive,
      required this.onMenu,
      this.addressPicker});
  final ApiClient api;
  final String lang;
  final bool isActive;
  final VoidCallback onMenu;
  final Future<Place?> Function(BuildContext, Place)? addressPicker;
  @override
  State<DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends State<DeliveryScreen> {
  List<Map<String, dynamic>> _categories = [],
      _shops = [],
      _searchProducts = [],
      _products = [],
      _orders = [];
  final Map<int, Map<String, dynamic>> _cart = {};
  final TextEditingController _search = TextEditingController();
  Map<String, dynamic>? _shop, _cartShop, _quote, _pending;
  int? _category;
  String? _owner, _error;
  Place? _destination;
  bool _busy = false, _loaded = false, _history = false, _cartOpen = false;
  Timer? _poll, _searchTimer;
  String _t(String ru, String uz) => widget.lang == 'uz' ? uz : ru;
  List<Map<String, dynamic>> _rows(dynamic value) =>
      (value as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  String _money(dynamic value) => '${value ?? 0} сум';
  String get _pendingStorageKey => 'delivery_checkout_$_owner';

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _activate();
  }

  @override
  void didUpdateWidget(covariant DeliveryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _activate();
    if (!widget.isActive) _poll?.cancel();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _searchTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _activate() {
    if (!_loaded) unawaited(_run(_load));
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (widget.isActive && _history && !_busy) unawaited(_run(_loadOrders));
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted)
        setState(() {
          _error = e is ApiException
              ? e.message
              : _t('Нет связи. Повторите запрос.',
                  'Aloqa yo‘q. Qayta urinib ko‘ring.');
        });
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
        });
    }
  }

  Future<void> _load() async {
    widget.api._requireDeliveryBackend();
    final profile = await widget.api.get('/api/me');
    final owner = (profile as Map)['client_id']?.toString();
    if (owner == null || !RegExp(r'^[1-9][0-9]*$').hasMatch(owner))
      throw ApiException('Не удалось подтвердить профиль клиента');
    _owner = owner;
    final saved = await _clientProfileStorage.read(key: _pendingStorageKey);
    if (saved != null) {
      final value = jsonDecode(saved);
      if (value is Map && value['quote_id'] is String && value['key'] is String)
        _pending = Map<String, dynamic>.from(value);
    }
    await _catalog();
    _loaded = true;
  }

  Future<void> _catalog() async {
    final value = Map<String, dynamic>.from(
        await widget.api.deliveryGet('/catalog', query: {
      if (_category != null) 'category': '$_category',
      if (_search.text.trim().isNotEmpty) 'q': _search.text.trim()
    }) as Map);
    if (!mounted) return;
    setState(() {
      _categories = _rows(value['categories']);
      _shops = _rows(value['shops']);
      _searchProducts = _rows(value['products']);
    });
  }

  Future<void> _openShop(int id) async {
    if (_cart.isNotEmpty && _cartShop?['id'] != id) {
      final clear = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: Text(_t(
                      'Заказ из одного магазина', 'Bitta do‘kondan buyurtma')),
                  content: Text(_t(
                      'Очистить корзину и перейти в другой магазин?',
                      'Savatni tozalab boshqa do‘konga o‘tasizmi?')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(_t('Остаться', 'Qolish'))),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(_t('Перейти', 'O‘tish')))
                  ]));
      if (clear != true) return;
      _cart.clear();
      _cartShop = null;
      _quote = null;
    }
    final shop = Map<String, dynamic>.from(
        await widget.api.deliveryGet('/shops/$id') as Map);
    if (!mounted) return;
    setState(() {
      _shop = shop;
      _products = _rows(shop['products']);
      _history = false;
      _cartOpen = false;
    });
  }

  void _quantity(Map<String, dynamic> product, int delta) {
    final id = (product['id'] as num).toInt(),
        quantity = ((_cart[id]?['quantity'] ?? 0) as int) + delta;
    if (quantity > (product['stock'] as num) || quantity > 99 || quantity < 0)
      return;
    setState(() {
      if (quantity == 0) {
        _cart.remove(id);
        if (_cart.isEmpty) _cartShop = null;
      } else {
        _cart[id] = {...product, 'quantity': quantity};
        _cartShop ??= _shop;
      }
      _quote = null;
    });
  }

  Future<void> _pickAddress() async {
    if (yandexMapKitApiKey.isEmpty && widget.addressPicker == null)
      throw ApiException(_t('Выбор адреса на карте недоступен в этой сборке.',
          'Bu versiyada xaritadan manzil tanlash mavjud emas.'));
    final initial = _destination ??
        Place(
            (_cartShop?['address'] ?? '').toString(),
            (_cartShop!['lat'] as num).toDouble(),
            (_cartShop!['lon'] as num).toDouble());
    final place = widget.addressPicker != null
        ? await widget.addressPicker!(context, initial)
        : await Navigator.of(context).push<Place>(MaterialPageRoute(
            builder: (_) => MapPointPickerScreen(
                title: _t('Куда доставить?', 'Qayerga yetkazish?'),
                lang: widget.lang,
                initial: initial)));
    if (place != null && mounted)
      setState(() {
        _destination = place;
        _quote = null;
      });
  }

  Future<void> _calculate() async {
    if (_destination == null || _cart.isEmpty || _pending != null) return;
    final quote = await widget.api.deliveryPost('/customer/quotes', {
      'shop_id': _cartShop!['id'],
      'items': _cart.entries
          .map((e) => {'product_id': e.key, 'quantity': e.value['quantity']})
          .toList(),
      'destination': {
        'address': _destination!.address,
        'lat': _destination!.lat,
        'lon': _destination!.lon
      }
    });
    if (mounted)
      setState(() {
        _quote = Map<String, dynamic>.from(quote as Map);
      });
  }

  Future<void> _submit() async {
    if (_pending == null) {
      if (_quote == null || _owner == null) return;
      _pending = {'quote_id': _quote!['id'], 'key': deliveryRequestKey()};
      // Persist intent before sending. A timeout or process restart must keep this key.
    }
    await _clientProfileStorage.write(
        key: _pendingStorageKey, value: jsonEncode(_pending));
    Map<String, dynamic> order;
    try {
      order = Map<String, dynamic>.from(await widget.api.deliveryPost(
          '/customer/orders', {'quote_id': _pending!['quote_id']},
          idempotencyKey: _pending!['key'] as String) as Map);
    } on ApiException catch (e) {
      if (e.statusCode != 409) rethrow;
      // A used quote can be reconciled only against this customer's server history.
      final history = _rows(await widget.api.deliveryGet('/customer/orders'));
      final matches =
          history.where((o) => o['quote_id'] == _pending!['quote_id']).toList();
      if (matches.isEmpty) {
        await _clientProfileStorage.delete(key: _pendingStorageKey);
        _pending = null;
        _quote = null;
        rethrow;
      }
      order = matches.single;
    }
    await _clientProfileStorage.delete(key: _pendingStorageKey);
    if (!mounted) return;
    setState(() {
      _pending = null;
      _quote = null;
      _cart.clear();
      _cartShop = null;
      _cartOpen = false;
      _history = true;
      _orders = [order];
    });
    await _loadOrders();
  }

  Future<void> _loadOrders() async {
    final rows = _rows(await widget.api.deliveryGet('/customer/orders'));
    if (mounted)
      setState(() {
        _orders = rows;
      });
  }

  Future<void> _cancel(Map<String, dynamic> order) async {
    final reason = TextEditingController();
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(_t('Отмена доставки', 'Buyurtmani bekor qilish')),
                content: TextField(
                    controller: reason,
                    maxLength: 300,
                    decoration:
                        InputDecoration(labelText: _t('Причина', 'Sabab'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(_t('Назад', 'Orqaga'))),
                  FilledButton(
                      onPressed: () {
                        if (reason.text.trim().isNotEmpty)
                          Navigator.pop(context, reason.text.trim());
                      },
                      child: Text(_t('Отменить заказ', 'Bekor qilish')))
                ]));
    reason.dispose();
    if (value == null) return;
    await widget.api.deliveryPost('/customer/orders/${order['id']}/cancel',
        {'version': order['version'], 'reason': value},
        idempotencyKey: deliveryRequestKey());
    await _loadOrders();
  }

  String _status(String status) =>
      {
        'pending_shop':
            _t('Магазин проверяет заказ', 'Do‘kon buyurtmani tekshirmoqda'),
        'confirmed': _t('Магазин подтвердил', 'Do‘kon tasdiqladi'),
        'ready': _t('Готов к выдаче', 'Olib ketishga tayyor'),
        'assigned': _t('Курьер назначен', 'Kuryer tayinlandi'),
        'accepted': _t('Курьер едет в магазин', 'Kuryer do‘konga bormoqda'),
        'picked_up': _t('Курьер едет к вам', 'Kuryer sizga kelmoqda'),
        'completed': _t('Доставлен', 'Yetkazildi'),
        'cancelled': _t('Отменён', 'Bekor qilindi'),
        'rejected': _t('Магазин отклонил заказ', 'Do‘kon buyurtmani rad etdi'),
      }[status] ??
      status;
  Widget _empty(String text) => Padding(
      padding: const EdgeInsets.all(28),
      child: Text(text, textAlign: TextAlign.center));
  Widget _product(Map<String, dynamic> p) {
    final quantity = (_cart[(p['id'] as num).toInt()]?['quantity'] ?? 0) as int;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              if (p['image_id'] != null)
                Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Image.network(
                        '${widget.api.baseUrl}/api/delivery/images/${p['image_id']}',
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.image_not_supported_outlined))),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('${p['name']}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(_money(p['price_uzs'])),
                    if ((p['description'] ?? '').toString().isNotEmpty)
                      Text('${p['description']}',
                          maxLines: 2, overflow: TextOverflow.ellipsis)
                  ])),
              if (quantity > 0)
                IconButton(
                    onPressed: _busy ? null : () => _quantity(p, -1),
                    icon: const Icon(Icons.remove_circle_outline)),
              if (quantity > 0) Text('$quantity'),
              IconButton(
                  onPressed: _busy || (p['stock'] as num) <= quantity
                      ? null
                      : () => _quantity(p, 1),
                  icon: const Icon(Icons.add_circle_outline)),
            ])));
  }

  Widget _catalogView() =>
      ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
            controller: _search,
            decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: _t('Поиск товаров', 'Mahsulotlarni qidirish')),
            onChanged: (_) {
              _searchTimer?.cancel();
              _searchTimer = Timer(
                  const Duration(milliseconds: 400), () => _run(_catalog));
            }),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          ChoiceChip(
              label: Text(_t('Все', 'Barchasi')),
              selected: _category == null,
              onSelected: _busy
                  ? null
                  : (_) {
                      setState(() {
                        _category = null;
                      });
                      _run(_catalog);
                    }),
          ..._categories.map((c) => ChoiceChip(
              label: Text('${c['name']}'),
              selected: _category == c['id'],
              onSelected: _busy
                  ? null
                  : (_) {
                      setState(() {
                        _category = c['id'] as int;
                      });
                      _run(_catalog);
                    }))
        ]),
        if (_searchProducts.isNotEmpty)
          ..._searchProducts.map((p) => Card(
              child: ListTile(
                  title: Text('${p['name']}'),
                  subtitle: Text(_money(p['price_uzs'])),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy
                      ? null
                      : () => _run(() => _openShop(p['shop_id'] as int))))),
        ..._shops.map((s) => Card(
            child: ListTile(
                leading: const Icon(Icons.storefront),
                title: Text('${s['name']}'),
                subtitle: Text('${s['address']}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy
                    ? null
                    : () => _run(() => _openShop(s['id'] as int))))),
        if (_loaded && _shops.isEmpty && _searchProducts.isEmpty)
          _empty(_t('В этой категории пока нет доступных магазинов.',
              'Bu toifada hozircha do‘konlar mavjud emas.')),
      ]);
  Widget _cartView() => ListView(padding: const EdgeInsets.all(16), children: [
        Text('${_cartShop?['name'] ?? ''}',
            style: Theme.of(context).textTheme.titleLarge),
        ..._cart.values.map(_product),
        OutlinedButton.icon(
            onPressed: _busy || _cart.isEmpty ? null : () => _run(_pickAddress),
            icon: const Icon(Icons.location_on_outlined),
            label: Text(_destination?.address ??
                _t('Выбрать адрес на карте', 'Manzilni xaritada tanlash'))),
        const SizedBox(height: 12),
        Text(
            _t('Оплата наличными при получении', 'Qabul qilishda naqd to‘lov')),
        if (_quote != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '${_t('Товары', 'Mahsulotlar')}: ${_money(_quote!['subtotal_uzs'])}'),
                        Text(
                            '${_t('Доставка', 'Yetkazish')}: ${_money(_quote!['delivery_uzs'])}'),
                        const SizedBox(height: 8),
                        Text(
                            '${_t('Итого', 'Jami')}: ${_money(_quote!['total_uzs'])}',
                            style: Theme.of(context).textTheme.titleLarge)
                      ]))),
        const SizedBox(height: 12),
        FilledButton(
            onPressed: _busy || _destination == null || _cart.isEmpty
                ? null
                : () => _run(_quote == null ? _calculate : _submit),
            child: Text(_quote == null
                ? _t('Рассчитать стоимость', 'Narxni hisoblash')
                : _t('Оформить заказ', 'Buyurtma berish'))),
      ]);
  Widget _historyView() => RefreshIndicator(
      onRefresh: () => _run(_loadOrders),
      child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_orders.isEmpty)
              _empty(_t('Заказов доставки пока нет',
                  'Yetkazish buyurtmalari hali yo‘q')),
            ..._orders.map((o) => Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${o['shop_name']}',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Text(_status('${o['status']}'),
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          Text('${(o['destination'] as Map)['address']}'),
                          ..._rows(o['items']).map(
                              (i) => Text('${i['name']} × ${i['quantity']}')),
                          const SizedBox(height: 8),
                          Text(_money(o['total_uzs'])),
                          if (o['status'] == 'pending_shop')
                            TextButton(
                                onPressed:
                                    _busy ? null : () => _run(() => _cancel(o)),
                                child: Text(_t('Отменить', 'Bekor qilish'))),
                        ])))),
          ]));
  @override
  Widget build(BuildContext context) {
    final back = _history || _cartOpen || _shop != null;
    return Scaffold(
      appBar: AppBar(
          title: Text(_history
              ? _t('История доставки', 'Buyurtmalar tarixi')
              : _cartOpen
                  ? _t('Корзина', 'Savat')
                  : _shop?['name']?.toString() ?? _t('Доставка', 'Yetkazish')),
          leading: IconButton(
              icon: Icon(back ? Icons.arrow_back : Icons.menu),
              onPressed: _busy
                  ? null
                  : () {
                      if (back) {
                        setState(() {
                          if (_cartOpen) {
                            _cartOpen = false;
                          } else {
                            _shop = null;
                            _history = false;
                          }
                        });
                      } else {
                        widget.onMenu();
                      }
                    }),
          actions: [
            IconButton(
                tooltip: _t('История', 'Tarix'),
                icon: const Icon(Icons.receipt_long_outlined),
                onPressed: _busy || !_loaded
                    ? null
                    : () {
                        setState(() {
                          _history = true;
                          _cartOpen = false;
                        });
                        _run(_loadOrders);
                      })
          ]),
      body: Column(children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        if (!_loaded && !_busy)
          TextButton(
              onPressed: () => _run(_load),
              child: Text(_t('Подключиться', 'Ulanish'))),
        if (_pending != null)
          Card(
              child: ListTile(
                  title: Text(_t('Проверьте оформление предыдущего заказа',
                      'Oldingi buyurtma holatini tekshiring')),
                  trailing: FilledButton(
                      onPressed: _busy ? null : () => _run(_submit),
                      child: Text(_t('Проверить', 'Tekshirish'))))),
        Expanded(
            child: _pending != null && _cartOpen
                ? const SizedBox.shrink()
                : _history
                    ? _historyView()
                    : _cartOpen
                        ? _cartView()
                        : _shop != null
                            ? ListView(
                                padding: const EdgeInsets.all(16),
                                children: _products.map(_product).toList())
                            : _catalogView()),
      ]),
      bottomNavigationBar: _cart.isNotEmpty && !_cartOpen && !_history
          ? SafeArea(
              top: false,
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() {
                                _cartOpen = true;
                              });
                            },
                      icon: const Icon(Icons.shopping_bag_outlined),
                      label: Text(
                          '${_t('Корзина', 'Savat')} · ${_cart.values.fold<int>(0, (s, i) => s + (i['quantity'] as int))}'))))
          : null,
    );
  }
}
