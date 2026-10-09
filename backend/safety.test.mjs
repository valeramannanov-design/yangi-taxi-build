import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createOrderRequestGuard } from './order-idempotency.mjs';
import { createAtomicJsonWriter } from './atomic-json-store.mjs';
import { assertOwnedOrder } from './order-ownership.mjs';
import { resolveOwnedRideState } from './ride-state.mjs';
import { mkdtemp, readFile, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const backendDir = fileURLToPath(new URL('./', import.meta.url));
const serverPath = fileURLToPath(new URL('./server.mjs', import.meta.url));
const source = readFileSync(serverPath, 'utf8');

test('LIVE backend rejects the default session secret', () => {
  const result = spawnSync(process.execPath, ['server.mjs'], {
    cwd: backendDir,
    env: {
      ...process.env,
      TM_API_MOCK: 'false',
      SESSION_SECRET: 'change-me-in-production',
      PORT: '0',
    },
    encoding: 'utf8',
    timeout: 10_000,
  });

  assert.notEqual(result.status, 0);
  assert.match(
    String(result.stderr || '') + String(result.stdout || ''),
    /SESSION_SECRET must be configured/,
  );
});

test('critical order safety invariants are present', () => {
  assert.match(source, /check_duplicate:\s*true/);
  assert.match(source, /runIdempotentOrderRequest/);
  assert.match(source, /normalizeOrderRequestId/);
  assert.match(source, /uniqueAddressParts\(\[district, street, house\]\)/);
});

test('only one LIVE settlement worker can own the process lock', () => {
  assert.match(source, /settlement-worker\.lock/);
  assert.match(source, /flag:\s*'wx'/);
  assert.match(source, /acquireSettlementWorkerLock/);
  assert.match(source, /another LIVE worker owns the lock/);
});

test('same order attempt creates once and returns the same response', async () => {
  const run = createOrderRequestGuard();
  let count = 0;
  const create = async () => {
    count += 1;
    await Promise.resolve();
    return { order_id: 123 };
  };
  const [first, second] = await Promise.all([
    run(5, 'attempt-123', 'same-body', create),
    run(5, 'attempt-123', 'same-body', create),
  ]);
  const third = await run(5, 'attempt-123', 'same-body', create);
  assert.equal(count, 1);
  assert.deepEqual(first, second);
  assert.deepEqual(third, first);
});

test('reusing a requestId with changed order details is rejected', async () => {
  const run = createOrderRequestGuard();
  const first = run(7, 'attempt-456', 'start:cash', async () => ({ order_id: 101 }));
  await assert.rejects(
    run(7, 'attempt-456', 'business:card', async () => ({ order_id: 102 })),
    { statusCode: 409 },
  );
  await first;
  await assert.rejects(
    run(7, 'attempt-456', 'business:card', async () => ({ order_id: 103 })),
    { statusCode: 409 },
  );
});

test('request attempts are isolated per client and failures can be retried', async () => {
  const run = createOrderRequestGuard();
  let count = 0;
  await assert.rejects(run(9, 'attempt-789', 'same', async () => {
    count += 1;
    throw new Error('temporary failure');
  }), /temporary failure/);
  await run(9, 'attempt-789', 'same', async () => {
    count += 1;
    return { order_id: 200 };
  });
  await run(10, 'attempt-789', 'same', async () => {
    count += 1;
    return { order_id: 201 };
  });
  assert.equal(count, 3);
});

test('concurrent JSON saves are serialized and leave a valid final snapshot', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'yangi-atomic-'));
  try {
    const file = join(dir, 'payments.json');
    const write = createAtomicJsonWriter(pathToFileURL(file));
    await Promise.all(Array.from({ length: 20 }, (_, i) => write({ sequence: i, payload: { count: i } })));
    assert.deepEqual(JSON.parse(await readFile(file, 'utf8')), { sequence: 19, payload: { count: 19 } });
    assert.deepEqual(await readdir(dir), ['payments.json']);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('financial JSON readers do not treat non-ENOENT errors as empty stores', () => {
  assert.match(source, /if \(error\?\.code !== 'ENOENT'\) throw error; \/\/ Avoid losing payment tokens/);
  assert.match(source, /if \(error\?\.code !== 'ENOENT'\) throw error; \/\/ Never silently erase payment state/);
});

test('orders reject a different explicit TaxiMaster owner', async () => {
  await assert.rejects(assertOwnedOrder({
    orderId: 42, clientId: 100, state: { client_id: 200 },
    loadCurrent: () => { throw new Error('should not call'); },
    loadHistory: () => { throw new Error('should not call'); },
  }), { statusCode: 403 });
});

test('orders without owner IDs require a matching authenticated order list', async () => {
  const base = {
    orderId: 42, clientId: 100, state: {},
    loadCurrent: async () => ({ orders: [{ order_id: 41 }] }),
    loadHistory: async () => ({ orders: [{ order_id: 42 }] }),
  };
  await assert.doesNotReject(assertOwnedOrder(base));
  await assert.rejects(assertOwnedOrder({
    ...base, loadHistory: async () => ({ orders: [{ order_id: 43 }] }),
  }), { statusCode: 403 });
  await assert.rejects(assertOwnedOrder({
    ...base, loadHistory: async () => { throw new Error('TaxiMaster unavailable'); },
  }), { statusCode: 503 });
});

test('unverified legacy registration is closed and request bodies are bounded', () => {
  assert.match(source, /Registration requires SMS verification/);
  assert.match(source, /const maxBytes = 5 \* 1024 \* 1024/);
  assert.match(source, /await getOwnedRideState\(orderId\)/);
});

test('SMS registration cannot bypass or consume a code before TaxiMaster succeeds', () => {
  assert.match(source, /registrationSendLocks\.has\(phone\)/);
  assert.match(source, /registrationCodes\.delete\(phone\);\s+return send\(res, 201/);
  assert.match(source, /The endpoint consumes the code only after registration succeeds/);
});

test('driver credit lookup requires an exact marker instead of a prefix match', () => {
  assert.ok(source.includes("String(op.comment || '').split(';').some((part) => part.trim() === marker)"));
});

test('ATMOS uncertain create cannot automatically start a second transaction', () => {
  assert.match(source, /ATMOS_CREATE_OUTCOME_UNKNOWN/);
  assert.match(source, /payment_review_required/);
  assert.match(source, /manual ATMOS reconciliation before retry/);
  assert.match(source, /if \(!record\.atmosTransactionId && record\.atmosAccount\)/);
});


test('LIVE ride routes use the scoped state reconciliation helper', () => {
  const realStart = source.indexOf('async function realRoute(');
  const helperStart = source.indexOf('  async function getOwnedRideState(');
  const mainStart = source.indexOf('const server = http.createServer', realStart);
  assert.ok(realStart > 0 && helperStart > realStart && helperStart < mainStart);
  const liveRoute = source.slice(realStart, mainStart);
  assert.equal((liveRoute.match(/await getOwnedRideState\(orderId\)/g) || []).length, 4);
});

test('missing detailed ride state recovers from the same client current list', async () => {
  const r = await resolveOwnedRideState({
    orderId: 44, clientId: 9,
    getState: async () => { throw new Error('Order not found'); },
    getCurrent: async () => ({ orders: [{ order_id: 44, client_id: 9, state_kind: 'driver_assigned' }] }),
    getHistory: async () => ({ orders: [] }),
  });
  assert.equal(r.source, 'current_orders');
  assert.equal(r.state.state_kind, 'driver_assigned');
});

test('finished ride recovery uses history and never fabricates cancellation', async () => {
  const r = await resolveOwnedRideState({
    orderId: 45, clientId: 9,
    getState: async () => { throw new Error('Order not found'); },
    getCurrent: async () => ({ orders: [] }),
    getHistory: async () => ({ orders: [{ order_id: 45, state_kind: 'finished' }] }),
  });
  assert.equal(r.source, 'finished_orders');
  assert.equal(r.state.state_kind, 'finished');
  const base = {
    orderId: 46, clientId: 9,
    getState: async () => { throw new Error('Order not found'); },
    getCurrent: async () => ({ orders: [] }),
    getHistory: async () => ({ orders: [] }),
  };
  await assert.rejects(resolveOwnedRideState(base), { statusCode: 404 });
  await assert.rejects(resolveOwnedRideState({
    ...base, getHistory: async () => { throw new Error('network unavailable'); },
  }), { statusCode: 503 });
});

test('ride recovery blocks mismatched owners and unrelated TaxiMaster failures', async () => {
  const common = { orderId: 50, clientId: 9 };
  await assert.rejects(resolveOwnedRideState({
    ...common,
    getState: async () => { throw new Error('Order not found'); },
    getCurrent: async () => ({ orders: [{ order_id: 50, client_id: 7, state_kind: 'new_order' }] }),
    getHistory: async () => ({ orders: [] }),
  }), { statusCode: 403 });
  await assert.rejects(resolveOwnedRideState({
    ...common,
    getState: async () => { throw new Error('TaxiMaster timeout'); },
    getCurrent: async () => ({ orders: [] }),
    getHistory: async () => ({ orders: [] }),
  }), /TaxiMaster timeout/);
});

test('TaxiMaster code 100 recovers an authenticated current order even with a localized error', async () => {
  const result = await resolveOwnedRideState({
    orderId: 810, clientId: 51,
    getState: async () => { throw Object.assign(new Error('Не найден заказ ИД=810'), { tmCode: 100 }); },
    getCurrent: async () => ({ orders: [{ id: 810, client_id: 51, state_kind: 'new_order' }] }),
    getHistory: async () => ({ orders: [] }),
  });
  assert.equal(result.state.order_id, 810);
  assert.equal(result.state.state_kind, 'new_order');
  assert.equal(result.source, 'current_orders');
});

test('do not misinterpret unrelated TaxiMaster code 100 as a valid ride state', async () => {
  await assert.rejects(resolveOwnedRideState({
    orderId: 811, clientId: 51,
    getState: async () => { throw Object.assign(new Error('Заказ не найден'), { tmCode: 100 }); },
    getCurrent: async () => ({ orders: [] }),
    getHistory: async () => ({ orders: [] }),
  }), { statusCode: 404 });
});
