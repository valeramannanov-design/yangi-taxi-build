import { randomBytes } from 'node:crypto';
import { DeliveryError } from './store.mjs';
import { validatePromotion, promotionalPrice } from './product-promotions.mjs';
const fail=(message,code=422)=>{throw new DeliveryError(code,message);};
const amount=(value,max=10000000)=>{if(!Number.isSafeInteger(value)||value<0||value>max)fail('Invalid catalog integer');return value;};
const measure=value=>value==null||value===''?null:amount(value,1000000)||fail('Measurement must be positive');
const label=(value,max)=>{if(typeof value!=='string'||value.trim().length>max||/[\x00-\x1f\x7f]/u.test(value))fail('Invalid catalog text');return value.trim();};
const composition=value=>{if(typeof value!=='string')fail('Invalid composition');value=value.replace(/\r\n/g,'\n');if(value.trim().length>2000||/[\x00-\x08\x0b-\x1f\x7f]/u.test(value))fail('Invalid composition');return value.trim();};
const total=rows=>rows.filter(v=>v.active).reduce((sum,v)=>sum+v.stock,0);
export class ProductOptions {
 constructor(store){this.s=store;}
 describe(row,staff=false){
  const p=this.s.one('SELECT ingredients,weight_g,volume_ml,variants_json,catalog_version,promotion_json FROM delivery_products WHERE id=?',row.id);
  const {variants_json,promotion_json,...data}={...row,...p};const promotion=JSON.parse(promotion_json),variants=JSON.parse(variants_json);
  const available=variants.filter(v=>v.active&&v.stock>0);
  const base=!staff&&available.length?Math.min(...available.map(v=>v.price_uzs)):data.price_uzs;
  return {...data,...(staff?{promotion}:promotionalPrice(base,promotion,this.s.now())),has_variants:variants.length>0,variants:staff?variants:variants.filter(v=>v.active).map(v=>({...v,...promotionalPrice(v.price_uzs,promotion,this.s.now())}))};
 }
 prepare(shopId,input,productId){
  const old=productId?this.s.one('SELECT * FROM delivery_products WHERE id=? AND shop_id=?',productId,shopId):null;
  if(productId&&!old)fail('Product not found',404);
  const before=JSON.parse(old?.variants_json||'[]');let variants=before;
  if(Object.hasOwn(input,'variants')){
   if(!Array.isArray(input.variants)||input.variants.length>100)fail('Up to 50 variants allowed');
   const ids=new Set(),names=new Set();variants=input.variants.map(v=>{
    if(!v||typeof v!=='object'||Array.isArray(v))fail('Invalid variant');
    if(v.id!=null&&!before.some(b=>b.id===v.id))fail('Variant does not belong to this product');
    const id=v.id??randomBytes(18).toString('hex'),name=label(v.name,100);
    if(!name||ids.has(id)||names.has(name.toLocaleLowerCase()))fail('Unique variant names and IDs required');ids.add(id);names.add(name.toLocaleLowerCase());
    if(typeof v.active!=='boolean')fail('Variant active must be boolean');
    return {id,name,price_uzs:amount(v.price_uzs),stock:amount(v.stock,1000000),active:v.active,weight_g:measure(v.weight_g),volume_ml:measure(v.volume_ml)};
   });
   if(variants.filter(v=>v.active).length>50)fail('Up to 50 active variants allowed');
   // Never erase a variant referenced by a frozen or active order.
   variants.push(...before.filter(v=>!ids.has(v.id)).map(v=>({...v,active:false})));
   if(variants.length>100)fail('Too many retained variants');
   if(!before.length&&variants.length&&this.s.one("SELECT 1 FROM delivery_orders o,json_each(o.snapshot,'$.items') i WHERE o.shop_id=? AND o.status NOT IN ('completed','cancelled','rejected') AND json_extract(i.value,'$.product_id')=? LIMIT 1",shopId,productId??0))fail('Finish existing product orders before enabling variants',409);
  }else if(before.length&&(input.stock!==old.stock||input.price_uzs!==old.price_uzs))fail('Edit variant prices and stock explicitly',409);
  const ingredients=Object.hasOwn(input,'ingredients')?composition(input.ingredients):old?.ingredients||'';
  const weight_g=Object.hasOwn(input,'weight_g')?measure(input.weight_g):old?.weight_g??null,volume_ml=Object.hasOwn(input,'volume_ml')?measure(input.volume_ml):old?.volume_ml??null;
  const active=variants.filter(v=>v.active);
  const promotion=Object.hasOwn(input,'promotion')?validatePromotion(input.promotion):JSON.parse(old?.promotion_json??'null');
  return {ingredients,weight_g,volume_ml,variants,promotion,stock:variants.length?amount(total(variants),1000000):input.stock,price_uzs:variants.length?(active.length?Math.min(...active.map(v=>v.price_uzs)):old?.price_uzs??input.price_uzs):input.price_uzs};
 }
 write(productId,value){this.s.run('UPDATE delivery_products SET ingredients=?,weight_g=?,volume_ml=?,variants_json=?,promotion_json=?,catalog_version=catalog_version+1 WHERE id=?',value.ingredients,value.weight_g,value.volume_ml,JSON.stringify(value.variants),JSON.stringify(value.promotion),productId);}
 line(product,row){
  const variants=JSON.parse(product.variants_json),variant=row.variant_id==null?null:variants.find(v=>v.id===row.variant_id);
  if(variants.length&&(!variant||!variant.active)||!variants.length&&row.variant_id!=null)fail('Choose an available product variant',409);
  if((variant?.stock??product.stock)<row.quantity)fail('Variant unavailable',409);
  return {product_id:product.id,name:product.name,...promotionalPrice(variant?.price_uzs??product.price_uzs,JSON.parse(product.promotion_json),this.s.now()),quantity:row.quantity,catalog_version:product.catalog_version,ingredients:product.ingredients,weight_g:variant?.weight_g??product.weight_g,volume_ml:variant?.volume_ml??product.volume_ml,...(variant?{variant_id:variant.id,variant_name:variant.name}:{})};
 }
 reserve(item,shopId){
  const p=this.s.one('SELECT * FROM delivery_products WHERE id=? AND shop_id=? AND active=1',item.product_id,shopId);
  if(!p||item.catalog_version!=null&&p.catalog_version!==item.catalog_version)fail('Product changed; calculate again',409);
  const actual=this.line(p,item);if(actual.price_uzs!==item.price_uzs)fail('Price changed; calculate again',409);
  if(item.variant_id){const variants=JSON.parse(p.variants_json);variants.find(v=>v.id===item.variant_id).stock-=item.quantity;this.s.run('UPDATE delivery_products SET variants_json=?,stock=?,version=version+1 WHERE id=?',JSON.stringify(variants),total(variants),p.id);}
  else if(!this.s.run('UPDATE delivery_products SET stock=stock-?,version=version+1 WHERE id=? AND stock>=?',item.quantity,p.id,item.quantity).changes)fail('Product unavailable',409);
 }
 restore(item,shopId){
  if(!item.variant_id){this.s.run('UPDATE delivery_products SET stock=stock+?,version=version+1 WHERE id=? AND shop_id=?',item.quantity,item.product_id,shopId);return;}
  const p=this.s.one('SELECT * FROM delivery_products WHERE id=? AND shop_id=?',item.product_id,shopId),variants=JSON.parse(p.variants_json),v=variants.find(v=>v.id===item.variant_id);
  if(!v)fail('Reserved variant requires review',409);v.stock+=item.quantity;
  this.s.run('UPDATE delivery_products SET variants_json=?,stock=?,version=version+1 WHERE id=?',JSON.stringify(variants),total(variants),p.id);
 }
}
