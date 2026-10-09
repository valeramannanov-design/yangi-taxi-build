// Per-process order creation guard. TaxiMaster check_duplicate is an additional
// safety layer, not a substitute for requestId and matching request details.
export function createOrderRequestGuard({ ttlMs = 15 * 60 * 1000, now = Date.now } = {}) {
  const completed = new Map();
  const inFlight = new Map();

  function rejectConflict() {
    const error = new Error('order requestId was already used for different order details');
    error.statusCode = 409;
    throw error;
  }

  function expire() {
    const current = now();
    for (const [key, value] of completed) {
      if (value.expiresAt <= current) completed.delete(key);
    }
  }

  return async function runIdempotentOrderRequest(clientId, requestId, fingerprint, create) {
    if (!requestId) return create(); // Older clients remain compatible.

    expire();
    const key = String(Number(clientId)) + ':' + requestId;
    const saved = completed.get(key);
    if (saved) {
      if (saved.fingerprint !== fingerprint) rejectConflict();
      return saved.data;
    }

    const pending = inFlight.get(key);
    if (pending) {
      if (pending.fingerprint !== fingerprint) rejectConflict();
      return pending.promise;
    }

    const promise = Promise.resolve().then(create).then((data) => {
      completed.set(key, {
        fingerprint,
        data,
        expiresAt: now() + ttlMs,
      });
      return data;
    });
    inFlight.set(key, { fingerprint, promise });
    try {
      return await promise;
    } finally {
      if (inFlight.get(key)?.promise === promise) inFlight.delete(key);
    }
  };
}
