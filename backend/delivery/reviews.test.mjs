import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { unlinkSync } from 'node:fs';
import { startTestHost } from './testing/host.mjs';
import { createRoadQuotes } from './road-pricing.mjs';
import { DeliveryTransport } from './transport.mjs';
import { createTestAdapters } from './testing/adapter.mjs';
import { DeliveryStore } from './store.mjs';
import { isolatedTestPermit } from './runtime-mode.mjs';
const customer={id:'101',phone:'+998900000001'},foreign={id:'102',phone:'+998900000002'},key=()=>randomUUID();
async function fixture(t,pickup=true){
 const h=await startTestHost();t.after(async()=>{await h.close();for(const suffix of ['', '-wal', '-shm'])try{unlinkSync(h.path+suffix);}catch{}});
 const s=h.store,admin=s.identity(h.adminToken),partner=s.identity(h.merchantToken),shop=s.one('SELECT * FROM delivery_shops WHERE id=?',h.shop_id);
 if(pickup)s.updateShop(admin,shop.id,{...shop,active:true,pickup_enabled:true});
 const adapters=createTestAdapters(s),transport=new DeliveryTransport(s,adapters.transport);
 const q=await createRoadQuotes(s,adapters.pricing)(customer,{shop_id:h.shop_id,items:[{product_id:h.product_id,quantity:1}],...(pickup?{fulfillment:'pickup'}:{destination:{address:'TEST',lat:40.01,lon:65}})});
 const o=s.checkout(customer,{quote_id:q.id},key()),id=o.id;
 const row=()=>s.orderForCustomer(customer,id),act=(action,extra={})=>s.merchantAction(partner,id,{action,version:row().version,...extra},key());
 async function finish(){
  act('confirm',pickup?{ready_in_minutes:5}:{});act('ready');
  if(pickup){act('pickup_cash_received',{amount_uzs:25000});act('pickup_handed_over');return;}
  transport.dispatch(admin,id,{crew_id:4,tariff_id:27,version:row().version},key());await transport.tick();
  const tm=row().transport_order_id,driver={driver_id:5,crew_id:4};adapters.setState(tm,{state_kind:'car_at_place',confirmed:'confirmed_by_driver'});await transport.tick();
  await transport.confirmShopPayment(tm,driver,25000);act('cash_received');await transport.authorizePickup(tm,driver);
  adapters.setState(tm,{state_kind:'client_inside'});await transport.tick();await transport.confirmClientArrival(tm,driver);await transport.confirmCash(tm,driver,31000);
  adapters.setState(tm,{state_kind:'finished',cash_sum:6000,cashless_sum:0,bonus_sum:0,bank_card_sum:0});await transport.tick();
 }
 const submit=(input,k=key(),identity=customer)=>s.reviews.submit(identity,id,input,k);
 async function request(path,token,body,k=key()){
  const r=await fetch(h.base+'/api/delivery'+path,{method:body?'POST':'GET',headers:{authorization:'Bearer '+token,...(body?{'content-type':'application/json',...(k?{'idempotency-key':k}:{})}:{})},body:body?JSON.stringify(body):undefined});return {status:r.status,data:await r.json()};
 }
 return {h,s,id,row,admin,partner,finish,submit,request};
}
test('GO reviews require owned completed orders and exact input; no spoofed target IDs',async t=>{
 const f=await fixture(t);
 assert.deepEqual(f.s.reviews.forCustomer(customer,f.id),{eligible_targets:[],reviews:[]});
 assert.throws(()=>f.submit({target:'shop',rating:1}),e=>e.statusCode===409);
 await f.finish();
 for(const input of [{target:'shop',rating:0},{target:'shop',rating:1.5},{target:'shop',rating:'1'},{target:'driver',rating:5},{target:'shop',rating:5,driver_id:999},{target:'shop',rating:5,comment:'x'.repeat(1001)},{target:'shop',rating:5,comment:5}])assert.throws(()=>f.submit(input),e=>e.statusCode===422);
 assert.throws(()=>f.submit({target:'shop',rating:5},key(),foreign),e=>e.statusCode===404);
 assert.throws(()=>f.s.reviews.forCustomer(foreign,f.id),e=>e.statusCode===404);
 assert.equal(f.s.one('SELECT count(*) n FROM delivery_reviews').n,0);
});
test('pickup low rating creates exactly one immutable review and complaint, no courier score or invented average',async t=>{
 const f=await fixture(t);assert.deepEqual(f.s.reviews.summary(f.h.shop_id),{count:0,average:null});await f.finish();
 const input={target:'shop',rating:2,comment:' TEST <script> '},k=key();const saved=f.submit(input,k);
 f.submit(input,k);f.submit(input);assert.equal(saved.reviews[0].complaint_status,'open');assert.deepEqual(saved.eligible_targets,['shop']);
 assert.throws(()=>f.submit({...input,rating:5},k),e=>e.statusCode===409);assert.throws(()=>f.submit({...input,rating:5}),e=>e.statusCode===409);assert.throws(()=>f.submit({target:'courier',rating:5}),e=>e.statusCode===409);
 assert.equal(f.s.one('SELECT count(*) n FROM delivery_reviews').n,1);assert.equal(f.s.reviews.complaints(f.admin).length,1);
 assert.deepEqual(f.s.shop(f.h.shop_id).rating,{count:1,average:2});assert.deepEqual(f.s.catalog().shops[0].rating,{count:1,average:2});
 assert.equal(f.s.reviews.forStaff(f.partner)[0].comment,'TEST <script>');
 assert.throws(()=>f.s.run('UPDATE delivery_reviews SET rating=5'),/immutable/);assert.throws(()=>f.s.run('DELETE FROM delivery_reviews'),/immutable/);
});
test('actual TEST courier cash cycle rates final server-bound driver separately, without financial writes',async t=>{
 const f=await fixture(t,false);await f.finish();assert.equal(f.row().status,'completed');
 const ledger=f.s.all('SELECT * FROM delivery_ledger'),cash=f.s.all('SELECT * FROM delivery_cash_journal');
 assert.deepEqual(f.s.reviews.forCustomer(customer,f.id).eligible_targets,['shop','courier']);
 f.submit({target:'shop',rating:5});f.submit({target:'courier',rating:1,comment:'TEST late'});
 assert.equal(f.s.one("SELECT target_id FROM delivery_reviews WHERE target='courier'").target_id,5);
 assert.equal(f.s.reviews.forStaff(f.partner).length,1);assert.equal(f.s.reviews.forStaff(f.admin).length,2);
 assert.equal(f.s.reviews.complaints(f.admin)[0].target,'courier');assert.deepEqual(f.s.reviews.summary(f.h.shop_id),{count:1,average:5});
 assert.deepEqual(f.s.all('SELECT * FROM delivery_ledger'),ledger);assert.deepEqual(f.s.all('SELECT * FROM delivery_cash_journal'),cash);
});
test('complaints are admin-only, versioned, audited and durable; another merchant sees no reviews',async t=>{
 const f=await fixture(t);await f.finish();f.submit({target:'shop',rating:1});
 const other=f.s.createShop(f.admin,{name:'TEST other',login:'test-other',password:'test-other-password',category_id:1,address:'TEST',lat:40,lon:65,commission_bps:0,service_kind:'food'});
 const outsider=f.s.identity(f.s.login('test-other','test-other-password','TEST').token);
 assert.deepEqual(f.s.reviews.forStaff(outsider),[]);assert.throws(()=>f.s.reviews.complaints(f.partner),e=>e.statusCode===403);
 let c=f.s.reviews.complaints(f.admin)[0];const payload={status:'in_review',version:c.version,note:'TEST contacting shop'},k=key();
 f.s.reviews.updateComplaint(f.admin,c.id,payload,k);f.s.reviews.updateComplaint(f.admin,c.id,payload,k);
 assert.throws(()=>f.s.reviews.updateComplaint(f.admin,c.id,{...payload,status:'resolved'},key()),e=>e.statusCode===409);
 c=f.s.reviews.complaints(f.admin)[0];assert.equal(c.events.length,2);
 assert.throws(()=>f.s.reviews.updateComplaint(f.partner,c.id,{status:'resolved',version:c.version,note:'TEST'},key()),e=>e.statusCode===403);
 assert.throws(()=>f.s.reviews.updateComplaint(f.admin,c.id,{status:'resolved',version:c.version,note:''},key()),e=>e.statusCode===422);
 f.s.reviews.updateComplaint(f.admin,c.id,{status:'resolved',version:c.version,note:'TEST handled; no refund'},key());
 const reopened=new DeliveryStore(f.h.path,{testIsolation:isolatedTestPermit(f.h.path)});
 try{assert.equal(reopened.reviews.complaints(f.admin)[0].events.length,3);assert.equal(reopened.reviews.forCustomer(customer,f.id).reviews[0].complaint_status,'resolved');assert.throws(()=>reopened.run('DELETE FROM delivery_complaint_events'),/immutable/);}finally{reopened.close();}
 assert.equal(other.id>0,true);
});
test('review and automatic complaint roll back together on storage failure and retry safely',async t=>{
 const f=await fixture(t);await f.finish();f.s.db.exec("CREATE TRIGGER test_complaint_failure BEFORE INSERT ON delivery_complaints BEGIN SELECT RAISE(ABORT,'TEST failure'); END;");
 const k=key(),input={target:'shop',rating:1};assert.throws(()=>f.submit(input,k),/TEST failure/);assert.equal(f.s.one('SELECT count(*) n FROM delivery_reviews').n,0);
 f.s.db.exec('DROP TRIGGER test_complaint_failure');f.submit(input,k);assert.equal(f.s.reviews.complaints(f.admin).length,1);
 const other=new DeliveryStore(f.h.path,{testIsolation:isolatedTestPermit(f.h.path)});
 try{other.reviews.submit(customer,f.id,input,key());assert.equal(other.reviews.complaints(f.admin).length,1);}finally{other.close();}
});
test('review HTTP uses owned passenger identity, valid keys and separate admin complaint access',async t=>{
 const f=await fixture(t);await f.finish();const path='/customer/orders/'+f.id+'/reviews';
 assert.equal((await f.request(path,f.h.merchantToken)).status,401);assert.equal((await f.request(path,f.h.passengerToken)).status,200);
 assert.equal((await f.request(path,f.h.passengerToken,{target:'shop',rating:1},null)).status,422);
 assert.equal((await f.request(path,f.h.passengerToken,{target:'shop',rating:1})).status,200);
 assert.equal((await f.request('/admin/complaints',f.h.merchantToken)).status,403);assert.equal((await f.request('/admin/complaints',f.h.passengerToken)).status,401);
 const c=(await f.request('/admin/complaints',f.h.adminToken)).data.data[0];assert.equal((await f.request('/admin/complaints/'+c.id,f.h.adminToken,{status:'resolved',version:c.version,note:'TEST reviewed'})).status,200);
 assert.equal((await f.request('/merchant/reviews',f.h.merchantToken)).data.data.length,1);
});
