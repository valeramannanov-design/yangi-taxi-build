import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { DeliveryStore } from './store.mjs';
import { createDeliveryHandler } from './http.mjs';

async function fixture(t) {
  const store = new DeliveryStore(':memory:');
  store.createAdmin('admin', 'unit-test-admin-password');
  const token = store.login('admin', 'unit-test-admin-password', 'test-peer').token;
  const admin = store.identity(token);
  const category = store.category(admin, { name: 'Shop category', active: true });
  const zone = store.zone(admin, { name: 'Zone', south: 39, north: 41, west: 64, east: 66, base_uzs: 5000, per_km_uzs: 1000, max_distance_m: 10000, active: true });
  const shop = store.createShop(admin, { name: 'Shop', address: 'Store address', lat: 40, lon: 65, category_id: category.id, zone_id: zone.id, commission_bps: 1000, login: 'partner', password: 'unit-test-partner-password' });
  store.updateShop(admin, shop.id, { ...shop, active: true });
  const partnerToken = store.login('partner', 'unit-test-partner-password', 'test-peer').token;
  const product = store.saveProduct(store.identity(partnerToken), { name: 'Milk', description: '', sku: 'milk', price_uzs: 10000, stock: 5, active: true });
  const handler = createDeliveryHandler({ store, passengerIdentity: req => {
    if (req.headers.authorization !== 'Bearer test-passenger-session') { const e = new Error('Unauthorized'); e.statusCode = 401; throw e; }
    return { id: '101', phone: '+998900000001' };
  } });
  const server = http.createServer(async (req, res) => { if (!await handler(req, res)) { res.writeHead(404); res.end('taxi host fallback'); } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); store.close(); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const request = async (path, { method = 'GET', body, authorization, key, headers = {} } = {}) => {
    const r = await fetch(base + path, { method, headers: { ...(authorization ? { authorization: 'Bearer ' + authorization } : {}), ...(key ? { 'Idempotency-Key': key } : {}), ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
    const value = await r.text(); let json; try { json = JSON.parse(value); } catch { json = null; }
    return { status: r.status, json, text: value, headers: r.headers };
  };
  return { request, token, partnerToken, shop, product, base };
}
test('HTTP auth derives identities from trusted host; role and passenger token spaces stay separate', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('/api/orders/current')).text, 'taxi host fallback');
  assert.equal((await f.request('/api/delivery/catalog')).json.data.shops.length, 1);
  assert.equal((await f.request('/api/delivery/admin/config')).status, 401);
  assert.equal((await f.request('/api/delivery/admin/config', { authorization: f.partnerToken })).status, 403);
  assert.equal((await f.request('/api/delivery/customer/orders', { authorization: f.token })).status, 401);
  assert.equal((await f.request('/api/delivery/merchant/orders', { authorization: 'test-passenger-session' })).status, 401);
  assert.equal((await f.request('/api/delivery/customer/orders', { headers: { 'x-customer-id': '101', 'x-driver-id': '5' } })).status, 401);
});
test('HTTP catalog → quote → checkout → merchant confirmation; no endpoint can forge transport completion', async t => {
  const f = await fixture(t), authorization = 'test-passenger-session';
  const q = await f.request('/api/delivery/customer/quotes', { method: 'POST', authorization, body: { shop_id: f.shop.id, items: [{ product_id: f.product.id, quantity: 1 }], destination: { address: 'Customer address', lat: 40, lon: 65 } } });
  assert.equal(q.status, 200); assert.equal(q.json.data.total_uzs, 15000);
  const body = { quote_id: q.json.data.id }, key = 'http-idempotent-order-1';
  assert.equal((await f.request('/api/delivery/customer/orders', { method: 'POST', authorization, body })).status, 422);
  const o = await f.request('/api/delivery/customer/orders', { method: 'POST', authorization, body, key });
  const retry = await f.request('/api/delivery/customer/orders', { method: 'POST', authorization, body, key });
  assert.equal(o.json.data.id, retry.json.data.id);
  const confirm = await f.request(`/api/delivery/merchant/orders/${o.json.data.id}/action`, { method: 'POST', authorization: f.partnerToken, body: { action: 'confirm', version: 1 }, key: 'http-confirm-order-1' });
  assert.equal(confirm.json.data.status, 'confirmed');
  assert.equal((await f.request(`/api/delivery/merchant/orders/${o.json.data.id}/action`, { method: 'POST', authorization: f.partnerToken, body: { action: 'complete', version: 2 }, key: 'http-forge-complete-1' })).status, 422);
  assert.equal((await f.request('/api/delivery/transport/complete', { method: 'POST', authorization: f.token, body: { order_id: o.json.data.id } })).status, 404);
  const history = await f.request('/api/delivery/customer/orders', { authorization });
  assert.equal(history.json.data[0].status, 'confirmed');
  assert.equal(history.headers.get('cache-control'), 'no-store');
});
test('HTTP rejects malformed JSON, excessive bodies and SQL-shaped identifiers', async t => {
  const f = await fixture(t);
  const bad = await fetch(f.base + '/api/delivery/auth/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{bad' });
  assert.equal(bad.status, 400); await bad.text();
  const large = await f.request('/api/delivery/auth/login', { method: 'POST', body: { login: 'admin', password: 'x'.repeat(70000) } });
  assert.equal(large.status, 413);
  assert.equal((await f.request('/api/delivery/catalog?category=1%20OR%201=1')).status, 422);
  assert.equal((await f.request('/api/delivery/shops/1%20OR%201=1')).status, 401);
});
