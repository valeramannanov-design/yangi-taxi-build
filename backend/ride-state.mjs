import { assertOwnedOrder } from './order-ownership.mjs';

function failure(message, statusCode) {
  return Object.assign(new Error(message), { statusCode });
}

function findOwnedRecord(response, orderId, clientId) {
  const orders = Array.isArray(response) ? response : response?.orders;
  if (!Array.isArray(orders)) throw failure('TaxiMaster order list is malformed', 503);
  const found = orders.find((item) =>
    item && Number(item.order_id ?? item.orderId ?? item.id) === Number(orderId)
  );
  if (!found) return null;
  const owner = Number(found.client_id ?? found.clientId ?? 0);
  if (owner > 0 && owner !== Number(clientId)) throw failure('Forbidden', 403);
  const stateKind = String(found.state_kind ?? found.state_type ?? '').toLowerCase();
  if (!stateKind) throw failure('TaxiMaster order list has no confirmed state', 503);
  return { ...found, order_id: Number(orderId), state_kind: stateKind };
}

// Read-only reconciliation of a missing detailed order with the same client's
// current/finished order lists. Never treat an absent record as cancelled.
export async function resolveOwnedRideState({
  orderId, clientId, getState, getCurrent, getHistory,
}) {
  let state;
  try {
    state = await getState();
  } catch (error) {
    const missing = /order not found|заказ не найден/i.test(String(error?.message || '')) ||
      error?.statusCode === 404 || Number(error?.tmCode) === 100;
    if (!missing) throw error;
    const [current, history] = await Promise.allSettled([getCurrent(), getHistory()]);
    if (current.status === 'fulfilled') {
      const record = findOwnedRecord(current.value, orderId, clientId);
      if (record) return { state: record, source: 'current_orders' };
    }
    if (history.status === 'fulfilled') {
      const record = findOwnedRecord(history.value, orderId, clientId);
      if (record) return { state: record, source: 'finished_orders' };
    }
    if (current.status === 'rejected' || history.status === 'rejected') {
      throw failure('TaxiMaster order status cannot be verified', 503);
    }
    throw failure('Order not found in TaxiMaster current or finished orders', 404);
  }

  await assertOwnedOrder({
    orderId, clientId, state,
    loadCurrent: getCurrent, loadHistory: getHistory,
  });
  return { state, source: 'order_state' };
}
