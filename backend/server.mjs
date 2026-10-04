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
  timeZone: process.env.TM_TIME_ZONE || 'Asia/Tashkent',
  sessionSecret: process.env.SESSION_SECRET || 'change-me-in-production',
  city: process.env.TM_DEFAULT_CITY || '',
  searchTm: String(process.env.TM_ADDRESS_SEARCH_TM || 'true').toLowerCase() !== 'false',
  searchGeo: String(process.env.TM_ADDRESS_SEARCH_TMGEO || 'false').toLowerCase() === 'true',
  search2gis: String(process.env.TM_ADDRESS_SEARCH_2GIS || 'false').toLowerCase() === 'true',
  togetherDiscountPercent: Math.max(0, Math.min(90, Number(process.env.YANGI_TOGETHER_DISCOUNT_PERCENT || 18))),
  crewGroups: {
    start: Number(process.env.TM_CREW_GROUP_START_ID || 2),
    comfort: Number(process.env.TM_CREW_GROUP_COMFORT_ID || 3),
    business: Number(process.env.TM_CREW_GROUP_BUSINESS_ID || 4),
    delivery: Number(process.env.TM_CREW_GROUP_DELIVERY_ID || 16),
    cargo: Number(process.env.TM_CREW_GROUP_CARGO_ID || 15),
  },
  fixedTariffs: {
    delivery: Number(process.env.TM_TARIFF_DELIVERY_ID || 27),
    cargo: Number(process.env.TM_TARIFF_CARGO_ID || 28),
  },
};

const pad = (n) => String(n).padStart(2, '0');
function tmTime(date = new Date()) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-GB', {
      timeZone: cfg.timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
    }).formatToParts(date).filter((x) => x.type !== 'literal').map((x) => [x.type, x.value]),
  );
  return parts.year + parts.month + parts.day + parts.hour + parts.minute + parts.second;
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

function optionalPoint(body, name) {
  if (!body[name]) return null;
  return point(body, name);
}

const appTariffs = [
  { key: 'start', nameRu: 'Старт', nameUz: 'Start', crewGroupId: cfg.crewGroups.start, dynamic: true },
  { key: 'together', nameRu: 'Вместе', nameUz: 'Birga', crewGroupId: cfg.crewGroups.start, dynamic: true },
  { key: 'comfort', nameRu: 'Комфорт', nameUz: 'Komfort', crewGroupId: cfg.crewGroups.comfort, dynamic: true },
  { key: 'business', nameRu: 'Бизнес', nameUz: 'Biznes', crewGroupId: cfg.crewGroups.business, dynamic: true },
  { key: 'delivery', nameRu: 'Доставка', nameUz: 'Yetkazib berish', crewGroupId: cfg.crewGroups.delivery, tariffId: cfg.fixedTariffs.delivery },
  { key: 'cargo', nameRu: 'Грузовой', nameUz: 'Yuk tashish', crewGroupId: cfg.crewGroups.cargo, tariffId: cfg.fixedTariffs.cargo },
];

function tariffDefinition(key) {
  return appTariffs.find((x) => x.key === String(key || '').toLowerCase()) || appTariffs[0];
}

async function liveCatalog() {
  const [groupsData, tariffsData] = await Promise.all([
    tmGet('get_crew_groups_list'),
    tmGet('get_tariffs_list'),
  ]);
  const groups = new Map((groupsData.crew_groups || groupsData.groups || []).map((x) => [Number(x.id || x.crew_group_id), x]));
  const tariffs = new Map((tariffsData.tariffs || []).map((x) => [Number(x.id || x.tariff_id), x]));
  return { groups, tariffs };
}

function routeAddresses(source, destination) {
  return destination ? [source, destination] : [source];
}

async function selectTariffId(definition, session, source, destination, sourceTime) {
  if (definition.tariffId) return Number(definition.tariffId);
  const data = await tmPostJson('select_tariff_for_order', {
    client_id: session.clientId,
    crew_group_id: definition.crewGroupId,
    source_time: sourceTime,
    is_prize: false,
    addresses: routeAddresses(source, destination).map((x) => ({ lat: x.lat, lon: x.lon })),
  });
  const id = Number(data.tariff_id || data.id || 0);
  if (!id) throw new Error('TaxiMaster did not select tariff for ' + definition.key);
  return id;
}

async function analyzeLiveRoute(source, destination) {
  return tmPostJson('analyze_route2', {
    get_full_route_coords: true,
    addresses: [source, destination],
  });
}

async function calculateLiveCost({
  session,
  source,
  destination,
  route,
  tariffId,
  crewGroupId,
  sourceTime,
}) {
  const analyzed = route.addresses || [];
  return tmPostJson('calc_order_cost2', {
    tariff_id: tariffId,
    crew_group_id: crewGroupId,
    source_time: sourceTime,
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
}

async function buildLiveEstimateOptions(session, source, destination) {
  const sourceTime = tmTime();
  const [route, catalog] = await Promise.all([
    analyzeLiveRoute(source, destination),
    liveCatalog(),
  ]);

  const rawCoords = Array.isArray(route.full_route_coords) ? route.full_route_coords : [];
  console.info(
    '[estimate-options] source=%s,%s destination=%s,%s route_points=%d first=%j last=%j',
    source.lat, source.lon, destination.lat, destination.lon, rawCoords.length,
    rawCoords.slice(0, 3), rawCoords.slice(-3),
  );

  const baseDefinitions = appTariffs.filter((x) => x.key !== 'together');
  const resolved = {};

  await Promise.all(baseDefinitions.map(async (definition) => {
    try {
      const crew = catalog.groups.get(Number(definition.crewGroupId));
      if (!crew) {
        resolved[definition.key] = {
          available: false,
          error: 'crew_group_not_found',
          crewGroupId: definition.crewGroupId,
        };
        return;
      }
      const tariffId = await selectTariffId(definition, session, source, destination, sourceTime);
      const tariff = catalog.tariffs.get(tariffId);
      if (!tariff || tariff.is_active === false) {
        resolved[definition.key] = {
          available: false,
          error: 'tariff_not_active',
          tariffId,
          crewGroupId: definition.crewGroupId,
        };
        return;
      }
      const cost = await calculateLiveCost({
        session,
        source,
        destination,
        route,
        tariffId,
        crewGroupId: definition.crewGroupId,
        sourceTime,
      });
      const amount = Number(cost.sum);
      resolved[definition.key] = {
        available: Number.isFinite(amount) && amount > 0,
        tariffId,
        tariffName: tariff.name || '',
        crewGroupId: definition.crewGroupId,
        crewGroupName: crew.name || '',
        cost: amount,
        costInfo: cost.info || [],
        pricingSource: 'taximaster',
      };
    } catch (error) {
      resolved[definition.key] = {
        available: false,
        error: error.message || String(error),
        crewGroupId: definition.crewGroupId,
      };
    }
  }));

  const start = resolved.start || { available: false };
  const options = appTariffs.map((definition) => {
    if (definition.key === 'together') {
      if (!start.available) {
        return {
          key: definition.key,
          nameRu: definition.nameRu,
          nameUz: definition.nameUz,
          available: false,
          tariffId: start.tariffId || null,
          crewGroupId: cfg.crewGroups.start,
        };
      }
      const discount = cfg.togetherDiscountPercent;
      const amount = Math.max(0, Math.round(Number(start.cost) * (1 - discount / 100)));
      return {
        key: definition.key,
        nameRu: definition.nameRu,
        nameUz: definition.nameUz,
        available: amount > 0,
        tariffId: start.tariffId,
        tariffName: start.tariffName,
        crewGroupId: cfg.crewGroups.start,
        crewGroupName: start.crewGroupName,
        cost: amount,
        savingVsStart: Math.max(0, Math.round(Number(start.cost) - amount)),
        savingPercentVsStart: discount,
        pricingSource: 'yangi_together_rule',
        priceBadgeRu: 'На ' + discount + '% дешевле Старт',
        priceBadgeUz: 'Startdan ' + discount + '% arzon',
        costInfo: start.costInfo || [],
      };
    }

    const item = resolved[definition.key] || { available: false };
    return {
      key: definition.key,
      nameRu: definition.nameRu,
      nameUz: definition.nameUz,
      available: item.available === true,
      tariffId: item.tariffId || null,
      tariffName: item.tariffName || '',
      crewGroupId: definition.crewGroupId,
      crewGroupName: item.crewGroupName || '',
      cost: item.available ? item.cost : null,
      costInfo: item.costInfo || [],
      ...(item.error ? { error: item.error } : {}),
    };
  });

  for (const option of options) {
    console.info(
      '[estimate-options] key=%s available=%s tariff_id=%s crew_group_id=%s cost=%s source_time=%s',
      option.key, option.available, option.tariffId, option.crewGroupId, option.cost, sourceTime,
    );
  }

  return { sourceTime, route, options };
}

let mockOrder = null;
let mockStarted = null;
let mockClientPhoto = '';
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
    return send(res, 200, {
      ok: true,
      data: {
        client_id: session.clientId,
        name: 'Yangi Taxi Demo',
        phones: [{ phone: session.phone }],
        bonus_balance: 12000,
        client_rating: 4.86,
        client_rating_count: 27,
        client_photo: mockClientPhoto,
      },
    });
  }
  if (req.method === 'POST' && path === '/api/profile/photo') {
    const body = await readJson(req);
    mockClientPhoto = String(body.photoBase64 || '');
    return send(res, 200, { ok: true, data: { saved: true } });
  }
  const mockRating = /^\/api\/orders\/(\d+)\/rating$/.exec(path);
  if (req.method === 'POST' && mockRating) {
    const body = await readJson(req);
    const rating = Number(body.rating);
    if (!Number.isInteger(rating) || rating < 1 || rating > 5) {
      const e = new Error('rating must be an integer from 1 to 5');
      e.statusCode = 400;
      throw e;
    }
    return send(res, 200, { ok: true, data: { saved: true, rating } });
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
    try {
      const photo = await tmGet('get_client_info', {
        client_id: session.clientId,
        fields: 'client_photo',
      });
      if (photo.client_photo != null) data.client_photo = photo.client_photo;
    } catch (error) {
      console.warn('[profile] client_photo is unavailable:', error.message || error);
    }
    return send(res, 200, { ok: true, data });
  }

  if (req.method === 'POST' && path === '/api/profile/photo') {
    const body = await readJson(req);
    const raw = String(body.photoBase64 || '')
      .trim()
      .replace(/^data:image\/[^;]+;base64,/, '')
      .replace(/\s+/g, '');
    if (!raw) {
      const e = new Error('photoBase64 is required');
      e.statusCode = 400;
      throw e;
    }
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(raw) || raw.length % 4 === 1) {
      const e = new Error('Invalid Base64 image');
      e.statusCode = 400;
      throw e;
    }
    const bytes = Buffer.from(raw, 'base64');
    if (!bytes.length || bytes.length > 3 * 1024 * 1024) {
      const e = new Error('Photo must be between 1 byte and 3 MB');
      e.statusCode = 413;
      throw e;
    }
    await tmPostJson('update_client_info2', {
      client_id: session.clientId,
      client_photo: raw,
    });
    return send(res, 200, { ok: true, data: { saved: true, bytes: bytes.length } });
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

  if (req.method === 'GET' && path === '/api/tariffs') {
    const catalog = await liveCatalog();
    const data = appTariffs.map((definition) => {
      const crewAvailable = catalog.groups.has(Number(definition.crewGroupId));
      const fixedTariffAvailable = !definition.tariffId ||
        (catalog.tariffs.has(Number(definition.tariffId)) &&
          catalog.tariffs.get(Number(definition.tariffId))?.is_active !== false);
      const crew = catalog.groups.get(Number(definition.crewGroupId));
      const fixedTariff = definition.tariffId
        ? catalog.tariffs.get(Number(definition.tariffId))
        : null;
      return {
        key: definition.key,
        nameRu: definition.nameRu,
        nameUz: definition.nameUz,
        crewGroupId: definition.crewGroupId,
        crewGroupName: crew?.name || '',
        tariffId: definition.tariffId || null,
        tariffName: fixedTariff?.name || '',
        available: crewAvailable && fixedTariffAvailable,
      };
    });
    return send(res, 200, { ok: true, data });
  }

  if (req.method === 'POST' && path === '/api/orders/estimate-options') {
    const body = await readJson(req);
    const source = point(body, 'source');
    const destination = point(body, 'destination');
    const data = await buildLiveEstimateOptions(session, source, destination);
    return send(res, 200, {
      ok: true,
      data: {
        options: data.options,
        route: data.route,
        sourceTime: data.sourceTime,
        timeZone: cfg.timeZone,
      },
    });
  }

  if (req.method === 'POST' && path === '/api/orders/estimate') {
    const body = await readJson(req);
    const source = point(body, 'source');
    const destination = point(body, 'destination');
    const estimate = await buildLiveEstimateOptions(session, source, destination);
    const start = estimate.options.find((x) => x.key === 'start' && x.available);
    if (!start) throw new Error('TaxiMaster Start tariff is unavailable');
    return send(res, 200, {
      ok: true,
      data: {
        cost: start.cost,
        costInfo: start.costInfo || [],
        route: estimate.route,
      },
    });
  }

  if (req.method === 'POST' && path === '/api/orders') {
    const body = await readJson(req);
    const source = point(body, 'source');
    const tariffKey = String(body.tariffKey || 'start').toLowerCase();
    const definition = tariffDefinition(tariffKey);
    const destination = optionalPoint(body, 'destination');

    if (!destination && tariffKey !== 'delivery') {
      const e = new Error('destination is required');
      e.statusCode = 400;
      throw e;
    }

    const sourceTime = tmTime();
    const catalog = await liveCatalog();
    const crew = catalog.groups.get(Number(definition.crewGroupId));
    if (!crew) throw new Error('TaxiMaster crew group is unavailable for ' + tariffKey);

    const tariffId = await selectTariffId(definition, session, source, destination, sourceTime);
    const tariff = catalog.tariffs.get(tariffId);
    if (!tariff || tariff.is_active === false) {
      throw new Error('TaxiMaster tariff is unavailable for ' + tariffKey);
    }

    const payload = {
      client_id: session.clientId,
      source_time: sourceTime,
      is_prior: false,
      check_duplicate: true,
      crew_group_id: definition.crewGroupId,
      tariff_id: tariffId,
      addresses: routeAddresses(source, destination),
    };

    if (tariffKey === 'together' && destination) {
      const startDefinition = tariffDefinition('start');
      const startTariffId = await selectTariffId(startDefinition, session, source, destination, sourceTime);
      const route = await analyzeLiveRoute(source, destination);
      const baseCost = await calculateLiveCost({
        session,
        source,
        destination,
        route,
        tariffId: startTariffId,
        crewGroupId: startDefinition.crewGroupId,
        sourceTime,
      });
      const startAmount = Number(baseCost.sum);
      if (!Number.isFinite(startAmount) || startAmount <= 0) {
        throw new Error('TaxiMaster returned invalid Start cost');
      }
      payload.total_cost = Math.max(
        0,
        Math.round(startAmount * (1 - cfg.togetherDiscountPercent / 100)),
      );
      payload.cost_freeze = true;
    }

    const data = await tmPostJson('create_order2', payload);
    return send(res, 201, {
      ok: true,
      data: {
        ...data,
        tariffId,
        crewGroupId: definition.crewGroupId,
        tariffKey,
      },
    });
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

  const ratingMatch = /^\/api\/orders\/(\d+)\/rating$/.exec(path);
  if (req.method === 'POST' && ratingMatch) {
    const orderId = Number(ratingMatch[1]);
    const state = await tmGet('get_order_state', { order_id: orderId });
    if (state.client_id && Number(state.client_id) !== Number(session.clientId)) {
      const e = new Error('Forbidden');
      e.statusCode = 403;
      throw e;
    }

    const body = await readJson(req);
    const rating = Number(body.rating);
    if (!Number.isInteger(rating) || rating < 1 || rating > 5) {
      const e = new Error('rating must be an integer from 1 to 5');
      e.statusCode = 400;
      throw e;
    }

    const stateKind = String(state.state_kind || state.state_type || '').toLowerCase();
    if (stateKind && stateKind !== 'finished') {
      const e = new Error('The trip must be finished before rating the driver');
      e.statusCode = 409;
      throw e;
    }

    const comment = String(body.comment || '').trim().slice(0, 1000);
    await tmPostJson('save_client_feed_back', {
      phone: session.phone,
      rating,
      text: comment,
      order_id: orderId,
    });
    return send(res, 200, {
      ok: true,
      data: { saved: true, orderId, rating },
    });
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
