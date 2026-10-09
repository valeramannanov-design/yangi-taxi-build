import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createOrderRequestGuard } from './order-idempotency.mjs';

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
