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

// Compatibility wrapper: pickup and the general inbox share loading/ack logic.
class GoReadyAlerts extends StatelessWidget {
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
  Widget build(BuildContext context) => GoNotificationHub(
      api: api,
      lang: lang,
      isActive: isActive,
      onOrder: onOrder,
      pickupOnly: true);
}
