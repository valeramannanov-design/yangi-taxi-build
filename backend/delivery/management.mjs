import { randomUUID } from 'node:crypto';
import { DeliveryError } from './store.mjs';
const fail = message => { throw new DeliveryError(409, message); };
const positive = value => { if (!Number.isSafeInteger(value) || value < 1 || value > 2147483647) throw new DeliveryError(422, 'Invalid identifier'); return value; };

export class DeliveryManagement {
  constructor(transport) { this.transport=transport;this.store=transport.store; }
  active(orderId) { return this.store.one("SELECT * FROM delivery_management WHERE order_id=? AND phase IN ('queued','sending','uncertain','review')",orderId); }
  hasGoods(orderId) { return this.store.one('SELECT 1 FROM delivery_pickup_authorizations WHERE order_id=?',orderId) || this.store.one('SELECT 1 FROM delivery_cash_receipts WHERE order_id=?',orderId); }
  reserveCrew(orderId,crew) {
    const s=this.store;
    if (s.one("SELECT 1 FROM delivery_transport_jobs j JOIN delivery_orders o ON o.id=j.order_id WHERE j.order_id<>? AND j.crew_id=? AND (j.phase IN ('queued','creating','uncertain','review') OR (j.phase='bound' AND o.status NOT IN ('completed','cancelled','rejected')))",orderId,crew)) fail('Courier already reserved');
    if (s.all("SELECT payload FROM delivery_management WHERE action='reassign' AND phase IN ('queued','sending','uncertain','review') AND order_id<>?",orderId).some(row=>JSON.parse(row.payload).crew_id===crew)) fail('Courier already reserved for reassignment');
  }
  request(user,orderId,input,key) {
    const s=this.store;s.admin(user);
    const action=input.action,version=positive(input.version),reason=typeof input.reason==='string'?input.reason.trim():'';
    if (!['cancel','reassign'].includes(action) || !reason || reason.length>300 || /[\x00-\x1f\x7f]/.test(reason)) throw new DeliveryError(422,'Action and reason required');
    const payload={action,version,reason,...(action==='reassign'?{crew_id:positive(input.crew_id),tariff_id:positive(input.tariff_id)}:{}),...(input.cancel_state_id!=null?{cancel_state_id:positive(input.cancel_state_id)}:{})};
    return s.command('admin:'+user.id,key,{orderId,...payload},()=>{
      const order=s.one('SELECT * FROM delivery_orders WHERE id=?',orderId),job=s.one('SELECT * FROM delivery_transport_jobs WHERE order_id=?',orderId);
      if (!order) throw new DeliveryError(404,'Order not found');
      if (order.version!==version || !['pending_shop','confirmed','ready','assigned','accepted'].includes(order.status) || this.active(orderId) || this.hasGoods(orderId)) fail('Order changed, goods pickup authorized, or operation unresolved');
      if (action==='reassign') { if (order.status==='pending_shop') fail('Store has not confirmed');this.reserveCrew(orderId,payload.crew_id);if(job?.crew_id===payload.crew_id) fail('Choose another courier'); }
      if (job && !['queued','blocked','bound'].includes(job.phase)) fail('Transport creation must be reconciled first');
      if (!order.transport_order_id) {
        if (job && (job.transport_order_id!==null || job.request_json!==null && job.phase!=='blocked')) fail('Transport creation is unresolved');
        if (action==='cancel') {
          if(job)s.run("UPDATE delivery_transport_jobs SET phase='blocked',last_error='Order cancelled',updated_at=? WHERE order_id=?",s.now(),orderId);
          s.restoreStock(order);s.transition(order,'cancelled','admin:'+user.id,reason);
        } else {
          if (!job) fail('Dispatch the first courier before reassignment');
          s.run("UPDATE delivery_transport_jobs SET crew_id=?,tariff_id=?,phase='queued',request_json=NULL,last_error='',updated_at=? WHERE order_id=?",payload.crew_id,payload.tariff_id,s.now(),orderId);
          s.run('UPDATE delivery_orders SET version=version+1,updated_at=? WHERE id=?',s.now(),orderId);s.event(orderId,'admin:'+user.id,'courier_reassigned_before_creation',reason);
        }
        return {order_id:orderId,phase:'applied'};
      }
      if (!job || job.phase!=='bound' || !payload.cancel_state_id) fail('Bound transport and cancellation state required');
      const id=randomUUID();s.run("INSERT INTO delivery_management(id,order_id,action,phase,payload,created_at,updated_at) VALUES(?,?,?,'queued',?,?,?)",id,orderId,action,JSON.stringify(payload),s.now(),s.now());
      s.run('UPDATE delivery_orders SET version=version+1,updated_at=? WHERE id=?',s.now(),orderId);s.event(orderId,'admin:'+user.id,action+'_requested',reason);
      return {order_id:orderId,action_id:id,phase:'queued'};
    });
  }
  phase(id,phase,message='') { this.store.run("UPDATE delivery_management SET phase=?,last_error=?,updated_at=? WHERE id=? AND phase IN ('queued','sending','uncertain')",phase,message,this.store.now(),id); }
  async tick() {
    const s=this.store;
    for (const action of s.all("SELECT * FROM delivery_management WHERE phase IN ('queued','sending','uncertain') ORDER BY updated_at LIMIT 20")) {
      s.run('UPDATE delivery_management SET updated_at=? WHERE id=?',s.now(),action.id);
      try {
        if(action.phase==='queued') await this.send(action);
        else if(action.request_json) await this.reconcile(action);
        else s.run("UPDATE delivery_management SET phase='blocked',last_error='Interrupted before write; request can be submitted again',updated_at=? WHERE id=? AND phase='sending' AND request_json IS NULL",s.now(),action.id);
      } catch { /* Unknown mutation results are read/reconciled, never resent. */ }
    }
  }
  async send(action) {
    const s=this.store,adapter=this.transport.adapter;
    if(!s.run("UPDATE delivery_management SET phase='sending' WHERE id=? AND phase='queued'",action.id).changes)return;
    let plan;
    try {
      const order=s.one('SELECT * FROM delivery_orders WHERE id=?',action.order_id),job=s.one('SELECT * FROM delivery_transport_jobs WHERE order_id=?',action.order_id),payload=JSON.parse(action.payload);
      const found=await adapter.read(job.transport_order_id);this.transport.verify(job,order,found);
      if(!['driver_assigned','car_at_place'].includes(found.state_kind) || this.hasGoods(order.id)) fail('Goods may already be with courier');
      if(payload.action==='reassign') await adapter.prepare({...job,crew_id:payload.crew_id,tariff_id:payload.tariff_id},order,JSON.parse(order.snapshot));
      plan=await adapter.prepareCancel(job,payload.cancel_state_id);
      const fresh=await adapter.read(job.transport_order_id);this.transport.verify(job,order,fresh);
      if(!['driver_assigned','car_at_place'].includes(fresh.state_kind) || this.hasGoods(order.id))fail('Pickup or order state changed');
      if(!s.run("UPDATE delivery_management SET request_json=? WHERE id=? AND phase='sending' AND request_json IS NULL",JSON.stringify(plan),action.id).changes)return;
    } catch { this.phase(action.id,'blocked','Cancellation preflight rejected; refresh TaxiMaster state');return; }
    try { await adapter.cancel(plan); }
    catch(e) { this.phase(action.id,Number.isInteger(e.tmCode)&&e.tmCode>0?'blocked':'uncertain','Cancellation not confirmed');return; }
    await this.reconcile({...action,request_json:JSON.stringify(plan)});
  }
  async reconcile(action) {
    const s=this.store,job=s.one('SELECT * FROM delivery_transport_jobs WHERE order_id=?',action.order_id),order=s.one('SELECT * FROM delivery_orders WHERE id=?',action.order_id),payload=JSON.parse(action.payload);
    const found=await this.transport.adapter.read(job.transport_order_id),expected=JSON.parse(job.request_json);
    if(found.state_kind!=='aborted') { this.phase(action.id,['client_inside','finished'].includes(found.state_kind)?'review':'uncertain','Cancellation requires TaxiMaster confirmation');return; }
    if(Number(found.order_id)!==job.transport_order_id || found.customer!==job.marker || String(found.client_id)!==order.customer_id || ![0,expected.driver_id].includes(found.driver_id) || ![0,job.crew_id].includes(found.crew_id)) { this.phase(action.id,'review','Cancelled transport identity changed');return; }
    s.transaction(()=>{
      if(s.one('SELECT phase FROM delivery_management WHERE id=?',action.id).phase==='applied')return;
      if(this.hasGoods(order.id)) fail('Goods pickup is unresolved');
      const current=s.one('SELECT * FROM delivery_orders WHERE id=?',order.id);
      if(payload.action==='cancel') { s.restoreStock(current);s.transition(current,'cancelled','admin-management:'+action.id,payload.reason); }
      else {
        // A replacement is created only after the previous TM transport is proved
        // aborted. Preserve the old mapping and never restore reserved goods.
        s.run('INSERT INTO delivery_transport_history VALUES(?,?,?,?,?)',job.transport_order_id,order.id,JSON.stringify(job),action.id,s.now());
        s.run("UPDATE delivery_transport_jobs SET marker=?,crew_id=?,tariff_id=?,phase='queued',request_json=NULL,transport_order_id=NULL,last_error='',updated_at=? WHERE order_id=?",'YANGI_DELIVERY/'+order.id+'/'+action.id,payload.crew_id,payload.tariff_id,s.now(),order.id);
        s.run('UPDATE delivery_orders SET transport_order_id=NULL,driver_id=NULL,crew_id=NULL,status=?,version=version+1,updated_at=? WHERE id=?',current.ready_at===null?'confirmed':'ready',s.now(),order.id);
        s.event(order.id,'admin-management:'+action.id,'replacement_transport_queued',payload.reason);
      }
      s.run("UPDATE delivery_management SET phase='applied',last_error='',updated_at=? WHERE id=?",s.now(),action.id);
    });
  }
}
