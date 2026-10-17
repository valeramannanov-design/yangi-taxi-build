import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { DeliveryStore } from './store.mjs';
const customer={id:'101',phone:'+998900000001'},key=()=>randomUUID();
function fixture(t){
 const s=new DeliveryStore(':memory:');t.after(()=>s.close());s.createAdmin('admin','test-product-options-password');const admin=s.identity(s.login('admin','test-product-options-password','test').token);
 const c=s.category(admin,{name:'TEST',active:true}),z=s.zone(admin,{name:'TEST',south:39,north:41,west:64,east:67,base_uzs:3000,per_km_uzs:1000,max_distance_m:30000,active:true});
 const shop=s.createShop(admin,{name:'TEST shop',login:'merchant',password:'test-product-options-password',category_id:c.id,zone_id:z.id,address:'TEST',lat:40,lon:65,commission_bps:0});s.updateShop(admin,shop.id,{...shop,active:true});
 const partner=s.identity(s.login('merchant','test-product-options-password','test').token);
 const input={sku:'one',name:'TEST drink',description:'TEST',price_uzs:10000,stock:5,active:true,ingredients:'Water, fruit',weight_g:null,volume_ml:500,variants:[{name:'Small',price_uzs:18000,stock:2,active:true,volume_ml:500},{name:'Large',price_uzs:25000,stock:1,active:true,volume_ml:1000}]};
 const product=s.saveProduct(partner,input);
 const quoteInput={shop_id:shop.id,items:[{product_id:product.id,variant_id:product.variants[0].id,quantity:1}],destination:{address:'TEST recipient',lat:40.001,lon:65}};
 return {s,partner,product,input,shop,quoteInput};
}
test('real variant prices/measurements are frozen and forged price/name fields ignored',t=>{
 const f=fixture(t),q=f.s.quote(customer,{...f.quoteInput,items:[{...f.quoteInput.items[0],price_uzs:1,variant_name:'fake'}]});
 assert.equal(q.items[0].price_uzs,18000);assert.equal(q.items[0].variant_name,'Small');assert.equal(q.items[0].volume_ml,500);assert.equal(q.items[0].ingredients,'Water, fruit');
 assert.equal(f.s.shop(f.shop.id).products[0].stock,3);assert.equal(f.s.shop(f.shop.id).products[0].price_uzs,18000);
 for(const variant_id of [undefined,'foreign'])assert.throws(()=>f.s.quote(customer,{...f.quoteInput,items:[{product_id:f.product.id,variant_id,quantity:1}]}),e=>e.statusCode===409);
});
test('two variants reserve independently; concurrent quotes cannot oversell; cancellation restores once',t=>{
 const f=fixture(t),items=f.product.variants.map(v=>({product_id:f.product.id,variant_id:v.id,quantity:1}));
 const first=f.s.quote(customer,{...f.quoteInput,items}),second=f.s.quote(customer,{...f.quoteInput,items});
 const order=f.s.checkout(customer,{quote_id:first.id},key());assert.equal(order.items.length,2);assert.equal(order.subtotal_uzs,43000);
 assert.throws(()=>f.s.checkout(customer,{quote_id:second.id},key()),e=>e.statusCode===409);
 assert.equal(f.s.products(f.partner)[0].stock,1);assert.deepEqual(f.s.products(f.partner)[0].variants.map(v=>v.stock),[1,0]);
 f.s.cancel(customer,order.id,{version:order.version,reason:'TEST'},key());assert.equal(f.s.products(f.partner)[0].stock,3);
});
test('soft-hidden variant is retained for exact restoration and absent from public results',t=>{
 const f=fixture(t),q=f.s.quote(customer,f.quoteInput),o=f.s.checkout(customer,{quote_id:q.id},key()),current=f.s.products(f.partner)[0];
 f.s.saveProduct(f.partner,{...f.input,version:current.version,variants:[current.variants[1]]},current.id);
 assert.equal(f.s.productDetail(f.shop.id,current.id).variants.length,1);
 f.s.cancel(customer,o.id,{version:o.version,reason:'TEST'},key());const after=f.s.products(f.partner)[0];
 assert.equal(after.variants.find(v=>v.id===f.product.variants[0].id).stock,2);assert.equal(after.stock,1);
});
test('catalog edits invalidate quotes atomically; stale/foreign variant edits cannot overwrite inventory',t=>{
 const f=fixture(t),q=f.s.quote(customer,f.quoteInput);
 assert.throws(()=>f.s.saveProduct(f.partner,{...f.input,version:f.product.version,variants:[{...f.input.variants[0],id:'foreign'}]},f.product.id),e=>e.statusCode===422);
 const edited=f.s.saveProduct(f.partner,{...f.input,version:f.product.version,ingredients:'Changed composition',variants:f.product.variants},f.product.id);
 assert.throws(()=>f.s.checkout(customer,{quote_id:q.id},key()),e=>e.statusCode===409);assert.equal(f.s.products(f.partner)[0].stock,3);
 assert.throws(()=>f.s.saveProduct(f.partner,{...f.input,version:f.product.version},f.product.id),e=>e.statusCode===409);
 assert.equal(f.s.products(f.partner)[0].ingredients,edited.ingredients);
});
test('legacy products stay usable; enabling variants waits for active base-product reservations',t=>{
 const f=fixture(t),base=f.s.saveProduct(f.partner,{sku:'plain',name:'TEST plain',price_uzs:10000,stock:3,active:true});
 const q=f.s.quote(customer,{...f.quoteInput,items:[{product_id:base.id,quantity:1}]});f.s.checkout(customer,{quote_id:q.id},key());const current=f.s.products(f.partner).find(p=>p.id===base.id);
 assert.throws(()=>f.s.saveProduct(f.partner,{...current,active:true,variants:f.input.variants},base.id),e=>e.statusCode===409);
 assert.throws(()=>f.s.saveProduct(f.partner,{...current,active:true,weight_g:0},base.id),e=>e.statusCode===422);
});

test('catalog starting price excludes sold-out variants and does not invalidate other available options',t=>{
 const f=fixture(t),q=f.s.quote(customer,{...f.quoteInput,items:[{...f.quoteInput.items[0],quantity:2}]});f.s.checkout(customer,{quote_id:q.id},key());
 const product=f.s.productDetail(f.shop.id,f.product.id);assert.equal(product.price_uzs,25000);assert.equal(product.variants.find(v=>v.name==='Small').stock,0);
 assert.equal(Object.hasOwn(product,'variants_json'),false);
});
