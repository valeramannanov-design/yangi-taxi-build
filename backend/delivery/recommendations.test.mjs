import test from 'node:test';
import assert from 'node:assert/strict';
import { DeliveryStore } from './store.mjs';

test('recommendations preserve ordered own-store choices and reject invalid edits atomically',t=>{
  const s=new DeliveryStore(':memory:');t.after(()=>s.close());
  const password='test-private-partner-password';s.createAdmin('admin',password);
  const admin=s.identity(s.login('admin',password,'test').token),category=s.category(admin,{name:'Test',active:true});
  const shop=i=>{const value=s.createShop(admin,{name:'Shop '+i,address:'Test address',lat:40,lon:65,category_id:category.id,commission_bps:0,login:'partner'+i,password});s.updateShop(admin,value.id,{...value,active:true});return value;};
  const one=shop(1),two=shop(2),p1=s.identity(s.login('partner1',password,'test').token),p2=s.identity(s.login('partner2',password,'test').token);
  const input=n=>({sku:'sku'+n,name:'Product '+n,price_uzs:1000+n,stock:5,active:true});
  const products=Array.from({length:12},(_,n)=>s.saveProduct(p1,input(n)));
  const foreign=s.saveProduct(p2,input(100));
  let root=products[0];
  root=s.saveProduct(p1,{...input(0),version:root.version,recommendation_ids:[products[2].id,products[1].id]},root.id);
  assert.deepEqual(s.productDetail(one.id,root.id).recommendations.map(p=>p.id),[products[2].id,products[1].id]);
  for(const ids of [[root.id],[foreign.id],[products[1].id,products[1].id],products.slice(1).map(p=>p.id),'invalid',[-1]]){
    assert.throws(()=>s.saveProduct(p1,{...input(0),stock:999,version:root.version,recommendation_ids:ids},root.id),e=>e.statusCode===422);
    assert.equal(s.products(p1).find(p=>p.id===root.id).stock,5);
    assert.equal(s.products(p1).find(p=>p.id===root.id).version,root.version);
  }
  assert.throws(()=>s.saveProduct(p2,{...input(0),version:root.version,recommendation_ids:[]},root.id),e=>e.statusCode===404);
  assert.throws(()=>s.productDetail(two.id,root.id),e=>e.statusCode===404);
  // Old editors may update a product without erasing newer recommendation metadata.
  const oldVersion=root.version;root=s.saveProduct(p1,{...input(0),version:root.version},root.id);
  assert.deepEqual(root.recommendation_ids,[products[2].id,products[1].id]);
  assert.throws(()=>s.saveProduct(p1,{...input(0),version:oldVersion,recommendation_ids:[]},root.id),e=>e.statusCode===409);
  s.saveProduct(p1,{...input(2),version:products[2].version,stock:0},products[2].id);
  assert.deepEqual(s.productDetail(one.id,root.id).recommendations.map(p=>p.id),[products[1].id]);
  const active=s.products(p1).find(p=>p.id===products[1].id);
  s.adminSaveProduct(admin,one.id,{...input(1),version:active.version,active:false},active.id);
  assert.deepEqual(s.productDetail(one.id,root.id).recommendations,[]);
  assert.deepEqual(s.all('PRAGMA foreign_key_check'),[]);
});
