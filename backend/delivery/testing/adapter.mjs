import { isTestIsolation } from '../runtime-mode.mjs';
/** TEST ONLY. Fixed fixture prices are not TaxiMaster tariffs. No network access. */
export function createTestAdapters(store,{delivery_uzs=6000,distance_m=2000}={}) {
 if(!isTestIsolation(store.testIsolation,store.testIsolationPath))throw new Error('Isolated TEST store required');
 const remote=new Map();let sequence=1000;
 return {
  pricing:{environment:'TEST',options:async()=>({tariffs:[{id:27,name:'TEST delivery'}],groups:[{id:3,name:'TEST crew group'}]}),calculate:async()=>({source:'TEST',delivery_uzs,distance_m})},
  transport:{environment:'TEST',options:async()=>({crews:[{id:4,driver_id:5,name:'TEST courier'}],tariffs:[{id:27,name:'TEST delivery'}]}),
   prepare:async(job,order,snapshot)=>({driver_id:5,body:{customer:job.marker,client_id:Number(order.customer_id),crew_id:job.crew_id,driver_id:5,tariff_id:job.tariff_id,total_sum:snapshot.delivery_uzs}}),
   create:async body=>{const order_id=++sequence;remote.set(order_id,{...body,order_id,state_kind:'driver_assigned',confirmed:'not_confirmed',is_prior:false});return {order_id};},
   read:async id=>{if(!remote.has(id))throw new Error('TEST order not found');return {...remote.get(id)};},find:async job=>[...remote.values()].filter(o=>o.customer===job.marker),
  },
  // Test fixture control only, never part of the production TM adapter.
  setState(id,patch){if(!remote.has(id))throw new Error('TEST order not found');Object.assign(remote.get(id),patch);},
 };
}
