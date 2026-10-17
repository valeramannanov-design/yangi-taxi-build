import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, createHmac } from 'node:crypto';
import net from 'node:net';

test('actual passenger server loads optional delivery with existing authentication and taxi health', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'yangi-delivery-host-'));
  const socket = net.createServer(); await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port; await new Promise(resolve => socket.close(resolve));
  const secret = randomBytes(40).toString('hex');
  const child = spawn(process.execPath, [fileURLToPath(new URL('../server.mjs', import.meta.url))], {
    cwd: dir, env: { ...process.env, HOST: '127.0.0.1', PORT: String(port), SESSION_SECRET: secret, TM_API_MOCK: 'true', ATMOS_ENABLED: 'false', YANGI_PAYMENT_SETTLEMENT_ENABLED: 'false', DELIVERY_ENABLED: 'true', DELIVERY_DB_PATH: join(dir, 'delivery.sqlite') }, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
  });
  t.after(async () => {
    const exited = new Promise(resolve => child.once('exit', resolve));
    child.kill(); if (child.exitCode === null) await exited;
    const target = resolve(dir);
    if (dirname(target) !== resolve(tmpdir()) || !basename(target).startsWith('yangi-delivery-host-')) throw new Error('Invalid cleanup target');
    rmSync(target, { recursive: true, force: true });
  });
  await new Promise((resolve, reject) => {
    let logs = ''; const timer = setTimeout(() => reject(new Error('Passenger test server failed to become ready')), 10000);
    child.stdout.on('data', data => { logs += data.toString(); if (logs.includes('backend listening')) { clearTimeout(timer); resolve(); } });
    child.once('exit', code => { clearTimeout(timer); reject(new Error('Passenger test server exited: ' + code)); });
  });
  const base = `http://127.0.0.1:${port}`;
  const health = await (await fetch(base + '/health')).json();
  assert.equal(health.ok, true); assert.equal(health.mock, true);
  const catalog = await (await fetch(base + '/api/delivery/catalog')).json();
  assert.deepEqual(catalog.data.shops, []);
  assert.equal((await fetch(base + '/delivery')).status, 200);
  assert.equal((await fetch(base + '/api/delivery/customer/orders')).status, 401);
  const body = Buffer.from(JSON.stringify({ clientId: 101, phone: '+998900000001', exp: Date.now() + 60000 })).toString('base64url');
  const signature = createHmac('sha256', secret).update(body).digest('base64url');
  const result = await fetch(base + '/api/delivery/customer/orders', { headers: { Authorization: 'Bearer ' + body + '.' + signature } });
  assert.equal(result.status, 200); assert.deepEqual((await result.json()).data, []);
  const headers={Authorization:'Bearer '+body+'.'+signature,'content-type':'application/json'};
  const saved=await fetch(base+'/api/profile/favorites',{method:'POST',headers,body:JSON.stringify({name:'Home',address:'TEST address',lat:40,lon:65,entrance:' 2 ',floor:'3',apartment:'12A',landmark:'Near park'})});
  assert.equal(saved.status,201);const favorite=(await saved.json()).data.favorite;assert.equal(favorite.entrance,'2');
  const edited=await fetch(base+'/api/profile/favorites/'+favorite.id,{method:'POST',headers,body:JSON.stringify({floor:'4'})});
  assert.equal(edited.status,200);const updated=(await edited.json()).data.favorite;assert.equal(updated.floor,'4');assert.equal(updated.apartment,'12A');
  const invalid=await fetch(base+'/api/profile/favorites/'+favorite.id,{method:'POST',headers,body:JSON.stringify({landmark:'x'.repeat(301)})});assert.equal(invalid.status,400);
  const list=await (await fetch(base+'/api/profile/favorites',{headers})).json();assert.equal(list.data.favorites[0].landmark,'Near park');

});
