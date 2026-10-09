import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

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
