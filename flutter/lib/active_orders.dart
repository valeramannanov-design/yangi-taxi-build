/// Current orders returned by the authenticated passenger endpoint.
/// Keep only usable IDs; no order is cancelled or recreated when switching.
List<Map<String, dynamic>> currentPassengerOrders(dynamic response) {
  if (response is! List) return <Map<String, dynamic>>[];
  final orders = <Map<String, dynamic>>[];
  final seenIds = <int>{};
  for (final item in response) {
    if (item is! Map) continue;
    final rawId = item['order_id'] ?? item['orderId'] ?? item['id'];
    final id = rawId is num ? rawId.toInt() : int.tryParse(rawId?.toString() ?? '');
    if (id == null || id <= 0 || !seenIds.add(id)) continue;
    final state = (item['state_kind'] ?? item['state_type'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (state == 'finished' || state == 'aborted' || state == 'cancelled') {
      continue;
    }
    orders.add(<String, dynamic>{...item, 'order_id': id});
  }
  return orders;
}

/// Prefer the latest order the passenger opened, not the API list's first item.
int? preferredPassengerOrderId(List<Map<String, dynamic>> orders, int? savedId) {
  if (savedId != null && orders.any((order) => order['order_id'] == savedId)) {
    return savedId;
  }
  return orders.isEmpty ? null : orders.first['order_id'] as int;
}
