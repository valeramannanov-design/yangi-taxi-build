// Our authenticated driver-location response metadata, not new CommonAPI fields.
// TM coords_time is a local YYYYMMDDhhmmss wall time in configured TM_TIME_ZONE.
const formatters=new Map();
function formatter(zone){
 if(!formatters.has(zone))formatters.set(zone,new Intl.DateTimeFormat('en-GB',{timeZone:zone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}));
 return formatters.get(zone);
}
function partsAt(epoch,zone){
 const p=Object.fromEntries(formatter(zone).formatToParts(new Date(epoch)).filter(x=>x.type!=='literal').map(x=>[x.type,Number(x.value)]));
 return [p.year,p.month,p.day,p.hour,p.minute,p.second];
}
const wall=parts=>Date.UTC(parts[0],parts[1]-1,...parts.slice(2));
export function taxiCoordinateEpoch(value,zone){
 if(typeof zone!=='string'||!zone)return null;
 if(typeof value!=='string'||!/^\d{14}$/.test(value))return null;
 const p=[Number(value.slice(0,4)),Number(value.slice(4,6)),Number(value.slice(6,8)),Number(value.slice(8,10)),Number(value.slice(10,12)),Number(value.slice(12,14))],local=wall(p);
 if(p[0]<1970||!Number.isFinite(local))return null;
 const d=new Date(local);
 if([d.getUTCFullYear(),d.getUTCMonth()+1,d.getUTCDate(),d.getUTCHours(),d.getUTCMinutes(),d.getUTCSeconds()].some((v,i)=>v!==p[i]))return null;
 try{
  const candidates=new Set();
  // Check both sides of an offset transition; ambiguous/nonexistent local times
  // are rejected rather than making an hour-old coordinate look fresh.
  for(const delta of [-86400000,0,86400000]){
   const sample=local+delta,offset=wall(partsAt(sample,zone))-sample,candidate=local-offset;
   if(partsAt(candidate,zone).every((v,i)=>v===p[i]))candidates.add(candidate);
  }
  return candidates.size===1?[...candidates][0]:null;
 }catch{return null;}
}
export function driverTracking(state,location,{timeZone,now=Date.now()}={}){
 const observed=taxiCoordinateEpoch(location?.coords_time,timeZone),age=observed===null?null:Math.floor((now-observed)/1000);
 const matches=Number.isSafeInteger(state?.crew_id)&&state.crew_id>0&&location?.crew_id===state.crew_id;
 const point=typeof location?.lat==='number'&&Number.isFinite(location.lat)&&Math.abs(location.lat)<=90&&typeof location?.lon==='number'&&Number.isFinite(location.lon)&&Math.abs(location.lon)<=180;
 return {source:'TaxiMaster',checked_at:now,location_observed_at:observed,location_age_seconds:age,available:matches&&point&&age!==null&&age>=0&&age<=120};
}
