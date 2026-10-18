part of 'main.dart';

const _goNoticeLabels = <String, List<String>>{
  'order_created': ['Заказ оформлен', 'Buyurtma yaratildi'],
  'order_confirmed': [
    'Магазин подтвердил заказ',
    'Do‘kon buyurtmani tasdiqladi'
  ],
  'order_ready': ['Заказ готов к выдаче', 'Buyurtma topshirishga tayyor'],
  'pickup_ready': ['Заказ готов к самовывозу', 'Buyurtma olib ketishga tayyor'],
  'pickup_time_changed': [
    'Магазин уточнил время готовности',
    'Do‘kon tayyorlik vaqtini yangiladi'
  ],
  'courier_assigned': ['Курьер назначен', 'Kuryer tayinlandi'],
  'courier_accepted': ['Курьер принял заказ', 'Kuryer buyurtmani qabul qildi'],
  'goods_picked_up': ['Курьер забрал товары', 'Kuryer mahsulotlarni oldi'],
  'order_completed': ['Заказ завершён', 'Buyurtma yakunlandi'],
  'order_cancelled': ['Заказ отменён', 'Buyurtma bekor qilindi'],
  'order_rejected': ['Магазин отклонил заказ', 'Do‘kon buyurtmani rad etdi'],
  'complaint_updated': [
    'Обновление по обращению',
    'Murojaat bo‘yicha yangilik'
  ],
};
String goNoticeTitle(Map n, String lang) =>
    _goNoticeLabels[n['kind']]?[lang == 'uz' ? 1 : 0] ?? '';

/// Same inbox/ack API as pickup readiness, extended to all confirmed GO events.
class GoNotificationHub extends StatefulWidget {
  const GoNotificationHub(
      {super.key,
      required this.api,
      required this.lang,
      required this.isActive,
      required this.onOrder,
      this.pickupOnly = false,
      this.fullPage = false});
  final ApiClient api;
  final String lang;
  final bool isActive, pickupOnly, fullPage;
  final ValueChanged<String> onOrder;
  @override
  State<GoNotificationHub> createState() => _GoNotificationHubState();
}

class _GoNotificationHubState extends State<GoNotificationHub>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _rows = [];
  Timer? _timer;
  bool _loading = false,
      _reading = false,
      _foreground = true,
      _pendingOpen = false,
      _more = true;
  int _epoch = 0, _unread = 0;
  String? _auth, _error;
  final Map<int, String> _keys = {};
  String _t(String ru, String uz) => widget.lang == 'uz' ? uz : ru;
  @override
  void initState() {
    super.initState();
    _auth = widget.api.token;
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _timer =
        Timer.periodic(const Duration(seconds: 30), (_) => unawaited(_load()));
    unawaited(_load());
    if (!widget.pickupOnly && !widget.fullPage)
      GoAndroidPush.instance.attach(widget.api, widget.lang,
          onChange: () => unawaited(_load()), onOpen: _showInbox);
  }

  @override
  void didUpdateWidget(covariant GoNotificationHub oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.pickupOnly && !widget.fullPage)
      GoAndroidPush.instance.attach(widget.api, widget.lang,
          onChange: () => unawaited(_load()), onOpen: _showInbox);
    if (widget.api != oldWidget.api ||
        widget.api.token != _auth ||
        widget.isActive != oldWidget.isActive) {
      _epoch++;
      _loading = false;
      _reading = false;
      _rows = [];
      _unread = 0;
      _error = null;
      _keys.clear();
      _auth = widget.api.token;
      unawaited(_load());
    }
    if (widget.isActive && _pendingOpen)
      WidgetsBinding.instance.addPostFrameCallback((_) => _showInbox());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _epoch++;
    _loading = false;
    _reading = false;
    _foreground = state == AppLifecycleState.resumed;
    if (mounted)
      setState(() {
        _rows = [];
        _unread = 0;
      });
    if (_foreground) {
      unawaited(_load());
      if (_pendingOpen) _showInbox();
    }
  }

  Future<void> _load({bool older = false}) async {
    if (_loading || !widget.isActive || !_foreground || (_reading && !older))
      return;
    _loading = true;
    final epoch = _epoch, api = widget.api, auth = _auth;
    try {
      final data = await api
          .deliveryGet('/customer/notifications',
              query: older && _rows.isNotEmpty
                  ? {'before': '${_rows.last['id']}'}
                  : null)
          .timeout(const Duration(seconds: 15));
      final rows = (data as List)
          .whereType<Map>()
          .where((n) =>
              n['id'] is int &&
              n['order_id'] is String &&
              _goNoticeLabels.containsKey(n['kind']) &&
              (!widget.pickupOnly ||
                  (n['kind'] == 'pickup_ready' && n['status'] == 'ready')))
          .map((n) => Map<String, dynamic>.from(n))
          .toList();
      var unread = rows.where((n) => n['read_at'] == null).length;
      if (!widget.pickupOnly)
        try {
          final summary =
              await api.deliveryGet('/customer/notification-summary');
          unread = (summary['unread'] as num).toInt();
        } catch (_) {/* Older compatible inbox still works. */}
      if (mounted && epoch == _epoch && api.token == auth)
        setState(() {
          if (older) {
            final ids = _rows.map((r) => r['id']).toSet();
            _rows.addAll(rows.where((r) => !ids.contains(r['id'])));
          } else
            _rows = rows;
          _unread = unread;
          _error = null;
          _more = data.length == 100;
        });
    } catch (_) {
      if (mounted && epoch == _epoch)
        setState(() {
          _rows = [];
          _unread = 0;
          _error = _t('Не удалось загрузить уведомления',
              'Bildirishnomalar yuklanmadi');
        });
    } finally {
      if (epoch == _epoch) {
        _loading = false;
        if (mounted) setState(() {});
      }
    }
  }

  void _showInbox() {
    if (!mounted) return;
    if (!widget.isActive || !_foreground) {
      _pendingOpen = true;
      return;
    }
    _pendingOpen = false;
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
            builder: (_) => Scaffold(
                appBar:
                    AppBar(title: Text(_t('Уведомления', 'Bildirishnomalar'))),
                body: GoNotificationHub(
                    api: widget.api,
                    lang: widget.lang,
                    isActive: true,
                    fullPage: true,
                    onOrder: widget.onOrder))))
        .then((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _open(Map<String, dynamic> n) async {
    if (_reading) return;
    setState(() => _reading = true);
    final epoch = _epoch, api = widget.api, auth = _auth;
    try {
      final ack = await api.deliveryPost(
          '/customer/notifications/${n['id']}/read', {},
          idempotencyKey:
              _keys.putIfAbsent(n['id'] as int, deliveryRequestKey));
      if (ack is! Map || ack['id'] != n['id'] || ack['read_at'] is! int)
        throw StateError('Read not confirmed');
      if (mounted && epoch == _epoch && api.token == auth)
        setState(() {
          if (n['read_at'] == null) _unread = math.max(0, _unread - 1);
          n['read_at'] = ack['read_at'];
        });
    } catch (_) {
      /* Keep unread; the owned order may still be opened to inspect it. */
    } finally {
      if (mounted && epoch == _epoch) setState(() => _reading = false);
    }
    if (mounted && epoch == _epoch && api.token == auth)
      widget.onOrder(n['order_id'] as String);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _epoch++;
    _timer?.cancel();
    if (!widget.pickupOnly && !widget.fullPage)
      GoAndroidPush.instance.detach(widget.api);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.fullPage
        ? _rows
        : _rows.where((n) => n['read_at'] == null).take(3);
    final content = <Widget>[
      if (!widget.pickupOnly && !widget.fullPage)
        ListTile(
            key: const ValueKey('go-notifications-open'),
            leading: const Icon(Icons.notifications_outlined),
            title: Text('${_t('Уведомления', 'Bildirishnomalar')} ($_unread)'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showInbox),
      if (_error != null && !widget.pickupOnly)
        TextButton(
            onPressed: _loading ? null : () => _load(), child: Text(_error!)),
      if (widget.fullPage && _rows.isEmpty && _error == null)
        Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_loading
                ? _t('Загрузка…', 'Yuklanmoqda…')
                : _t(
                    'Уведомлений пока нет', 'Hozircha bildirishnomalar yo‘q'))),
      for (final n in rows)
        Card(
            key: ValueKey(widget.pickupOnly
                ? 'go-ready-${n['id']}'
                : 'go-notice-${n['id']}'),
            child: ListTile(
                leading: Icon(n['read_at'] == null
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_none),
                title: Text(goNoticeTitle(n, widget.lang)),
                subtitle: Text(
                    '${n['shop_name'] ?? ''}${widget.fullPage && n['created_at'] is int ? ' · ${DateTime.fromMillisecondsSinceEpoch(n['created_at'] as int).toLocal()}' : ''}'),
                onTap: _reading ? null : () => _open(n))),
      if (widget.fullPage && _more && _rows.isNotEmpty)
        TextButton(
            onPressed: _loading ? null : () => _load(older: true),
            child: Text(_t('Ранее', 'Oldingilari'))),
    ];
    return widget.fullPage
        ? RefreshIndicator(
            onRefresh: () => _load(),
            child: ListView(
                padding: const EdgeInsets.all(12),
                physics: const AlwaysScrollableScrollPhysics(),
                children: content))
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: content);
  }
}
