import { DeliveryError } from './store.mjs';
const fail=(message,status=409)=>{throw new DeliveryError(status,message);};
const isPickup=snapshot=>snapshot.fulfillment==='pickup'&&snapshot.cash_model==='store_pickup_cash_v1';
export function fulfillment(input){
 const value=input.fulfillment??'delivery';if(!['delivery','pickup'].includes(value))fail('Unknown fulfillment mode',422);return value;
}
export class StorePickup{
 constructor(store){this.s=store;}
 assertShop(shop){if(!['food','market'].includes(shop.service_kind)||shop.pickup_enabled!==1)fail('Self-pickup is unavailable');}
 assertNoTransport(order){if(order&&isPickup(JSON.parse(order.snapshot)))fail('Self-pickup does not use a courier or TaxiMaster transport');}
 events(orderId){return this.s.all('SELECT kind,amount_uzs,actor,created_at FROM delivery_store_pickup_journal WHERE order_id=? ORDER BY created_at,rowid',orderId);}
 metadata(order){
  if(!isPickup(JSON.parse(order.snapshot)))return {};
  return {ready_expected_at:order.ready_expected_at,pickup_cash:{events:this.events(order.id)}};
 }
 fingerprint(input){
  return {...(Object.hasOwn(input,'ready_in_minutes')?{ready_in_minutes:input.ready_in_minutes}:{}),...(Object.hasOwn(input,'amount_uzs')?{amount_uzs:input.amount_uzs}:{})};
 }
 action(order,user,input,reason){
  const s=this.s,snapshot=JSON.parse(order.snapshot);if(!isPickup(snapshot))return false;
  const action=input.action,actor='partner:'+user.id;
  if(order.transport_order_id!==null||s.one('SELECT 1 FROM delivery_transport_jobs WHERE order_id=?',order.id))fail('Pickup transport conflict requires review');
  if(['confirm','set_ready_time'].includes(action)){
   if(order.status!==(action==='confirm'?'pending_shop':'confirmed'))fail('Pickup preparation state changed');
   const minutes=input.ready_in_minutes;if(!Number.isSafeInteger(minutes)||minutes<1||minutes>1440)fail('Provide preparation time in minutes',422);
   s.availableShop(order.shop_id);s.run('UPDATE delivery_orders SET ready_expected_at=? WHERE id=?',s.now()+minutes*60000,order.id);
   s.transition(order,'confirmed',actor,'',action);return true;
  }
  if(action==='ready'){
   if(order.status!=='confirmed'||order.ready_at!==null)fail('Pickup is not awaiting readiness');
   s.availableShop(order.shop_id);s.run('UPDATE delivery_orders SET ready_at=? WHERE id=?',s.now(),order.id);s.transition(order,'ready',actor);
   s.run("INSERT OR IGNORE INTO delivery_notifications(customer_id,order_id,kind,created_at) VALUES(?,?,'pickup_ready',?)",order.customer_id,order.id,s.now());return true;
  }
  if(['reject','pickup_cancel'].includes(action)){
   if(action==='reject'?order.status!=='pending_shop':!['confirmed','ready'].includes(order.status))fail('Pickup cannot be cancelled in this state');
   // TODO: actual cash-refund acknowledgement + immutable reversal contract;
   // never erase this receipt or restore stock just to make cancellation pass.
   if(this.events(order.id).length)fail('Paid pickup needs an actual refund/reconciliation, not cancellation');
   s.restoreStock(order);s.transition(order,action==='reject'?'rejected':'cancelled',actor,reason,action);return true;
  }
  if(['pickup_cash_received','pickup_handed_over'].includes(action)){
   if(order.status!=='ready')fail('Pickup must be ready');
   if(action==='pickup_cash_received'){
    if(!Number.isSafeInteger(input.amount_uzs)||input.amount_uzs!==snapshot.total_uzs)fail('Cash must equal the confirmed pickup total');
    if(this.events(order.id).some(e=>e.kind==='cash_received'))fail('Pickup cash already confirmed');
   }else if(!this.events(order.id).some(e=>e.kind==='cash_received'))fail('Confirm actual store cash receipt before handover');
   s.run('INSERT INTO delivery_store_pickup_journal VALUES(?,?,?,?,?)',order.id,action==='pickup_cash_received'?'cash_received':'handed_over',snapshot.total_uzs,actor,s.now());
   s.transition(order,action==='pickup_handed_over'?'completed':'ready',actor,'',action);return true;
  }
  fail('Unsupported self-pickup action',422);
 }
 notifications(customer){return this.s.all('SELECT n.id,n.order_id,n.kind,n.created_at,n.read_at,o.status,o.snapshot FROM delivery_notifications n JOIN delivery_orders o ON o.id=n.order_id WHERE n.customer_id=? AND o.customer_id=? ORDER BY n.id DESC LIMIT 100',customer.id,customer.id).map(({snapshot,...row})=>({...row,shop_name:JSON.parse(snapshot).shop_name,pickup:JSON.parse(snapshot).pickup}));}
 readNotification(customer,id,key){
  if(!Number.isSafeInteger(id)||id<1)fail('Invalid notification',422);
  const s=this.s;return s.command('passenger:'+customer.id,key,{action:'read_pickup_notice',id},()=>{
   if(!s.one('SELECT 1 FROM delivery_notifications WHERE id=? AND customer_id=?',id,customer.id))fail('Notification not found',404);
   s.run('UPDATE delivery_notifications SET read_at=coalesce(read_at,?) WHERE id=? AND customer_id=?',s.now(),id,customer.id);
   return s.one('SELECT id,read_at FROM delivery_notifications WHERE id=? AND customer_id=?',id,customer.id);
  });
 }
}
