import { DeliveryError } from './store.mjs';
const fail=message=>{throw new DeliveryError(409,message);};
/** Our cash evidence, not a TM tariff engine, bank transfer or driver balance. */
export class CashJournal {
  constructor(store){this.store=store;}
  isGo(order){return JSON.parse(order.snapshot).cash_model==='courier_buyout_v1';}
  entries(orderId){return this.store.all('SELECT kind,amount_uzs,actor,created_at FROM delivery_cash_journal WHERE order_id=? ORDER BY created_at,rowid',orderId);}
  has(orderId,kind){return this.store.one('SELECT * FROM delivery_cash_journal WHERE order_id=? AND kind=?',orderId,kind);}
  summary(orderId){
    const events=this.entries(orderId);
    return {shop_paid:events.some(e=>e.kind==='shop_paid'),shop_received:events.some(e=>e.kind==='shop_received'),client_arrived:events.some(e=>e.kind==='client_arrived'),client_cash:events.some(e=>e.kind==='client_cash'),events};
  }
  put(order,kind,identity,amount,actor){
    const s=this.store,old=this.has(order.id,kind);
    if(old){if(old.driver_id!==identity.driver_id||old.crew_id!==identity.crew_id||old.amount_uzs!==amount||old.actor!==actor)fail('Cash evidence differs');return false;}
    s.run('INSERT INTO delivery_cash_journal VALUES(?,?,?,?,?,?,?)',order.id,kind,identity.driver_id,identity.crew_id,amount,actor,s.now());
    s.run('UPDATE delivery_orders SET version=version+1,updated_at=? WHERE id=?',s.now(),order.id);
    s.event(order.id,actor,kind);return true;
  }
  merchantReceived(order,user){
    if(!this.isGo(order)||!['assigned','accepted'].includes(order.status))fail('Shop receipt is not available');
    const paid=this.has(order.id,'shop_paid');if(!paid)fail('Courier has not confirmed shop payment');
    const identity={driver_id:paid.driver_id,crew_id:paid.crew_id};
    if(order.driver_id!==paid.driver_id||order.crew_id!==paid.crew_id)fail('Courier assignment changed');
    if(this.put(order,'shop_received',identity,paid.amount_uzs,'partner:'+user.id)){
      this.ledger(order,paid.driver_id,{merchant_cash_received:paid.amount_uzs,courier_cash_advanced:-paid.amount_uzs});
    }
  }
  ledger(order,driver,entries){for(const [kind,amount] of Object.entries(entries))this.store.run('INSERT INTO delivery_ledger VALUES(?,?,?,?,?,?)',order.id,kind,order.shop_id,driver,amount,this.store.now());}
  assertTransition(order,proof){
    if(!this.isGo(order))return;
    if(proof.status==='cancelled'&&this.has(order.id,'shop_paid'))fail('Courier buyout requires dispatcher dispute review');
    if(['picked_up','completed'].includes(proof.status)&&(!this.has(order.id,'shop_received')||!this.store.one('SELECT 1 FROM delivery_pickup_authorizations WHERE order_id=?',order.id)))fail('Shop payment and goods pickup are not confirmed');
    if(proof.status==='completed'&&!this.has(order.id,'client_cash'))fail('Customer cash not confirmed');
  }
  finish(order,driver,crew){
    const snapshot=JSON.parse(order.snapshot);
    this.put(order,'completed',{driver_id:driver,crew_id:crew},snapshot.total_uzs,'tm-transport:'+order.transport_order_id);
    // Reimbursement and delivery earnings: no merchant payable, guessed commission,
    // or second debit to TM. TM's commission must be reconciled independently.
    this.ledger(order,driver,{courier_cash_received:snapshot.total_uzs,goods_reimbursement:-snapshot.subtotal_uzs,delivery_cash_earned:-snapshot.delivery_uzs});
  }
}
