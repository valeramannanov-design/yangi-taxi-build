import test from 'node:test';
import assert from 'node:assert/strict';
import { DeliveryStore } from './store.mjs';

test('GO catalog filters explicit services, search and categories without guessing legacy stores', t => {
  const s=new DeliveryStore(':memory:');t.after(()=>s.close());
  s.createAdmin('admin','test-admin-private-password');
  const admin=s.identity(s.login('admin','test-admin-private-password','test').token);
  const category=s.category(admin,{name:'Shared category',active:true});
  const shops=[];
  for(const [i,kind] of [null,'food','market'].entries()){
    const shop=s.createShop(admin,{name:'Restaurant named market '+i,address:'Test address',lat:40,lon:65,category_id:category.id,commission_bps:0,login:'shop'+i,password:'test-partner-private-password',service_kind:kind});
    s.updateShop(admin,shop.id,{...shop,active:true});
    s.adminSaveProduct(admin,shop.id,{sku:'one',name:'Shared product',price_uzs:25000,stock:5,active:true});shops.push(shop);
  }
  assert.equal(s.catalog().shops.length,3);
  for(const [index,kind] of [[1,'food'],[2,'market']]){
    const data=s.catalog(undefined,'shared',kind);
    assert.equal(data.service,kind);assert.deepEqual(data.shops.map(x=>x.id),[shops[index].id]);
    assert.deepEqual(data.products.map(x=>x.shop_id),[shops[index].id]);assert.equal(data.categories.length,1);
    assert.equal(s.shop(shops[index].id,kind).service_kind,kind);
  }
  assert.throws(()=>s.shop(shops[1].id,'market'),e=>e.statusCode===404);
  assert.throws(()=>s.catalog(undefined,'','parcel'),e=>e.statusCode===422);
  assert.throws(()=>s.catalog(undefined,'',"food' OR 1=1"),e=>e.statusCode===422);
  const customer={id:'101',phone:'+998900000001'}, input={shop_id:shops[1].id,items:[{product_id:2,quantity:1}],destination:{lat:40.01,lon:65,address:'Test destination'}};
  assert.throws(()=>s.roadQuoteContext(customer,input),e=>e.statusCode===503);
  assert.throws(()=>s.quote(customer,input),e=>e.statusCode===503);
  assert.throws(()=>s.updateShop(admin,shops[0].id,{...shops[0],active:true,service_kind:'parcel'}),e=>e.statusCode===422);
  assert.equal(s.one('SELECT service_kind FROM delivery_shops WHERE id=?',shops[0].id).service_kind,null);
  // An older client update omits the new field and cannot erase its mapping.
  const oldInput={...shops[1],active:true};delete oldInput.service_kind;
  s.updateShop(admin,shops[1].id,oldInput);assert.equal(s.shop(shops[1].id).service_kind,'food');
  s.updateShop(admin,shops[1].id,{...shops[1],active:false});
  assert.equal(s.catalog(undefined,'shared','food').shops.length,0);
  assert.equal(s.catalog(undefined,'shared','food').products.length,0);
  assert.equal(s.catalog(undefined,'','food').categories.length,0);
  assert.deepEqual(s.all('PRAGMA foreign_key_check'),[]);
});
