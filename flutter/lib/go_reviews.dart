part of 'main.dart';

/// GO reviews use the owned delivery API. Taxi feedback keeps its existing TM path.
class GoOrderReviews extends StatefulWidget {
  const GoOrderReviews(
      {super.key,
      required this.api,
      required this.orderId,
      required this.lang});
  final ApiClient api;
  final String orderId, lang;
  @override
  State<GoOrderReviews> createState() => _GoOrderReviewsState();
}

class _GoOrderReviewsState extends State<GoOrderReviews> {
  Map<String, dynamic>? _data;
  bool _loading = false;
  String? _error;
  int _generation = 0;
  String _t(String ru, String uz) => widget.lang == 'uz' ? uz : ru;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant GoOrderReviews oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.orderId != oldWidget.orderId || widget.api != oldWidget.api) {
      _generation++;
      _data = null;
      _loading = false;
      _error = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final generation = ++_generation;
    try {
      final value = await widget.api
          .deliveryGet('/customer/orders/${widget.orderId}/reviews')
          .timeout(const Duration(seconds: 15));
      if (mounted && generation == _generation)
        setState(() {
          _data = Map<String, dynamic>.from(value as Map);
          _error = null;
        });
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() => _error = _t('Оценки недоступны. Повторить',
            'Baholar yuklanmadi. Qayta urinish'));
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_data == null)
      return TextButton(
          onPressed: _loading ? null : _load,
          child:
              Text(_error ?? _t('Загрузка оценок…', 'Baholar yuklanmoqda…')));
    final eligible = (_data!['eligible_targets'] as List? ?? [])
        .whereType<String>()
        .where((t) => const ['shop', 'courier'].contains(t));
    final reviews = (_data!['reviews'] as List? ?? []).whereType<Map>();
    return Column(children: [
      for (final target in eligible)
        _GoReviewForm(
            key: ValueKey('${widget.orderId}:$target'),
            api: widget.api,
            orderId: widget.orderId,
            target: target,
            lang: widget.lang,
            saved: reviews.where((r) => r['target'] == target).firstOrNull,
            onSaved: (data) => setState(() => _data = data)),
    ]);
  }
}

class _GoReviewForm extends StatefulWidget {
  const _GoReviewForm(
      {super.key,
      required this.api,
      required this.orderId,
      required this.target,
      required this.lang,
      required this.saved,
      required this.onSaved});
  final ApiClient api;
  final String orderId, target, lang;
  final Map? saved;
  final ValueChanged<Map<String, dynamic>> onSaved;
  @override
  State<_GoReviewForm> createState() => _GoReviewFormState();
}

class _GoReviewFormState extends State<_GoReviewForm> {
  final _comment = TextEditingController();
  int? _rating;
  bool _busy = false;
  String? _error, _key;
  Map<String, dynamic>? _pending;
  String _t(String ru, String uz) => widget.lang == 'uz' ? uz : ru;
  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || widget.saved != null || _rating == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // Unknown outcomes retry the exact payload/key, including after a timeout.
    _pending ??= {
      'target': widget.target,
      'rating': _rating,
      'comment': _comment.text.trim()
    };
    _key ??= deliveryRequestKey();
    try {
      final data = await widget.api
          .deliveryPost('/customer/orders/${widget.orderId}/reviews', _pending!,
              idempotencyKey: _key)
          .timeout(const Duration(seconds: 15));
      if (data is! Map ||
          data['reviews'] is! List ||
          !(data['reviews'] as List).whereType<Map>().any((r) =>
              r['target'] == widget.target &&
              r['rating'] == _pending!['rating'] &&
              r['comment'] == _pending!['comment']))
        throw StateError('Review was not confirmed');
      if (mounted) widget.onSaved(Map<String, dynamic>.from(data));
    } catch (_) {
      if (mounted)
        setState(() => _error = _t(
            'Подтверждение не получено. Повторите отправку или откройте заказ заново для проверки.',
            'Tasdiq olinmadi. Qayta yuboring yoki buyurtmani qayta oching.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = widget.saved,
        locked = _busy || _pending != null || saved != null;
    return Card(
        key: ValueKey('go-review-${widget.target}'),
        child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  widget.target == 'shop'
                      ? _t('Оценка магазина', 'Do‘kon bahosi')
                      : _t('Оценка курьера', 'Kuryer bahosi'),
                  style: Theme.of(context).textTheme.titleMedium),
              if (saved != null) ...[
                Text('${saved['rating']} / 5'),
                if ('${saved['comment'] ?? ''}'.isNotEmpty)
                  Text('${saved['comment']}'),
                Text(_t('Оценка сохранена', 'Baho saqlandi')),
                if (saved['complaint_status'] != null)
                  Text(saved['complaint_status'] == 'resolved'
                      ? _t('Обращение закрыто', 'Murojaat yopildi')
                      : saved['complaint_status'] == 'in_review'
                          ? _t('Обращение в работе',
                              'Murojaat ko‘rib chiqilmoqda')
                          : _t('Обращение создано в GO',
                              'GO murojaati yaratildi')),
              ] else ...[
                Wrap(
                    children: List.generate(
                        5,
                        (i) => IconButton(
                            tooltip: '${i + 1}',
                            onPressed: locked
                                ? null
                                : () => setState(() => _rating = i + 1),
                            icon: Icon(
                                i < (_rating ?? 0)
                                    ? Icons.star_rounded
                                    : Icons.star_outline_rounded,
                                color: Colors.amber)))),
                TextField(
                    controller: _comment,
                    enabled: !locked,
                    maxLength: 1000,
                    maxLines: 3,
                    decoration: InputDecoration(
                        labelText: _t('Комментарий (необязательно)',
                            'Izoh (ixtiyoriy)'))),
                if ((_rating ?? 5) <= 2)
                  Text(_t(
                      'При оценке 1–2 создадим обращение администратору GO.',
                      '1–2 baho GO administratoriga murojaat yaratadi.')),
                if (_error != null)
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                FilledButton(
                    onPressed: _busy || _rating == null ? null : _send,
                    child: Text(_busy
                        ? _t('Отправляем…', 'Yuborilmoqda…')
                        : _pending != null
                            ? _t('Повторить отправку', 'Qayta yuborish')
                            : _t('Отправить оценку', 'Bahoni yuborish'))),
              ]
            ])));
  }
}
