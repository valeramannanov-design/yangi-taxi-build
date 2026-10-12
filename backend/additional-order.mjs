// Separate intentional additional bookings from accidental retry/duplicates.
// This never authorizes an additional booking for another client.
export function shouldCheckDuplicateForNewOrder({
  additionalOrder = false,
  currentOrders,
  clientId,
}) {
  if (additionalOrder !== true) return true;
  if (!Array.isArray(currentOrders)) {
    const error = new Error('Cannot verify active orders for an additional booking');
    error.statusCode = 503;
    throw error;
  }
  const activeOwnedOrderExists = currentOrders.some((order) => {
    if (!order || typeof order !== 'object') return false;
    const id = Number(order.order_id ?? order.orderId ?? order.id);
    if (!Number.isSafeInteger(id) || id <= 0) return false;
    const owner = Number(order.client_id ?? order.clientId ?? 0);
    if (owner > 0 && owner !== Number(clientId)) return false;
    const status = String(order.state_kind ?? order.state_type ?? '')
      .trim()
      .toLowerCase();
    return !['finished', 'aborted', 'cancelled'].includes(status);
  });
  return !activeOwnedOrderExists;
}
