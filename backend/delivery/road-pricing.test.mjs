import test from 'node:test';
import assert from 'node:assert/strict';
import { DeliveryStore } from './store.mjs';
import { createRoadQuotes, createTaxiMasterRoadPricing } from './road-pricing.mjs';
import { DeliveryTransport } from './transport.mjs';

function fixture(t) {
  const store=new DeliveryStore(':memory:');t.after(()=>store.close());store.createAdmin('admin','unit-test-road-password');
  const admin=store.identity(store.login('admin','unit-test-road-password','test').token);
  const category=store.category(admin,{name:'Test',active:true});
  const shop=store.createShop(admin,{category_id:category.id,name:'Store',address:'Pickup',lat:40,lon:65,commission_bps:1000,login:'partner',password:'unit-test-partner-password'});
  store.updateShop(admin,shop.id,{...shop,active:true});const partner=store.identity(store.login('partner','unit-test-partner-password','test').token);
  const product=store.saveProduct(partner,{sku:'goods',name:'Goods',price_uzs:10000,stock:5,active:true});
  store.savePricing(admin,{enabled:true,tariff_id:9,crew_group_id:8,max_distance_m:10000,version:1});
  const customer={id:'101',phone:'+998900000001'},input={shop_id:shop.id,items:[{product_id:product.id,quantity:1}],destination:{address:'Recipient',lat:40.01,lon:65}};
  return {store,admin,partner,shop,customer,input};
}

test('no zone needed; server road quote freezes TM fee and commission across settings changes',async t=>{
  const f=fixture(t);assert.equal(f.shop.zone_id,null);assert.equal(f.store.all('SELECT * FROM delivery_zones').length,0);assert.equal(f.store.catalog().shops.length,1);
  const quote=await createRoadQuotes(f.store,{calculate:async()=>({distance_m:2500,delivery_uzs:7000})})(f.customer,{...f.input,delivery_uzs:1,tariff_id:100});
  assert.equal(quote.delivery_uzs,7000);assert.equal(quote.total_uzs,17000);assert.equal(quote.pricing_basis,'taximaster_road');assert.equal(quote.delivery_tariff_id,9);
  f.store.savePricing(f.admin,{enabled:true,tariff_id:12,crew_group_id:8,max_distance_m:20000,version:2});
  const a=f.store.checkout(f.customer,{quote_id:quote.id},'road-checkout-stable-key'),b=f.store.checkout(f.customer,{quote_id:quote.id},'road-checkout-stable-key');
  assert.equal(a.id,b.id);assert.equal(a.delivery_uzs,7000);assert.equal(a.delivery_tariff_id,9);assert.equal(f.store.finance(f.admin).length,0);
  const confirmed=f.store.merchantAction(f.partner,a.id,{action:'confirm',version:1},'road-confirm-for-dispatch');
  const transport=new DeliveryTransport(f.store,{});
  assert.throws(()=>transport.dispatch(f.admin,a.id,{crew_id:4,tariff_id:12,version:confirmed.version},'road-dispatch-wrong-tariff'),e=>e.statusCode===409);
  assert.equal(f.store.all('SELECT * FROM delivery_transport_jobs').length,0);
});

test('network failure never falls back to zone/straight-line price or reserves goods',async t=>{
  const f=fixture(t),quote=createRoadQuotes(f.store,{calculate:async()=>{throw new Error('Unavailable');}});
  await assert.rejects(quote(f.customer,f.input),e=>e.statusCode===503);
  assert.equal(f.store.all('SELECT * FROM delivery_quotes').length,0);assert.equal(f.store.products(f.partner)[0].stock,5);
  await assert.rejects(createRoadQuotes(f.store,null)(f.customer,f.input),e=>e.statusCode===503);
});

test('settings/store edits during network calculation invalidate result; overlapping requests are blocked',async t=>{
  const f=fixture(t);let resolve;const quote=createRoadQuotes(f.store,{calculate:()=>new Promise(r=>resolve=r)});
  const pending=quote(f.customer,f.input);await assert.rejects(quote(f.customer,f.input),e=>e.statusCode===429);
  f.store.savePricing(f.admin,{enabled:true,tariff_id:10,crew_group_id:8,max_distance_m:10000,version:2});resolve({distance_m:2000,delivery_uzs:7000});
  await assert.rejects(pending,e=>e.statusCode===409);assert.equal(f.store.all('SELECT * FROM delivery_quotes').length,0);
  const pending2=quote(f.customer,f.input);f.store.updateShop(f.admin,f.shop.id,{...f.shop,address:'Changed',active:true});resolve({distance_m:2000,delivery_uzs:7000});await assert.rejects(pending2,e=>e.statusCode===409);
  assert.throws(()=>f.store.savePricing(f.partner,{enabled:false,version:3}),e=>e.statusCode===403);
  assert.throws(()=>f.store.savePricing(f.admin,{enabled:false,version:1}),e=>e.statusCode===409);
});

test('real TM adapter reuses route/cost calls and rejects invalid routes, excess distance and fees',async()=>{
  let calls=0,route={city_dist:1.5,country_dist:1,full_route_coords:[{lat:40,lon:65},{lat:40.01,lon:65}]},sum='7000';
  const provider=createTaxiMasterRoadPricing({catalog:async()=>({tariffs:new Map([[9,{is_active:true}]]),groups:new Map([[8,{}]])}),time:()=> '20261017120000',analyzeRoute:async()=>route,calculateCost:async p=>{calls++;assert.equal(p.tariffId,9);assert.equal(p.session.clientId,101);return {sum};}});
  const context={customer:{id:'101'},shop:{address:'Store',lat:40,lon:65},destination:{address:'Recipient',lat:40.01,lon:65},pricing:{tariff_id:9,crew_group_id:8,max_distance_m:10000}};
  assert.deepEqual(await provider.calculate(context),{distance_m:2500,delivery_uzs:7000});
  await assert.rejects(provider.calculate({...context,pricing:{...context.pricing,max_distance_m:2000}}),e=>e.statusCode===422);assert.equal(calls,1);
  for(const value of [null,true,'bad','-1','7000.5',0,Infinity]){sum=value;await assert.rejects(provider.calculate(context));}
  sum='7000';route={...route,city_dist:0,country_dist:0};await assert.rejects(provider.calculate(context));
  route={...route,city_dist:2,full_route_coords:[]};await assert.rejects(provider.calculate(context));
  await assert.rejects(provider.calculate({...context,pricing:{...context.pricing,tariff_id:100}}));
});
