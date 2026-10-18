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
      this.serviceKind,
      this.checkoutEnabled = true,
      this.addressPicker});
  final ApiClient api;
  final String lang;
  final bool isActive;
  final VoidCallback onMenu;
  final String? serviceKind;
  final bool checkoutEnabled;
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
  final Map<String, Map<String, dynamic>> _cart = {};
  final TextEditingController _search = TextEditingController();
  final TextEditingController _coupon = TextEditingController();
  Map<String, dynamic>? _shop, _cartShop, _quote, _pending;
  int? _category;
  String? _owner, _error;
  Place? _destination;
  Map<String, dynamic> _addressDetails = {};
  List<Map<String, dynamic>> _favoriteAddresses = [];
  String? _addressNotice;
  bool _busy = false, _loaded = false, _history = false, _cartOpen = false;
  bool _catalogReload = false;
  Map<String, dynamic>? _checkoutCapability;
  bool get _canCheckout =>
      widget.checkoutEnabled &&
      (widget.serviceKind == null || _checkoutCapability?['enabled'] == true);
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
    if (widget.serviceKind != oldWidget.serviceKind) {
      _shop = null;
      _products = [];
      _shops = [];
      _searchProducts = [];
      _categories = [];
      _category = null;
      _search.clear();
      _history = false;
      _catalogReload = true;
      if (widget.isActive) _activate();
    }
    if (widget.isActive && !oldWidget.isActive) _activate();
    if (!widget.isActive) _poll?.cancel();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _searchTimer?.cancel();
    _search.dispose();
    _coupon.dispose();
    super.dispose();
  }

  void _activate() {
    if (!_loaded)
      unawaited(_run(_load));
    else if (_catalogReload) unawaited(_run(_catalog));
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
      if (mounted && widget.isActive && _catalogReload)
        unawaited(_run(_catalog));
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
    try {
      await _loadOrders();
    } catch (_) {/* No history: require map confirmation. */}
    try {
      _favoriteAddresses = await _loadFavoriteAddresses(widget.api);
    } catch (_) {
      _addressNotice = _t('Сохранённые адреса временно недоступны',
          'Saqlangan manzillar vaqtincha mavjud emas');
    }
  }

  Future<void> _catalog() async {
    _catalogReload = false;
    final kind = widget.serviceKind,
        search = _search.text.trim(),
        category = _category;
    final value = Map<String, dynamic>.from(
        await widget.api.deliveryGet('/catalog', query: {
      if (kind != null) 'service': kind,
      if (_category != null) 'category': '$_category',
      if (_search.text.trim().isNotEmpty) 'q': _search.text.trim()
    }) as Map);
    if (!mounted ||
        kind != widget.serviceKind ||
        search != _search.text.trim() ||
        category != _category) return;
    if (kind != null && value['service'] != kind)
      throw ApiException(_t('Для каталога GO требуется обновление сервера.',
          'GO katalogi uchun server yangilanishi kerak.'));
    setState(() {
      _checkoutCapability = value['go_checkout'] is Map
          ? Map<String, dynamic>.from(value['go_checkout'] as Map)
          : null;
      _categories = _rows(value['categories']);
      _shops = _rows(value['shops']);
      _searchProducts = _rows(value['products']);
    });
  }

  Future<void> _openShop(int id) async {
    final kind = widget.serviceKind;
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
      _coupon.clear();
      _cartShop = null;
      _quote = null;
    }
    final shop = Map<String, dynamic>.from(await widget.api.deliveryGet(
        '/shops/$id',
        query: {if (kind != null) 'service': kind}) as Map);
    if (!mounted || kind != widget.serviceKind) return;
    if (kind != null && shop['service_kind'] != kind)
      throw ApiException(_t('Заведение недоступно в этом разделе.',
          'Muassasa bu bo‘limda mavjud emas.'));
    setState(() {
      _shop = shop;
      _products = _rows(shop['products'])
          .map((p) => {...p, 'shop_id': shop['id']})
          .toList();
      _history = false;
      _cartOpen = false;
    });
  }

  void _quantity(Map<String, dynamic> product, int delta) {
    if (product['has_variants'] == true && product['variant_id'] == null)
      return;
    final id = _cartKey(product),
        quantity = ((_cart[id]?['quantity'] ?? 0) as int) + delta;
    if (quantity > (product['stock'] as num) || quantity > 99 || quantity < 0)
      return;
    setState(() {
      if (quantity == 0) {
        _cart.remove(id);
        if (_cart.isEmpty) {
          _cartShop = null;
          _coupon.clear();
        }
      } else {
        _cart[id] = {...product, 'quantity': quantity};
        _cartShop ??= _shop;
      }
      _quote = null;
    });
  }

  String _cartKey(Map p) => '${p['id']}:${p['variant_id'] ?? ''}';
  String _productName(Map p) =>
      '${p['name']}${p['variant_name'] != null ? ' · ${p['variant_name']}' : ''}';
  String _measure(Map p) => [
        if (p['weight_g'] != null) '${p['weight_g']} г',
        if (p['volume_ml'] != null) '${p['volume_ml']} мл'
      ].join(' · ');
  Future<void> _addProduct(Map<String, dynamic> p) async {
    if (p['has_variants'] == true && p['variant_id'] == null) {
      final variants = _rows(p['variants'] ?? []);
      final selected = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                  title: Text(_t('Выберите вариант', 'Variantni tanlang')),
                  content: SizedBox(
                      width: double.maxFinite,
                      child: ListView(shrinkWrap: true, children: [
                        for (final v in variants)
                          ListTile(
                            title: Text('${v['name']}'),
                            subtitle: Text(
                                '${_money(v['price_uzs'])} · ${_measure(v)}'),
                            enabled: (v['stock'] as num) > 0,
                            onTap: (v['stock'] as num) > 0
                                ? () => Navigator.pop(dialogContext, v)
                                : null,
                          )
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: Text(_t('Отмена', 'Bekor')))
                  ]));
      if (selected == null || !mounted) return;
      _quantity({
        ...p,
        'variant_id': selected['id'],
        'variant_name': selected['name'],
        'price_uzs': selected['price_uzs'],
        'original_price_uzs': selected['original_price_uzs'],
        'stock': selected['stock'],
        'weight_g': selected['weight_g'] ?? p['weight_g'],
        'volume_ml': selected['volume_ml'] ?? p['volume_ml']
      }, 1);
    } else {
      _quantity(p, 1);
    }
  }

  Widget _productGrid(List<Map<String, dynamic>> products) => GridView.builder(
      key: const ValueKey('go-products-grid'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: products.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          mainAxisExtent:
              260 + ((MediaQuery.textScalerOf(context).scale(16) - 16) * 6)),
      itemBuilder: (_, index) => _productTile(products[index]));
  Widget _productTile(Map<String, dynamic> p) => Card(
      key: ValueKey('go-product-${p['id']}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
          padding: const EdgeInsets.all(8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: InkWell(
                    onTap: _busy ? null : () => _productDetails(p),
                    child: SizedBox(
                        width: double.infinity,
                        child: p['image_id'] == null
                            ? const Icon(Icons.shopping_bag_outlined, size: 48)
                            : Image.network(
                                '${widget.api.baseUrl}/api/delivery/images/${p['image_id']}',
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(
                                    Icons.image_not_supported_outlined))))),
            TextButton(
                onPressed: _busy ? null : () => _productDetails(p),
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                child: Text(_productName(p),
                    maxLines: 2, overflow: TextOverflow.ellipsis)),
            if (_measure(p).isNotEmpty)
              Text(_measure(p), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (p['original_price_uzs'] != null)
              Text(_money(p['original_price_uzs']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(decoration: TextDecoration.lineThrough)),
            Text(
                '${p['has_variants'] == true ? _t('от ', 'dan ') : ''}${_money(p['price_uzs'])}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if ((_cart[_cartKey(p)]?['quantity'] ?? 0) > 0) ...[
                IconButton(
                    onPressed: _busy ? null : () => _quantity(p, -1),
                    icon: const Icon(Icons.remove_circle_outline)),
                Text('${_cart[_cartKey(p)]!['quantity']}')
              ],
              IconButton(
                  tooltip: _t('Добавить', 'Qo‘shish'),
                  onPressed: _busy ||
                          (p['stock'] as num) <=
                              (_cart[_cartKey(p)]?['quantity'] ?? 0)
                      ? null
                      : () => _addProduct(p),
                  icon: const Icon(Icons.add_circle_outline)),
            ])
          ])));
  Future<void> _pickAddress(
      {Place? initialPoint, Map<String, dynamic>? details}) async {
    if (yandexMapKitApiKey.isEmpty && widget.addressPicker == null)
      throw ApiException(_t('Выбор адреса на карте недоступен в этой сборке.',
          'Bu versiyada xaritadan manzil tanlash mavjud emas.'));
    final initial = initialPoint ??
        _destination ??
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
        final previous = initialPoint ?? _destination;
        _addressDetails = previous != null &&
                previous.lat == place.lat &&
                previous.lon == place.lon
            ? goAddressDetails(details ?? _addressDetails)
            : {};
        _destination = place;
        _addressNotice = null;
        _quote = null;
      });
  }

  Future<void> _useSavedAddress(Map<String, dynamic> saved) async {
    final place = Place(
        saved['address'].toString(),
        double.parse(saved['lat'].toString()),
        double.parse(saved['lon'].toString()));
    if (_orders.isEmpty) {
      await _pickAddress(initialPoint: place, details: saved);
      return;
    }
    setState(() {
      _destination = place;
      _addressDetails = goAddressDetails(saved);
      _addressNotice = null;
      _quote = null;
    });
  }

  Future<void> _editDeliveryDetails() async {
    final value =
        await editGoAddressDetails(context, widget.lang, _addressDetails);
    if (value != null && mounted)
      setState(() {
        _addressDetails = value;
        _addressNotice = null;
        _quote = null;
      });
  }

  Future<void> _saveDeliveryAddress() async {
    final place = _destination;
    if (place == null) return;
    final body = <String, dynamic>{
      'name': _t('Доставка', 'Yetkazish'),
      'address': place.address,
      'lat': place.lat,
      'lon': place.lon,
      ...goAddressDetails(_addressDetails)
    };
    final existing = _favoriteAddresses
        .where((a) =>
            a['address'] == place.address &&
            a['lat'] == place.lat &&
            a['lon'] == place.lon)
        .firstOrNull;
    final path = existing == null
        ? '/api/profile/favorites'
        : '/api/profile/favorites/${Uri.encodeComponent(existing['id'].toString())}';
    if (existing != null) body['name'] = existing['name'];
    final response = await widget.api.post(path, body);
    requireGoAddressDetailsEcho(body, response);
    final fresh = await _loadFavoriteAddresses(widget.api);
    if (mounted)
      setState(() {
        _favoriteAddresses = fresh;
        _addressNotice = _t(
            'Адрес сохранён в вашем профиле', 'Manzil profilingizda saqlandi');
      });
  }

  Future<void> _calculate() async {
    if (!_canCheckout) return;
    if (_destination == null || _cart.isEmpty || _pending != null) return;
    final quote = await widget.api.deliveryPost('/customer/quotes', {
      'shop_id': _cartShop!['id'],
      if (_coupon.text.trim().isNotEmpty)
        'coupon_code': _coupon.text.trim().toUpperCase(),
      'items': _cart.entries
          .map((e) => {
                'product_id': e.value['id'],
                'quantity': e.value['quantity'],
                if (e.value['variant_id'] != null)
                  'variant_id': e.value['variant_id']
              })
          .toList(),
      'destination': {
        'address': _destination!.address,
        'lat': _destination!.lat,
        'lon': _destination!.lon,
        ...goAddressDetails(_addressDetails)
      }
    });
    requireGoAddressDetailsEcho(
        _addressDetails, {'favorite': (quote as Map)['destination']});
    if (_coupon.text.trim().isNotEmpty &&
        (quote['coupon'] is! Map ||
            quote['coupon']['code'] != _coupon.text.trim().toUpperCase() ||
            quote['coupon']['funding'] != 'merchant' ||
            quote['coupon']['discount_uzs'] is! num ||
            quote['coupon']['discount_uzs'] <= 0)) {
      throw ApiException(_t(
          'Сервер не подтвердил купон. Обновите расчёт или удалите код.',
          'Server kuponni tasdiqlamadi. Hisobni yangilang yoki kodni o‘chiring.'));
    }
    if (mounted)
      setState(() {
        _quote = Map<String, dynamic>.from(quote);
      });
  }

  Future<void> _submit() async {
    if (!_canCheckout) {
      await _loadOrders();
      return;
    }
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
      _coupon.clear();
      _cartShop = null;
      _cartOpen = false;
      _history = true;
      _orders = [order];
      _destination = null;
      _addressDetails = {};
      _addressNotice = null;
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
  Future<void> _productDetails(Map<String, dynamic> product) async {
    final shopId = product['shop_id'] ?? _cartShop?['id'] ?? _shop?['id'];
    if (shopId == null) return;
    Map<String, dynamic>? detail;
    await _run(() async {
      final value = Map<String, dynamic>.from(await widget.api
          .deliveryGet('/shops/$shopId/products/${product['id']}', query: {
        if (widget.serviceKind != null) 'service': widget.serviceKind!
      }) as Map);
      if (value['shop_id'] != shopId)
        throw ApiException(_t('Товар недоступен.', 'Mahsulot mavjud emas.'));
      detail = value;
    });
    if (!mounted || detail == null) return;
    final p = detail!, seen = <int>{(detail!['id'] as num).toInt()};
    final recommendations = _rows(p['recommendations'] ?? [])
        .where((r) =>
            r['shop_id'] == shopId &&
            (r['stock'] as num) > 0 &&
            seen.add((r['id'] as num).toInt()))
        .take(10)
        .toList();
    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => StatefulBuilder(
            builder: (context, refresh) => DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.8,
                minChildSize: 0.4,
                maxChildSize: 0.95,
                builder: (context, controller) => ListView(
                        controller: controller,
                        padding: const EdgeInsets.all(20),
                        children: [
                          if (p['image_id'] != null)
                            Image.network(
                                '${widget.api.baseUrl}/api/delivery/images/${p['image_id']}',
                                height: 200,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(
                                    Icons.image_not_supported_outlined)),
                          Text('${p['name']}',
                              style: Theme.of(context).textTheme.headlineSmall),
                          if ((p['description'] ?? '').toString().isNotEmpty)
                            Text('${p['description']}'),
                          if ((p['ingredients'] ?? '').toString().isNotEmpty)
                            Text(
                                '${_t('Состав', 'Tarkibi')}: ${p['ingredients']}'),
                          if (_measure(p).isNotEmpty) Text(_measure(p)),
                          if (p['original_price_uzs'] != null)
                            Text(_money(p['original_price_uzs']),
                                style: const TextStyle(
                                    decoration: TextDecoration.lineThrough)),
                          Text(_money(p['price_uzs']),
                              style: Theme.of(context).textTheme.titleLarge),
                          FilledButton.icon(
                              onPressed:
                                  (_cart[_cartKey(p)]?['quantity'] ?? 0) >=
                                          (p['stock'] as num)
                                      ? null
                                      : () {
                                          _addProduct(p);
                                          refresh(() {});
                                        },
                              icon: const Icon(Icons.add),
                              label: Text(_t(
                                  'Добавить в корзину', 'Savatga qo‘shish'))),
                          if (recommendations.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                                _t('Вам может понравиться',
                                    'Sizga yoqishi mumkin'),
                                style: Theme.of(context).textTheme.titleMedium),
                            _productGrid(recommendations)
                          ],
                        ]))));
  }

  Widget _product(Map<String, dynamic> p) {
    final quantity = (_cart[_cartKey(p)]?['quantity'] ?? 0) as int;
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
                    TextButton(
                        onPressed: _busy ? null : () => _productDetails(p),
                        style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            alignment: Alignment.centerLeft),
                        child: Text(_productName(p),
                            style:
                                const TextStyle(fontWeight: FontWeight.bold))),
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
                      : () => _addProduct(p),
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
  Widget _cartView() => ListView(
          key: const ValueKey('go-cart-scroll'),
          padding: const EdgeInsets.all(16),
          children: [
            Text('${_cartShop?['name'] ?? ''}',
                style: Theme.of(context).textTheme.titleLarge),
            ..._cart.values.map(_product),
            OutlinedButton.icon(
                onPressed:
                    _busy || _cart.isEmpty ? null : () => _run(_pickAddress),
                icon: const Icon(Icons.location_on_outlined),
                label: Text(_destination?.address ??
                    _t('Выбрать адрес на карте', 'Manzilni xaritada tanlash'))),
            if (_orders.isEmpty)
              Text(_t('При первом заказе подтвердите точку доставки на карте.',
                  'Birinchi buyurtmada yetkazish nuqtasini xaritada tasdiqlang.')),
            if (_favoriteAddresses.isNotEmpty)
              Wrap(spacing: 8, children: [
                for (final saved in _favoriteAddresses)
                  ActionChip(
                      label: Text('${saved['name']} · ${saved['address']}'),
                      onPressed: _busy
                          ? null
                          : () => _run(() => _useSavedAddress(saved))),
              ]),
            if (_orders.isNotEmpty && _orders.first['destination'] is Map)
              TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() => _useSavedAddress(
                          Map<String, dynamic>.from(
                              _orders.first['destination'] as Map))),
                  child: Text(_t('Повторить последний адрес доставки',
                      'Oxirgi yetkazish manzilini takrorlash'))),
            if (_destination != null) ...[
              Text(goAddressDetailsText(_addressDetails, widget.lang)),
              TextButton(
                  onPressed: _busy ? null : _editDeliveryDetails,
                  child: Text(_t('Подъезд, этаж, квартира, ориентир',
                      'Kirish, qavat, xonadon, mo‘ljal'))),
              TextButton(
                  onPressed: _busy ? null : () => _run(_saveDeliveryAddress),
                  child: Text(_t('Сохранить адрес в профиле',
                      'Manzilni profilda saqlash'))),
            ],
            if (_addressNotice != null) Text(_addressNotice!),
            const SizedBox(height: 12),
            Text(_t('Оплата наличными при получении',
                'Qabul qilishda naqd to‘lov')),
            TextField(
                key: const ValueKey('go-coupon-code'),
                controller: _coupon,
                enabled: !_busy && _pending == null,
                maxLength: 32,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                    labelText: _t('Купон магазина', 'Do‘kon kuponi'),
                    helperText: _t('На товары без акций; доставка не меняется',
                        'Aksiyasiz tovarlarga; yetkazish o‘zgarmaydi')),
                onChanged: (_) => setState(() {
                      _quote = null;
                    })),
            if (_quote != null)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_quote!['coupon'] is Map)
                              Text(
                                  '${_t('Купон', 'Kupon')} ${_quote!['coupon']['code']}: −${_money(_quote!['coupon']['discount_uzs'])}'),
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
            if (_checkoutCapability?['environment'] == 'TEST')
              const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(
                      'TEST — тестовые суммы, не реальные тарифы TaxiMaster')),
            if (!_canCheckout)
              Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_t(
                      'Оформление временно недоступно: требуется подтверждение расчёта подачи и комиссии TaxiMaster.',
                      'Buyurtma vaqtincha mavjud emas: TaxiMaster yetib kelish narxi va komissiyasi tasdiqlanishi kerak.'))),
            FilledButton(
                onPressed: !_canCheckout ||
                        _busy ||
                        _destination == null ||
                        _cart.isEmpty
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
                          Text(goAddressDetailsText(
                              o['destination'] as Map, widget.lang)),
                          ..._rows(o['items']).map((i) =>
                              Text('${_productName(i)} × ${i['quantity']}')),
                          const SizedBox(height: 8),
                          if (o['coupon'] is Map)
                            Text(
                                '${_t('Купон', 'Kupon')} ${o['coupon']['code']}: −${_money(o['coupon']['discount_uzs'])}'),
                          Text(_money(o['total_uzs'])),
                          GoCashHistory(order: o, lang: widget.lang),
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
                  : _shop?['name']?.toString() ??
                      (widget.serviceKind == 'food'
                          ? _t('Еда', 'Taom')
                          : widget.serviceKind == 'market'
                              ? _t('Маркет', 'Market')
                              : _t('Доставка', 'Yetkazish'))),
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
                                children: [_productGrid(_products)])
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

const goAddressDetailLimits = <String, int>{
  'entrance': 32,
  'floor': 16,
  'apartment': 32,
  'landmark': 300
};
Map<String, dynamic> goAddressDetails(Map source) => {
      for (final key in goAddressDetailLimits.keys)
        key: (source[key] ?? '').toString().trim()
    };
String goAddressDetailsText(Map source, String lang) {
  final labels = lang == 'uz'
      ? ['Kirish', 'Qavat', 'Xonadon', 'Mo‘ljal']
      : ['Подъезд', 'Этаж', 'Квартира', 'Ориентир'];
  return goAddressDetailLimits.keys.indexed
      .where((entry) => (source[entry.$2] ?? '').toString().trim().isNotEmpty)
      .map((entry) => '${labels[entry.$1]}: ${source[entry.$2]}')
      .join(' · ');
}

void requireGoAddressDetailsEcho(Map expected, dynamic response) {
  final actual = response is Map ? response['favorite'] : null;
  for (final key in goAddressDetailLimits.keys) {
    final value = (expected[key] ?? '').toString().trim();
    if (expected.containsKey(key) &&
        (value.isNotEmpty || actual is Map && actual.containsKey(key)) &&
        (actual is! Map || (actual[key] ?? '').toString() != value))
      throw ApiException(
          'Сервер не сохранил детали адреса. Требуется обновление сервера.');
  }
}

Future<Map<String, dynamic>?> editGoAddressDetails(
        BuildContext context, String lang, Map initial) =>
    showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _GoAddressDetailsDialog(lang: lang, initial: initial));

class _GoAddressDetailsDialog extends StatefulWidget {
  const _GoAddressDetailsDialog({required this.lang, required this.initial});
  final String lang;
  final Map initial;
  @override
  State<_GoAddressDetailsDialog> createState() =>
      _GoAddressDetailsDialogState();
}

class _GoAddressDetailsDialogState extends State<_GoAddressDetailsDialog> {
  late final controllers = {
    for (final key in goAddressDetailLimits.keys)
      key: TextEditingController(text: (widget.initial[key] ?? '').toString())
  };
  @override
  void dispose() {
    for (final controller in controllers.values) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.lang == 'uz'
        ? ['Kirish', 'Qavat', 'Xonadon', 'Mo‘ljal']
        : ['Подъезд', 'Этаж', 'Квартира', 'Ориентир'];
    return AlertDialog(
        title:
            Text(widget.lang == 'uz' ? 'Manzil tafsilotlari' : 'Детали адреса'),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final entry in goAddressDetailLimits.keys.indexed)
            TextField(
                key: ValueKey('go-address-${entry.$2}'),
                controller: controllers[entry.$2],
                maxLength: goAddressDetailLimits[entry.$2],
                decoration: InputDecoration(labelText: labels[entry.$1])),
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(widget.lang == 'uz' ? 'Bekor' : 'Отмена')),
          FilledButton(
              onPressed: () => Navigator.pop(context, {
                    for (final entry in controllers.entries)
                      entry.key: entry.value.text.trim()
                  }),
              child: Text(widget.lang == 'uz' ? 'Saqlash' : 'Сохранить'))
        ]);
  }
}
