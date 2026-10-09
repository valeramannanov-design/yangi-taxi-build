// CommonAPI can report a crew assignment before driver acceptance.
// A detailed current-order record sometimes omits the confirmation flag.
// Never override explicit "not_confirmed".
bool isDriverAcceptanceConfirmed(Map<dynamic, dynamic> state) {
  final confirmed = (state['confirmed'] ?? '').toString().trim().toLowerCase();
  return confirmed == 'confirmed_by_driver';
}

bool canDisplayConfirmedAssignment(Map<dynamic, dynamic> state) {
  final kind = (state['state_kind'] ?? '').toString().trim().toLowerCase();
  if (kind != 'driver_assigned') return false;
  final crewId = int.tryParse((state['crew_id'] ?? '').toString()) ?? 0;
  if (crewId <= 0) return false;
  final confirmed = (state['confirmed'] ?? '').toString().trim().toLowerCase();
  if (confirmed == 'not_confirmed') return false;
  if (confirmed == 'confirmed_by_driver' || confirmed == 'confirmed_by_oper') {
    return true;
  }
  if (confirmed.isNotEmpty) return false;

  // Legacy/fallback status: if the detailed confirmation field is absent,
  // independently identified assigned driver + vehicle prove the assignment.
  // "crew_id" or a model/number alone is NOT enough.
  final driverId = int.tryParse((state['driver_id'] ?? '').toString()) ?? 0;
  final carId = int.tryParse((state['car_id'] ?? '').toString()) ?? 0;
  return driverId > 0 && carId > 0;
}
