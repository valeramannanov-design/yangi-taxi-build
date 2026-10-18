import { DeliveryError } from './store.mjs';
const fail=(status,message)=>{throw new DeliveryError(status,message);};
function comment(value=''){
 if(typeof value!=='string'||value.trim().length>1000||/[\x00-\x08\x0b-\x1f\x7f]/u.test(value))fail(422,'Invalid review text');
 return value.trim();
}
export class Reviews{
 constructor(store){this.s=store;}
 owned(customer,id){
  const order=this.s.one('SELECT * FROM delivery_orders WHERE id=? AND customer_id=?',id,customer.id);
  if(!order)fail(404,'Order not found');return order;
 }
 targets(order){
  if(order.status!=='completed')return [];
  const targets=['shop'],snapshot=JSON.parse(order.snapshot);
  // Only the final bound courier, never a passenger-supplied driver ID.
  if(snapshot.fulfillment!=='pickup'&&Number.isSafeInteger(order.driver_id)&&order.driver_id>0&&Number.isSafeInteger(order.transport_order_id)&&order.transport_order_id>0)targets.push('courier');
  return targets;
 }
 rows(orderId){return this.s.all('SELECT r.id,r.target,r.rating,r.comment,r.created_at,c.status AS complaint_status FROM delivery_reviews r LEFT JOIN delivery_complaints c ON c.review_id=r.id WHERE r.order_id=? ORDER BY r.id',orderId);}
 forCustomer(identity,id){const customer=this.s.customer(identity),order=this.owned(customer,id);return {eligible_targets:this.targets(order),reviews:this.rows(id)};}
 submit(identity,id,input,key){
  const customer=this.s.customer(identity),target=input.target,rating=input.rating,note=comment(input.comment);
  if(!['shop','courier'].includes(target)||!Number.isSafeInteger(rating)||rating<1||rating>5)fail(422,'Select a target and rating from 1 to 5');
  if(Object.keys(input).some(k=>!['target','rating','comment'].includes(k)))fail(422,'Unsupported review field');
  return this.s.command('passenger:'+customer.id,key,{action:'go_review',id,target,rating,comment:note},()=>{
   const order=this.owned(customer,id);
   if(!this.targets(order).includes(target))fail(409,'This completed order cannot be rated for that target');
   const existing=this.s.one('SELECT * FROM delivery_reviews WHERE order_id=? AND target=?',id,target);
   if(existing){if(existing.rating!==rating||existing.comment!==note)fail(409,'Review already submitted');return this.forCustomer(customer,id);}
   const reviewId=Number(this.s.run('INSERT INTO delivery_reviews(order_id,customer_id,target,target_id,rating,comment,created_at) VALUES(?,?,?,?,?,?,?)',id,customer.id,target,target==='shop'?order.shop_id:order.driver_id,rating,note,this.s.now()).lastInsertRowid);
   if(rating<=2){
    const complaintId=Number(this.s.run('INSERT INTO delivery_complaints(review_id,created_at,updated_at) VALUES(?,?,?)',reviewId,this.s.now(),this.s.now()).lastInsertRowid);
    this.s.run("INSERT INTO delivery_complaint_events(complaint_id,actor,status,note,created_at) VALUES(?,?,'open','Low rating',?)",complaintId,'passenger:'+customer.id,this.s.now());
   }
   return this.forCustomer(customer,id);
  });
 }
 summary(shopId){const row=this.s.one("SELECT count(*) AS count,avg(rating) AS average FROM delivery_reviews WHERE target='shop' AND target_id=?",shopId);return {count:row.count,average:row.average===null?null:Math.round(row.average*100)/100};}
 forStaff(user){
  if(user.role==='admin')return this.s.all('SELECT r.id,r.order_id,r.target,r.target_id,r.rating,r.comment,r.created_at,o.shop_id FROM delivery_reviews r JOIN delivery_orders o ON o.id=r.order_id ORDER BY r.id DESC LIMIT 200');
  const shop=this.s.partner(user);return this.s.all("SELECT r.id,r.order_id,r.target,r.rating,r.comment,r.created_at FROM delivery_reviews r WHERE r.target='shop' AND r.target_id=? ORDER BY r.id DESC LIMIT 200",shop);
 }
 complaints(user){
  this.s.admin(user);return this.s.all('SELECT c.*,r.order_id,r.target,r.target_id,r.rating,r.comment,o.shop_id FROM delivery_complaints c JOIN delivery_reviews r ON r.id=c.review_id JOIN delivery_orders o ON o.id=r.order_id ORDER BY c.id DESC LIMIT 200').map(row=>({...row,events:this.s.all('SELECT actor,status,note,created_at FROM delivery_complaint_events WHERE complaint_id=? ORDER BY id',row.id)}));
 }
 updateComplaint(user,id,input,key){
  this.s.admin(user);const status=input.status,note=comment(input.note),version=input.version;
  if(!Number.isSafeInteger(id)||id<1||!Number.isSafeInteger(version)||version<1||!['open','in_review','resolved'].includes(status)||!note)fail(422,'Provide complaint status, version and handling note');
  return this.s.command('admin:'+user.id,key,{action:'go_complaint',id,version,status,note},()=>{
   const row=this.s.one('SELECT * FROM delivery_complaints WHERE id=?',id);if(!row)fail(404,'Complaint not found');
   if(row.version!==version||row.status===status)fail(409,'Complaint changed; refresh');
   this.s.run('UPDATE delivery_complaints SET status=?,version=version+1,updated_at=? WHERE id=? AND version=?',status,this.s.now(),id,version);
   this.s.run('INSERT INTO delivery_complaint_events(complaint_id,actor,status,note,created_at) VALUES(?,?,?,?,?)',id,'admin:'+user.id,status,note,this.s.now());
   const review=this.s.one('SELECT order_id FROM delivery_reviews WHERE id=?',row.review_id),order=this.s.one('SELECT * FROM delivery_orders WHERE id=?',review.order_id);
   this.s.notifications.emit(order,'complaint_updated',`complaint:${id}:${version+1}`,id);
   return this.s.one('SELECT * FROM delivery_complaints WHERE id=?',id);
  });
 }
}
