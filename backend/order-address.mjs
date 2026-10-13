// Format a genuine location label for TaxiMaster order endpoints.
// Coordinates come from the passenger's selected pin or GPS position;
// they do not pretend a street name or house number was geocoded.
export function fallbackOrderAddress(value, lat, lon) {
  const label = String(value ?? '')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  // GPS-only positions must not appear to be a resolved civic address.
  const unlocated = /^(?:текущее местоположение|joriy joylashuv|current location|joylashuv aniqlanmoqda|определяем местоположение|место назначения|manzilni tanlang)$/iu;
  if (label && !unlocated.test(label)) return label.slice(0, 240);
  return `GPS ${lat.toFixed(6)}, ${lon.toFixed(6)}`;
}
