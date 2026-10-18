import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { Worker } from 'node:worker_threads';
import { DeliveryStore, distanceMeters } from './store.mjs';
import { DeliveryTransport } from './transport.mjs';

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
test('admin catalog edits preserve shop ownership, image isolation and stock versions', t => {
  const f=fixture(t);
  status(403,()=>f.store.adminProducts(f.p1,f.s1.id));
  status(403,()=>f.store.adminSaveProduct(f.p1,f.s1.id,f.productInput));
  status(404,()=>f.store.adminProducts(f.admin,9999));
  const saved=f.store.adminSaveProduct(f.admin,f.s1.id,{...f.productInput,name:'Updated',stock:85,version:f.product.version},f.product.id);
  assert.equal(saved.stock,85);
  assert.equal(f.store.products(f.p1)[0].name,'Updated');
  status(409,()=>f.store.saveProduct(f.p1,{...f.productInput,stock:999,version:f.product.version},f.product.id));
  status(404,()=>f.store.adminSaveProduct(f.admin,f.s2.id,{...f.productInput,version:saved.version},saved.id));
  const png=Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),Buffer.alloc(20)]);
  const image=f.store.adminImage(f.admin,f.s2.id,png);
  status(422,()=>f.store.adminSaveProduct(f.admin,f.s1.id,{...f.productInput,sku:'other',image_id:image.id}));
  status(403,()=>f.store.adminImage(f.p1,f.s1.id,png));
  assert.equal(f.store.adminProducts(f.admin,f.s2.id).length,0);
});
function confirmed(f, suffix = 'primary') {
  const q = f.quote(), o = f.store.checkout(customer, { quote_id: q.id }, key(suffix));
  return f.store.merchantAction(f.p1, o.id, { action: 'confirm', version: 1 }, key('confirm-' + suffix));
}
function managementFixture(f) {
  const remote=new Map();let created=0,cancelled=0,lost=false;
  const adapter={
    prepare:async job=>({driver_id:job.crew_id+1,body:{crew_id:job.crew_id,tariff_id:job.tariff_id,customer:job.marker}}),
    create:async body=>{const order_id=9000+(++created);remote.set(order_id,{order_id,customer:body.customer,client_id:101,driver_id:body.crew_id+1,crew_id:body.crew_id,tariff_id:body.tariff_id,total_sum:4000,state_kind:'driver_assigned',confirmed:'not_confirmed'});return {order_id};},
    read:async id=>remote.get(id),find:async()=>[],
    prepareCancel:async job=>({order_id:job.transport_order_id,new_state:88,cancel_order_penalty_sum:0}),
    cancel:async plan=>{cancelled++;remote.get(plan.order_id).state_kind='aborted';if(lost)throw new Error('Response lost');},
  };
  return {transport:new DeliveryTransport(f.store,adapter),remote,adapter,counts:()=>({created,cancelled}),lose:()=>{lost=true;}};
}

test('admin local cancellation is idempotent and prevents queued transport creation',async t=>{
  const f=fixture(t),o=confirmed(f),m=managementFixture(f);
  m.transport.dispatch(f.admin,o.id,{crew_id:4,tariff_id:3,version:o.version},key('local-dispatch'));
  const input={action:'cancel',version:o.version,reason:'Test cancellation'};
  status(403,()=>m.transport.management.request(f.p1,o.id,input,key('local-cancel')));
  m.transport.management.request(f.admin,o.id,input,key('local-cancel'));
  m.transport.management.request(f.admin,o.id,input,key('local-cancel'));
  await m.transport.tick();assert.equal(m.counts().created,0);
  assert.equal(f.store.orderForCustomer(customer,o.id).status,'cancelled');
  assert.equal(f.store.shop(f.s1.id).products[0].stock,5);
});

test('bound cancellation waits for real TM abort proof before restoring stock exactly once',async t=>{
  const f=fixture(t),o=confirmed(f),m=managementFixture(f);
  m.transport.dispatch(f.admin,o.id,{crew_id:4,tariff_id:3,version:o.version},key('bound-dispatch'));await m.transport.tick();
  const input={action:'cancel',version:f.store.orderForCustomer(customer,o.id).version,reason:'Cancel before pickup',cancel_state_id:88};
  m.transport.management.request(f.admin,o.id,input,key('bound-cancel'));
  assert.equal(f.store.shop(f.s1.id).products[0].stock,3);
  await m.transport.tick();await m.transport.tick();
  assert.equal(m.counts().cancelled,1);assert.equal(f.store.orderForCustomer(customer,o.id).status,'cancelled');
  assert.equal(f.store.shop(f.s1.id).products[0].stock,5);assert.equal(f.store.finance(f.admin).length,0);
});

test('reassignment reconciles a lost cancel response, archives old transport and retains goods',async t=>{
  const f=fixture(t),o=confirmed(f),m=managementFixture(f);
  m.transport.dispatch(f.admin,o.id,{crew_id:4,tariff_id:3,version:o.version},key('replace-dispatch'));await m.transport.tick();
  m.lose();m.transport.management.request(f.admin,o.id,{action:'reassign',crew_id:6,tariff_id:3,cancel_state_id:88,version:f.store.orderForCustomer(customer,o.id).version,reason:'Other courier'},key('replace-command'));
  const second=confirmed(f,'other');
  status(409,()=>m.transport.dispatch(f.admin,second.id,{crew_id:6,tariff_id:3,version:second.version},key('reserved-target')));
  await m.transport.tick();assert.equal(m.counts().created,1);assert.equal(f.store.one('SELECT phase FROM delivery_management').phase,'uncertain');
  await new DeliveryTransport(f.store,m.adapter).tick();
  assert.equal(m.counts().cancelled,1);assert.equal(m.counts().created,2);
  const fresh=f.store.orderForCustomer(customer,o.id);assert.equal(fresh.transport_order_id,9002);assert.equal(fresh.driver_id,7);
  assert.equal(f.store.one('SELECT transport_order_id FROM delivery_transport_history').transport_order_id,9001);
  assert.equal(f.store.shop(f.s1.id).products[0].stock,1);assert.equal(f.store.finance(f.admin).length,0);
});

test('pickup authorization and management cannot race into a false stock restoration',async t=>{
  const f=fixture(t),o=confirmed(f),m=managementFixture(f);
  m.transport.dispatch(f.admin,o.id,{crew_id:4,tariff_id:3,version:o.version},key('pickup-dispatch'));await m.transport.tick();
  m.remote.get(9001).state_kind='car_at_place';
  await assert.rejects(m.transport.authorizePickup(9001,{driver_id:5,crew_id:4}),e=>e.statusCode===409);
  const current=f.store.orderForCustomer(customer,o.id);
  f.store.merchantAction(f.p1,o.id,{action:'ready',version:current.version},key('ready-pickup'));
  await m.transport.authorizePickup(9001,{driver_id:5,crew_id:4});await m.transport.authorizePickup(9001,{driver_id:5,crew_id:4});
  assert.equal(f.store.one('SELECT count(*) AS n FROM delivery_pickup_authorizations').n,1);
  status(409,()=>m.transport.management.request(f.admin,o.id,{action:'cancel',version:f.store.orderForCustomer(customer,o.id).version,reason:'Too late'},key('late-cancel')));
  m.remote.get(9001).state_kind='aborted';await m.transport.tick();
  assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase,'review');assert.equal(f.store.shop(f.s1.id).products[0].stock,3);
});

test('restored bound assignment recovers by reads only, once and with exact identity',async t=>{
  const f=fixture(t),o=confirmed(f),m=managementFixture(f);
  m.transport.dispatch(f.admin,o.id,{crew_id:4,tariff_id:3,version:o.version},key('recover-dispatch'));await m.transport.tick();
  const remote=m.remote.get(9001),original={...remote,is_prior:false};
  remote.crew_id=0;remote.driver_id=0;await m.transport.tick();
  assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase,'review');
  for (const change of [{driver_id:9},{crew_id:8},{client_id:102},{customer:'other'},{tariff_id:8},{total_sum:5000},{is_prior:true},{state_kind:'client_inside'},{state_kind:'finished'}]) {
    Object.assign(remote,original,change);await m.transport.tick();
    assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase,'review');
  }
  Object.assign(remote,original);await new DeliveryTransport(f.store,m.adapter).tick();await m.transport.tick();
  assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase,'bound');
  assert.deepEqual(m.counts(),{created:1,cancelled:0});
  assert.equal(f.store.one("SELECT count(*) AS n FROM delivery_events WHERE action='transport_assignment_restored'").n,1);
  assert.equal(f.store.finance(f.admin).length,0);assert.equal(f.store.shop(f.s1.id).products[0].stock,3);
});

test('assignment recovery cannot bypass pickup proof, management or creation review',async t=>{
  const f=fixture(t),o=confirmed(f),m=managementFixture(f);
  m.transport.dispatch(f.admin,o.id,{crew_id:4,tariff_id:3,version:o.version},key('guard-recovery'));await m.transport.tick();
  const remote=m.remote.get(9001);remote.is_prior=false;
  f.store.run("UPDATE delivery_transport_jobs SET phase='review',last_error='Transport identity or assignment does not match'");
  await m.transport.tick();assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase,'review');
  f.store.run("UPDATE delivery_transport_jobs SET phase='review',last_error='Transport assignment or amount changed'");
  f.store.run("UPDATE delivery_transport_jobs SET phase='bound'");
  const action=m.transport.management.request(f.admin,o.id,{action:'cancel',cancel_state_id:88,version:f.store.orderForCustomer(customer,o.id).version,reason:'Test management gate'},key('recovery-gate'));
  f.store.run("UPDATE delivery_transport_jobs SET phase='review',last_error='Transport assignment or amount changed'");
  f.store.run("UPDATE delivery_management SET phase='review' WHERE id=?",action.action_id);
  await m.transport.tick();assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase,'review');
  f.store.run("UPDATE delivery_management SET phase='blocked' WHERE id=?",action.action_id);
  f.store.run('INSERT INTO delivery_pickup_authorizations VALUES(?,?,?,?,?)',o.id,9001,5,4,f.store.now());
  await m.transport.tick();assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase,'review');
  assert.deepEqual(m.counts(),{created:1,cancelled:0});assert.equal(f.store.finance(f.admin).length,0);
});

test('a queued dispatcher action blocks pickup, cash and ambiguous creation changes',async t=>{
  const f=fixture(t),o=confirmed(f),m=managementFixture(f);
  m.transport.dispatch(f.admin,o.id,{crew_id:4,tariff_id:3,version:o.version},key('gate-dispatch'));await m.transport.tick();
  m.transport.management.request(f.admin,o.id,{action:'cancel',cancel_state_id:88,version:f.store.orderForCustomer(customer,o.id).version,reason:'Cancel'},key('gate-cancel'));
  await assert.rejects(m.transport.authorizePickup(9001,{driver_id:5,crew_id:4}));
  await assert.rejects(m.transport.confirmCash(9001,{driver_id:5,crew_id:4},o.total_uzs));
  assert.equal((await m.transport.info(9001,{driver_id:5,crew_id:4})).delivery.management_pending,true);
});

test('unresolved creation cannot be cancelled and missing-write restart does not send cancellation',async t=>{
  const f=fixture(t),o=confirmed(f),m=managementFixture(f);
  m.transport.dispatch(f.admin,o.id,{crew_id:4,tariff_id:3,version:o.version},key('uncertain-management'));
  f.store.run("UPDATE delivery_transport_jobs SET phase='uncertain'");
  status(409,()=>m.transport.management.request(f.admin,o.id,{action:'cancel',version:o.version,reason:'Unknown creation'},key('uncertain-management-cancel')));
  f.store.run("UPDATE delivery_transport_jobs SET phase='queued'");await m.transport.tick();
  const action=m.transport.management.request(f.admin,o.id,{action:'cancel',cancel_state_id:88,version:f.store.orderForCustomer(customer,o.id).version,reason:'Before write'},key('interrupted-cancel'));
  f.store.run("UPDATE delivery_management SET phase='sending' WHERE id=?",action.action_id);
  await m.transport.tick();assert.equal(m.counts().cancelled,0);
  assert.equal(f.store.one('SELECT phase FROM delivery_management').phase,'blocked');
  assert.equal(f.store.orderForCustomer(customer,o.id).status,'assigned');
});

test('known cancellation rejection releases management gate without changing stock or transport',async t=>{
  const f=fixture(t),o=confirmed(f),m=managementFixture(f);
  m.transport.dispatch(f.admin,o.id,{crew_id:4,tariff_id:3,version:o.version},key('rejected-cancel-dispatch'));await m.transport.tick();
  m.adapter.cancel=async()=>{throw Object.assign(new Error('TM rejected'),{tmCode:107});};
  m.transport.management.request(f.admin,o.id,{action:'cancel',cancel_state_id:88,version:f.store.orderForCustomer(customer,o.id).version,reason:'Cancel'},key('rejected-cancel-command'));
  await m.transport.tick();assert.equal(f.store.one('SELECT phase FROM delivery_management').phase,'blocked');
  assert.equal(f.store.orderForCustomer(customer,o.id).status,'assigned');assert.equal(f.store.shop(f.s1.id).products[0].stock,3);
  assert.equal((await m.transport.info(9001,{driver_id:5,crew_id:4})).delivery.management_pending,false);
});
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
test('migrations upgrade an existing v1 database and preserve its data', t => {
  const dir = mkdtempSync(join(tmpdir(), 'yangi-delivery-migration-')); t.after(() => cleanupTemp(dir));
  const path = join(dir, 'existing.sqlite'), old = new DatabaseSync(path);
  old.exec(readFileSync(new URL('./migrations/001.sql', import.meta.url), 'utf8'));
  old.exec("INSERT INTO delivery_migrations VALUES(1,1); INSERT INTO delivery_categories(name) VALUES('Existing category')");
  old.close();
  const upgraded = new DeliveryStore(path);
  try {
    assert.equal(upgraded.one('SELECT name FROM delivery_categories').name, 'Existing category');
    assert.equal(upgraded.one('SELECT max(version) AS v FROM delivery_migrations').v, 14);
    assert.ok(upgraded.all('PRAGMA table_info(delivery_shops)').some(c => c.name === 'service_kind'));
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

test('transport outbox reconciles a lost creation response without another POST', async t => {
  const f = fixture(t), o = confirmed(f), input = { crew_id: 4, tariff_id: 3, version: o.version };
  let posts = 0, remote = null;
  const adapter = {
    prepare: async job => ({ driver_id: 5, body: { customer: job.marker } }),
    create: async body => { posts++; remote = { order_id: 7001, customer: body.customer, client_id: 101, driver_id: 5, crew_id: 4, tariff_id: 3, total_sum: o.delivery_uzs }; throw new Error('Response lost'); },
    find: async () => remote ? [remote] : [], read: async () => remote,
  };
  const transport = new DeliveryTransport(f.store, adapter);
  status(403, () => transport.dispatch(f.p1, o.id, input, key('dispatch')));
  assert.deepEqual(transport.dispatch(f.admin, o.id, input, key('dispatch')), { order_id: o.id, phase: 'queued' });
  transport.dispatch(f.admin, o.id, input, key('dispatch'));
  await transport.tick(); assert.equal(posts, 1);
  assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase, 'uncertain');
  await new DeliveryTransport(f.store, adapter).tick();
  await transport.tick();
  assert.equal(posts, 1); assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase, 'bound');
  assert.equal(f.store.orderForCustomer(customer, o.id).transport_order_id, 7001);
  assert.equal(f.store.one('SELECT count(*) AS n FROM delivery_ledger').n, 0);
  const second = confirmed(f, 'second-dispatch');
  status(409, () => transport.dispatch(f.admin, second.id, { ...input, version: second.version }, key('dispatch-second')));
});

test('uncertain, crashed and mismatched transport jobs never create duplicates', async t => {
  const f = fixture(t), o = confirmed(f);
  let posts = 0, matches = [];
  const adapter = { prepare: async job => ({ driver_id: 5, body: { customer: job.marker } }), create: async () => { posts++; throw Object.assign(new Error('Duplicate'), { tmCode: 100 }); }, find: async () => matches };
  const transport = new DeliveryTransport(f.store, adapter);
  transport.dispatch(f.admin, o.id, { crew_id: 4, tariff_id: 3, version: o.version }, key('uncertain'));
  await transport.tick(); await transport.tick(); assert.equal(posts, 1);
  assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase, 'uncertain');
  matches = [{ order_id: 7002, customer: 'YANGI_DELIVERY/' + o.id, client_id: 101, driver_id: 99, crew_id: 4, tariff_id: 3, total_sum: o.delivery_uzs }];
  await transport.tick(); assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase, 'review');
  assert.equal(f.store.orderForCustomer(customer, o.id).transport_order_id, null);
  f.store.run("UPDATE delivery_transport_jobs SET phase='creating',request_json=NULL");
  matches = [];
  await new DeliveryTransport(f.store, adapter).tick(); assert.equal(posts, 1);
});

test('concurrent transport workers claim one request; offline courier prevents POST', async t => {
  const f = fixture(t), o = confirmed(f);
  let posts = 0;
  const adapter = { prepare: async () => { throw new Error('Offline'); }, create: async () => { posts++; }, find: async () => [] };
  const transport = new DeliveryTransport(f.store, adapter);
  transport.dispatch(f.admin, o.id, { crew_id: 4, tariff_id: 3, version: o.version }, key('offline'));
  await Promise.all([transport.tick(), new DeliveryTransport(f.store, adapter).tick()]);
  assert.equal(posts, 0); assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase, 'blocked');
});

test('TaxiMaster lifecycle restores delivery state; only exact cash plus finished TM writes finance', async t => {
  const f = fixture(t), o = confirmed(f);
  let remote;
  const adapter = {
    prepare: async job => ({ driver_id: 5, body: { customer: job.marker } }),
    create: async body => { remote = { order_id: 8001, customer: body.customer, client_id: 101, driver_id: 5, crew_id: 4, tariff_id: 3, total_sum: o.delivery_uzs, state_kind: 'driver_assigned', confirmed: 'not_confirmed', cash_sum: o.delivery_uzs, cashless_sum: 0, bonus_sum: 0, bank_card_sum: 0 }; return { order_id: 8001 }; },
    read: async () => remote, find: async () => [],
  };
  const transport = new DeliveryTransport(f.store, adapter);
  transport.dispatch(f.admin, o.id, { crew_id: 4, tariff_id: 3, version: o.version }, key('lifecycle'));
  await transport.tick(); assert.equal(f.store.orderForCustomer(customer, o.id).status, 'assigned');
  const details = (await transport.info(8001, { driver_id:5, crew_id:4 })).delivery;
  assert.equal(details.total_uzs,o.total_uzs);assert.equal(details.commission_uzs,undefined);
  await assert.rejects(transport.info(8001, { driver_id:6, crew_id:4 }),e=>e.statusCode===403);
  remote.confirmed = 'confirmed_by_oper'; await transport.tick();
  assert.equal(f.store.orderForCustomer(customer, o.id).status, 'assigned');
  remote.confirmed = 'confirmed_by_driver'; await transport.tick();
  assert.equal(f.store.orderForCustomer(customer, o.id).status, 'accepted');
  remote.state_kind = 'client_inside'; await new DeliveryTransport(f.store, adapter).tick();
  assert.equal(f.store.orderForCustomer(customer, o.id).status, 'picked_up');
  await assert.rejects(transport.confirmCash(8001, { driver_id: 6, crew_id: 4 }, o.total_uzs), e => e.statusCode === 403);
  await assert.rejects(transport.confirmCash(8001, { driver_id: 5, crew_id: 4 }, o.delivery_uzs), e => e.statusCode === 409);
  remote.state_kind = 'finished'; await transport.tick();
  assert.equal(f.store.orderForCustomer(customer, o.id).status, 'picked_up');
  await transport.confirmCash(8001, { driver_id: 5, crew_id: 4 }, o.total_uzs);
  await transport.confirmCash(8001, { driver_id: 5, crew_id: 4 }, o.total_uzs);
  remote.cash_sum = 0; await transport.tick(); assert.equal(f.store.finance(f.admin).length, 0);
  remote.cash_sum = o.delivery_uzs; await transport.tick(); await transport.tick();
  assert.equal(f.store.orderForCustomer(customer, o.id).status, 'completed');
  assert.equal(f.store.one('SELECT count(*) AS n FROM delivery_cash_receipts').n, 1);
  assert.equal(f.store.finance(f.admin).length, 4);
  assert.equal(f.store.finance(f.admin).reduce((sum, r) => sum + r.amount_uzs, 0), 0);
});

test('unresolved transport jobs cannot starve dispatches beyond the worker batch limit', async t => {
  const f=fixture(t);f.store.saveProduct(f.p1,{...f.productInput,stock:1000},f.product.id);
  let posts=0;
  const adapter={prepare:async()=>({driver_id:5,body:{}}),create:async()=>{posts++;throw new Error('Lost response');},find:async()=>[]};
  const transport=new DeliveryTransport(f.store,adapter);
  for(let i=0;i<22;i++){
    const o=confirmed(f,'batch-'+i);
    transport.dispatch(f.admin,o.id,{crew_id:i+1,tariff_id:3,version:o.version},key('batch-'+i));
  }
  f.clock(1001000);await transport.tick();assert.equal(posts,20);
  f.clock(1002000);await transport.tick();assert.equal(posts,22);
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
