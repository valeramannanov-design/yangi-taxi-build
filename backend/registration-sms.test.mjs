// Isolated integration test: fake TaxiMaster server, no real SMS or LIVE calls.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const backendDir = fileURLToPath(new URL('.', import.meta.url));

async function freePort() {
  const socket = net.createServer();
  await new Promise((resolve, reject) => socket.once('error', reject).listen(0, '127.0.0.1', resolve));
  const port = socket.address().port;
  await new Promise((resolve) => socket.close(resolve));
  return port;
}

async function bindServer(server) {
  await new Promise((resolve, reject) => server.once('error', reject).listen(0, '127.0.0.1', resolve));
  return server.address().port;
}

function reply(res, code, data) {
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify({ code, data: data || {}, ...(code ? { descr: 'Fake TaxiMaster rejected request' } : {}) }));
}

async function api(base, route, payload) {
  const result = await fetch(base + route, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(7000),
  });
  return { status: result.status, data: await result.json() };
}

async function waitUntil(predicate, limitMs = 4000) {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > limitMs) throw new Error('Timed out waiting for fake TaxiMaster call');
    await sleep(20);
  }
}

test('real-route SMS enrollment uses only fake TaxiMaster, enforces OTP and locks concurrent registration', { timeout: 25000 }, async (t) => {
  const messages = [];
  const registrations = [];
  let registerDelayMs = 0;

  const tm = http.createServer(async (req, res) => {
    const name = new URL(req.url, 'http://local').pathname.split('/').pop();
    let body = '';
    for await (const chunk of req) body += chunk.toString();
    if (name === 'send_sms') {
      const p = new URLSearchParams(body);
      const phone = p.get('phone');
      const message = p.get('message');
      messages.push({ phone, message });
      if (phone === '998901234571') return reply(res, 42);
      return reply(res, 0);
    }
    if (name === 'register_client2') {
      const p = JSON.parse(body);
      registrations.push(p);
      if (registerDelayMs) await sleep(registerDelayMs);
      if (p.login === '+998901234570') return reply(res, 0, {});
      return reply(res, 0, { client_id: 321 });
    }
    if (name === 'ping') return reply(res, 0, {});
    reply(res, 1);
  });
  const tmPort = await bindServer(tm);
  t.after(async () => new Promise(resolve => tm.close(resolve)));

  const apiPort = await freePort();
  const service = spawn(process.execPath, ['server.mjs'], {
    cwd: backendDir,
    env: {
      ...process.env,
      HOST: '127.0.0.1',
      PORT: String(apiPort),
      TM_API_MOCK: 'false',
      TM_API_BASE_URL: 'http://127.0.0.1:' + tmPort + '/common_api/1.0',
      TM_API_USER_ID: 'test',
      TM_API_SECRET: 'local-fake-commonapi-key-not-a-real-secret',
      TM_API_VERIFY_TLS: 'true',
      SESSION_SECRET: 'only-test-secret-do-not-use-in-production-12345678',
      YANGI_PAYMENT_SETTLEMENT_ENABLED: 'false',
      ATMOS_ENABLED: 'false',
      REG_CODE_TTL_MS: '300000',
      REG_CODE_RESEND_MS: '60000',
      REG_CODE_MAX_ATTEMPTS: '5',
      REG_CODE_MAX_SENDS_PER_HOUR: '3',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => { if (service.exitCode === null) service.kill('SIGTERM'); });

  const base = 'http://127.0.0.1:' + apiPort;
  let ready = false;
  for (let i = 0; i < 90; i += 1) {
    if (service.exitCode !== null) throw new Error('Test backend exited before readiness');
    try {
      const response = await fetch(base + '/health', { signal: AbortSignal.timeout(500) });
      if (response.status === 200) { ready = true; break; }
    } catch {}
    await sleep(60);
  }
  assert.ok(ready, 'Test backend must start with fake TaxiMaster');

  await t.test('rejects non-Uzbek numbers BEFORE sending SMS', async () => {
    const before = messages.length;
    const invalid = await api(base, '/api/auth/register/request-code', { phone: '+997901234567' });
    assert.equal(invalid.status, 400);
    assert.equal(messages.length, before);
  });

  await t.test('registers only with matching six-digit code and server-verified ID', async () => {
    const phone = '+998901234567';
    const sent = await api(base, '/api/auth/register/request-code', { phone: '901234567' });
    assert.equal(sent.status, 200);
    const message = messages.at(-1);
    assert.equal(message.phone, '998901234567');
    const match = /Yangi Taxi: kod (\d{6})$/.exec(message.message);
    assert.ok(match, 'SMS must be sent by CommonAPI with the original message');
    const wrong = await api(base, '/api/auth/register/verify-code', {
      name: 'Passenger', phone, password: 'safe-passphrase', code: '123',
    });
    assert.equal(wrong.status, 400);
    const registered = await api(base, '/api/auth/register/verify-code', {
      name: 'Passenger', phone, password: 'safe-passphrase', code: match[1],
    });
    assert.equal(registered.status, 201);
    assert.equal(registered.data.data.clientId, 321);
    assert.ok(registered.data.data.token);
    assert.equal(registrations.at(-1).login, phone);
    assert.equal(registrations.at(-1).phones[0].phone, '998901234567');
    const reused = await api(base, '/api/auth/register/verify-code', {
      name: 'Passenger', phone, password: 'safe-passphrase', code: match[1],
    });
    assert.equal(reused.status, 400);
  });

  await t.test('invalid codes exhaust exactly five attempts', async () => {
    const phone = '+998901234568';
    assert.equal((await api(base, '/api/auth/register/request-code', { phone })).status, 200);
    for (let n = 0; n < 5; n++) {
      const result = await api(base, '/api/auth/register/verify-code', {
        phone, name: 'Passenger', password: 'safe-passphrase', code: '000000',
      });
      assert.equal(result.status, n === 4 ? 429 : 400);
    }
    const actual = /(\d{6})$/.exec(messages.at(-1).message)[1];
    assert.equal((await api(base, '/api/auth/register/verify-code', {
      phone, name: 'Passenger', password: 'safe-passphrase', code: actual,
    })).status, 400);
  });

  await t.test('simultaneous verification makes ONE TaxiMaster registration', async () => {
    const phone = '+998901234569';
    assert.equal((await api(base, '/api/auth/register/request-code', { phone })).status, 200);
    const code = /(\d{6})$/.exec(messages.at(-1).message)[1];
    const initialRegistrations = registrations.length;
    registerDelayMs = 250;
    const payload = { phone, name: 'Passenger', password: 'safe-passphrase', code };
    const first = api(base, '/api/auth/register/verify-code', payload);
    await waitUntil(() => registrations.length > initialRegistrations);
    const second = await api(base, '/api/auth/register/verify-code', payload);
    assert.equal(second.status, 429);
    assert.equal((await first).status, 201);
    assert.equal(registrations.length, initialRegistrations + 1);
    registerDelayMs = 0;
  });

  await t.test('never issues session for successful TaxiMaster call missing client ID', async () => {
    const phone = '+998901234570';
    assert.equal((await api(base, '/api/auth/register/request-code', { phone })).status, 200);
    const code = /(\d{6})$/.exec(messages.at(-1).message)[1];
    const result = await api(base, '/api/auth/register/verify-code', {
      phone, name: 'Passenger', password: 'safe-passphrase', code,
    });
    assert.equal(result.status, 502);
    assert.equal(result.data?.data?.token, undefined);
  });

  await t.test('upstream rejection never produces a usable SMS verification', async () => {
    const phone = '+998901234571';
    const result = await api(base, '/api/auth/register/request-code', { phone });
    assert.equal(result.status, 500);
    const verify = await api(base, '/api/auth/register/verify-code', {
      phone, name: 'Passenger', password: 'safe-passphrase', code: '123456',
    });
    assert.equal(verify.status, 400);
  });
});
