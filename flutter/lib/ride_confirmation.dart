// TaxiMaster CommonAPI get_order_state reports assignment (state_kind) and
// acceptance (confirmed) independently. Driver card must stay hidden until
// the driver actually accepts. An absent confirmation is NOT acceptance.
bool isDriverAcceptanceConfirmed(Map<dynamic, dynamic> state) {
  final confirmed = (state['confirmed'] ?? '').toString().trim().toLowerCase();
  return confirmed == 'confirmed_by_driver';
}
