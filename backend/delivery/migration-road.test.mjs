import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync,readFileSync,rmSync } from 'node:fs';
import { join,resolve,dirname,basename } from 'node:path';
import { tmpdir } from 'node:os';
import { DeliveryStore } from './store.mjs';

for(const baseline of [4,5,6,7,8,9,10,11,12,13])test('schema'+baseline+' → schema14 preserves orders, receipts, ledger and foreign keys',t=>{
  const dir=mkdtempSync(join(tmpdir(),'yangi-delivery-road-migration-')),file=join(dir,'existing.sqlite');
  t.after(()=>{const target=resolve(dir);assert.equal(dirname(target),resolve(tmpdir()));assert.ok(basename(target).startsWith('yangi-delivery-'));rmSync(target,{recursive:true,force:true});});
  const old=new DatabaseSync(file);old.exec('PRAGMA foreign_keys=ON');
  for(const v of Array.from({length:baseline},(_,i)=>i+1)){old.exec(readFileSync(new URL('./migrations/'+String(v).padStart(3,'0')+'.sql',import.meta.url),'utf8'));old.prepare('INSERT INTO delivery_migrations VALUES(?,?)').run(v,1);}
  old.exec("INSERT INTO delivery_users VALUES(1,'partner','test-only-hash','partner',1);INSERT INTO delivery_categories VALUES(1,'Category',1);INSERT INTO delivery_zones VALUES(1,'Old zone',39,41,64,66,3000,1000,30000,1);INSERT INTO delivery_shops(id,partner_id,category_id,zone_id,name,address,lat,lon,commission_bps,active) VALUES(1,1,1,1,'Store','Address',40,65,1000,1)");
  const snapshot=JSON.stringify({total_uzs:12000,delivery_uzs:6000,pricing_basis:'straight_line_zone'});
  old.prepare('INSERT INTO delivery_quotes VALUES(?,?,?,?,?)').run('old-quote','101',1,snapshot,1000);
  old.exec("INSERT INTO delivery_orders(id,customer_id,shop_id,quote_id,snapshot,status,transport_order_id,driver_id,crew_id,created_at,updated_at) VALUES('old-order','101',1,'old-quote','{}','completed',7001,5,4,1,1)");
  old.prepare('UPDATE delivery_orders SET snapshot=?').run(snapshot);
  old.exec("INSERT INTO delivery_cash_receipts VALUES('old-order',5,4,12000,1);INSERT INTO delivery_pickup_authorizations VALUES('old-order',7001,5,4,1)");
  for(const [kind,amount] of [['driver_cash_receivable',12000],['courier_payable',-6000],['merchant_payable',-5250],['service_revenue',-750]])old.prepare('INSERT INTO delivery_ledger VALUES(?,?,?,?,?,?)').run('old-order',kind,1,5,amount,1);
  if(baseline>=8)old.exec("INSERT INTO delivery_cash_journal VALUES('old-order','completed',5,4,12000,'tm-transport:7001',1)");
  if(baseline>=9)old.exec("INSERT INTO delivery_products(id,shop_id,sku,name,description,price_uzs,stock,active,ingredients,volume_ml,variants_json) VALUES(1,1,'old','TEST old','',1000,2,1,'Water',500,'[{\"id\":\"retained\",\"name\":\"TEST\",\"price_uzs\":1000,\"stock\":2,\"active\":true}]')");
  if(baseline>=10)old.exec("UPDATE delivery_products SET promotion_json='{\"kind\":\"percent\",\"amount\":10,\"starts_at\":0,\"ends_at\":1}'");
  if(baseline>=12)old.exec("INSERT INTO delivery_notifications(id,customer_id,order_id,kind,created_at,read_at) VALUES(7,'101','old-order','pickup_ready',1,2)");
  old.close();const store=new DeliveryStore(file);
  try{
    assert.equal(store.one('SELECT max(version) AS version FROM delivery_migrations').version,14);assert.equal(store.one('SELECT count(*) AS n FROM delivery_cash_journal').n,baseline>=8?1:0);
    if(baseline>=12){const n=store.one('SELECT * FROM delivery_notifications WHERE id=7');assert.equal(n.read_at,2);assert.equal(n.event_key,'pickup-ready:old-order');}assert.equal(store.one('SELECT count(*) n FROM delivery_push_outbox').n,0);
    assert.equal(store.one('SELECT count(*) n FROM delivery_coupons').n,0);assert.equal(store.one('SELECT count(*) n FROM delivery_coupon_redemptions').n,0);
    if(baseline>=9){const product=store.options.describe(store.one('SELECT * FROM delivery_products WHERE id=1'));assert.equal(product.variants[0].id,'retained');assert.equal(product.ingredients,'Water');assert.equal(product.price_uzs,1000);assert.equal(product.original_price_uzs,undefined);}
    if(baseline>=10)assert.equal(store.options.describe(store.one('SELECT * FROM delivery_products WHERE id=1'),true).promotion.amount,10);
    assert.deepEqual(store.all('PRAGMA foreign_key_check'),[]);assert.equal(store.one('SELECT snapshot FROM delivery_orders').snapshot,snapshot);
    assert.equal(store.one('SELECT count(*) AS n FROM delivery_cash_receipts').n,1);assert.equal(store.one('SELECT count(*) AS n,sum(amount_uzs) AS sum FROM delivery_ledger').n,4);
    assert.equal(store.one('SELECT sum(amount_uzs) AS sum FROM delivery_ledger').sum,0);assert.equal(store.pricing().enabled,0);
    store.run('UPDATE delivery_shops SET zone_id=NULL');assert.equal(store.one('SELECT zone_id FROM delivery_shops').zone_id,null);assert.deepEqual(store.all('PRAGMA foreign_key_check'),[]);
  }finally{store.close();}
});
