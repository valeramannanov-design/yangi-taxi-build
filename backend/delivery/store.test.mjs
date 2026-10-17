import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { Worker } from 'node:worker_threads';
import { DeliveryStore, distanceMeters } from './store.mjs';

const password = 'unit-test-private-password';
const customer = { id: '101', phone: '+998900000001' };
const otherCustomer = { id: '102', phone: '+998900000002' };
const key = n => 'test-idempotency-' + n;
function cleanupTemp(dir) {
  const target = resolve(dir);
  if (dirname(target) !== resolve(tmpdir()) || !basename(target).startsWith('yangi-delivery-')) throw new Error('Refusing unexpected cleanup path');
  rmSync(target, { recursive: true, force: true });
}
function fixture(t, file = ':memory:') {
  let now = 1000000;
  const store = new DeliveryStore(file, { now: () => now }); t.after(() => store.close());
  store.createAdmin('admin', password);
  const admin = store.identity(store.login('admin', password, 'local-test').token);
  const category = store.category(admin, { name: 'Продукты', active: true });
  const zone = store.zone(admin, { name: 'Test zone', south: 39, north: 41, west: 64, east: 67, base_uzs: 3000, per_km_uzs: 1000, max_distance_m: 30000, active: true });
  const shopInput = n => ({ name: 'Store ' + n, login: 'partner' + n, password, address: 'Store address ' + n, category_id: category.id, zone_id: zone.id, lat: 40, lon: 65, commission_bps: 1250 });
  const s1 = store.createShop(admin, shopInput(1)), s2 = store.createShop(admin, shopInput(2));
  for (const s of [s1, s2]) store.updateShop(admin, s.id, { ...s, active: true });
  const p1 = store.identity(store.login('partner1', password, 'local-test').token), p2 = store.identity(store.login('partner2', password, 'local-test').token);
  const productInput = { sku: 'milk', name: 'МОЛОКО', description: 'Молоко местное', price_uzs: 10001, stock: 5, active: true, version: 1 };
  const product = store.saveProduct(p1, productInput);
  const quoteInput = { shop_id: s1.id, items: [{ product_id: product.id, quantity: 2 }], destination: { address: 'Customer address', lat: 40.001, lon: 65 } };
  return { store, admin, p1, p2, s1, s2, zone, category, product, productInput, quoteInput, clock: value => { now = value; }, quote: () => store.quote(customer, quoteInput) };
}
const status = (code, fn) => assert.throws(fn, e => e.statusCode === code);
function confirmed(f, suffix = 'primary') {
  const q = f.quote(), o = f.store.checkout(customer, { quote_id: q.id }, key(suffix));
  return f.store.merchantAction(f.p1, o.id, { action: 'confirm', version: 1 }, key('confirm-' + suffix));
}
test('migrations and checkout survive restart; quote and checkout are idempotent', t => {
  const dir = mkdtempSync(join(tmpdir(), 'yangi-delivery-'));
  const file = join(dir, 'test.sqlite'), f = fixture(t, file), q = f.quote();
  t.after(() => cleanupTemp(dir));
  const o = f.store.checkout(customer, { quote_id: q.id }, key(1));
  assert.equal(o.total_uzs, 24002); assert.equal(o.delivery_uzs, 4000); assert.equal(o.subtotal_uzs, 20002);
  assert.equal(o.commission_uzs, undefined); assert.equal(o.pricing_basis, 'straight_line_zone');
  assert.deepEqual(f.store.checkout(customer, { quote_id: q.id }, key(1)), o);
  status(409, () => f.store.checkout(customer, { quote_id: f.quote().id }, key(1)));
  status(409, () => f.store.checkout(customer, { quote_id: q.id }, key(2)));
  const reopened = new DeliveryStore(file, { now: () => 1000000 });
  try { assert.equal(reopened.orderForCustomer(customer, o.id).id, o.id); assert.equal(reopened.shop(f.s1.id).products[0].stock, 3); }
  finally { reopened.close(); }
});
test('partners cannot see or change another store products, orders, images or finance', t => {
  const f = fixture(t), q = f.quote(), o = f.store.checkout(customer, { quote_id: q.id }, key(3));
  status(403, () => f.store.createShop(f.p1, {}));
  status(404, () => f.store.saveProduct(f.p2, f.productInput, f.product.id));
  assert.deepEqual(f.store.ordersForStaff(f.p2), []);
  status(404, () => f.store.merchantAction(f.p2, o.id, { action: 'confirm', version: 1 }, key(4)));
  status(404, () => f.store.orderForCustomer(otherCustomer, o.id));
  const image = f.store.image(f.p1, Buffer.from([137,80,78,71,13,10,26,10,0,0,0,0]));
  status(422, () => f.store.saveProduct(f.p2, { ...f.productInput, image_id: image.id }));
  status(422, () => f.store.image(f.p1, Buffer.from('<svg>unsafe executable image</svg>')));
  status(422, () => f.store.image(f.p1, Buffer.alloc(2 * 1024 * 1024 + 1)));
});
test('server validates price, stock, ownership, expiry and destination', t => {
  const f = fixture(t), q = f.quote();
  status(401, () => f.store.quote({ id: 'other', phone: '123' }, f.quoteInput));
  status(409, () => f.store.checkout(otherCustomer, { quote_id: q.id }, key(5)));
  for (const coords of [{ lat: NaN, lon: 65 }, { lat: 90.1, lon: 65 }, { lat: 39.5, lon: 65 }]) status(422, () => f.store.quote(customer, { ...f.quoteInput, destination: { address: 'Customer', ...coords } }));
  status(422, () => f.store.quote(customer, { ...f.quoteInput, items: [{ product_id: f.product.id, quantity: 1 }, { product_id: f.product.id, quantity: 1 }] }));
  status(409, () => f.store.quote(customer, { ...f.quoteInput, shop_id: f.s2.id }));
  f.store.saveProduct(f.p1, { ...f.productInput, price_uzs: 20000 }, f.product.id);
  status(409, () => f.store.checkout(customer, { quote_id: q.id }, key(6)));
  assert.equal(f.store.shop(f.s1.id).products[0].stock, 5);
  f.clock(1300001); status(409, () => f.store.checkout(customer, { quote_id: q.id }, key(7)));
  assert.equal(distanceMeters({ lat: 40, lon: 65 }, { lat: 40, lon: 65 }), 0);
});
test('catalog respects blocking, Unicode search, prices and active categories', t => {
  const f = fixture(t);
  assert.equal(f.store.catalog(undefined, 'молоко').products[0].id, f.product.id);
  assert.equal(f.store.catalog(undefined, 'МолОко').products.length, 1);
  f.store.updateShop(f.admin, f.s1.id, { ...f.s1, active: false });
  assert.equal(f.store.catalog().shops.length, 1); assert.equal(f.store.catalog(undefined, 'молоко').products.length, 0);
  status(409, () => f.quote());
  f.store.category(f.admin, { name: 'Продукты', active: false }, f.category.id);
  assert.equal(f.store.catalog().shops.length, 0);
});
test('a merchant edit cannot overwrite stock reserved or restored after the form loaded', t => {
  const f = fixture(t), o = f.store.checkout(customer, { quote_id: f.quote().id }, key('stock-form'));
  status(409, () => f.store.saveProduct(f.p1, { ...f.productInput, name: 'New description' }, f.product.id));
  assert.equal(f.store.shop(f.s1.id).products[0].stock, 3);
  const latest = f.store.products(f.p1)[0];
  f.store.cancel(customer, o.id, { version: 1, reason: 'Not needed' }, key('restore-form'));
  status(409, () => f.store.saveProduct(f.p1, { ...latest, active: true, name: 'Stale form after cancellation' }, f.product.id));
  assert.equal(f.store.shop(f.s1.id).products[0].stock, 5);
});
test('migration 002 upgrades an existing v1 database and preserves its data', t => {
  const dir = mkdtempSync(join(tmpdir(), 'yangi-delivery-migration-')); t.after(() => cleanupTemp(dir));
  const path = join(dir, 'existing.sqlite'), old = new DatabaseSync(path);
  old.exec(readFileSync(new URL('./migrations/001.sql', import.meta.url), 'utf8'));
  old.exec("INSERT INTO delivery_migrations VALUES(1,1); INSERT INTO delivery_categories(name) VALUES('Existing category')");
  old.close();
  const upgraded = new DeliveryStore(path);
  try {
    assert.equal(upgraded.one('SELECT name FROM delivery_categories').name, 'Existing category');
    assert.equal(upgraded.one('SELECT max(version) AS v FROM delivery_migrations').v, 2);
    assert.ok(upgraded.all('PRAGMA table_info(delivery_products)').some(c => c.name === 'version'));
  } finally { upgraded.close(); }
});
test('cancellation and rejection restore stock once; stale commands cannot change state', t => {
  const f = fixture(t), o = f.store.checkout(customer, { quote_id: f.quote().id }, key(8));
  status(409, () => f.store.cancel(customer, o.id, { version: 2, reason: 'Changed mind' }, key(9)));
  const input = { version: 1, reason: 'Changed mind' };
  assert.equal(f.store.cancel(customer, o.id, input, key(9)).status, 'cancelled');
  assert.equal(f.store.cancel(customer, o.id, input, key(9)).status, 'cancelled');
  assert.equal(f.store.shop(f.s1.id).products[0].stock, 5);
  status(409, () => f.store.merchantAction(f.p1, o.id, { action: 'confirm', version: 1 }, key(10)));
  const second = f.store.checkout(customer, { quote_id: f.quote().id }, key(11));
  const reject = { action: 'reject', version: 1, reason: 'Product unavailable' };
  f.store.merchantAction(f.p1, second.id, reject, key(12)); f.store.merchantAction(f.p1, second.id, reject, key(12));
  assert.equal(f.store.shop(f.s1.id).products[0].stock, 5);
});
test('TM bridge rejects unbound, wrong courier and out-of-order proofs; ledger balances exactly once', t => {
  const f = fixture(t), o = confirmed(f), proof = { transport_order_id: 1234, driver_id: 5, crew_id: 4, status: 'assigned' };
  status(409, () => f.store.recordTransport(o.id, proof));
  f.store.bindTransport(o.id, 1234);
  status(409, () => f.store.recordTransport(o.id, { ...proof, transport_order_id: 5678 }));
  status(409, () => f.store.recordTransport(o.id, { ...proof, status: 'completed', cash_collected_uzs: o.total_uzs }));
  assert.equal(f.store.recordTransport(o.id, proof).status, 'assigned');
  assert.equal(f.store.recordTransport(o.id, { ...proof, status: 'accepted' }).status, 'accepted');
  f.store.merchantAction(f.p1, o.id, { action: 'ready', version: 4 }, key(13));
  assert.equal(f.store.ordersForStaff(f.p1)[0].status, 'accepted');
  assert.notEqual(f.store.ordersForStaff(f.p1)[0].ready_at, null);
  status(409, () => f.store.recordTransport(o.id, { ...proof, driver_id: 6, status: 'picked_up' }));
  f.store.recordTransport(o.id, { ...proof, status: 'picked_up' });
  status(409, () => f.store.recordTransport(o.id, { ...proof, status: 'completed', cash_collected_uzs: 0 }));
  const complete = { ...proof, status: 'completed', cash_collected_uzs: o.total_uzs };
  f.store.recordTransport(o.id, complete); f.store.recordTransport(o.id, complete);
  const rows = f.store.finance(f.admin);
  assert.equal(rows.length, 4); assert.equal(rows.reduce((s, row) => s + row.amount_uzs, 0), 0);
  assert.equal(rows.find(r => r.kind === 'service_revenue').amount_uzs, -2500);
  assert.deepEqual(f.store.finance(f.p2), []);
  assert.equal(f.store.one('SELECT count(*) AS n FROM delivery_ledger').n, 4);
});
test('one courier cannot hold two delivery jobs', t => {
  const f = fixture(t), a = confirmed(f, 'a'), b = confirmed(f, 'b');
  f.store.bindTransport(a.id, 1001); f.store.bindTransport(b.id, 1002);
  f.store.recordTransport(a.id, { transport_order_id: 1001, driver_id: 5, crew_id: 4, status: 'assigned' });
  status(409, () => f.store.recordTransport(b.id, { transport_order_id: 1002, driver_id: 5, crew_id: 4, status: 'assigned' }));
});
test('authentication expires and is revoked; password hashes and throttle persist', t => {
  const f = fixture(t), session = f.store.login('partner1', password, 'fresh-peer');
  assert.equal(f.store.identity(session.token).shop_id, f.s1.id);
  assert.notEqual(f.store.one('SELECT password_hash FROM delivery_users WHERE id=?', f.p1.id).password_hash, password);
  f.store.logout(session.token); status(401, () => f.store.identity(session.token));
  for (let i = 0; i < 10; i++) status(401, () => f.store.login('missing', 'bad', 'attacker'));
  status(429, () => f.store.login('missing', password, 'attacker'));
  const token = f.store.login('partner1', password, 'another-peer').token;
  f.clock(50_000_000); status(401, () => f.store.identity(token));
  status(409, () => f.store.createAdmin('second-admin', password));
});
test('concurrent checkout in separate workers never oversells one available item', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'yangi-delivery-race-'));
  const file = join(dir, 'test.sqlite'), f = fixture(t, file);
  t.after(() => cleanupTemp(dir));
  f.store.saveProduct(f.p1, { ...f.productInput, stock: 1 }, f.product.id);
  const input = { ...f.quoteInput, items: [{ product_id: f.product.id, quantity: 1 }] };
  const quotes = [f.store.quote(customer, input), f.store.quote(otherCustomer, input)];
  const result = await Promise.all(quotes.map((q, i) => new Promise((resolve, reject) => {
    const worker = new Worker(new URL('./checkout-worker.mjs', import.meta.url), { workerData: { file, customer: i ? otherCustomer : customer, quote_id: q.id, key: key('race-' + i) } });
    let result; worker.once('message', value => { result = value; }); worker.once('error', reject);
    worker.once('exit', code => code === 0 ? resolve(result) : reject(new Error('Checkout worker failed')));
  })));
  assert.equal(result.filter(r => r.ok).length, 1); assert.equal(result.filter(r => r.status === 409).length, 1);
  assert.equal(f.store.shop(f.s1.id).products[0].stock, 0);
  assert.equal(f.store.one('SELECT count(*) AS n FROM delivery_orders').n, 1);
});
