import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { unlinkSync } from 'node:fs';
import { startTestHost } from './testing/host.mjs';
import { validatePromotion,promotionalPrice } from './product-promotions.mjs';
const customer={id:'101',phone:'+998900000001'},key=()=>randomUUID();
async function fixture(t){
 const h=await startTestHost();t.after(async()=>{await h.close();for(const suffix of ['', '-wal', '-shm'])try{unlinkSync(h.path+suffix);}catch{}});
 let clock=1000;h.store.now=()=>clock;
 const partner=h.store.identity(h.merchantToken),product=h.store.products(partner)[0];
 const promotion={kind:'percent',amount:20,starts_at:1000,ends_at:10000};
 const edit=(changes={})=>{const current=h.store.products(partner)[0];return h.store.saveProduct(partner,{...current,active:true,...changes},product.id);};
 const input={shop_id:h.shop_id,items:[{product_id:h.product_id,quantity:2,price_uzs:1,promotion:{amount:100}}],destination:{address:'TEST',lat:40.01,lon:65}};
 const quote=async(body=input)=>{const r=await fetch(h.base+'/api/delivery/customer/quotes',{method:'POST',headers:{authorization:'Bearer '+h.passengerToken,'content-type':'application/json'},body:JSON.stringify(body)});const data=await r.json();assert.equal(r.status,200,JSON.stringify(data));return data.data;};
 return {h,partner,product,promotion,edit,input,quote,setClock:v=>{clock=v;}};
}
test('promotion validation, exact time bounds, integer rounding and capped fixed discounts',()=>{
 const p={kind:'percent',amount:15,starts_at:1000,ends_at:2000};
 assert.equal(promotionalPrice(101,p,999).price_uzs,101);assert.equal(promotionalPrice(101,p,1000).price_uzs,86);assert.equal(promotionalPrice(101,p,2000).price_uzs,101);
 assert.equal(promotionalPrice(101,{...p,kind:'fixed',amount:200},1000).price_uzs,0);
 for(const bad of [[],{...p,kind:'fake'},{...p,amount:101},{...p,amount:1.5},{...p,ends_at:1000},{...p,starts_at:-1},{}])assert.throws(()=>validatePromotion(bad),e=>e.statusCode===422);
});
test('merchant promotion uses authoritative per-unit price and expires before checkout without stock loss',async t=>{
 const f=await fixture(t);f.edit({promotion:f.promotion});const q=await f.quote();
 assert.equal(q.items[0].original_price_uzs,25000);assert.equal(q.items[0].price_uzs,20000);assert.equal(q.items[0].discount_uzs,5000);assert.equal(q.items[0].promotion.funding,'merchant');assert.equal(q.subtotal_uzs,40000);assert.equal(q.delivery_uzs,6000);assert.equal(q.total_uzs,46000);
 assert.equal(f.h.store.products(f.partner)[0].price_uzs,25000);assert.equal(f.h.store.shop(f.h.shop_id).products[0].price_uzs,20000);
 f.setClock(10000);assert.throws(()=>f.h.store.checkout(customer,{quote_id:q.id},key()),e=>e.statusCode===409);assert.equal(f.h.store.products(f.partner)[0].stock,85);
});
test('promotion revision and future activation invalidate quotes; frozen accepted prices survive edits',async t=>{
 const f=await fixture(t);f.edit({promotion:{...f.promotion,starts_at:2000}});const q=await f.quote();f.setClock(2000);
 assert.throws(()=>f.h.store.checkout(customer,{quote_id:q.id},key()),e=>e.statusCode===409);
 const fresh=await f.quote(),k=key(),o=f.h.store.checkout(customer,{quote_id:fresh.id},k);f.edit({promotion:null});
 assert.equal(f.h.store.orderForCustomer(customer,o.id).subtotal_uzs,40000);assert.equal(f.h.store.checkout(customer,{quote_id:fresh.id},k).id,o.id);
 const q2=await f.quote();f.edit({promotion:f.promotion});assert.throws(()=>f.h.store.checkout(customer,{quote_id:q2.id},key()),e=>e.statusCode===409);
 f.h.store.cancel(customer,o.id,{version:o.version,reason:'TEST'},key());assert.equal(f.h.store.products(f.partner)[0].stock,85);
});
test('variant discount is applied once and retains exact option inventory',async t=>{
 const f=await fixture(t);const p=f.edit({promotion:{...f.promotion,kind:'fixed',amount:3000},variants:[{name:'TEST A',price_uzs:10000,stock:3,active:true},{name:'TEST B',price_uzs:20000,stock:2,active:true}]});
 const publicProduct=f.h.store.shop(f.h.shop_id).products[0];assert.equal(publicProduct.price_uzs,7000);assert.equal(publicProduct.variants[1].price_uzs,17000);
 const q=await f.quote({...f.input,items:p.variants.map(v=>({product_id:p.id,variant_id:v.id,quantity:1}))});assert.equal(q.subtotal_uzs,24000);
 const o=f.h.store.checkout(customer,{quote_id:q.id},key());assert.deepEqual(f.h.store.products(f.partner)[0].variants.map(v=>v.stock),[2,1]);
 f.h.store.cancel(customer,o.id,{version:o.version,reason:'TEST'},key());assert.deepEqual(f.h.store.products(f.partner)[0].variants.map(v=>v.stock),[3,2]);
});
for(const [percent,goods] of [[20,40000],[100,0]])test('discounted GO full cash cycle: '+percent+'% preserves TM fare and balanced journal',async t=>{
 const f=await fixture(t),s=f.h.store,driver={driver_id:5,crew_id:4};f.edit({promotion:{...f.promotion,amount:percent}});const q=await f.quote();
 let o=s.checkout(customer,{quote_id:q.id},key());for(const action of ['confirm','ready'])o=s.merchantAction(f.partner,o.id,{action,version:o.version},key());
 f.h.transport.dispatch(s.identity(f.h.adminToken),o.id,{crew_id:4,tariff_id:27,version:o.version},key());await f.h.transport.tick();
 const tm=s.orderForCustomer(customer,o.id).transport_order_id;
 async function state(kind){const r=await fetch(f.h.base+'/test/taximaster',{method:'POST',headers:{authorization:'Bearer '+f.h.adminToken,'content-type':'application/json'},body:JSON.stringify({order_id:tm,state_kind:kind})});assert.equal(r.status,200);}
 await state('car_at_place');await f.h.transport.confirmShopPayment(tm,driver,goods);
 s.merchantAction(f.partner,o.id,{action:'cash_received',version:s.orderForCustomer(customer,o.id).version},key());await f.h.transport.authorizePickup(tm,driver);await state('client_inside');
 await f.h.transport.confirmClientArrival(tm,driver);await f.h.transport.confirmCash(tm,driver,goods+6000);await state('finished');
 const final=s.orderForCustomer(customer,o.id);assert.equal(final.status,'completed');assert.equal(final.subtotal_uzs,goods);assert.equal(final.delivery_uzs,6000);assert.equal(final.total_uzs,goods+6000);
 assert.equal(s.one("SELECT amount_uzs FROM delivery_ledger WHERE kind='goods_reimbursement'").amount_uzs,goods===0?0:-goods);assert.equal(s.one('SELECT sum(amount_uzs) n FROM delivery_ledger').n,0);
});
