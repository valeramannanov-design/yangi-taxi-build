import test from 'node:test';
import assert from 'node:assert/strict';
import { checkDeliveryBuild, probeDeliveryBuild } from './check-delivery-build.mjs';

test('Delivery builds require explicit HTTPS and MapKit configuration', () => {
  for (const BACKEND_URL of [undefined, '', 'demo', 'http://api.example.test', 'https://user:secret@api.example.test', 'https://api.example.test/?key=secret', 'https://api.example.test/#secret']) {
    assert.throws(() => checkDeliveryBuild({ BACKEND_URL, MAPKIT_API_KEY: 'test-client-key' }));
  }
  assert.throws(() => checkDeliveryBuild({ BACKEND_URL: 'https://api.example.test' }));
  assert.equal(checkDeliveryBuild({ BACKEND_URL: 'https://api.example.test/', MAPKIT_API_KEY: 'test-client-key' }), 'https://api.example.test');
});

test('preflight rejects mock or unhealthy TM and unavailable Delivery', async () => {
  const request = health => async () => ({ ok: true, json: async () => health });
  for (const health of [{ ok: true, mock: true, tmApi: 'ok' }, { ok: true, mock: false, tmApi: 'error' }]) {
    await assert.rejects(probeDeliveryBuild('https://api.example.test', request(health)));
  }
  await assert.rejects(probeDeliveryBuild('https://api.example.test', async () => ({ ok: false, status: 503 })));
  await assert.rejects(probeDeliveryBuild('https://api.example.test', request({ ok: true, mock: false, tmApi: 'ok' })));
});

test('preflight checks actual catalog without requiring synthetic shops', async () => {
  const paths = [];
  const result = await probeDeliveryBuild('https://api.example.test', async (url, options) => {
    paths.push(url); assert.equal(options.redirect, 'error');
    return { ok: true, json: async () => url.endsWith('/health') ? { ok: true, mock: false, tmApi: 'ok' } : { ok: true, data: { categories: [], shops: [] } } };
  });
  assert.deepEqual(paths, ['https://api.example.test/health', 'https://api.example.test/api/delivery/catalog']);
  assert.equal(result.shops, 0);
});
