import { DeliveryError, distanceMeters } from './store.mjs';

/** Existing host TM methods only. No Yandex price formula or local fare fallback. */
export function createTaxiMasterRoadPricing({ catalog, analyzeRoute, calculateCost, time }) {
  return {
    async options() {
      const definitions = await catalog();
      return { tariffs:[...definitions.tariffs].filter(([,v])=>v.is_active===true).map(([id,v])=>({id,name:v.name||String(id)})),
        groups:[...definitions.groups].map(([id,v])=>({id,name:v.name||String(id)})) };
    },
    async calculate({ customer, shop, destination, pricing }) {
      const definitions=await catalog();
      if(definitions.tariffs.get(pricing.tariff_id)?.is_active!==true || !definitions.groups.has(pricing.crew_group_id)) throw new Error('Delivery tariff unavailable');
      const source={address:shop.address,lat:shop.lat,lon:shop.lon},sourceTime=time();
      const route=await analyzeRoute(source,destination);
      if(!['city_dist','country_dist'].every(k=>typeof route[k]==='number'&&Number.isFinite(route[k])&&route[k]>=0) || !Array.isArray(route.full_route_coords) || route.full_route_coords.length<2) throw new Error('Road route unavailable');
      const distance_m=Math.ceil((route.city_dist+route.country_dist)*1000);
      if(route.full_route_coords.some(p=>!p||!Number.isFinite(p.lat)||!Number.isFinite(p.lon)||Math.abs(p.lat)>90||Math.abs(p.lon)>180) || distance_m+100<distanceMeters(source,destination))throw new Error('Road route is incomplete');
      if(!Number.isSafeInteger(distance_m) || distance_m>pricing.max_distance_m) throw new DeliveryError(422,'Address too far from store by road');
      const cost=await calculateCost({session:{clientId:Number(customer.id)},source,destination,route,tariffId:pricing.tariff_id,crewGroupId:pricing.crew_group_id,sourceTime});
      const delivery_uzs=typeof cost.sum==='number'||typeof cost.sum==='string'&&/^\d+(?:\.0+)?$/.test(cost.sum)?Number(cost.sum):NaN;
      if(!Number.isSafeInteger(delivery_uzs)||delivery_uzs<1||delivery_uzs>100_000_000)throw new Error('Delivery fare unavailable');
      return {distance_m,delivery_uzs};
    },
  };
}

export function createRoadQuotes(store,provider) {
  const pending=new Set();
  return async (identity,input)=>{
    const context=store.roadQuoteContext(identity,input);
    if(!provider)throw new DeliveryError(503,'Road pricing is not connected');
    if(pending.size>=8||pending.has(context.customer.id))throw new DeliveryError(429,'A delivery calculation is already running; retry later');
    pending.add(context.customer.id);
    try {
      let quote;
      try { quote=await provider.calculate(context); }
      catch(e) { if(e instanceof DeliveryError)throw e;throw new DeliveryError(503,'Road route or TaxiMaster price unavailable; retry later'); }
      return store.quote(identity,input,{...quote,context});
    } finally { pending.delete(context.customer.id); }
  };
}
