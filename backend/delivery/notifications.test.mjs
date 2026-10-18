import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID,generateKeyPairSync,verify } from 'node:crypto';
import { unlinkSync } from 'node:fs';
import { startTestHost } from './testing/host.mjs';
import { DeliveryStore } from './store.mjs';
import { isolatedTestPermit } from './runtime-mode.mjs';
import { createRoadQuotes } from './road-pricing.mjs';
import { createAndroidFcm,AndroidPushWorker,androidFcmFromEnv } from './android-push.mjs';
const customer={id:'101',phone:'+998900000001'},foreign={id:'102',phone:'+998900000002'},key=()=>randomUUID();
const device=(n=1)=>({installation_id:'TEST_installation_'+n,fid:'TEST_fid_registered_'+n,lang:'ru'});
async function fixture(t){
 const h=await startTestHost();t.after(async()=>{await h.close();for(const suffix of ['', '-wal', '-shm'])try{unlinkSync(h.path+suffix);}catch{}});
 const s=h.store,admin=s.identity(h.adminToken),partner=s.identity(h.merchantToken);let clock=1000000;s.now=()=>clock;
 const shop=s.one('SELECT * FROM delivery_shops WHERE id=?',h.shop_id);s.updateShop(admin,shop.id,{...shop,active:true,pickup_enabled:true});
 s.notifications.register(customer,device(),key());
 const q=await createRoadQuotes(s,null)(customer,{shop_id:h.shop_id,fulfillment:'pickup',items:[{product_id:h.product_id,quantity:1}]}),order=s.checkout(customer,{quote_id:q.id},key());
 const row=()=>s.orderForCustomer(customer,order.id),act=(action,extra={})=>s.merchantAction(partner,order.id,{action,version:row().version,...extra},key());
 return {h,s,admin,partner,order,row,act,clock:v=>clock=v};
}
test('GO inbox reuses pickup notices and emits actual lifecycle once, preserving ownership and read acknowledgements',async t=>{
 const f=await fixture(t),s=f.s;
 assert.equal(s.notifications.list(customer)[0].kind,'order_created');f.act('confirm',{ready_in_minutes:5});f.act('set_ready_time',{ready_in_minutes:10});f.act('ready');
 assert.deepEqual(s.notifications.list(customer).map(n=>n.kind),['pickup_ready','pickup_time_changed','order_confirmed','order_created']);
 assert.deepEqual(s.notifications.list(foreign),[]);assert.equal(s.pickup.notifications(customer).length,1);
 const n=s.notifications.list(customer)[0],k=key();s.notifications.read(customer,n.id,k);s.notifications.read(customer,n.id,k);
 assert.throws(()=>s.notifications.read(foreign,n.id,key()),e=>e.statusCode===404);
 assert.equal(s.notifications.summary(customer).unread,3);assert.equal(s.notifications.list(customer,{before:n.id}).length,3);
 assert.throws(()=>s.notifications.list(customer,{before:NaN}),e=>e.statusCode===422);
 f.act('pickup_cash_received',{amount_uzs:25000});assert.equal(s.notifications.list(customer).length,4);f.act('pickup_handed_over');assert.equal(s.notifications.list(customer)[0].kind,'order_completed');
 const reopened=new DeliveryStore(f.h.path,{testIsolation:isolatedTestPermit(f.h.path)});try{assert.equal(reopened.notifications.summary(customer).unread,4);assert.equal(reopened.notifications.list(customer).find(r=>r.id===n.id).read_at,1000000);assert.throws(()=>reopened.run('UPDATE delivery_notifications SET customer_id=?','102'),/immutable/);}finally{reopened.close();}
});
test('notice and outbox are transactional with order state; no history replay on device registration',async t=>{
 const f=await fixture(t);f.s.db.exec("CREATE TRIGGER test_notice_abort BEFORE INSERT ON delivery_notifications WHEN NEW.kind='order_confirmed' BEGIN SELECT RAISE(ABORT,'TEST notice failure'); END;");
 assert.throws(()=>f.act('confirm',{ready_in_minutes:5}),/TEST notice failure/);assert.equal(f.row().status,'pending_shop');assert.equal(f.row().ready_expected_at,null);
 f.s.db.exec('DROP TRIGGER test_notice_abort');f.act('confirm',{ready_in_minutes:5});
 assert.equal(f.s.one('SELECT count(*) n FROM delivery_push_outbox').n,2);
 f.s.notifications.register(customer,device(2),key());assert.equal(f.s.one('SELECT count(*) n FROM delivery_push_outbox').n,2);
 f.act('ready');assert.equal(f.s.one('SELECT count(*) n FROM delivery_push_outbox').n,4);
 const ready=f.s.notifications.list(customer)[0];f.s.notifications.emit(f.s.one('SELECT * FROM delivery_orders WHERE id=?',f.order.id),'pickup_ready','pickup-ready:'+f.order.id);assert.equal(f.s.one('SELECT count(*) n FROM delivery_push_outbox WHERE notification_id=?',ready.id).n,2);
});
test('Android registration is owned, bounded, revocable and generation-safe; no guessed OS credentials',async t=>{
 const f=await fixture(t),s=f.s;assert.equal(androidFcmFromEnv({}),null);assert.throws(()=>androidFcmFromEnv({DELIVERY_PUSH_ENABLED:'true'}),/private FCM/);
 assert.throws(()=>s.notifications.register(foreign,device(),key()),e=>e.statusCode===409);
 assert.throws(()=>s.notifications.revoke(foreign,device(),key()),e=>e.statusCode===404);
 for(let n=2;n<=5;n++)s.notifications.register(customer,device(n),key());
 assert.throws(()=>s.notifications.register(customer,device(6),key()),e=>e.statusCode===409);
 const k=key();s.notifications.revoke(customer,device(),k);s.notifications.revoke(customer,device(),k);assert.equal(s.one('SELECT enabled FROM delivery_push_devices WHERE id=?',device().installation_id).enabled,0);
 assert.equal(s.one('SELECT status FROM delivery_push_outbox LIMIT 1').status,'discarded');
 s.notifications.register(foreign,device(),key());assert.equal(s.one('SELECT customer_id FROM delivery_push_devices WHERE id=?',device().installation_id).customer_id,foreign.id);
 assert.throws(()=>s.notifications.register(customer,{...device(7),customer_id:foreign.id},key()),e=>e.statusCode===422);
});
test('push worker retries, respects leases/restarts and never sends a revoked/read/expired notice',async t=>{
 const f=await fixture(t);let attempts=0,release;
 const provider={environment:'TEST',send:async()=>{attempts++;if(attempts===1)throw new Error('private token must not be recorded');return {messageId:'TEST accepted'};}};
 const worker=new AndroidPushWorker(f.s,provider);await worker.tick();assert.equal(f.s.one('SELECT status FROM delivery_push_outbox').status,'retry');assert.equal(f.s.one('SELECT last_error FROM delivery_push_outbox').last_error,'PUSH_NETWORK');
 await worker.tick();assert.equal(attempts,1);f.clock(1030000);await worker.tick();assert.equal(attempts,2);assert.equal(f.s.one('SELECT status FROM delivery_push_outbox').status,'sent');
 f.act('confirm',{ready_in_minutes:5});const slow=new AndroidPushWorker(f.s,{environment:'TEST',send:()=>new Promise(r=>{release=r;})});const running=slow.tick();
 await worker.tick();assert.equal(attempts,2);f.s.notifications.revoke(customer,device(),key());release({messageId:'TEST accepted late'});await running;
 assert.equal(f.s.one('SELECT status FROM delivery_push_outbox ORDER BY id DESC').status,'discarded');
 f.s.notifications.register(customer,device(),key());f.act('ready');f.s.notifications.read(customer,f.s.notifications.list(customer)[0].id,key());await worker.tick();assert.equal(attempts,2);
 f.act('pickup_cash_received',{amount_uzs:25000});f.act('pickup_handed_over');f.clock(90000000);await worker.tick();assert.equal(attempts,2);
 assert.throws(()=>new AndroidPushWorker(f.s,{environment:'production'}),/Real push is forbidden/);
});
test('permanent FCM unregistration disables only matching device and retry limit stays bounded',async t=>{
 const f=await fixture(t);f.s.notifications.register(customer,device(2),key());f.act('confirm',{ready_in_minutes:5});
 const worker=new AndroidPushWorker(f.s,{environment:'TEST',send:async({fid})=>{if(fid===device().fid)throw Object.assign(new Error('bad'),{pushCode:'FCM_UNREGISTERED',revoke:true});return {messageId:'TEST accepted'};}});await worker.tick();
 assert.equal(f.s.one('SELECT enabled FROM delivery_push_devices WHERE id=?',device().installation_id).enabled,0);assert.equal(f.s.one('SELECT enabled FROM delivery_push_devices WHERE id=?',device(2).installation_id).enabled,1);
 f.act('ready');f.s.run("UPDATE delivery_push_outbox SET attempts=8 WHERE status='pending'");let calls=0;await new AndroidPushWorker(f.s,{environment:'TEST',send:async()=>{calls++;}}).tick();assert.equal(calls,0);
});
test('complaint updates notify only order owner and never expose internal handling text in push payload',async t=>{
 const f=await fixture(t);f.act('confirm',{ready_in_minutes:1});f.act('ready');f.act('pickup_cash_received',{amount_uzs:25000});f.act('pickup_handed_over');
 f.s.reviews.submit(customer,f.order.id,{target:'shop',rating:1,comment:'TEST'},key());let c=f.s.reviews.complaints(f.admin)[0];
 f.s.reviews.updateComplaint(f.admin,c.id,{status:'in_review',version:c.version,note:'PRIVATE internal note'},key());
 const n=f.s.notifications.list(customer)[0];assert.equal(n.kind,'complaint_updated');assert.equal(n.complaint_status,'in_review');assert.equal(JSON.stringify(n).includes('PRIVATE'),false);assert.deepEqual(f.s.notifications.list(foreign),[]);
});
test('notification HTTP is authenticated; absent FCM config cannot register and inbox is still usable',async t=>{
 const f=await fixture(t);
 async function request(path,token,body){const r=await fetch(f.h.base+'/api/delivery'+path,{method:body?'POST':'GET',headers:{authorization:'Bearer '+token,...(body?{'content-type':'application/json','idempotency-key':key()}:{})},body:body?JSON.stringify(body):undefined});return {status:r.status,value:await r.json()};}
 assert.equal((await request('/customer/notifications',f.h.merchantToken)).status,401);
 const summary=(await request('/customer/notification-summary',f.h.passengerToken)).value.data;assert.equal(summary.unread,1);assert.deepEqual(summary.push,{available:false,project_id:null});
 assert.equal((await request('/customer/push/register',f.h.passengerToken,device())).status,503);
 assert.equal((await request('/customer/notifications?before=invalid',f.h.passengerToken)).status,422);
 assert.equal((await request('/customer/push/revoke',f.h.passengerToken,device())).status,200);
});
test('FCM v1 uses verified OAuth RS256 and FID targeting, caches token, sanitizes errors and sends generic Android payload',async()=>{
 const {privateKey,publicKey}=generateKeyPairSync('rsa',{modulusLength:2048});let authCalls=0,sendCalls=0,bad=false;const now=()=>1800000000000;
 const provider=createAndroidFcm({account:{type:'service_account',project_id:'test-project',client_email:'test@test-project.iam.gserviceaccount.com',private_key:privateKey.export({type:'pkcs8',format:'pem'})},now,request:async(url,options)=>{
  assert.equal(options.redirect,'error');if(url==='https://oauth2.googleapis.com/token'){
   authCalls++;const jwt=options.body.get('assertion').split('.'),payload=JSON.parse(Buffer.from(jwt[1],'base64url'));assert.equal(payload.aud,url);assert.equal(payload.exp-payload.iat,3600);assert.equal(verify('RSA-SHA256',Buffer.from(jwt[0]+'.'+jwt[1]),publicKey,Buffer.from(jwt[2],'base64url')),true);
   return {ok:true,json:async()=>({access_token:'TEST OAuth',expires_in:3600})};
  }
  assert.equal(url,'https://fcm.googleapis.com/v1/projects/test-project/messages:send');sendCalls++;
  const m=JSON.parse(options.body).message;assert.equal(m.fid,device().fid);assert.equal(m.token,undefined);assert.deepEqual(m.data,{go_notice:'7'});assert.equal(m.android.notification.visibility,'PRIVATE');assert.equal(m.notification.body.includes('заказу'),true);assert.equal(m.android.notification.tag,'go-7');
  if(bad)return {ok:false,status:404,headers:new Headers(),json:async()=>({error:{message:'SECRET',details:[{'@type':'type.googleapis.com/google.firebase.fcm.v1.FcmError',errorCode:'UNREGISTERED'}]}})};
  return {ok:true,json:async()=>({name:'projects/test-project/messages/123'})};
 }});
 await provider.send({fid:device().fid,lang:'ru',noticeId:7});await provider.send({fid:device().fid,lang:'ru',noticeId:7});assert.equal(authCalls,1);assert.equal(sendCalls,2);bad=true;
 await assert.rejects(()=>provider.send({fid:device().fid,lang:'ru',noticeId:7}),e=>e.pushCode==='FCM_UNREGISTERED'&&e.revoke===true&&!e.message.includes('SECRET'));
});
