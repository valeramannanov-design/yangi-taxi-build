/** Dedicated loopback TEST host. Never imports server.mjs or live configuration. */
import http from 'node:http';
import { randomUUID, randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { DeliveryStore, DeliveryError } from '../store.mjs';
import { isolatedTestPermit } from '../runtime-mode.mjs';
import { createTestAdapters } from './adapter.mjs';
import { createDeliveryHandler } from '../http.mjs';
import { DeliveryTransport } from '../transport.mjs';
import { createDeliveryBridge } from '../bridge.mjs';
import { listenForFetch } from './listen.mjs';
export async function startTestHost(){
 const path=join(tmpdir(),'yangi-go-test-'+randomUUID()+'.sqlite');
 const permit=isolatedTestPermit(path),store=new DeliveryStore(path,{testIsolation:permit});
 const password=randomBytes(24).toString('base64url'),passengerToken=randomBytes(32).toString('base64url'),bridgeToken=randomBytes(32).toString('base64url');
 store.createAdmin('test-admin',password);const adminToken=store.login('test-admin',password,'TEST').token,admin=store.identity(adminToken);
 const category=store.category(admin,{name:'TEST food',active:true});
 let shop=store.createShop(admin,{name:'TEST restaurant — no cooking',login:'test-merchant',password,category_id:category.id,zone_id:null,lat:40,lon:65,address:'TEST store',commission_bps:0,service_kind:'food'});
 store.updateShop(admin,shop.id,{...shop,active:true});const merchantToken=store.login('test-merchant',password,'TEST').token;
 const product=store.saveProduct(store.identity(merchantToken),{sku:'TEST',name:'TEST goods — not for delivery',price_uzs:25000,stock:85,active:true});
 store.savePricing(admin,{enabled:true,tariff_id:27,crew_group_id:3,max_distance_m:30000,version:1});
 const adapters=createTestAdapters(store),transport=new DeliveryTransport(store,adapters.transport),bridge=createDeliveryBridge({transport,token:bridgeToken});
 const handler=createDeliveryHandler({store,transport,pricingProvider:adapters.pricing,passengerIdentity:req=>{
  if(req.headers.authorization!=='Bearer '+passengerToken)throw new DeliveryError(401,'TEST passenger token required');
  return {id:'101',phone:'+998900000001'};
 }});
 const server=http.createServer(async(req,res)=>{
  try{
   // Test fixture control has no counterpart in the production server/HTTP API.
   if(req.url==='/test/taximaster'&&req.method==='POST'){
    if(req.headers.authorization!=='Bearer '+adminToken)throw new DeliveryError(403,'TEST admin required');
    let raw='';for await(const part of req){raw+=part;if(raw.length>4096)throw new DeliveryError(413,'Too large');}
    const body=JSON.parse(raw);if(!['driver_assigned','car_at_place','client_inside','finished','aborted'].includes(body.state_kind))throw new DeliveryError(422,'TEST state required');
    adapters.setState(body.order_id,{state_kind:body.state_kind,confirmed:'confirmed_by_driver',...(body.state_kind==='finished'?{cash_sum:6000,cashless_sum:0,bonus_sum:0,bank_card_sum:0}:{})});
    await transport.tick();res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({ok:true,environment:'TEST'}));return;
   }
   if(await bridge(req,res)||await handler(req,res))return;
   res.writeHead(404);res.end('Isolated GO TEST host');
  }catch(e){res.writeHead(e.statusCode||500,{'content-type':'application/json'});res.end(JSON.stringify({error:'TEST request rejected'}));}
 });
 await listenForFetch(server);
 return {base:'http://127.0.0.1:'+server.address().port,path,store,transport,adminToken,merchantToken,passengerToken,bridgeToken,shop_id:shop.id,product_id:product.id,
  async close(){await new Promise(resolve=>server.close(resolve));store.close();}};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 const host=await startTestHost();
 const accessFile=host.path+'.access.private.json';
 writeFileSync(accessFile,JSON.stringify({environment:'TEST',base:host.base,adminToken:host.adminToken,merchantToken:host.merchantToken,passengerToken:host.passengerToken,bridgeToken:host.bridgeToken,shop_id:host.shop_id,product_id:host.product_id},null,2),{mode:0o600});
 console.log('GO TEST only: '+host.base+'; local access file: '+accessFile);
 for(const signal of ['SIGINT','SIGTERM'])process.on(signal,async()=>{await host.close();process.exit(0);});
}
