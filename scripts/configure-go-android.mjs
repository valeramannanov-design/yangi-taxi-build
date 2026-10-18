import { readFileSync,writeFileSync,mkdirSync } from 'node:fs';
import { resolve,join } from 'node:path';
// Generated Android platform stays ignored; this reproducible step is tracked.
const args=process.argv.slice(2),root=resolve(args[0]||'flutter/android'),values=args[1]?JSON.parse(readFileSync(resolve(args[1]),'utf8').replace(/^\uFEFF/,'')):{};
if(/-----BEGIN (?:RSA )?PRIVATE KEY-----/.test(JSON.stringify(values))||values.type==='service_account')throw new Error('Server credentials are forbidden in Android build defines');
const manifest=join(root,'app/src/main/AndroidManifest.xml');let xml=readFileSync(manifest,'utf8');
if(!xml.includes('android.permission.POST_NOTIFICATIONS'))xml=xml.replace('<application','<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />\n    <application');
if(!xml.includes('firebase_messaging_auto_init_enabled'))xml=xml.replace('</application>','<meta-data android:name="firebase_messaging_auto_init_enabled" android:value="false" />\n    </application>');
writeFileSync(manifest,xml);
const keys=['GO_FIREBASE_API_KEY','GO_FIREBASE_APP_ID','GO_FIREBASE_SENDER_ID','GO_FIREBASE_PROJECT_ID'];
const configured=keys.filter(k=>typeof values[k]==='string'&&values[k]);
if(configured.length&&configured.length!==4)throw new Error('All four Android Firebase client options are required');
const names=['google_api_key','google_app_id','gcm_defaultSenderId','project_id'];
const escape=v=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));
const dir=join(root,'app/src/main/res/values');mkdirSync(dir,{recursive:true});
// Empty resources replace stale prior configurations too. Keys here are public
// client identifiers; service-account/private keys must never enter this file.
writeFileSync(join(dir,'go_firebase.xml'),'<resources>\n'+(configured.length?keys.map((k,i)=>`<string name="${names[i]}" translatable="false">${escape(values[k])}</string>`).join('\n'):'')+'\n</resources>\n');
console.log('Android notification permission configured; FCM client '+(configured.length?'configured':'disabled'));
