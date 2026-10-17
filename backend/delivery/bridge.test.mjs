import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createDeliveryBridge } from './bridge.mjs';

test('private driver bridge requires its dedicated token and verified identities', async t => {
  const calls=[],token='private-test-token-'.padEnd(43,'x');
  const bridge=createDeliveryBridge({token,transport:{
    info:async(id,identity)=>{calls.push({id,identity});return {delivery:null};},
    confirmCash:async(id,identity,amount)=>{calls.push({id,identity,amount});return {cash_confirmed:true};},
  }});
  const server=http.createServer(async(req,res)=>{if(!await bridge(req,res)){res.writeHead(404);res.end();}});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));t.after(()=>new Promise(resolve=>server.close(resolve)));
  const base='http://127.0.0.1:'+server.address().port;
  async function request(path,body,authorization='Bearer '+token){return fetch(base+path,{method:'POST',headers:{'content-type':'application/json',authorization},body:JSON.stringify(body)});}
  const identity={order_id:90,driver_id:5,crew_id:4};
  assert.equal((await request('/internal/delivery/info',identity,'Bearer passenger-token')).status,403);
  assert.equal(calls.length,0);
  assert.equal((await request('/internal/delivery/info',{...identity,driver_id:'5'})).status,422);
  assert.equal((await request('/internal/delivery/info',{...identity,completed:true})).status,422);
  assert.equal((await request('/internal/delivery/info',identity)).status,200);
  assert.equal(calls[0].identity.driver_id,5);
  assert.equal((await request('/internal/delivery/cash',{...identity,amount_uzs:25000})).status,200);
  assert.equal(calls[1].amount,25000);
  assert.equal((await request('/internal/delivery/complete',identity)).status,404);
  assert.throws(()=>createDeliveryBridge({token:'short'}));
});

test('forwarding headers cannot make a remote peer a private driver worker', async()=>{
  let invoked=false,result;
  const bridge=createDeliveryBridge({token:'x'.repeat(43),transport:{info:async()=>{invoked=true;}}});
  const req={url:'/internal/delivery/info',method:'POST',socket:{remoteAddress:'192.168.1.20'},headers:{authorization:'Bearer '+'x'.repeat(43),'x-forwarded-for':'127.0.0.1'}};
  await bridge(req,{writeHead:code=>{result=code;},end:()=>{}});
  assert.equal(result,403);assert.equal(invoked,false);
});
