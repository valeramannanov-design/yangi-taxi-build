import { readFileSync } from 'node:fs';
import { isAbsolute } from 'node:path';
import { createPrivateKey, sign, randomUUID } from 'node:crypto';
const oauth='https://oauth2.googleapis.com/token';
const encode=value=>Buffer.from(JSON.stringify(value)).toString('base64url');
const safeError=(code,revoke=false,retryAfter=0)=>Object.assign(new Error(code),{pushCode:code,revoke,retryAfter});
/** Actual FCM HTTP v1 adapter. No network request until explicitly configured and ticked. */
export function createAndroidFcm({account,projectId=account?.project_id,request=fetch,now=()=>Date.now()}){
 if(!/^[a-z][a-z0-9-]{4,62}$/.test(projectId||'')||account?.type!=='service_account'||typeof account.client_email!=='string'||!account.client_email.endsWith('.gserviceaccount.com'))throw new Error('Invalid FCM service account configuration');
 const key=createPrivateKey(account.private_key);if(key.asymmetricKeyType!=='rsa')throw new Error('FCM requires an RSA service account key');
 let cached=null;
 async function access(){
  if(cached&&cached.expires>now()+60000)return cached.token;
  const iat=Math.floor(now()/1000),body=encode({alg:'RS256',typ:'JWT'})+'.'+encode({iss:account.client_email,scope:'https://www.googleapis.com/auth/firebase.messaging',aud:oauth,iat,exp:iat+3600});
  const jwt=body+'.'+sign('RSA-SHA256',Buffer.from(body),key).toString('base64url');
  const r=await request(oauth,{method:'POST',redirect:'error',headers:{'content-type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'urn:ietf:params:oauth:grant-type:jwt-bearer',assertion:jwt}),signal:AbortSignal.timeout(10000)});
  const v=await r.json();if(!r.ok||typeof v.access_token!=='string'||!Number.isFinite(v.expires_in))throw safeError('FCM_AUTH');
  cached={token:v.access_token,expires:now()+Math.min(v.expires_in,3600)*1000};return cached.token;
 }
 return {environment:'production',projectId,async send({fid,lang,noticeId}){
  const token=await access();
  const r=await request('https://fcm.googleapis.com/v1/projects/'+projectId+'/messages:send',{method:'POST',redirect:'error',signal:AbortSignal.timeout(10000),headers:{authorization:'Bearer '+token,'content-type':'application/json'},body:JSON.stringify({message:{fid,
   // Generic lock-screen text: no names, addresses, phone, fare or complaint text.
   notification:{title:'Yangi Taxi GO',body:lang==='uz'?'Buyurtmangizda yangilik bor. Ilovani oching.':'Есть обновление по заказу. Откройте приложение.'},
   data:{go_notice:String(noticeId)},android:{priority:'high',ttl:'86400s',notification:{tag:'go-'+noticeId,visibility:'PRIVATE'}}}})});
  const v=await r.json();if(!r.ok){
   if(r.status===401)cached=null;
   const unregistered=Array.isArray(v.error?.details)&&v.error.details.some(d=>d['@type']==='type.googleapis.com/google.firebase.fcm.v1.FcmError'&&d.errorCode==='UNREGISTERED');
   const retry=Number(r.headers?.get('retry-after'));throw safeError(unregistered?'FCM_UNREGISTERED':r.status===429?'FCM_QUOTA':r.status===401||r.status===403?'FCM_AUTH':r.status>=500?'FCM_SERVER':'FCM_REJECTED',unregistered,Number.isFinite(retry)?Math.min(3600,Math.max(0,retry))*1000:0);
  }
  if(typeof v.name!=='string'||!v.name.startsWith('projects/'+projectId+'/messages/'))throw safeError('FCM_RESPONSE');
  return {messageId:v.name}; // Acceptance by FCM is not delivery/read proof.
 }};
}
export function androidFcmFromEnv(env=process.env){
 if(env.DELIVERY_PUSH_ENABLED!=='true')return null;
 if(!env.DELIVERY_FCM_SERVICE_ACCOUNT_FILE||!isAbsolute(env.DELIVERY_FCM_SERVICE_ACCOUNT_FILE))throw new Error('Absolute private FCM service-account file required');
 try{return createAndroidFcm({account:JSON.parse(readFileSync(env.DELIVERY_FCM_SERVICE_ACCOUNT_FILE,'utf8')),projectId:env.DELIVERY_FCM_PROJECT_ID||undefined});}
 catch{throw new Error('Invalid private Android FCM configuration');}
}
export class AndroidPushWorker{
 constructor(store,provider){if(store.testIsolation&&provider.environment!=='TEST')throw new Error('Real push is forbidden in an isolated TEST host');this.s=store;this.provider=provider;this.running=false;}
 async tick(){
  if(this.running)return;this.running=true;
  try{for(let i=0;i<20;i++){
   const job=this.s.transaction(()=>{
    const now=this.s.now(),j=this.s.one(`SELECT q.*,n.customer_id,n.read_at,d.fid,d.lang,d.enabled,d.customer_id AS device_customer,d.generation AS device_generation
     FROM delivery_push_outbox q JOIN delivery_notifications n ON n.id=q.notification_id JOIN delivery_push_devices d ON d.id=q.device_id
     WHERE (q.status IN ('pending','retry') AND q.next_attempt_at<=?) OR (q.status='sending' AND q.lease_until<=?) ORDER BY q.id LIMIT 1`,now,now);
    if(!j)return null;
    if(!j.enabled||j.generation!==j.device_generation||j.customer_id!==j.device_customer||j.read_at!==null||j.created_at<now-86400000||j.attempts>=8){this.s.run("UPDATE delivery_push_outbox SET status='discarded',claim=NULL,lease_until=NULL WHERE id=?",j.id);return {skip:true};}
    const claim=randomUUID();this.s.run("UPDATE delivery_push_outbox SET status='sending',claim=?,lease_until=?,attempts=attempts+1 WHERE id=?",claim,now+60000,j.id);return {...j,claim};
   });
   if(!job)break;if(job.skip)continue;
   try{
    const result=await this.provider.send({fid:job.fid,lang:job.lang,noticeId:job.notification_id});
    this.s.run("UPDATE delivery_push_outbox SET status='sent',provider_message_id=?,last_error=NULL,lease_until=NULL,claim=NULL WHERE id=? AND status='sending' AND claim=?",String(result.messageId).slice(0,240),job.id,job.claim);
   }catch(e){this.s.transaction(()=>{
    const code=['FCM_UNREGISTERED','FCM_AUTH','FCM_QUOTA','FCM_SERVER','FCM_REJECTED','FCM_RESPONSE'].includes(e.pushCode)?e.pushCode:'PUSH_NETWORK';
    const permanent=e.revoke===true||code==='FCM_REJECTED'||job.attempts>=7;
    this.s.run("UPDATE delivery_push_outbox SET status=?,last_error=?,next_attempt_at=?,claim=NULL,lease_until=NULL WHERE id=? AND status='sending' AND claim=?",permanent?'failed':'retry',code,this.s.now()+Math.max(30000,Math.min(3600000,e.retryAfter||30000*2**job.attempts)),job.id,job.claim);
    if(e.revoke===true)this.s.run('UPDATE delivery_push_devices SET enabled=0,generation=generation+1 WHERE id=? AND generation=? AND fid=?',job.device_id,job.generation,job.fid);
   });}
  }}finally{this.running=false;}
 }
}
