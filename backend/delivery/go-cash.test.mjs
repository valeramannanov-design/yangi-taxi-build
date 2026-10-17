import test from 'node:test';
import assert from 'node:assert/strict';
import { unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { DeliveryStore } from './store.mjs';
import { DeliveryTransport } from './transport.mjs';
import { isolatedTestPermit } from './runtime-mode.mjs';
import { createTestAdapters } from './testing/adapter.mjs';
import { createRoadQuotes } from './road-pricing.mjs';
const customer={id:'101',phone:'+998900000001'},identity={driver_id:5,crew_id:4};
const key=()=>randomUUID();
async function fixture(t,path=':memory:'){
 let store=new DeliveryStore(path,{testIsolation:isolatedTestPermit(path)});t.after(()=>store.close());
 store.createAdmin('admin','test-only-password');const admin=store.identity(store.login('admin','test-only-password','test').token);
 const category=store.category(admin,{name:'TEST food',active:true});
 let shop=store.createShop(admin,{name:'TEST shop',login:'merchant',password:'test-only-password',category_id:category.id,zone_id:null,lat:40,lon:65,address:'TEST shop',commission_bps:9000,service_kind:'food'});
 shop=store.updateShop(admin,shop.id,{...shop,active:true});const partner=store.identity(store.login('merchant','test-only-password','test').token);
 const product=store.saveProduct(partner,{sku:'TEST',name:'TEST goods',description:'TEST',price_uzs:25000,stock:85,active:true});
 store.savePricing(admin,{enabled:true,tariff_id:27,crew_group_id:3,max_distance_m:30000,version:1});
 const adapters=createTestAdapters(store),quote=await createRoadQuotes(store,adapters.pricing)(customer,{shop_id:shop.id,items:[{product_id:product.id,quantity:1}],destination:{lat:40.01,lon:65,address:'TEST client'}});
 let order=store.checkout(customer,{quote_id:quote.id},key());const id=order.id;
 order=store.merchantAction(partner,id,{action:'confirm',version:order.version},key());
 order=store.merchantAction(partner,id,{action:'ready',version:order.version},key());
 let transport=new DeliveryTransport(store,adapters.transport);transport.dispatch(admin,id,{crew_id:4,tariff_id:27,version:order.version},key());await transport.tick();
 const tmId=store.orderForCustomer(customer,id).transport_order_id;
 const row=()=>store.orderForCustomer(customer,id);
 const merchant=()=>store.merchantAction(partner,id,{action:'cash_received',version:row().version},key());
 return {get store(){return store;},get transport(){return transport;},admin,partner,id,tmId,row,merchant,adapters,quote,
  async arrive(){adapters.setState(tmId,{state_kind:'car_at_place',confirmed:'confirmed_by_driver'});await transport.tick();},
  async pickup(){await transport.authorizePickup(tmId,identity);adapters.setState(tmId,{state_kind:'client_inside'});await transport.tick();},
  restart(){store.close();store=new DeliveryStore(path,{testIsolation:isolatedTestPermit(path)});transport=new DeliveryTransport(store,adapters.transport);},
 };
}
const rejects=async fn=>assert.rejects(fn,e=>[403,409].includes(e.statusCode));
test('TEST cash cycle uses dual shop confirmations, courier reimbursement, exact customer cash and TM finish once',async t=>{
 const path=join(tmpdir(),'yangi-go-test-'+randomUUID()+'.sqlite');t.after(()=>{for(const suffix of ['', '-wal', '-shm'])try{unlinkSync(path+suffix);}catch{}});const f=await fixture(t,path);
 assert.equal(f.quote.pricing_basis,'TEST');assert.equal(f.quote.total_uzs,31000);assert.equal(f.row().commission_uzs,undefined);
 await rejects(()=>f.transport.confirmShopPayment(f.tmId,identity,25000));await f.arrive();
 await rejects(()=>f.transport.authorizePickup(f.tmId,identity));
 await rejects(()=>f.transport.confirmShopPayment(f.tmId,identity,24000));
 await rejects(()=>f.transport.confirmShopPayment(f.tmId,{driver_id:6,crew_id:4},25000));
 await f.transport.confirmShopPayment(f.tmId,identity,25000);await f.transport.confirmShopPayment(f.tmId,identity,25000);
 await rejects(()=>f.transport.authorizePickup(f.tmId,identity));
 assert.throws(()=>f.store.merchantAction({...f.partner,shop_id:999},f.id,{action:'cash_received',version:f.row().version},key()),e=>e.statusCode===404);
 f.merchant();await f.pickup();await rejects(()=>f.transport.confirmCash(f.tmId,identity,31000));
 await f.transport.confirmClientArrival(f.tmId,identity);await rejects(()=>f.transport.confirmCash(f.tmId,identity,6000));
 await f.transport.confirmCash(f.tmId,identity,31000);f.restart();await f.transport.confirmCash(f.tmId,identity,31000);
 f.adapters.setState(f.tmId,{state_kind:'finished',cash_sum:6000,cashless_sum:0,bonus_sum:0,bank_card_sum:0});
 await f.transport.tick();await f.transport.tick();assert.equal(f.row().status,'completed');
 await f.transport.confirmShopPayment(f.tmId,identity,25000);await f.transport.confirmClientArrival(f.tmId,identity);await f.transport.confirmCash(f.tmId,identity,31000);
 assert.equal(f.row().cash.events.length,5);assert.equal(f.store.all('SELECT * FROM delivery_cash_receipts').length,1);
 const ledger=f.store.all('SELECT * FROM delivery_ledger');assert.equal(ledger.length,5);assert.equal(ledger.reduce((a,e)=>a+e.amount_uzs,0),0);
 assert.ok(ledger.every(e=>!['merchant_payable','service_revenue'].includes(e.kind)));
 assert.equal(f.row().commission_status,'not_verified');
 assert.throws(()=>f.store.run("UPDATE delivery_cash_journal SET amount_uzs=1"),/immutable/);
});
test('buyout claim blocks cancellation/reassignment and external abortion preserves cash history and stock',async t=>{
 const f=await fixture(t);await f.arrive();await f.transport.confirmShopPayment(f.tmId,identity,25000);
 for(const action of ['cancel','reassign'])assert.throws(()=>f.transport.management.request(f.admin,f.id,{action,version:f.row().version,reason:'TEST',crew_id:8,tariff_id:27,cancel_state_id:5},key()),e=>e.statusCode===409);
 f.adapters.setState(f.tmId,{state_kind:'aborted'});await f.transport.tick();
 assert.equal(f.store.one('SELECT phase FROM delivery_transport_jobs').phase,'review');assert.equal(f.store.products(f.partner)[0].stock,84);assert.equal(f.row().cash.events.length,1);
});
test('direct TM pickup cannot bypass unpaid shop and does not complete financial records',async t=>{
 const f=await fixture(t);f.adapters.setState(f.tmId,{state_kind:'client_inside'});await f.transport.tick();
 assert.equal(f.row().status,'accepted');assert.equal(f.store.finance(f.admin).length,0);
 await rejects(()=>f.transport.confirmCash(f.tmId,identity,31000));
});
test('production rejects TEST permits, adapters and mapped GO checkout while preserving legacy behavior',async t=>{
 const store=new DeliveryStore(':memory:');t.after(()=>store.close());
 assert.equal(store.goCheckout().enabled,false);assert.throws(()=>createTestAdapters(store),/isolated/i);
 assert.throws(()=>new DeliveryStore(':memory:',{testIsolation:{label:'TEST'}}),/Invalid/);
 assert.throws(()=>isolatedTestPermit('C:/Yangi-Taxi-client/delivery-private/delivery.sqlite'),/isolated/);
});
