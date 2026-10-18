import { DeliveryError } from './store.mjs';
import { validatePromotion,promotionalPrice } from './product-promotions.mjs';
const fail=(status,message)=>{throw new DeliveryError(status,message);};
const integer=(n,min,max)=>{if(!Number.isSafeInteger(n)||n<min||n>max)fail(422,'Invalid coupon integer');return n;};
function code(value){if(typeof value!=='string'||! /^[A-Z0-9_-]{3,32}$/.test(value.trim().toUpperCase()))fail(422,'Coupon code must be 3–32 Latin letters, digits, _ or -');return value.trim().toUpperCase();}
export class Coupons{
 constructor(store){this.s=store;}
 list(shop){return this.s.all('SELECT c.*,(SELECT count(*) FROM delivery_coupon_redemptions r WHERE r.coupon_id=c.id) uses FROM delivery_coupons c WHERE shop_id=? ORDER BY id DESC',shop);}
 save(shop,input,id){
  const terms=validatePromotion(input);if(!terms)fail(422,'Coupon terms required');
  const values=[code(input.code),terms.kind,terms.amount,terms.starts_at,terms.ends_at,integer(input.min_goods_uzs,0,100000000),integer(input.max_uses,1,1000000),integer(input.per_customer,1,1000000)];
  if(typeof input.active!=='boolean')fail(422,'Coupon active must be boolean');values.push(Number(input.active));
  return this.s.transaction(()=>{
   if(id!=null&&!this.s.one('SELECT 1 FROM delivery_coupons WHERE id=? AND shop_id=?',integer(id,1,Number.MAX_SAFE_INTEGER),shop))fail(404,'Coupon not found');
   if(this.s.one('SELECT 1 FROM delivery_coupons WHERE shop_id=? AND code=? AND id<>?',shop,values[0],id??0))fail(409,'Coupon code already exists');
   if(id!=null){if(!this.s.run('UPDATE delivery_coupons SET code=?,kind=?,amount=?,starts_at=?,ends_at=?,min_goods_uzs=?,max_uses=?,per_customer=?,active=?,version=version+1 WHERE id=? AND shop_id=? AND version=?',...values,id,shop,integer(input.version,1,Number.MAX_SAFE_INTEGER)).changes)fail(409,'Coupon changed; refresh');}
   else id=Number(this.s.run('INSERT INTO delivery_coupons(shop_id,code,kind,amount,starts_at,ends_at,min_goods_uzs,max_uses,per_customer,active) VALUES(?,?,?,?,?,?,?,?,?,?)',shop,...values).lastInsertRowid);
   return this.list(shop).find(c=>c.id===id);
  });
 }
 quote(shop,customer,rawCode,items){
  if(rawCode==null||rawCode==='')return null;
  const c=this.s.one('SELECT * FROM delivery_coupons WHERE shop_id=? AND code=?',shop,code(rawCode)),now=this.s.now();
  if(!c||!c.active||now<c.starts_at||now>=c.ends_at)fail(409,'Coupon unavailable or expired');
  const used=this.s.one('SELECT count(*) total,coalesce(sum(customer_id=?),0) customer FROM delivery_coupon_redemptions WHERE coupon_id=?',customer,c.id);
  if(used.total>=c.max_uses||used.customer>=c.per_customer)fail(409,'Coupon use limit reached');
  // A product promotion and a coupon never discount the same goods twice.
  const eligible=items.filter(i=>!(i.discount_uzs>0)).reduce((sum,i)=>sum+i.price_uzs*i.quantity,0);
  if(eligible<c.min_goods_uzs)fail(409,'Coupon minimum goods amount not reached');
  const price=promotionalPrice(eligible,c,now);if(!price.discount_uzs)fail(409,'No eligible goods for coupon');
  return {id:c.id,code:c.code,version:c.version,kind:c.kind,amount:c.amount,starts_at:c.starts_at,ends_at:c.ends_at,eligible_subtotal_uzs:eligible,discount_uzs:price.discount_uzs,funding:'merchant'};
 }
 validate(shop,customer,snapshot){
  if(!snapshot.coupon)return;
  const c=this.quote(shop,customer,snapshot.coupon.code,snapshot.items);
  if(c.id!==snapshot.coupon.id||c.version!==snapshot.coupon.version||c.discount_uzs!==snapshot.coupon.discount_uzs)fail(409,'Coupon changed; calculate again');
 }
 redeem(order,customer,snapshot){
  if(!snapshot.coupon)return;
  this.s.run('INSERT INTO delivery_coupon_redemptions VALUES(?,?,?,?,?)',order,snapshot.coupon.id,customer,snapshot.coupon.discount_uzs,this.s.now());
 }
}
