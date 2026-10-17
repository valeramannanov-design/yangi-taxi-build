/** Own profile/delivery fields, never TaxiMaster tariff or address API fields. */
export const addressDetailLimits=Object.freeze({entrance:32,floor:16,apartment:32,landmark:300});
export function addressDetails(value,{current={},strict=true}={}) {
  const result={};
  for(const [key,limit] of Object.entries(addressDetailLimits)) {
    const raw=Object.hasOwn(value||{},key)?value[key]:current[key]??'';
    if(raw===null){result[key]='';continue;}
    if(typeof raw!=='string'||raw.trim().length>limit||/[\x00-\x1f\x7f]/u.test(raw)) {
      if(strict)throw Object.assign(new Error('Invalid address detail: '+key),{statusCode:400});
      result[key]='';
    } else result[key]=raw.trim();
  }
  return result;
}
