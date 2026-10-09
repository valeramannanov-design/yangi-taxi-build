// Authorization for TaxiMaster orders. Some TaxiMaster responses omit client_id;
// then require the order ID in the authenticated client's own current/history.
export async function assertOwnedOrder({
  orderId,
  clientId,
  state,
  loadCurrent,
  loadHistory,
}) {
  const forbidden = () => {
    const error = new Error('Forbidden');
    error.statusCode = 403;
    throw error;
  };
  const expected = Number(clientId);
  const target = Number(orderId);
  if (!Number.isSafeInteger(expected) || expected <= 0 ||
      !Number.isSafeInteger(target) || target <= 0) forbidden();

  const stateClient = Number(state?.client_id ?? state?.clientId ?? 0);
  if (Number.isSafeInteger(stateClient) && stateClient > 0) {
    if (stateClient !== expected) forbidden();
    return;
  }

  const hasOrder = (raw) => {
    const orders = Array.isArray(raw) ? raw : raw?.orders;
    return Array.isArray(orders) && orders.some((order) => {
      const id = Number(order?.order_id ?? order?.orderId ?? order?.id ?? 0);
      return id === target;
    });
  };

  // Fail closed: a missing owner ID is never proof of authorization.
  const [current, history] = await Promise.allSettled([loadCurrent(), loadHistory()]);
  if (current.status === 'fulfilled' && hasOrder(current.value)) return;
  if (history.status === 'fulfilled' && hasOrder(history.value)) return;
  if (current.status === 'rejected' || history.status === 'rejected') {
    const error = new Error('Unable to verify order ownership');
    error.statusCode = 503;
    throw error;
  }
  forbidden();
}
