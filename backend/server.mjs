import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';

function loadEnv() {
  if (!fs.existsSync('.env')) return;
  for (const raw of fs.readFileSync('.env', 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const i = line.indexOf('=');
    if (i < 0) continue;
    const k = line.slice(0, i).trim();
    let v = line.slice(i + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    if (!(k in process.env)) process.env[k] = v;
  }
}
loadEnv();

const cfg = {
  port: Number(process.env.PORT || 8787),
  host: process.env.HOST || '0.0.0.0',
  mock: String(process.env.TM_API_MOCK || 'true').toLowerCase() === 'true',
  base: (process.env.TM_API_BASE_URL || '').replace(/\/$/, ''),
  userId: process.env.TM_API_USER_ID || '',
  secret: process.env.TM_API_SECRET || '',
  verifyTls: String(process.env.TM_API_VERIFY_TLS || 'true').toLowerCase() !== 'false',
  timeout: Number(process.env.TM_API_TIMEOUT_MS || 12000),
  sessionSecret: process.env.SESSION_SECRET || 'change-me-in-production',
  city: process.env.TM_DEFAULT_CITY || '',
  searchTm: String(process.env.TM_ADDRESS_SEARCH_TM || 'true').toLowerCase() !== 'false',
  searchGeo: String(process.env.TM_ADDRESS_SEARCH_TMGEO || 'false').toLowerCase() === 'true',
  search2gis: String(process.env.TM_ADDRESS_SEARCH_2GIS || 'false').toLowerCase() === 'true',
};

const pad = (n) => String(n).padStart(2, '0');
function tmTime(date = new Date()) {
  return String(date.getFullYear()) + pad(date.getMonth() + 1) + pad(date.getDate()) +
    pad(date.getHours()) + pad(date.getMinutes()) + pad(date.getSeconds());
}
function tmDaysAgo(days) {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return tmTime(d);
}

function send(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  });
  res.end(body);
}

async function readJson(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    const e = new Error('Invalid JSON');
    e.statusCode = 400;
    throw e;
  }
}

function normalizePhone(value) {
  const digits = String(value || '').replace(/\D/g, '');
  if (digits.length < 9) {
    const e = new Error('Invalid phone number');
    e.statusCode = 400;
    throw e;
  }
  return '+' + digits;
}

function b64url(value) {
  return Buffer.from(value).toString('base64url');
}
function issueSession(clientId, phone) {
  const payload = b64url(JSON.stringify({ clientId, phone, exp: Date.now() + 30 * 24 * 3600 * 1000 }));
  const sig = crypto.createHmac('sha256', cfg.sessionSecret).update(payload).digest('base64url');
  return payload + '.' + sig;
}
function verifySession(token) {
  const parts = String(token || '').split('.');
  if (parts.length !== 2) throw new Error('Unauthorized');
  const expected = crypto.createHmac('sha256', cfg.sessionSecret).update(parts[0]).digest('base64url');
  if (parts[1].length !== expected.length || !crypto.timingSafeEqual(Buffer.from(parts[1]), Buffer.from(expected))) {
    throw new Error('Unauthorized');
  }
  const data = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
  if (!data.exp || Date.now() > data.exp) throw new Error('Session expired');
  return data;
}
function auth(req) {
  const h = req.headers.authorization || '';
  if (!h.startsWith('Bearer ')) {
    const e = new Error('Unauthorized');
    e.statusCode = 401;
    throw e;
  }
  try {
    return verifySession(h.slice(7));
  } catch (error) {
    error.statusCode = 401;
    throw error;
  }
}

function md5(value) {
  return crypto.createHash('md5').update(value + cfg.secret, 'utf8').digest('hex');
}

function queryString(params) {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params || {})) {
    if (v === undefined || v === null || v === '') continue;
    q.append(k, String(v));
  }
  return q.toString();
}

function rawRequest(url, method, headers, body = '') {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const lib = u.protocol === 'https:' ? https : http;
    const req = lib.request({
      protocol: u.protocol,
      hostname: u.hostname,
      port: u.port || undefined,
      path: u.pathname + u.search,
      method,
      headers,
      timeout: cfg.timeout,
      ...(u.protocol === 'https:' ? { rejectUnauthorized: cfg.verifyTls } : {}),
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode || 0, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('timeout', () => req.destroy(new Error('TaxiMaster timeout')));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function tmGet(name, params = {}) {
  const q = queryString(params);
  return tmCall(name, 'GET', q, '', q);
}
async function tmPostJson(name, data = {}) {
  const body = JSON.stringify(data);
  return tmCall(name, 'POST', '', body, body);
}
async function tmPostQuery(name, params = {}) {
  const q = queryString(params);
  return tmCall(name, 'POST', q, '', q);
}
async function tmCall(name, method, query, body, signed) {
  if (!cfg.base || !cfg.secret) throw new Error('TaxiMaster API is not configured');
  const headers = { Accept: 'application/json', Signature: md5(signed) };
  if (cfg.userId) headers['X-User-Id'] = cfg.userId;
  if (body) {
    headers['Content-Type'] = 'application/json; charset=utf-8';
    headers['Content-Length'] = Buffer.byteLength(body);
  }
  const url = cfg.base + '/' + name + (query ? '?' + query : '');
  let r;
  try {
    r = await rawRequest(url, method, headers, body);
  } catch (e) {
    throw new Error('Cannot reach TaxiMaster: ' + e.message);
  }
  let p;
  try {
    p = JSON.parse(r.body);
  } catch {
    throw new Error('TaxiMaster returned non-JSON response');
  }
  if (p.code !== 0) {
    const e = new Error(p.descr || 'TaxiMaster rejected request');
    e.tmCode = p.code;
    throw e;
  }
  return p.data || {};
}

function point(body, name) {
  const p = body[name];
  if (!p || !p.address) {
    const e = new Error(name + ' is required');
    e.statusCode = 400;
    throw e;
  }
  const lat = Number(p.lat);
  const lon = Number(p.lon);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    const e = new Error(name + ' coordinates are invalid');
    e.statusCode = 400;
    throw e;
  }
  return { address: String(p.address), lat, lon };
}

function addressLabel(a) {
  return [a.city, a.street, a.house, a.point].filter(Boolean).join(', ') || a.address || a.name || '';
}

let mockOrder = null;
let mockStarted = null;
const mockHistory = [];

function mockState() {
  if (!mockOrder || !mockStarted) return null;
  const out = { ...mockOrder };
  if (out.state_kind === 'aborted') return out;
  const sec = Math.floor((Date.now() - mockStarted) / 1000);
  out.state_kind = sec < 8 ? 'new_order' : sec < 20 ? 'driver_assigned' : sec < 35 ? 'car_at_place' : sec < 70 ? 'client_inside' : 'finished';
  mockOrder = out;
  return out;
}

async function mockRoute(req, res, path, url) {
  if (req.method === 'POST' && (path === '/api/auth/login' || path === '/api/auth/register')) {
    const body = await readJson(req);
    const phone = normalizePhone(body.phone);
    return send(res, path.endsWith('register') ? 201 : 200, { ok: true, data: { token: issueSession(501, phone), clientId: 501 } });
  }
  const session = auth(req);
  if (req.method === 'GET' && path === '/api/me') {
    return send(res, 200, { ok: true, data: { client_id: session.clientId, name: 'Yangi Taxi Demo', phones: [{ phone: session.phone }], bonus_balance: 12000 } });
  }
  if (req.method === 'GET' && path === '/api/addresses/search') {
    const list = [
      { label: 'Amir Temur xiyoboni, Toshkent', lat: 41.3111, lon: 69.2797, source: 'backend demo' },
      { label: 'Toshkent xalqaro aeroporti', lat: 41.2579, lon: 69.2812, source: 'backend demo' },
      { label: 'Chorsu bozori, Toshkent', lat: 41.3265, lon: 69.2358, source: 'backend demo' },
      { label: 'Magic City, Toshkent', lat: 41.3047, lon: 69.2457, source: 'backend demo' },
    ];
    return send(res, 200, { ok: true, data: list });
  }
  if (req.method === 'POST' && path === '/api/orders/estimate') {
    const body = await readJson(req);
    const a = point(body, 'source');
    const b = point(body, 'destination');
    return send(res, 200, { ok: true, data: { cost: 28000, route: { full_route_coords: [a, b] } } });
  }
  if (req.method === 'POST' && path === '/api/orders') {
    const body = await readJson(req);
    const a = point(body, 'source');
    const b = point(body, 'destination');
    mockStarted = Date.now();
    mockOrder = {
      order_id: 40001,
      state_kind: 'new_order',
      source: a.address,
      destination: b.address,
      source_lat: a.lat,
      source_lon: a.lon,
      destination_lat: b.lat,
      destination_lon: b.lon,
      car_mark: 'Chevrolet',
      car_model: 'Cobalt',
      car_number: '01 Y 001 TX',
      total_cost: 28000,
    };
    return send(res, 201, { ok: true, data: { order_id: 40001 } });
  }
  if (req.method === 'GET' && path === '/api/orders/current') {
    const s = mockState();
    return send(res, 200, { ok: true, data: !s || ['finished', 'aborted'].includes(s.state_kind) ? [] : [s] });
  }
  if (req.method === 'GET' && path === '/api/orders/history') {
    const s = mockState();
    const list = [...mockHistory];
    if (s && ['finished', 'aborted'].includes(s.state_kind) && !list.some((x) => x.order_id === s.order_id)) list.unshift(s);
    return send(res, 200, { ok: true, data: list });
  }
  const driver = /^\/api\/orders\/(\d+)\/driver-location$/.exec(path);
  if (req.method === 'GET' && driver) {
    const s = mockState();
    if (!s) return send(res, 404, { ok: false, error: { message: 'Order not found' } });
    const sec = Math.floor((Date.now() - mockStarted) / 1000);
    const k = Math.min(1, Math.max(0, (sec - 8) / 62));
    const location = sec < 8 ? null : {
      lat: s.source_lat + (s.destination_lat - s.source_lat) * k,
      lon: s.source_lon + (s.destination_lon - s.source_lon) * k,
      speed: sec > 35 && sec < 70 ? 38 : 0,
    };
    return send(res, 200, { ok: true, data: { state: s, location } });
  }
  if (req.method === 'GET' && /^\/api\/orders\/(\d+)\/cancel-penalty$/.test(path)) {
    return send(res, 200, { ok: true, data: { cancel_order_penalty_sum: 0 } });
  }
  if (req.method === 'POST' && /^\/api\/orders\/(\d+)\/cancel$/.test(path)) {
    if (mockOrder) mockOrder.state_kind = 'aborted';
    return send(res, 200, { ok: true, data: { state: 'aborted' } });
  }
  return send(res, 404, { ok: false, error: { message: 'Not found' } });
}

let cancelStateId = null;
async function getCancelStateId() {
  if (cancelStateId != null) return cancelStateId;
  const data = await tmGet('get_order_states_list');
  const states = data.states || data.order_states || [];
  const found = states.find((s) => String(s.state_type || s.kind || '').toLowerCase() === 'aborted') ||
    states.find((s) => String(s.name || '').toLowerCase().includes('отмен'));
  if (!found) throw new Error('Cannot find TaxiMaster cancelled order state');
  cancelStateId = Number(found.id || found.state_id);
  return cancelStateId;
}

async function realRoute(req, res, path, url) {
  if (req.method === 'POST' && path === '/api/auth/register') {
    const body = await readJson(req);
    const phone = normalizePhone(body.phone);
    const data = await tmPostJson('register_client2', {
      name: String(body.name || '').trim(),
      login: phone,
      password: String(body.password || ''),
      phones: [{ phone, is_default: true }],
      need_validate: true,
    });
    return send(res, 201, { ok: true, data: { clientId: data.client_id, token: issueSession(data.client_id, phone) } });
  }
  if (req.method === 'POST' && path === '/api/auth/login') {
    const body = await readJson(req);
    const phone = normalizePhone(body.phone);
    const data = await tmGet('check_authorization', { login: phone, password: String(body.password || '') });
    return send(res, 200, { ok: true, data: { clientId: data.client_id, token: issueSession(data.client_id, phone) } });
  }

  const session = auth(req);

  if (req.method === 'GET' && path === '/api/me') {
    const data = await tmGet('get_client_info', { client_id: session.clientId });
    return send(res, 200, { ok: true, data });
  }

  if (req.method === 'GET' && path === '/api/addresses/search') {
    const q = (url.searchParams.get('q') || '').trim();
    if (q.length < 2) return send(res, 200, { ok: true, data: [] });
    const data = await tmGet('get_addresses_like2', {
      get_streets: true,
      get_points: true,
      get_houses: true,
      address: q,
      city: cfg.city,
      max_addresses_count: 12,
      search_in_tm: cfg.searchTm,
      search_in_tmgeoservice: cfg.searchGeo,
      search_in_2gis: cfg.search2gis,
    });
    const list = (data.addresses || []).map((a) => ({
      label: addressLabel(a),
      lat: Number(a.coords?.lat || 0),
      lon: Number(a.coords?.lon || 0),
      source: a.address_source || '',
    }));
    return send(res, 200, { ok: true, data: list });
  }

  if (req.method === 'POST' && path === '/api/orders/estimate') {
    const body = await readJson(req);
    const source = point(body, 'source');
    const destination = point(body, 'destination');
    const route = await tmPostJson('analyze_route2', {
      get_full_route_coords: true,
      addresses: [source, destination],
    });
    const analyzed = route.addresses || [];
    const cost = await tmPostJson('calc_order_cost2', {
      source_time: tmTime(),
      is_prior: false,
      client_id: session.clientId,
      source_zone_id: analyzed[0]?.zone_id || 0,
      source_lat: source.lat,
      source_lon: source.lon,
      dest_zone_id: analyzed.at(-1)?.zone_id || 0,
      dest_lat: destination.lat,
      dest_lon: destination.lon,
      distance_city: route.city_dist || 0,
      distance_country: route.country_dist || 0,
      source_distance_country: route.source_country_dist || 0,
      analyze_route: true,
    });
    return send(res, 200, { ok: true, data: { cost: cost.sum, costInfo: cost.info || [], route } });
  }

  if (req.method === 'POST' && path === '/api/orders') {
    const body = await readJson(req);
    const source = point(body, 'source');
    const destination = point(body, 'destination');
    const data = await tmPostJson('create_order2', {
      client_id: session.clientId,
      source_time: tmTime(),
      is_prior: false,
      check_duplicate: true,
      addresses: [source, destination],
    });
    return send(res, 201, { ok: true, data });
  }

  if (req.method === 'GET' && path === '/api/orders/current') {
    const data = await tmGet('get_current_orders', { client_id: session.clientId });
    return send(res, 200, { ok: true, data: data.orders || [] });
  }

  if (req.method === 'GET' && path === '/api/orders/history') {
    const data = await tmGet('get_finished_orders', {
      start_time: tmDaysAgo(90),
      finish_time: tmTime(),
      client_id: session.clientId,
      state_type: 'all',
    });
    return send(res, 200, { ok: true, data: data.orders || [] });
  }

  const driver = /^\/api\/orders\/(\d+)\/driver-location$/.exec(path);
  if (req.method === 'GET' && driver) {
    const orderId = Number(driver[1]);
    const state = await tmGet('get_order_state', { order_id: orderId });
    if (state.client_id && Number(state.client_id) !== Number(session.clientId)) {
      const e = new Error('Forbidden');
      e.statusCode = 403;
      throw e;
    }
    let location = null;
    if (state.crew_id) {
      const coords = await tmGet('get_crews_coords', { crew_id: state.crew_id });
      location = coords.crews_coords?.[0] || null;
    }
    return send(res, 200, { ok: true, data: { state, location } });
  }

  const penalty = /^\/api\/orders\/(\d+)\/cancel-penalty$/.exec(path);
  if (req.method === 'GET' && penalty) {
    const orderId = Number(penalty[1]);
    const state = await tmGet('get_order_state', { order_id: orderId });
    if (state.client_id && Number(state.client_id) !== Number(session.clientId)) {
      const e = new Error('Forbidden');
      e.statusCode = 403;
      throw e;
    }
    const stateId = await getCancelStateId();
    const data = await tmGet('check_cancel_order_penalty', { order_id: orderId, cancel_order_state_id: stateId });
    return send(res, 200, { ok: true, data: { stateId, ...data } });
  }

  const cancel = /^\/api\/orders\/(\d+)\/cancel$/.exec(path);
  if (req.method === 'POST' && cancel) {
    const orderId = Number(cancel[1]);
    const state = await tmGet('get_order_state', { order_id: orderId });
    if (state.client_id && Number(state.client_id) !== Number(session.clientId)) {
      const e = new Error('Forbidden');
      e.statusCode = 403;
      throw e;
    }
    const stateId = await getCancelStateId();
    const p = await tmGet('check_cancel_order_penalty', { order_id: orderId, cancel_order_state_id: stateId });
    const data = await tmPostQuery('change_order_state', {
      order_id: orderId,
      new_state: stateId,
      cancel_order_penalty_sum: p.cancel_order_penalty_sum || 0,
    });
    return send(res, 200, { ok: true, data: { ...data, penalty: p.cancel_order_penalty_sum || 0 } });
  }

  return send(res, 404, { ok: false, error: { message: 'Not found' } });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://local');
  const path = url.pathname;
  try {
    if (req.method === 'OPTIONS') return send(res, 204, {});
    if (req.method === 'GET' && path === '/health') {
      if (cfg.mock) return send(res, 200, { ok: true, service: 'Yangi Taxi Backend', tmApi: 'demo', mock: true });
      await tmGet('ping');
      return send(res, 200, { ok: true, service: 'Yangi Taxi Backend', tmApi: 'ok', mock: false });
    }
    return cfg.mock ? await mockRoute(req, res, path, url) : await realRoute(req, res, path, url);
  } catch (e) {
    const status = e.statusCode || 500;
    console.error(new Date().toISOString(), e);
    return send(res, status, {
      ok: false,
      error: {
        message: e.message || 'Internal error',
        tmCode: e.tmCode ?? null,
      },
    });
  }
});

server.listen(cfg.port, cfg.host, () => {
  console.log('Yangi Taxi backend listening on http://' + cfg.host + ':' + cfg.port + ' mock=' + cfg.mock);
});
