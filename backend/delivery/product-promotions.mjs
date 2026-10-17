import { DeliveryError } from './store.mjs';
const fail=()=>{throw new DeliveryError(422,'Invalid product promotion');};
// Own catalog contract: discounts are funded by the merchant through a lower
// goods buyout price. Never apply them to the TaxiMaster transport result.
export function validatePromotion(value){
 if(value===null)return null;
 if(!value||typeof value!=='object'||Array.isArray(value))fail();
 const {kind,amount,starts_at,ends_at}=value;
 if(!['percent','fixed'].includes(kind)||!Number.isSafeInteger(amount)||amount<1||amount>(kind==='percent'?100:10000000))fail();
 if(!Number.isSafeInteger(starts_at)||!Number.isSafeInteger(ends_at)||starts_at<0||ends_at<=starts_at||ends_at>8640000000000000)fail();
 return {kind,amount,starts_at,ends_at};
}
export function promotionalPrice(price,promotion,now){
 if(!promotion||now<promotion.starts_at||now>=promotion.ends_at)return {price_uzs:price};
 const discount=promotion.kind==='percent'?Math.floor(price*promotion.amount/100):Math.min(price,promotion.amount);
 return discount>0?{price_uzs:price-discount,original_price_uzs:price,discount_uzs:discount,promotion:{...promotion,funding:'merchant'}}:{price_uzs:price};
}
