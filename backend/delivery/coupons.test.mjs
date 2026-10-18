import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { unlinkSync } from 'node:fs';
import { Worker } from 'node:worker_threads';
import { startTestHost } from './testing/host.mjs';
import { createRoadQuotes } from './road-pricing.mjs';
import { createTestAdapters } from './testing/adapter.mjs';
import { DeliveryStore } from './store.mjs';
import { isolatedTestPermit } from './runtime-mode.mjs';
const customer={id:'101',phone:'+998900000001'},other={id:'102',phone:'+998900000002'},key=()=>randomUUID();
async function fixture(t){
 const h=await startTestHost();t.after(async()=>{await h.close();for(const suffix of ['', '-wal', '-shm'])try{unlinkSync(h.path+suffix);}catch{}});
 let clock=1000000;const s=h.store;s.now=()=>clock;const partner=s.identity(h.merchantToken),admin=s.identity(h.adminToken);
 const terms={code:'TEST20',kind:'percent',amount:20,starts_at:900000,ends_at:1100000,min_goods_uzs:10000,max_uses:10,per_customer:1,active:true};
 const coupon=s.saveCoupon(partner,terms),input={shop_id:h.shop_id,coupon_code:' test20 ',items:[{product_id:h.product_id,quantity:1,price_uzs:1}],destination:{address:'TEST',lat:40.01,lon:65}};
 const road=createRoadQuotes(s,createTestAdapters(s).pricing),quote=(who=customer,body=input)=>road(who,body);
 return {h,s,partner,admin,terms,coupon,input,quote,clock:v=>{clock=v;}};
}
const conflict=fn=>assert.throws(fn,e=>e.statusCode===409);
test('coupon quote uses server goods-only discount, normalization and merchant-funded snapshot',async t=>{
 const f=await fixture(t),q=await f.quote();assert.equal(q.coupon.code,'TEST20');assert.equal(q.coupon.funding,'merchant');assert.equal(q.coupon.discount_uzs,5000);assert.equal(q.goods_before_coupon_uzs,25000);assert.equal(q.subtotal_uzs,20000);assert.equal(q.delivery_uzs,6000);assert.equal(q.total_uzs,26000);
 const updated=f.s.saveCoupon(f.partner,{...f.terms,kind:'fixed',amount:50000,version:f.coupon.version},f.coupon.id);
 conflict(()=>f.s.checkout(customer,{quote_id:q.id},key()));assert.equal(f.s.products(f.partner)[0].stock,85);
 const free=await f.quote();assert.equal(free.subtotal_uzs,0);assert.equal(free.total_uzs,6000);
 conflict(()=>f.s.saveCoupon(f.partner,{...f.terms,version:1},f.coupon.id));assert.equal(f.s.coupons(f.partner)[0].version,updated.version);
 for(const change of [{code:'AB'},{amount:0},{max_uses:0},{per_customer:1.5},{min_goods_uzs:-1},{active:1},{ends_at:1}])assert.throws(()=>f.s.saveCoupon(f.partner,{...f.terms,...change}),e=>e.statusCode===422);
});
test('coupon never stacks on product promotions, and checks minimum eligible goods',async t=>{
 const f=await fixture(t),p=f.s.products(f.partner)[0];f.s.saveProduct(f.partner,{...p,active:true,promotion:{kind:'percent',amount:10,starts_at:900000,ends_at:2000000}},p.id);
 await assert.rejects(()=>f.quote(),e=>e.statusCode===409);
 const plain=f.s.saveProduct(f.partner,{sku:'plain',name:'TEST plain',price_uzs:10000,stock:10,active:true});
 const q=await f.quote(customer,{...f.input,items:[...f.input.items,{product_id:plain.id,quantity:1}]});assert.equal(q.goods_before_coupon_uzs,32500);assert.equal(q.coupon.eligible_subtotal_uzs,10000);assert.equal(q.coupon.discount_uzs,2000);assert.equal(q.subtotal_uzs,30500);
});
test('coupon expiry/deactivation at checkout rolls back stock; invalid/foreign codes stay unavailable',async t=>{
 const f=await fixture(t),q=await f.quote();assert.ok(f.terms.ends_at<q.expires_at);f.clock(f.terms.ends_at);assert.throws(()=>f.s.checkout(customer,{quote_id:q.id},key()),e=>e.statusCode===409&&e.message.includes('Coupon'));assert.equal(f.s.products(f.partner)[0].stock,85);
 f.clock(1000000);f.s.saveCoupon(f.partner,{...f.terms,active:false,version:f.coupon.version},f.coupon.id);conflict(()=>f.s.checkout(customer,{quote_id:q.id},key()));
 await assert.rejects(()=>f.quote(),e=>e.statusCode===409);await assert.rejects(()=>f.quote(customer,{...f.input,coupon_code:'OTHER'}),e=>e.statusCode===409);
 assert.equal(f.s.one('SELECT count(*) n FROM delivery_coupon_redemptions').n,0);
});
test('coupon redemption is idempotent, retained on cancellation and durable across restart',async t=>{
 const f=await fixture(t),q1=await f.quote(),q2=await f.quote(),k=key(),o=f.s.checkout(customer,{quote_id:q1.id},k);
 assert.equal(f.s.checkout(customer,{quote_id:q1.id},k).id,o.id);conflict(()=>f.s.checkout(customer,{quote_id:q2.id},key()));assert.equal(f.s.products(f.partner)[0].stock,84);
 f.s.cancel(customer,o.id,{version:o.version,reason:'TEST'},key());assert.equal(f.s.products(f.partner)[0].stock,85);await assert.rejects(()=>f.quote(),e=>e.statusCode===409);
 const reopened=new DeliveryStore(f.h.path,{now:()=>1000000,testIsolation:isolatedTestPermit(f.h.path)});try{assert.equal(reopened.coupons(f.partner)[0].uses,1);assert.equal(reopened.orderForCustomer(customer,o.id).coupon.discount_uzs,5000);assert.throws(()=>reopened.run('DELETE FROM delivery_coupon_redemptions'),/immutable/);}finally{reopened.close();}
 const another=await f.quote(other);assert.equal(another.coupon.discount_uzs,5000);
});
test('last coupon use is atomic across independent workers and does not consume losing stock',async t=>{
 const f=await fixture(t);f.s.saveCoupon(f.partner,{...f.terms,max_uses:1,version:f.coupon.version},f.coupon.id);
 // Reuse the legacy-stock worker, offline fixture only; no production GO gate bypass.
 f.s.run('UPDATE delivery_shops SET service_kind=NULL WHERE id=?',f.h.shop_id);
 const quotes=await Promise.all([f.quote(customer),f.quote(other)]);
 const results=await Promise.all(quotes.map((q,i)=>new Promise((resolve,reject)=>{
  const worker=new Worker(new URL('./checkout-worker.mjs',import.meta.url),{workerData:{file:f.h.path,customer:i?other:customer,quote_id:q.id,key:key()}});let result;
  worker.once('message',v=>{result=v;});worker.once('error',reject);worker.once('exit',code=>code===0?resolve(result):reject(new Error('Coupon checkout worker failed')));
 })));
 assert.equal(results.filter(r=>r.ok).length,1);assert.equal(results.filter(r=>r.status===409).length,1);assert.equal(f.s.products(f.partner)[0].stock,84);assert.equal(f.s.coupons(f.partner)[0].uses,1);
});
test('coupon HTTP access is scoped to merchant/store and passenger quotes, with no public coupon listing',async t=>{
 const f=await fixture(t);
 async function request(path,token,method='GET',body){const r=await fetch(f.h.base+'/api/delivery'+path,{method,headers:{authorization:'Bearer '+token,...(body?{'content-type':'application/json'}:{})},body:body?JSON.stringify(body):undefined});return {status:r.status,value:await r.json()};}
 assert.equal((await request('/merchant/coupons',f.h.merchantToken)).status,200);assert.equal((await request('/merchant/coupons',f.h.passengerToken)).status,401);assert.equal((await request('/admin/shops/'+f.h.shop_id+'/coupons',f.h.merchantToken)).status,403);
 assert.equal((await request('/admin/shops/'+f.h.shop_id+'/coupons',f.h.adminToken)).value.data[0].code,'TEST20');assert.equal((await request('/coupons',f.h.passengerToken)).status,401);
 const second=f.s.createShop(f.admin,{name:'TEST other shop',login:'other-merchant',password:'test-only-password',category_id:f.s.one('SELECT id FROM delivery_categories').id,zone_id:null,lat:40,lon:65,address:'TEST',commission_bps:0,service_kind:'food'});
 const secondToken=f.s.login('other-merchant','test-only-password','TEST').token;
 assert.equal((await request('/merchant/coupons/'+f.coupon.id,secondToken,'PUT',{...f.terms,version:f.coupon.version})).status,404);
 const saved=await request('/merchant/coupons',f.h.merchantToken,'POST',{...f.terms,code:'FIXED',kind:'fixed',amount:1000});assert.equal(saved.status,200);
 const updated=await request('/admin/shops/'+f.h.shop_id+'/coupons/'+saved.value.data.id,f.h.adminToken,'PUT',{...f.terms,code:'FIXED',active:false,version:saved.value.data.version});assert.equal(updated.status,200);
 const quoted=await request('/customer/quotes',f.h.passengerToken,'POST',f.input);assert.equal(quoted.status,200);assert.equal(quoted.value.data.coupon.discount_uzs,5000);
 const secondPartner=f.s.identity(secondToken);assert.deepEqual(f.s.coupons(secondPartner),[]);assert.equal(second.id,secondPartner.shop_id);
});
test('GO coupon cash cycle uses discounted buyout, exact recipient cash and unchanged transport fee',async t=>{
 const f=await fixture(t),q=await f.quote(),driver={driver_id:5,crew_id:4};let o=f.s.checkout(customer,{quote_id:q.id},key());
 for(const action of ['confirm','ready'])o=f.s.merchantAction(f.partner,o.id,{action,version:o.version},key());f.h.transport.dispatch(f.admin,o.id,{crew_id:4,tariff_id:27,version:o.version},key());await f.h.transport.tick();
 const tm=f.s.orderForCustomer(customer,o.id).transport_order_id;
 async function state(state_kind){const r=await fetch(f.h.base+'/test/taximaster',{method:'POST',headers:{authorization:'Bearer '+f.h.adminToken,'content-type':'application/json'},body:JSON.stringify({order_id:tm,state_kind})});assert.equal(r.status,200);}
 await state('car_at_place');await assert.rejects(()=>f.h.transport.confirmShopPayment(tm,driver,25000),e=>e.statusCode===409);await f.h.transport.confirmShopPayment(tm,driver,20000);
 f.s.merchantAction(f.partner,o.id,{action:'cash_received',version:f.s.orderForCustomer(customer,o.id).version},key());await f.h.transport.authorizePickup(tm,driver);await state('client_inside');await f.h.transport.confirmClientArrival(tm,driver);
 await f.h.transport.confirmCash(tm,driver,26000);await f.h.transport.confirmCash(tm,driver,26000);await state('finished');await f.h.transport.tick();
 const final=f.s.orderForCustomer(customer,o.id);assert.equal(final.status,'completed');assert.equal(final.total_uzs,26000);assert.equal(final.delivery_uzs,6000);assert.equal(f.s.coupons(f.partner)[0].uses,1);
 assert.equal(f.s.one('SELECT sum(amount_uzs) n FROM delivery_ledger').n,0);assert.equal(f.s.one("SELECT amount_uzs n FROM delivery_ledger WHERE kind='goods_reimbursement'").n,-20000);
});
