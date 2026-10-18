import { DeliveryError } from './store.mjs';
const fail=(status,message)=>{throw new DeliveryError(status,message);};
const installation=value=>{if(typeof value!=='string'||!/^[A-Za-z0-9_-]{16,100}$/.test(value))fail(422,'Invalid installation');return value;};
const kinds={pending_shop:'order_created',confirmed:'order_confirmed',ready:'order_ready',assigned:'courier_assigned',accepted:'courier_accepted',picked_up:'goods_picked_up',completed:'order_completed',cancelled:'order_cancelled',rejected:'order_rejected'};
export class Notifications{
 constructor(store){this.s=store;}
 emit(order,kind,eventKey,reference=null){
  const s=this.s;
  const inserted=s.run('INSERT OR IGNORE INTO delivery_notifications(customer_id,order_id,kind,event_key,reference_id,created_at) VALUES(?,?,?,?,?,?)',order.customer_id,order.id,kind,eventKey,reference,s.now());
  if(!inserted.changes)return;
  const notice=s.one('SELECT id FROM delivery_notifications WHERE event_key=?',eventKey);
  s.run(`INSERT OR IGNORE INTO delivery_push_outbox(notification_id,device_id,generation,next_attempt_at,created_at)
   SELECT ?,id,generation,?,? FROM delivery_push_devices WHERE customer_id=? AND enabled=1 AND updated_at>?`,notice.id,s.now(),s.now(),order.customer_id,s.now()-30*86400000);
 }
 transition(order,status,action){
  if(order.status===status&&action!=='set_ready_time')return;
  const pickup=JSON.parse(order.snapshot).fulfillment==='pickup';
  const kind=action==='set_ready_time'&&pickup?'pickup_time_changed':status==='ready'&&pickup?'pickup_ready':kinds[status];
  if(kind)this.emit(order,kind,kind==='pickup_ready'?'pickup-ready:'+order.id:`order:${order.id}:${order.version+1}:${kind}`);
 }
 list(identity,{before}={}){
  const customer=this.s.customer(identity);
  if(before!==undefined&&(!Number.isSafeInteger(before)||before<1))fail(422,'Invalid notification cursor');
  return this.s.all(`SELECT n.id,n.order_id,n.kind,n.reference_id,n.created_at,n.read_at,o.status,o.snapshot,c.status AS complaint_status
   FROM delivery_notifications n JOIN delivery_orders o ON o.id=n.order_id LEFT JOIN delivery_complaints c ON n.kind='complaint_updated' AND c.id=n.reference_id
   WHERE n.customer_id=? AND o.customer_id=? AND (? IS NULL OR n.id<?) ORDER BY n.id DESC LIMIT 100`,customer.id,customer.id,before??null,before??null).map(({snapshot,...row})=>({...row,shop_name:JSON.parse(snapshot).shop_name,pickup:JSON.parse(snapshot).pickup}));
 }
 summary(identity){const c=this.s.customer(identity);return {unread:this.s.one('SELECT count(*) n FROM delivery_notifications WHERE customer_id=? AND read_at IS NULL',c.id).n};}
 read(identity,id,key){
  const customer=this.s.customer(identity);if(!Number.isSafeInteger(id)||id<1)fail(422,'Invalid notification');
  return this.s.command('passenger:'+customer.id,key,{action:'read_pickup_notice',id},()=>{
   if(!this.s.one('SELECT 1 FROM delivery_notifications WHERE id=? AND customer_id=?',id,customer.id))fail(404,'Notification not found');
   this.s.run('UPDATE delivery_notifications SET read_at=coalesce(read_at,?) WHERE id=? AND customer_id=?',this.s.now(),id,customer.id);
   return this.s.one('SELECT id,read_at FROM delivery_notifications WHERE id=? AND customer_id=?',id,customer.id);
  });
 }
 register(identity,input,key){
  const c=this.s.customer(identity),id=installation(input.installation_id),fid=input.fid,lang=input.lang;
  if(typeof fid!=='string'||!/^[A-Za-z0-9_-]{16,200}$/.test(fid)||!['ru','uz'].includes(lang)||Object.keys(input).some(k=>!['installation_id','fid','lang'].includes(k)))fail(422,'Invalid Android registration');
  return this.s.command('passenger:'+c.id,key,{action:'register_android_push',id,fid,lang},()=>{
   const own=this.s.one('SELECT * FROM delivery_push_devices WHERE id=?',id),other=this.s.one('SELECT * FROM delivery_push_devices WHERE fid=?',fid);
   if((own&&own.customer_id!==c.id&&own.enabled)||(other&&other.customer_id!==c.id&&other.enabled))fail(409,'Installation is still bound to another account; disable it first');
   if((!own||!own.enabled||own.customer_id!==c.id)&&this.s.one('SELECT count(*) n FROM delivery_push_devices WHERE customer_id=? AND enabled=1',c.id).n>=5)fail(409,'Disable an old installation first');
   if(other&&other.id!==id){this.s.run("UPDATE delivery_push_outbox SET status='discarded',claim=NULL,lease_until=NULL WHERE device_id=? AND status IN ('pending','retry','sending')",other.id);this.s.run('UPDATE delivery_push_devices SET fid=?,enabled=0,generation=generation+1 WHERE id=?','revoked_'+other.id,other.id);}
   if(!own)this.s.run('INSERT INTO delivery_push_devices(id,customer_id,fid,lang,enabled,created_at,updated_at) VALUES(?,?,?,?,1,?,?)',id,c.id,fid,lang,this.s.now(),this.s.now());
   else this.s.run('UPDATE delivery_push_devices SET customer_id=?,fid=?,lang=?,enabled=1,generation=generation+?,updated_at=? WHERE id=?',c.id,fid,lang,own.fid===fid&&own.enabled&&own.customer_id===c.id?0:1,this.s.now(),id);
   return {enabled:true,installation_id:id};
  });
 }
 revoke(identity,input,key){
  const c=this.s.customer(identity),id=installation(input.installation_id);
  return this.s.command('passenger:'+c.id,key,{action:'revoke_android_push',id},()=>{
   const row=this.s.one('SELECT customer_id FROM delivery_push_devices WHERE id=?',id);if(row&&row.customer_id!==c.id)fail(404,'Installation not found');
   this.s.run('UPDATE delivery_push_devices SET enabled=0,generation=generation+1,updated_at=? WHERE id=? AND customer_id=?',this.s.now(),id,c.id);
   this.s.run("UPDATE delivery_push_outbox SET status='discarded',claim=NULL,lease_until=NULL WHERE device_id=? AND status IN ('pending','retry','sending')",id);
   return {enabled:false,installation_id:id};
  });
 }
}
