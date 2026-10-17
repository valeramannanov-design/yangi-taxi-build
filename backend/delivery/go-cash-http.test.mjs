import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { unlinkSync } from 'node:fs';
import { startTestHost } from './testing/host.mjs';
test('isolated HTTP customer → merchant → driver → dual cash receipt → completion, no live TM calls',async t=>{
 const h=await startTestHost();t.after(async()=>{await h.close();for(const suffix of ['', '-wal', '-shm'])try{unlinkSync(h.path+suffix);}catch{}});
 async function request(path,token,body,key=randomUUID()){
  const response=await fetch(h.base+path,{method:body?'POST':'GET',headers:{authorization:'Bearer '+token,...(body?{'content-type':'application/json','idempotency-key':key}:{})},body:body?JSON.stringify(body):undefined});
  return {status:response.status,value:await response.json()};
 }
 async function post(path,token,body,key){const r=await request(path,token,body,key);assert.equal(r.status,200,JSON.stringify(r.value));return r.value.data||r.value;}
 const catalog=await request('/api/delivery/catalog?service=food',h.passengerToken);assert.equal(catalog.value.data.go_checkout.environment,'TEST');
 const q=await post('/api/delivery/customer/quotes',h.passengerToken,{shop_id:h.shop_id,items:[{product_id:h.product_id,quantity:1}],destination:{address:'TEST recipient',lat:40.01,lon:65}});
 assert.equal(q.pricing_basis,'TEST');
 const checkoutKey=randomUUID(),o=await post('/api/delivery/customer/orders',h.passengerToken,{quote_id:q.id},checkoutKey);
 assert.equal((await post('/api/delivery/customer/orders',h.passengerToken,{quote_id:q.id},checkoutKey)).id,o.id);
 let current=o;
 for(const action of ['confirm','ready'])current=await post('/api/delivery/merchant/orders/'+o.id+'/action',h.merchantToken,{action,version:current.version});
 await post('/api/delivery/admin/orders/'+o.id+'/dispatch',h.adminToken,{crew_id:4,tariff_id:27,version:current.version});await h.transport.tick();
 const tmId=h.store.orderForCustomer({id:'101',phone:'+998900000001'},o.id).transport_order_id;
 const driver={order_id:tmId,driver_id:5,crew_id:4};
 await post('/test/taximaster',h.adminToken,{order_id:tmId,state_kind:'car_at_place'});
 assert.equal((await request('/internal/delivery/shop-payment',h.passengerToken,{...driver,amount_uzs:25000})).status,403);
 await post('/internal/delivery/shop-payment',h.bridgeToken,{...driver,amount_uzs:25000});
 current=(await request('/api/delivery/merchant/orders',h.merchantToken)).value.data[0];
 const ack=randomUUID(),body={action:'cash_received',version:current.version};
 await post('/api/delivery/merchant/orders/'+o.id+'/action',h.merchantToken,body,ack);await post('/api/delivery/merchant/orders/'+o.id+'/action',h.merchantToken,body,ack);
 await post('/internal/delivery/pickup',h.bridgeToken,driver);await post('/test/taximaster',h.adminToken,{order_id:tmId,state_kind:'client_inside'});
 await post('/internal/delivery/client-arrival',h.bridgeToken,driver);await post('/internal/delivery/cash',h.bridgeToken,{...driver,amount_uzs:31000});
 await post('/test/taximaster',h.adminToken,{order_id:tmId,state_kind:'finished'});
 const final=(await request('/api/delivery/customer/orders/'+o.id,h.passengerToken)).value.data;
 assert.equal(final.status,'completed');assert.equal(final.cash.events.length,5);assert.equal(final.total_uzs,31000);
 assert.equal(h.store.all('SELECT * FROM delivery_ledger').length,5);
});
