import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { unlinkSync } from 'node:fs';
import { startTestHost } from './testing/host.mjs';
import { createRoadQuotes } from './road-pricing.mjs';
import { DeliveryStore } from './store.mjs';
import { isolatedTestPermit } from './runtime-mode.mjs';
const customer={id:'101',phone:'+998900000001'},other={id:'102',phone:'+998900000002'},key=()=>randomUUID();
async function fixture(t){
 const h=await startTestHost();t.after(async()=>{await h.close();for(const suffix of ['', '-wal', '-shm'])try{unlinkSync(h.path+suffix);}catch{}});
 const s=h.store,admin=s.identity(h.adminToken),partner=s.identity(h.merchantToken);let clock=1000000;s.now=()=>clock;
 const shop=s.one('SELECT * FROM delivery_shops WHERE id=?',h.shop_id);s.updateShop(admin,shop.id,{...shop,active:true,pickup_enabled:true});
 const input={fulfillment:'pickup',shop_id:shop.id,items:[{product_id:h.product_id,quantity:1}]};
 const quote=()=>createRoadQuotes(s,null)(customer,input);
 const row=id=>s.orderForCustomer(customer,id);
 const act=(id,action,extra={},k=key())=>s.merchantAction(partner,id,{action,version:row(id).version,...extra},k);
 return {h,s,admin,partner,shop,input,quote,row,act,clock:v=>{clock=v;}};
}
test('pickup quotes use real product/coupon prices and no address, route, delivery fee or courier',async t=>{
 const f=await fixture(t);f.s.savePricing(f.admin,{enabled:false,version:f.s.pricing().version});let calls=0;
 const q=await createRoadQuotes(f.s,{calculate:()=>{calls++;throw new Error('No route should be called');}})(customer,f.input);
 assert.equal(calls,0);assert.equal(q.fulfillment,'pickup');assert.equal(q.destination,null);assert.equal(q.total_uzs,25000);assert.equal(q.delivery_uzs,0);assert.equal(q.distance_m,null);assert.equal(q.pricing_basis,'self_pickup');assert.equal(q.pickup.address,'TEST store');
 const o=f.s.checkout(customer,{quote_id:q.id},key());assert.equal(o.transport_order_id,null);assert.equal(o.driver_id,null);
 f.act(o.id,'confirm',{ready_in_minutes:20});const ready=f.act(o.id,'ready');
 for(const fn of [()=>f.h.transport.dispatch(f.admin,o.id,{crew_id:4,tariff_id:27,version:ready.version},key()),()=>f.s.bindTransport(o.id,99),()=>f.h.transport.management.request(f.admin,o.id,{action:'cancel',version:ready.version,reason:'TEST'},key())])assert.throws(fn,e=>e.statusCode===409);
 assert.equal(f.s.one('SELECT count(*) n FROM delivery_transport_jobs').n,0);
});
test('pickup requires actual shop capability; disabling after quote rolls back checkout; production guard stays closed',async t=>{
 const f=await fixture(t),q=await f.quote();f.s.updateShop(f.admin,f.shop.id,{...f.shop,active:true,pickup_enabled:false});
 assert.throws(()=>f.s.checkout(customer,{quote_id:q.id},key()),e=>e.statusCode===409);assert.equal(f.s.products(f.partner)[0].stock,85);
 await assert.rejects(()=>f.quote(),e=>e.statusCode===409);
 const production=new DeliveryStore(':memory:');t.after(()=>production.close());assert.equal(production.goCheckout().enabled,false);
 const normalHost=new DeliveryStore(f.h.path,{now:()=>1000000});try{assert.throws(()=>normalHost.quote(customer,f.input),e=>e.statusCode===503);assert.throws(()=>normalHost.checkout(customer,{quote_id:q.id},key()),e=>e.statusCode===503);}finally{normalHost.close();}
 await assert.rejects(()=>createRoadQuotes(f.s,null)(customer,{...f.input,fulfillment:'fake'}),e=>e.statusCode===422);
});
test('pickup full cash cycle: explicit preparation, durable readiness, exact cash and handover once',async t=>{
 const f=await fixture(t),q=await f.quote(),k=key(),o=f.s.checkout(customer,{quote_id:q.id},k);assert.equal(f.s.checkout(customer,{quote_id:q.id},k).id,o.id);
 assert.throws(()=>f.act(o.id,'confirm'),e=>e.statusCode===422);assert.equal(f.row(o.id).status,'pending_shop');
 const confirmed=f.act(o.id,'confirm',{ready_in_minutes:20});assert.equal(confirmed.ready_expected_at,2200000);
 f.act(o.id,'set_ready_time',{ready_in_minutes:10});assert.equal(f.row(o.id).ready_expected_at,1600000);
 const readyKey=key(),readyInput={action:'ready',version:f.row(o.id).version};f.s.merchantAction(f.partner,o.id,readyInput,readyKey);f.s.merchantAction(f.partner,o.id,readyInput,readyKey);
 assert.equal(f.s.pickup.notifications(customer).length,1);assert.equal(f.s.pickup.notifications(other).length,0);assert.equal(f.s.pickup.notifications(customer)[0].status,'ready');
 assert.throws(()=>f.act(o.id,'pickup_handed_over'),e=>e.statusCode===409);assert.throws(()=>f.act(o.id,'pickup_cash_received',{amount_uzs:1}),e=>e.statusCode===409);
 const cashKey=key(),cashInput={action:'pickup_cash_received',version:f.row(o.id).version,amount_uzs:25000};f.s.merchantAction(f.partner,o.id,cashInput,cashKey);f.s.merchantAction(f.partner,o.id,cashInput,cashKey);
 assert.throws(()=>f.s.merchantAction(f.partner,o.id,{...cashInput,amount_uzs:1},cashKey),e=>e.statusCode===409);
 assert.throws(()=>f.act(o.id,'pickup_cancel',{reason:'TEST'}),e=>e.statusCode===409);
 const completed=f.act(o.id,'pickup_handed_over');assert.equal(completed.status,'completed');assert.equal(completed.pickup_cash.events.length,2);
 assert.equal(f.s.one('SELECT count(*) n FROM delivery_cash_receipts').n,0);assert.equal(f.s.one('SELECT count(*) n FROM delivery_ledger').n,0);
 assert.equal(f.s.finance(f.partner).find(r=>r.kind==='merchant_pickup_cash_received').amount_uzs,25000);
 const reopened=new DeliveryStore(f.h.path,{testIsolation:isolatedTestPermit(f.h.path)});try{assert.equal(reopened.orderForCustomer(customer,o.id).status,'completed');assert.equal(reopened.orderForCustomer(customer,o.id).pickup_cash.events.length,2);assert.throws(()=>reopened.run('DELETE FROM delivery_store_pickup_journal'),/immutable/);}finally{reopened.close();}
});
test('unpaid pickup cancellation restores exact variant stock once; paid pickup is never auto-refunded',async t=>{
 const f=await fixture(t),p=f.s.products(f.partner)[0];const edited=f.s.saveProduct(f.partner,{...p,active:true,variants:[{name:'TEST option',price_uzs:30000,stock:2,active:true}]},p.id);
 const q=await createRoadQuotes(f.s,null)(customer,{...f.input,items:[{product_id:p.id,quantity:1,variant_id:edited.variants[0].id}]});const o=f.s.checkout(customer,{quote_id:q.id},key());f.act(o.id,'confirm',{ready_in_minutes:5});
 const input={action:'pickup_cancel',version:f.row(o.id).version,reason:'TEST'},k=key();f.s.merchantAction(f.partner,o.id,input,k);f.s.merchantAction(f.partner,o.id,input,k);
 assert.equal(f.s.products(f.partner)[0].variants[0].stock,2);assert.equal(f.row(o.id).status,'cancelled');assert.equal(f.s.finance(f.partner).length,0);
});
test('pickup coupon is deducted once and zero goods cash remains explicit',async t=>{
 const f=await fixture(t);f.s.saveCoupon(f.partner,{code:'FREE',kind:'percent',amount:100,starts_at:900000,ends_at:2000000,min_goods_uzs:0,max_uses:2,per_customer:1,active:true});
 const q=await createRoadQuotes(f.s,null)(customer,{...f.input,coupon_code:'FREE'});assert.equal(q.total_uzs,0);const o=f.s.checkout(customer,{quote_id:q.id},key());
 f.act(o.id,'confirm',{ready_in_minutes:1});f.act(o.id,'ready');f.act(o.id,'pickup_cash_received',{amount_uzs:0});f.act(o.id,'pickup_handed_over');assert.equal(f.row(o.id).status,'completed');assert.equal(f.s.coupons(f.partner)[0].uses,1);
});
test('pickup HTTP uses passenger/merchant identity; readiness read is owned and idempotent',async t=>{
 const f=await fixture(t);
 async function request(path,token,body,requestKey=key()) {const r=await fetch(f.h.base+'/api/delivery'+path,{method:body?'POST':'GET',headers:{authorization:'Bearer '+token,...(body?{'content-type':'application/json','idempotency-key':requestKey}:{})},body:body?JSON.stringify(body):undefined});return {status:r.status,value:await r.json()};}
 const q=await request('/customer/quotes',f.h.passengerToken,f.input);assert.equal(q.status,200);const o=(await request('/customer/orders',f.h.passengerToken,{quote_id:q.value.data.id})).value.data;
 f.act(o.id,'confirm',{ready_in_minutes:10});f.act(o.id,'ready');const notices=await request('/customer/notifications',f.h.passengerToken);assert.equal(notices.status,200);const notice=notices.value.data[0];
 assert.equal((await request('/customer/notifications',f.h.merchantToken)).status,401);
 const readKey=key();assert.equal((await request('/customer/notifications/'+notice.id+'/read',f.h.passengerToken,{},readKey)).status,200);assert.equal((await request('/customer/notifications/'+notice.id+'/read',f.h.passengerToken,{},readKey)).status,200);
 assert.throws(()=>f.s.pickup.readNotification(other,notice.id,key()),e=>e.statusCode===404);
 assert.equal((await request('/merchant/orders/'+o.id+'/action',f.h.passengerToken,{action:'pickup_cash_received',amount_uzs:25000,version:f.row(o.id).version})).status,401);
 assert.equal(f.s.pickup.notifications(customer)[0].read_at,1000000);
});
