import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync,mkdirSync,readFileSync,writeFileSync,rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join,resolve,dirname,basename } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
test('generated Android config is opt-in, repeatable, clears stale project and never packages service-account keys',t=>{
 const dir=mkdtempSync(join(tmpdir(),'yangi-notification-config-'));t.after(()=>{const p=resolve(dir);assert.equal(dirname(p),resolve(tmpdir()));assert.ok(basename(p).startsWith('yangi-notification-config-'));rmSync(p,{recursive:true,force:true});});
 const manifest=join(dir,'app/src/main/AndroidManifest.xml');mkdirSync(dirname(manifest),{recursive:true});writeFileSync(manifest,'<manifest xmlns:android="http://schemas.android.com/apk/res/android"><application></application></manifest>');
 const config=join(dir,'defines.json'),script=fileURLToPath(new URL('./configure-go-android.mjs',import.meta.url));
 const run=value=>{writeFileSync(config,JSON.stringify(value));return execFileSync(process.execPath,[script,dir,config],{stdio:'pipe'});};
 const fixture={GO_FIREBASE_API_KEY:'TEST public key',GO_FIREBASE_APP_ID:'TEST app',GO_FIREBASE_SENDER_ID:'123',GO_FIREBASE_PROJECT_ID:'test-project'};
 run(fixture);run(fixture);const xml=readFileSync(manifest,'utf8');assert.equal(xml.split('POST_NOTIFICATIONS').length-1,1);assert.equal(xml.split('firebase_messaging_auto_init_enabled').length-1,1);assert.match(xml,/android:value="false"/);
 const resources=join(dir,'app/src/main/res/values/go_firebase.xml');assert.match(readFileSync(resources,'utf8'),/name="google_app_id"/);run({});assert.equal(readFileSync(resources,'utf8').includes('test-project'),false);
 assert.throws(()=>run({GO_FIREBASE_PROJECT_ID:'partial'}));assert.throws(()=>run({type:'service_account',private_key:'TEST server only'}));
 assert.equal(readFileSync(resources,'utf8').includes('server only'),false);
});
