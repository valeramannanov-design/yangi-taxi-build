/** Durable transport outbox. Adapter methods below are internal interfaces,
 * not additional TaxiMaster endpoints. An uncertain POST is never sent again. */
import { DeliveryError } from './store.mjs';
import { DeliveryManagement } from './management.mjs';
const fail = (code, message) => { throw new DeliveryError(code, message); };
const positive = value => {
  if (!Number.isSafeInteger(value) || value < 1 || value > 2147483647) fail(422, 'Invalid transport identifier');
  return value;
};

export class DeliveryTransport {
  constructor(store, adapter) { this.store = store; this.adapter = adapter; this.running = false; this.management=new DeliveryManagement(this); }
  dispatch(user, orderId, input, key) {
    const s = this.store; s.admin(user);
    const crew = positive(input.crew_id), tariff = positive(input.tariff_id), version = positive(input.version);
    return s.command('admin:' + user.id, key, { action: 'dispatch', orderId, crew, tariff, version }, () => {
      const order = s.one('SELECT * FROM delivery_orders WHERE id=?', orderId);
      if (!order) fail(404, 'Order not found');
      if (order.version !== version || !['confirmed', 'ready'].includes(order.status) || order.transport_order_id !== null) fail(409, 'Order cannot be dispatched');
      const quoted=JSON.parse(order.snapshot);
      if(quoted.delivery_tariff_id && tariff!==quoted.delivery_tariff_id)fail(409,'Use the tariff of the confirmed delivery quote');
      if (s.one('SELECT 1 FROM delivery_transport_jobs WHERE order_id=?', orderId)) fail(409, 'Dispatch already requested; reconcile its result');
      this.management.reserveCrew(orderId,crew);
      if (s.one("SELECT 1 FROM delivery_transport_jobs j JOIN delivery_orders o ON o.id=j.order_id WHERE j.crew_id=? AND (j.phase IN ('queued','creating','uncertain','review') OR (j.phase='bound' AND o.status NOT IN ('completed','cancelled','rejected')))", crew) || s.one("SELECT 1 FROM delivery_orders WHERE crew_id=? AND status IN ('assigned','accepted','picked_up')", crew)) fail(409, 'Courier already reserved');
      s.run("INSERT INTO delivery_transport_jobs(order_id,marker,crew_id,tariff_id,phase,created_at,updated_at) VALUES(?,?,?,?,'queued',?,?)", orderId, 'YANGI_DELIVERY/' + orderId, crew, tariff, s.now(), s.now());
      s.event(orderId, 'admin:' + user.id, 'dispatch_requested');
      return { order_id: orderId, phase: 'queued' };
    });
  }
  setPhase(id, phase, message = '') {
    this.store.run("UPDATE delivery_transport_jobs SET phase=?,last_error=?,updated_at=? WHERE order_id=? AND phase IN ('creating','uncertain')", phase, message, this.store.now(), id);
  }
  async tick() {
    if (this.running) return;
    this.running = true;
    try {
      await this.management.tick();
      for (const job of this.store.all("SELECT j.* FROM delivery_transport_jobs j JOIN delivery_orders o ON o.id=j.order_id WHERE j.phase='review' AND j.last_error='Transport assignment or amount changed' AND o.transport_order_id=j.transport_order_id AND o.status IN ('confirmed','ready','assigned','accepted') ORDER BY j.updated_at LIMIT 20")) {
        this.store.run('UPDATE delivery_transport_jobs SET updated_at=? WHERE order_id=?', this.store.now(), job.order_id);
        try { await this.recoverAssignment(job); } catch { /* Reads cannot authorize a changed or unavailable transport. */ }
      }
      for (const job of this.store.all("SELECT * FROM delivery_transport_jobs WHERE phase IN ('queued','creating','uncertain') ORDER BY updated_at,created_at LIMIT 20")) {
        this.store.run('UPDATE delivery_transport_jobs SET updated_at=? WHERE order_id=?', this.store.now(), job.order_id);
        try { if (job.phase === 'queued') await this.create(job); else await this.reconcile(job); }
        catch { /* Keep durable intent and reconcile on the next pass. Never log PII. */ }
      }
      for (const job of this.store.all("SELECT j.* FROM delivery_transport_jobs j JOIN delivery_orders o ON o.id=j.order_id WHERE j.phase='bound' AND o.status NOT IN ('completed','cancelled','rejected') ORDER BY j.updated_at LIMIT 20")) {
        this.store.run('UPDATE delivery_transport_jobs SET updated_at=? WHERE order_id=?', this.store.now(), job.order_id);
        try { await this.synchronize(job); } catch { /* A failed read cannot change the last confirmed state. */ }
      }
    } finally { this.running = false; }
  }
  async create(job) {
    const s = this.store;
    if(this.management.active(job.order_id))return;
    // Cross-process claim occurs before any remote write. A crashed owner leaves
    // 'creating', which all successors reconcile rather than re-send.
    if (!s.run("UPDATE delivery_transport_jobs SET phase='creating',updated_at=? WHERE order_id=? AND phase='queued'", s.now(), job.order_id).changes) return;
    let request;
    try {
      const order = s.one('SELECT * FROM delivery_orders WHERE id=?', job.order_id);
      if (!['confirmed', 'ready'].includes(order.status) || order.transport_order_id !== null) throw new Error('State changed');
      request = await this.adapter.prepare(job, order, JSON.parse(order.snapshot));
      s.run('UPDATE delivery_transport_jobs SET request_json=? WHERE order_id=?', JSON.stringify(request), job.order_id);
    } catch { this.setPhase(job.order_id, 'blocked', 'Courier, tariff or order validation failed'); return; }
    let result;
    try { result = await this.adapter.create(request.body); }
    catch (e) {
      // Only an explicit TM protocol rejection proves that no order was made.
      this.setPhase(job.order_id, Number.isInteger(e.tmCode) && e.tmCode > 100 ? 'blocked' : 'uncertain', 'TaxiMaster creation requires reconciliation');
      return;
    }
    const tmId = Number(result?.order_id);
    if (!Number.isSafeInteger(tmId) || tmId < 1) { this.setPhase(job.order_id, 'uncertain', 'Creation response did not identify an order'); return; }
    s.run('UPDATE delivery_transport_jobs SET transport_order_id=? WHERE order_id=?', tmId, job.order_id);
    await this.reconcile({ ...job, transport_order_id: tmId });
  }
  async reconcile(job) {
    const s = this.store, order = s.one('SELECT * FROM delivery_orders WHERE id=?', job.order_id);
    const matches = job.transport_order_id ? [await this.adapter.read(job.transport_order_id)] : await this.adapter.find(job, order);
    if (matches.length !== 1) {
      this.setPhase(job.order_id, matches.length > 1 ? 'review' : 'uncertain', 'Transport creation result is unresolved'); return;
    }
    const found = matches[0], snapshot = JSON.parse(order.snapshot);
    const saved = s.one('SELECT request_json FROM delivery_transport_jobs WHERE order_id=?', job.order_id);
    const expected = saved.request_json ? JSON.parse(saved.request_json) : null;
    if (!expected || found.customer !== job.marker || String(found.client_id) !== order.customer_id || Number(found.crew_id) !== job.crew_id || Number(found.driver_id) !== expected.driver_id || Number(found.tariff_id) !== job.tariff_id || Number(found.total_sum) !== snapshot.delivery_uzs || !Number.isSafeInteger(Number(found.order_id)) || Number(found.order_id) < 1) {
      this.setPhase(job.order_id, 'review', 'Transport identity or assignment does not match'); return;
    }
    s.transaction(() => {
      // Bind and mark outbox atomically; repeated reconciliation is harmless.
      const current = s.one('SELECT * FROM delivery_orders WHERE id=?', order.id);
      if (s.one('SELECT phase FROM delivery_transport_jobs WHERE order_id=?', order.id).phase === 'bound') return;
      if (current.transport_order_id !== null && current.transport_order_id !== Number(found.order_id)) fail(409, 'Another transport is bound');
      if (!['confirmed', 'ready'].includes(current.status)) fail(409, 'Order changed during dispatch');
      s.run('UPDATE delivery_orders SET transport_order_id=? WHERE id=?', Number(found.order_id), order.id);
      s.run("UPDATE delivery_transport_jobs SET transport_order_id=?,phase='bound',last_error='',updated_at=? WHERE order_id=?", Number(found.order_id), s.now(), order.id);
      s.event(order.id, 'tm-transport:' + found.order_id, 'transport_bound');
    });
  }
  verify(job, order, found) {
    const expected = JSON.parse(job.request_json), snapshot = JSON.parse(order.snapshot);
    if (Number(found.order_id) !== job.transport_order_id || found.customer !== job.marker || String(found.client_id) !== order.customer_id || found.driver_id !== expected.driver_id || found.crew_id !== job.crew_id || found.tariff_id !== job.tariff_id || Number(found.total_sum) !== snapshot.delivery_uzs) fail(409, 'TaxiMaster transport proof changed');
    return snapshot;
  }
  async recoverAssignment(job) {
    const s = this.store;
    if (this.management.active(job.order_id) || this.management.hasGoods(job.order_id)) return;
    const order = s.one('SELECT * FROM delivery_orders WHERE id=?', job.order_id);
    const found = await this.adapter.read(job.transport_order_id);
    this.verify(job, order, found);
    // Recover only an already bound, current order restored to the exact original
    // courier before pickup. Creation uncertainty and financial reviews stay blocked.
    if (found.is_prior !== false || !['driver_assigned','car_at_place'].includes(found.state_kind)) return;
    s.transaction(() => {
      if (this.management.active(order.id) || this.management.hasGoods(order.id)) return;
      const changed = s.run("UPDATE delivery_transport_jobs SET phase='bound',last_error='',updated_at=? WHERE order_id=? AND phase='review' AND last_error='Transport assignment or amount changed'", s.now(), order.id).changes;
      if (changed) s.event(order.id, 'tm-transport:' + job.transport_order_id, 'transport_assignment_restored');
    });
  }
  async synchronize(job) {
    const s = this.store, order = s.one('SELECT * FROM delivery_orders WHERE id=?', job.order_id);
    if(this.management.active(order.id))return;
    const found = await this.adapter.read(job.transport_order_id);
    let snapshot;
    try { snapshot = this.verify(job, order, found); }
    catch { s.run("UPDATE delivery_transport_jobs SET phase='review',last_error='Transport assignment or amount changed',updated_at=? WHERE order_id=? AND phase='bound'", s.now(), order.id); return; }
    const proof = { transport_order_id: job.transport_order_id, driver_id: found.driver_id, crew_id: found.crew_id };
    if (found.state_kind === 'aborted') {
      if (order.status === 'picked_up' || this.management.hasGoods(order.id)) {
        s.run("UPDATE delivery_transport_jobs SET phase='review',last_error='Aborted after goods pickup; dispatcher review required',updated_at=? WHERE order_id=?", s.now(), order.id);
      } else s.recordTransport(order.id, { ...proof, status: 'cancelled' });
      return;
    }
    if (!['driver_assigned', 'car_at_place', 'client_inside', 'finished'].includes(found.state_kind)) return;
    const accepted = found.confirmed === 'confirmed_by_driver' || ['car_at_place', 'client_inside', 'finished'].includes(found.state_kind);
    const states = ['assigned', ...(accepted ? ['accepted'] : []), ...(['client_inside', 'finished'].includes(found.state_kind) ? ['picked_up'] : [])];
    // A single poll may miss an intermediate state. Replay only the transitions
    // implied by the authenticated TaxiMaster lifecycle, never by elapsed time.
    for (const state of states) {
      const current = s.one('SELECT status FROM delivery_orders WHERE id=?', order.id).status;
      if (['assigned','accepted','picked_up','completed'].indexOf(current) < ['assigned','accepted','picked_up','completed'].indexOf(state)) s.recordTransport(order.id, { ...proof, status: state });
    }
    if (found.state_kind === 'finished') {
      const receipt = s.one('SELECT * FROM delivery_cash_receipts WHERE order_id=?', order.id);
      if (receipt?.driver_id === found.driver_id && receipt.crew_id === found.crew_id && receipt.amount_uzs === snapshot.total_uzs && Number(found.cash_sum) === snapshot.delivery_uzs && ['cashless_sum','bonus_sum','bank_card_sum'].every(field => found[field] != null && Number(found[field]) === 0)) {
        s.recordTransport(order.id, { ...proof, status: 'completed', cash_collected_uzs: receipt.amount_uzs });
      }
    }
    s.run('UPDATE delivery_transport_jobs SET updated_at=? WHERE order_id=?', s.now(), order.id);
  }
  async confirmCash(transportOrderId, identity, amount) {
    // INTERNAL ONLY: caller must derive driver/crew from an authenticated fleet
    // session. No public passenger/admin endpoint accepts cash confirmations.
    const s = this.store, job = s.one("SELECT * FROM delivery_transport_jobs WHERE transport_order_id=? AND phase='bound'", positive(transportOrderId));
    if (!job) fail(404, 'Delivery transport not found');
    const order = s.one('SELECT * FROM delivery_orders WHERE id=?', job.order_id);
    if(this.management.active(order.id))fail(409,'Dispatcher operation is unresolved');
    const found = await this.adapter.read(transportOrderId), snapshot = this.verify(job, order, found);
    if (identity.driver_id !== found.driver_id || identity.crew_id !== found.crew_id) fail(403, 'Courier does not own delivery');
    if (!['client_inside', 'finished'].includes(found.state_kind) || amount !== snapshot.total_uzs) fail(409, 'Cash amount or delivery state does not match');
    s.transaction(() => {
      const existing = s.one('SELECT * FROM delivery_cash_receipts WHERE order_id=?', order.id);
      if (existing) { if (existing.driver_id !== identity.driver_id || existing.crew_id !== identity.crew_id || existing.amount_uzs !== amount) fail(409, 'Receipt differs'); return; }
      s.run('INSERT INTO delivery_cash_receipts VALUES(?,?,?,?,?)', order.id, identity.driver_id, identity.crew_id, amount, s.now());
      s.event(order.id, 'driver:' + identity.driver_id, 'cash_confirmed');
    });
    return { order_id: order.id, cash_confirmed: true, amount_uzs: amount };
  }
  async info(transportOrderId, identity) {
    const found = await this.adapter.read(positive(transportOrderId));
    if (found.driver_id !== identity.driver_id || found.crew_id !== identity.crew_id) fail(403, 'Courier does not own order');
    const s = this.store, job = s.one('SELECT * FROM delivery_transport_jobs WHERE transport_order_id=?', transportOrderId);
    if (!job) {
      if (String(found.customer || '').startsWith('YANGI_DELIVERY/')) fail(409, 'Delivery mapping is unresolved');
      return { delivery:null };
    }
    if (job.phase !== 'bound') fail(409, 'Delivery requires dispatcher review');
    const order = s.one('SELECT * FROM delivery_orders WHERE id=?', job.order_id), snapshot = this.verify(job, order, found);
    const receipt = s.one('SELECT 1 FROM delivery_cash_receipts WHERE order_id=?', order.id);
    return { delivery:{ order_id:order.id, transport_order_id:transportOrderId, status:order.status,
      shop_name:snapshot.shop_name, pickup:snapshot.pickup, destination:snapshot.destination,
      items:snapshot.items.map(i => ({ name:i.name, quantity:i.quantity })),
      subtotal_uzs:snapshot.subtotal_uzs, delivery_uzs:snapshot.delivery_uzs, total_uzs:snapshot.total_uzs,
      payment_method:'cash', ready:order.ready_at !== null && !this.management.active(order.id), management_pending:!!this.management.active(order.id), cash_confirmed:!!receipt } };
  }
  async authorizePickup(transportOrderId,identity) {
    const info=await this.info(transportOrderId,identity),d=info.delivery,s=this.store;
    if(!d || !d.ready)fail(409,'Store not ready or dispatcher operation pending');
    const found=await this.adapter.read(transportOrderId);
    if(found.driver_id!==identity.driver_id || found.crew_id!==identity.crew_id || found.state_kind!=='car_at_place')fail(409,'Courier is not at store');
    s.transaction(()=>{
      if(this.management.active(d.order_id))fail(409,'Dispatcher operation pending');
      const current=s.one('SELECT * FROM delivery_orders WHERE id=?',d.order_id);
      if(!current || current.transport_order_id!==transportOrderId || !['assigned','accepted'].includes(current.status) || current.ready_at===null)fail(409,'Delivery changed');
      const old=s.one('SELECT * FROM delivery_pickup_authorizations WHERE order_id=?',d.order_id);
      if(old) { if(old.transport_order_id!==transportOrderId || old.driver_id!==identity.driver_id || old.crew_id!==identity.crew_id)fail(409,'Pickup proof changed');return; }
      s.run('INSERT INTO delivery_pickup_authorizations VALUES(?,?,?,?,?)',d.order_id,transportOrderId,identity.driver_id,identity.crew_id,s.now());
      s.event(d.order_id,'driver:'+identity.driver_id,'goods_pickup_authorized');
    });
    return {pickup_authorized:true,transport_order_id:transportOrderId};
  }
}
