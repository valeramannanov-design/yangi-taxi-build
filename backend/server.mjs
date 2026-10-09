import crypto from 'node:crypto';
import { createOrderRequestGuard } from './order-idempotency.mjs';
import { createAtomicJsonWriter } from './atomic-json-store.mjs';
import { assertOwnedOrder } from './order-ownership.mjs';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';

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
  atmosEnabled: String(process.env.ATMOS_ENABLED || 'false').toLowerCase() === 'true',
  atmosConsumerKey: process.env.ATMOS_CONSUMER_KEY || '',
  atmosConsumerSecret: process.env.ATMOS_CONSUMER_SECRET || '',
  atmosStoreId: Number(process.env.ATMOS_STORE_ID || 0),
  atmosTerminalId: Number(process.env.ATMOS_TERMINAL_ID || 0),
  paymentDataKey: process.env.PAYMENT_DATA_KEY || '',
  atmosPostRideChargeDelaySec: Math.max(0, Number(process.env.ATMOS_POST_RIDE_CHARGE_DELAY_SEC || 10)),
  atmosPostRideRetrySec: Math.max(15, Number(process.env.ATMOS_POST_RIDE_RETRY_SEC || 60)),
  atmosPostRideMaxRetries: Math.max(1, Number(process.env.ATMOS_POST_RIDE_MAX_RETRIES || 10)),
  tmDriverCreditDelaySec: Math.max(0, Number(process.env.TM_DRIVER_CREDIT_DELAY_SEC || 20)),
  tmDriverSettlementIntervalSec: Math.max(5, Number(process.env.TM_DRIVER_SETTLEMENT_INTERVAL_SEC || 15)),
  paymentSettlementEnabled: String(process.env.YANGI_PAYMENT_SETTLEMENT_ENABLED || 'true').toLowerCase() !== 'false',
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
  enabledTariffs: {
    delivery: String(process.env.TM_ENABLE_DELIVERY || 'false').toLowerCase() === 'true',
    cargo: String(process.env.TM_ENABLE_CARGO || 'false').toLowerCase() === 'true',
  },
};

function validateRuntimeConfig() {
  if (!cfg.mock) {
    const sessionSecret = String(cfg.sessionSecret || '').trim();
    if (!sessionSecret || sessionSecret === 'change-me-in-production') {
      throw new Error(
        'SESSION_SECRET must be configured to a private non-default value before starting the LIVE backend'
      );
    }
  }
}

validateRuntimeConfig();

const settlementWorkerLockFile = new URL('./data/settlement-worker.lock', import.meta.url);
let settlementWorkerLockHeld = false;

function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === 'EPERM';
  }
}

function releaseSettlementWorkerLock() {
  if (!settlementWorkerLockHeld) return;
  try {
    const owner = JSON.parse(fs.readFileSync(settlementWorkerLockFile, 'utf8'));
    if (Number(owner?.pid || 0) === process.pid) {
      fs.unlinkSync(settlementWorkerLockFile);
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      console.warn('Could not release settlement worker lock:', error.message || error);
    }
  } finally {
    settlementWorkerLockHeld = false;
  }
}

async function acquireSettlementWorkerLock() {
  const dataDir = new URL('./data/', import.meta.url);
  await mkdir(dataDir, { recursive: true });
  const claim = JSON.stringify({
    pid: process.pid,
    startedAt: new Date().toISOString(),
  });

  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      await writeFile(settlementWorkerLockFile, claim, {
        encoding: 'utf8',
        flag: 'wx',
      });
      settlementWorkerLockHeld = true;
      process.once('exit', releaseSettlementWorkerLock);
      return true;
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;

      let ownerPid = 0;
      try {
        const owner = JSON.parse(await readFile(settlementWorkerLockFile, 'utf8'));
        ownerPid = Number(owner?.pid || 0);
      } catch {
        ownerPid = 0;
      }

      if (ownerPid > 0 && ownerPid !== process.pid && processIsAlive(ownerPid)) {
        return false;
      }

      // The previous worker is gone (or the lock is corrupt): remove the stale
      // file and retry the atomic create once.
      try {
        fs.unlinkSync(settlementWorkerLockFile);
      } catch (unlinkError) {
        if (unlinkError?.code !== 'ENOENT') throw unlinkError;
      }
    }
  }

  return false;
}

function normalizeOrderRequestId(value) {
  const requestId = String(value || '').trim();
  if (!requestId) return '';
  if (!/^[A-Za-z0-9._:-]{8,128}$/.test(requestId)) {
    const e = new Error('Invalid order requestId');
    e.statusCode = 400;
    throw e;
  }
  return requestId;
}

const runIdempotentOrderRequest = createOrderRequestGuard();

const registrationCodes = new Map();
const registrationSendLocks = new Set();
const REG_CODE_TTL_MS = Math.max(60_000, Number(process.env.REG_CODE_TTL_MS || 5 * 60_000));
const REG_CODE_RESEND_MS = Math.max(30_000, Number(process.env.REG_CODE_RESEND_MS || 60_000));
const REG_CODE_MAX_ATTEMPTS = Math.max(1, Number(process.env.REG_CODE_MAX_ATTEMPTS || 5));

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
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  });
  res.end(body);
}

async function readJson(req) {
  const chunks = [];
  let length = 0;
  const maxBytes = 5 * 1024 * 1024; // Includes 3 MB photoBase64 uploads.
  for await (const c of req) {
    length += c.length;
    if (length > maxBytes) {
      const error = new Error('Request body too large');
      error.statusCode = 413;
      throw error;
    }
    chunks.push(c);
  }
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

function tmPhoneDigits(value) {
  return String(value || '').replace(/\D/g, '');
}

function orderPhoneDigits(value) {
  const digits = String(value || '').replace(/\D/g, '');
  if (digits.length === 12 && digits.startsWith('998')) return digits.slice(3);
  return digits;
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
async function tmPostForm(name, params = {}) {
  const body = queryString(params);
  return tmCall(name, 'POST', '', body, body, 'application/x-www-form-urlencoded; charset=utf-8');
}
async function tmCall(name, method, query, body, signed, contentType = 'application/json; charset=utf-8') {
  if (!cfg.base || !cfg.secret) throw new Error('TaxiMaster API is not configured');
  const headers = { Accept: 'application/json', Signature: md5(signed) };
  if (cfg.userId) headers['X-User-Id'] = cfg.userId;
  if (body) {
    headers['Content-Type'] = contentType;
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
  if (!p) {
    const e = new Error(name + ' is required');
    e.statusCode = 400;
    throw e;
  }
  const district = String(p.district || '').trim();
  const street = String(p.street || '').trim();
  const house = String(p.house || '').trim();
  const address = uniqueAddressParts([district, street, house]).join(', ');
  if (!address) {
    const e = new Error(name + ' must contain District / Street / House');
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
  return { address, district, street, house, lat, lon };
}

function uniqueAddressParts(values) {
  const seen = new Set();
  return values
    .map((value) => String(value || '').trim())
    .filter(Boolean)
    .filter((value) => {
      const key = value.toLocaleLowerCase('ru-RU');
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

function addressLabel(a) {
  return uniqueAddressParts([a.city, a.street, a.house, a.point]).join(', ') || a.address || a.name || '';
}

function shortAddressLabel(a) {
  return uniqueAddressParts([a.point, a.street, a.house]).join(', ') || addressLabel(a);
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
  { key: 'delivery', nameRu: 'Доставка', nameUz: 'Yetkazib berish', crewGroupId: cfg.crewGroups.delivery, tariffId: cfg.fixedTariffs.delivery, enabled: cfg.enabledTariffs.delivery },
  { key: 'cargo', nameRu: 'Грузовой', nameUz: 'Yuk tashish', crewGroupId: cfg.crewGroups.cargo, tariffId: cfg.fixedTariffs.cargo, enabled: cfg.enabledTariffs.cargo },
];

function tariffDefinition(key) {
  return appTariffs.find((x) => x.key === String(key || '').toLowerCase()) || appTariffs[0];
}

function tariffEnabled(definition) {
  return definition.enabled !== false;
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

function routeAddress(point) {
  return {
    address: point.address,
    lat: point.lat,
    lon: point.lon,
  };
}

function routeAddresses(source, destination) {
  return destination
    ? [routeAddress(source), routeAddress(destination)]
    : [routeAddress(source)];
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
    addresses: routeAddresses(source, destination),
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
      if (!tariffEnabled(definition)) {
        resolved[definition.key] = {
          available: false,
          error: 'tariff_disabled_until_configured',
          tariffId: definition.tariffId || null,
          crewGroupId: definition.crewGroupId,
        };
        return;
      }
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

function haversineKm(lat1, lon1, lat2, lon2) {
  const r = 6371;
  const toRad = (v) => Number(v) * Math.PI / 180;
  const dLat = toRad(Number(lat2) - Number(lat1));
  const dLon = toRad(Number(lon2) - Number(lon1));
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(a));
}


const clientProfilesFile = new URL('./data/client-profiles.json', import.meta.url);
let clientProfilesLoaded = false;
let clientProfilesLoadPromise = null;
let clientProfileStore = new Map();
const writeClientProfiles = createAtomicJsonWriter(clientProfilesFile);

function emptyClientProfile() {
  return {
    favorites: [],
    promo: null,
    settings: {},
  };
}

function normalizeClientProfile(value) {
  const profile = value && typeof value === 'object' ? value : {};
  return {
    favorites: Array.isArray(profile.favorites)
      ? profile.favorites
          .filter((item) => item && typeof item === 'object')
          .map((item) => ({
            id: String(item.id || crypto.randomUUID()),
            name: String(item.name || '').trim().slice(0, 80),
            address: String(item.address || '').trim().slice(0, 300),
            lat: Number(item.lat),
            lon: Number(item.lon),
            createdAt: String(item.createdAt || new Date().toISOString()),
            updatedAt: String(item.updatedAt || item.createdAt || new Date().toISOString()),
          }))
          .filter((item) =>
            item.address &&
            Number.isFinite(item.lat) &&
            item.lat >= -90 &&
            item.lat <= 90 &&
            Number.isFinite(item.lon) &&
            item.lon >= -180 &&
            item.lon <= 180
          )
          .slice(0, 30)
      : [],
    promo: profile.promo && typeof profile.promo === 'object' && String(profile.promo.code || '').trim()
      ? {
          code: String(profile.promo.code).trim().slice(0, 64),
          savedAt: String(profile.promo.savedAt || new Date().toISOString()),
          updatedAt: String(profile.promo.updatedAt || profile.promo.savedAt || new Date().toISOString()),
        }
      : null,
    settings: profile.settings && typeof profile.settings === 'object'
      ? {
          ...(profile.settings.lang === 'ru' || profile.settings.lang === 'uz'
            ? { lang: profile.settings.lang }
            : {}),
          ...(['system', 'light', 'dark'].includes(profile.settings.theme)
            ? { theme: profile.settings.theme }
            : {}),
          ...(profile.settings.updatedAt
            ? { updatedAt: String(profile.settings.updatedAt) }
            : {}),
        }
      : {},
  };
}

async function loadClientProfiles() {
  if (clientProfilesLoaded) return;
  if (!clientProfilesLoadPromise) {
    clientProfilesLoadPromise = (async () => {
      try {
        const raw = await readFile(clientProfilesFile, 'utf8');
        const parsed = JSON.parse(raw);
        const clients = parsed?.clients && typeof parsed.clients === 'object'
          ? parsed.clients : parsed;
        clientProfileStore = new Map(
          Object.entries(clients || {}).map(([clientId, profile]) => [
            String(Number(clientId)),
            normalizeClientProfile(profile),
          ])
        );
      } catch (error) {
        if (error?.code !== 'ENOENT') throw error; // Never overwrite damaged data.
        clientProfileStore = new Map();
      }
      clientProfilesLoaded = true;
    })().finally(() => { clientProfilesLoadPromise = null; });
  }
  return clientProfilesLoadPromise;
}

async function saveClientProfiles() {
  await loadClientProfiles();
  return writeClientProfiles({
    version: 1,
    clients: Object.fromEntries(clientProfileStore.entries()),
  });
}

async function profileForClient(clientId) {
  await loadClientProfiles();
  const key = String(Number(clientId));
  let profile = clientProfileStore.get(key);
  if (!profile) {
    profile = emptyClientProfile();
    clientProfileStore.set(key, profile);
  }
  return profile;
}

async function persistClientProfile(clientId, profile) {
  await loadClientProfiles();
  const key = String(Number(clientId));
  const normalized = normalizeClientProfile(profile);
  clientProfileStore.set(key, normalized);
  await saveClientProfiles();
  return normalized;
}

function validateFavoritePayload(body, current = null) {
  const address = String(body?.address ?? current?.address ?? '').trim().slice(0, 300);
  const name = String(body?.name ?? current?.name ?? '').trim().slice(0, 80);
  const lat = Number(body?.lat ?? current?.lat);
  const lon = Number(body?.lon ?? current?.lon);
  if (!address) {
    throw Object.assign(new Error('Favorite address is required'), { statusCode: 400 });
  }
  if (!Number.isFinite(lat) || lat < -90 || lat > 90 ||
      !Number.isFinite(lon) || lon < -180 || lon > 180) {
    throw Object.assign(new Error('Favorite address coordinates are invalid'), { statusCode: 400 });
  }
  return { name, address, lat, lon };
}

function validatePromoCode(value) {
  const code = String(value || '').trim();
  if (!code) {
    throw Object.assign(new Error('Promo code is required'), { statusCode: 400 });
  }
  if (code.length > 64) {
    throw Object.assign(new Error('Promo code is too long'), { statusCode: 400 });
  }
  if (/[\u0000-\u001F\u007F]/.test(code)) {
    throw Object.assign(new Error('Promo code contains invalid characters'), { statusCode: 400 });
  }
  return code;
}

async function handleClientProfileRoute(req, res, path, session) {
  if (req.method === 'GET' && path === '/api/profile/favorites') {
    const profile = await profileForClient(session.clientId);
    return send(res, 200, { ok: true, data: { favorites: profile.favorites } });
  }

  if (req.method === 'POST' && path === '/api/profile/favorites') {
    const body = await readJson(req);
    const value = validateFavoritePayload(body);
    const profile = await profileForClient(session.clientId);
    if (profile.favorites.length >= 30) {
      throw Object.assign(new Error('Favorite address limit reached'), { statusCode: 409 });
    }
    const now = new Date().toISOString();
    const favorite = {
      id: crypto.randomUUID(),
      ...value,
      createdAt: now,
      updatedAt: now,
    };
    profile.favorites.push(favorite);
    await persistClientProfile(session.clientId, profile);
    return send(res, 201, { ok: true, data: { favorite } });
  }

  const favoriteMatch = /^\/api\/profile\/favorites\/([^/]+)$/.exec(path);
  if (favoriteMatch && (req.method === 'POST' || req.method === 'DELETE')) {
    const id = decodeURIComponent(favoriteMatch[1]);
    const profile = await profileForClient(session.clientId);
    const index = profile.favorites.findIndex((item) => String(item.id) === id);
    if (index < 0) {
      throw Object.assign(new Error('Favorite address not found'), { statusCode: 404 });
    }

    if (req.method === 'DELETE') {
      profile.favorites.splice(index, 1);
      await persistClientProfile(session.clientId, profile);
      return send(res, 200, { ok: true, data: { removed: true, id } });
    }

    const body = await readJson(req);
    const value = validateFavoritePayload(body, profile.favorites[index]);
    profile.favorites[index] = {
      ...profile.favorites[index],
      ...value,
      updatedAt: new Date().toISOString(),
    };
    await persistClientProfile(session.clientId, profile);
    return send(res, 200, { ok: true, data: { favorite: profile.favorites[index] } });
  }

  const removeFavoriteMatch = /^\/api\/profile\/favorites\/([^/]+)\/remove$/.exec(path);
  if (req.method === 'POST' && removeFavoriteMatch) {
    const id = decodeURIComponent(removeFavoriteMatch[1]);
    const profile = await profileForClient(session.clientId);
    const index = profile.favorites.findIndex((item) => String(item.id) === id);
    if (index < 0) {
      throw Object.assign(new Error('Favorite address not found'), { statusCode: 404 });
    }
    profile.favorites.splice(index, 1);
    await persistClientProfile(session.clientId, profile);
    return send(res, 200, { ok: true, data: { removed: true, id } });
  }

  if (req.method === 'GET' && path === '/api/profile/promo') {
    const profile = await profileForClient(session.clientId);
    return send(res, 200, {
      ok: true,
      data: {
        promo: profile.promo,
        appliedToTaxiMaster: false,
        note: 'Promo code is stored in Yangi Taxi. TaxiMaster discount integration is not configured.',
      },
    });
  }

  if (req.method === 'POST' && path === '/api/profile/promo') {
    const body = await readJson(req);
    const code = validatePromoCode(body.code);
    const profile = await profileForClient(session.clientId);
    const now = new Date().toISOString();
    profile.promo = {
      code,
      savedAt: profile.promo?.savedAt || now,
      updatedAt: now,
    };
    await persistClientProfile(session.clientId, profile);
    return send(res, 200, {
      ok: true,
      data: {
        promo: profile.promo,
        appliedToTaxiMaster: false,
      },
    });
  }

  if ((req.method === 'DELETE' && path === '/api/profile/promo') ||
      (req.method === 'POST' && path === '/api/profile/promo/remove')) {
    const profile = await profileForClient(session.clientId);
    profile.promo = null;
    await persistClientProfile(session.clientId, profile);
    return send(res, 200, { ok: true, data: { removed: true } });
  }

  if (req.method === 'GET' && path === '/api/profile/settings') {
    const profile = await profileForClient(session.clientId);
    return send(res, 200, {
      ok: true,
      data: {
        lang: profile.settings.lang || 'ru',
        theme: profile.settings.theme || 'system',
      },
    });
  }

  if (req.method === 'POST' && path === '/api/profile/settings') {
    const body = await readJson(req);
    const profile = await profileForClient(session.clientId);
    const next = { ...profile.settings };

    if (body.lang != null) {
      const lang = String(body.lang);
      if (!['ru', 'uz'].includes(lang)) {
        throw Object.assign(new Error('lang must be ru or uz'), { statusCode: 400 });
      }
      next.lang = lang;
    }

    if (body.theme != null) {
      const theme = String(body.theme);
      if (!['system', 'light', 'dark'].includes(theme)) {
        throw Object.assign(new Error('theme must be system, light or dark'), { statusCode: 400 });
      }
      next.theme = theme;
    }

    next.updatedAt = new Date().toISOString();
    profile.settings = next;
    await persistClientProfile(session.clientId, profile);
    return send(res, 200, {
      ok: true,
      data: {
        lang: profile.settings.lang || 'ru',
        theme: profile.settings.theme || 'system',
      },
    });
  }

  return false;
}

const cardsFile = new URL('./data/cards.json', import.meta.url);
let cardsLoaded = false;
let cardsLoadPromise = null;
let cardStore = new Map();
let pendingCardBinds = new Map();
const writeCards = createAtomicJsonWriter(cardsFile);

function paymentCryptoKey() {
  const value = String(cfg.paymentDataKey || '').trim();
  if (!/^[0-9a-fA-F]{64}$/.test(value)) {
    throw Object.assign(
      new Error('PAYMENT_DATA_KEY must be a 64-character hex key'),
      { statusCode: 409 }
    );
  }
  return Buffer.from(value, 'hex');
}

function cardBindingConfigured() {
  if (!atmosConfigured()) return false;
  try {
    paymentCryptoKey();
    return true;
  } catch {
    return false;
  }
}

function encryptCardToken(token) {
  const key = paymentCryptoKey();
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([
    cipher.update(String(token), 'utf8'),
    cipher.final()
  ]);
  const tag = cipher.getAuthTag();
  return [
    'v1',
    iv.toString('base64url'),
    tag.toString('base64url'),
    encrypted.toString('base64url')
  ].join('.');
}

function decryptCardToken(value) {
  const parts = String(value || '').split('.');
  if (parts.length !== 4 || parts[0] !== 'v1') {
    throw Object.assign(new Error('Invalid encrypted card token'), { statusCode: 500 });
  }
  const key = paymentCryptoKey();
  const iv = Buffer.from(parts[1], 'base64url');
  const tag = Buffer.from(parts[2], 'base64url');
  const encrypted = Buffer.from(parts[3], 'base64url');
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(encrypted), decipher.final()]).toString('utf8');
}

async function loadCards() {
  if (cardsLoaded) return;
  if (!cardsLoadPromise) {
    cardsLoadPromise = (async () => {
      try {
        const raw = await readFile(cardsFile, 'utf8');
        const parsed = JSON.parse(raw);
        cardStore = new Map(Object.entries(parsed?.clients || {}));
        pendingCardBinds = new Map(Object.entries(parsed?.pending || {}));
      } catch (error) {
        if (error?.code !== 'ENOENT') throw error; // Avoid losing payment tokens.
        cardStore = new Map();
        pendingCardBinds = new Map();
      }
      cardsLoaded = true;
    })().finally(() => { cardsLoadPromise = null; });
  }
  return cardsLoadPromise;
}

async function saveCards() {
  await loadCards();
  return writeCards({
    clients: Object.fromEntries(cardStore.entries()),
    pending: Object.fromEntries(pendingCardBinds.entries()),
  });
}

function publicCard(card, defaultCardId = 0) {
  return {
    cardId: Number(card.cardId),
    maskedPan: String(card.maskedPan || ''),
    expiry: String(card.expiry || ''),
    holder: String(card.holder || ''),
    isDefault: Number(card.cardId) === Number(defaultCardId)
  };
}

async function cardsForClient(clientId) {
  await loadCards();
  const key = String(Number(clientId));
  const bundle = cardStore.get(key) || { defaultCardId: 0, cards: [] };
  if (!Array.isArray(bundle.cards)) bundle.cards = [];
  return bundle;
}

async function saveClientCards(clientId, bundle) {
  await loadCards();
  cardStore.set(String(Number(clientId)), bundle);
  await saveCards();
}

function atmosErrorDetails(payload) {
  const resultCode = payload?.result?.code;
  const statusCode = payload?.status?.code;
  const atmosCode = resultCode != null ? String(resultCode) : (statusCode != null ? String(statusCode) : 'UNKNOWN');
  const description = String(
    payload?.result?.description ||
    payload?.status?.message ||
    payload?.status?.description ||
    'ATMOS error'
  );
  return { atmosCode, description };
}

function makeAtmosError(payload, label = 'ATMOS', extra = {}) {
  const { atmosCode, description } = atmosErrorDetails(payload);
  const error = new Error(`${label}: ${atmosCode} — ${description}`);
  error.statusCode = 502;
  error.code = 'ATMOS_API_ERROR';
  error.atmosCode = atmosCode;
  error.details = { atmosCode, ...extra };
  return error;
}

function assertAtmosResult(payload, label = 'ATMOS') {
  const code = payload?.result?.code;
  if (code != null && String(code).toUpperCase() !== 'OK' && String(code) !== '0') {
    throw makeAtmosError(payload, label);
  }
  const statusCode = payload?.status?.code;
  if (statusCode != null && Number(statusCode) !== 0 && String(statusCode).toUpperCase() !== 'OK') {
    throw makeAtmosError(payload, label);
  }
}

async function beginAtmosCardBind(clientId, cardNumber, expiry) {
  if (!cardBindingConfigured()) {
    throw Object.assign(new Error('ATMOS card binding is not configured'), { statusCode: 409 });
  }
  const pan = String(cardNumber || '').replace(/\D/g, '');
  const exp = String(expiry || '').replace(/\D/g, '');
  if (pan.length !== 16) {
    throw Object.assign(new Error('ATMOS card number must contain exactly 16 digits'), { statusCode: 400 });
  }
  if (!/^\d{4}$/.test(exp)) {
    throw Object.assign(new Error('Expiry must be in YYMM format'), { statusCode: 400 });
  }
  const expiryMonth = Number(exp.slice(2, 4));
  if (expiryMonth < 1 || expiryMonth > 12) {
    throw Object.assign(new Error('Expiry month must be between 01 and 12'), { statusCode: 400 });
  }

  const payload = await atmosJson('/partner/bind-card/init', {
    card_number: pan,
    expiry: exp
  });
  assertAtmosResult(payload, 'ATMOS card bind');
  const transactionId = Number(payload.transaction_id || 0);
  if (!transactionId) {
    throw Object.assign(new Error('ATMOS did not return transaction_id'), { statusCode: 502 });
  }

  await loadCards();
  pendingCardBinds.set(String(transactionId), {
    clientId: Number(clientId),
    phone: String(payload.phone || ''),
    createdAt: new Date().toISOString()
  });
  await saveCards();

  return {
    transactionId,
    phone: String(payload.phone || ''),
    expiresIn: 600
  };
}

async function confirmAtmosCardBind(clientId, transactionId, otp) {
  if (!cardBindingConfigured()) {
    throw Object.assign(new Error('ATMOS card binding is not configured'), { statusCode: 409 });
  }
  await loadCards();
  const pending = pendingCardBinds.get(String(transactionId));
  if (!pending || Number(pending.clientId) !== Number(clientId)) {
    throw Object.assign(new Error('Card binding session not found'), { statusCode: 404 });
  }
  const age = Date.now() - Date.parse(pending.createdAt || 0);
  if (!Number.isFinite(age) || age > 10 * 60 * 1000) {
    pendingCardBinds.delete(String(transactionId));
    await saveCards();
    throw Object.assign(new Error('Card binding code expired'), { statusCode: 410 });
  }

  const payload = await atmosJson('/partner/bind-card/confirm', {
    transaction_id: Number(transactionId),
    otp: String(otp || '').trim()
  });
  assertAtmosResult(payload, 'ATMOS card bind confirmation');
  const data = payload.data || {};
  const cardId = Number(data.card_id || 0);
  const token = String(data.card_token || '');
  if (!cardId || !token) {
    throw Object.assign(new Error('ATMOS did not return card token'), { statusCode: 502 });
  }

  const bundle = await cardsForClient(clientId);
  bundle.cards = bundle.cards.filter((c) => Number(c.cardId) !== cardId);
  const card = {
    cardId,
    maskedPan: String(data.pan || ''),
    expiry: String(data.expiry || ''),
    holder: String(data.card_holder || ''),
    phone: String(data.phone || ''),
    tokenEncrypted: encryptCardToken(token),
    createdAt: new Date().toISOString()
  };
  bundle.cards.push(card);
  if (!bundle.defaultCardId) bundle.defaultCardId = cardId;
  await saveClientCards(clientId, bundle);

  pendingCardBinds.delete(String(transactionId));
  await saveCards();
  return publicCard(card, bundle.defaultCardId);
}

async function removeAtmosCard(clientId, cardId) {
  const bundle = await cardsForClient(clientId);
  const card = bundle.cards.find((c) => Number(c.cardId) === Number(cardId));
  if (!card) throw Object.assign(new Error('Card not found'), { statusCode: 404 });

  const token = decryptCardToken(card.tokenEncrypted);
  const payload = await atmosJson('/partner/remove-card', {
    id: Number(card.cardId),
    token
  });
  assertAtmosResult(payload, 'ATMOS remove card');

  bundle.cards = bundle.cards.filter((c) => Number(c.cardId) !== Number(cardId));
  if (Number(bundle.defaultCardId) === Number(cardId)) {
    bundle.defaultCardId = bundle.cards.length ? Number(bundle.cards[0].cardId) : 0;
  }
  await saveClientCards(clientId, bundle);
  return { removed: true, defaultCardId: Number(bundle.defaultCardId || 0) };
}

async function getStoredCard(clientId, requestedCardId = 0) {
  const bundle = await cardsForClient(clientId);
  const cardId = Number(requestedCardId || bundle.defaultCardId || 0);
  const card = bundle.cards.find((c) => Number(c.cardId) === cardId);
  if (!card) {
    throw Object.assign(new Error('Добавьте банковскую карту в разделе «Карты»'), { statusCode: 409 });
  }
  return { bundle, card };
}

function finalOrderAmount(state) {
  for (const key of ['total_cost', 'cost', 'sum', 'order_cost']) {
    const value = Number(state?.[key]);
    if (Number.isFinite(value) && value > 0) return value;
  }
  return 0;
}

function paymentRetryDelayMs(attempt) {
  const base = Math.max(15, Number(cfg.atmosPostRideRetrySec || 60)) * 1000;
  const factor = Math.min(16, 2 ** Math.max(0, Number(attempt || 1) - 1));
  return base * factor;
}

function atmosPaymentIsConfirmed(payload) {
  const tx = payload?.store_transaction || {};
  return tx.confirmed === true || (
    Number(tx.success_trans_id || 0) > 0 &&
    String(tx.status_code ?? '') === '0'
  );
}

async function verifyAtmosMerchantPayment(record) {
  if (!record.atmosTransactionId) return false;
  const payload = await atmosJson('/merchant/pay/get', {
    store_id: cfg.atmosStoreId,
    transaction_id: Number(record.atmosTransactionId)
  });
  record.atmosLastVerifiedAt = new Date().toISOString();
  if (!atmosPaymentIsConfirmed(payload)) return false;
  const tx = payload.store_transaction || {};
  record.atmosSuccessTransId = Number(tx.success_trans_id || record.atmosSuccessTransId || record.atmosTransactionId);
  record.status = 'paid_waiting_driver_credit';
  record.paidAt = record.paidAt || new Date().toISOString();
  record.lastPaymentError = null;
  record.nextPaymentAttemptAt = null;
  await setPayment(record.checkoutId, record);
  return true;
}

async function chargeAtmosStoredCard(record, card, amount) {
  if (record.paidAt) return record;

  const finalAmount = Number(amount || record.amount || 0);
  if (!Number.isFinite(finalAmount) || finalAmount <= 0) {
    throw Object.assign(new Error('TaxiMaster final order cost is not ready'), { statusCode: 409 });
  }

  record.amount = finalAmount;
  record.amountTiyin = Math.round(finalAmount * 100);
  record.paymentKind = 'stored_card';
  record.cardId = Number(card.cardId);
  record.maskedPan = String(card.maskedPan || record.maskedPan || '');

  // ATMOS explicitly recommends /merchant/pay/get when apply may have succeeded
  // but the caller did not receive a reliable result. Reusing the same ATMOS
  // transaction prevents accidental double charges after network/process failures.
  if (record.atmosTransactionId && (record.atmosApplyStartedAt || Number(record.paymentAttempts || 0) > 0)) {
    try {
      if (await verifyAtmosMerchantPayment(record)) return record;
    } catch (error) {
      // If status lookup itself is unavailable, continue with the same transaction.
      // Never create a second transaction for this ride.
      record.atmosLastVerifyError = error.message;
      await setPayment(record.checkoutId, record);
    }
  }

  if (!record.atmosTransactionId) {
    const account = record.atmosAccount || String(BigInt(Date.now()) * 1000n + BigInt(crypto.randomInt(0, 1000)));
    const createBody = {
      amount: record.amountTiyin,
      account,
      store_id: cfg.atmosStoreId,
      lang: 'ru'
    };
    if (cfg.atmosTerminalId > 0) createBody.terminal_id = cfg.atmosTerminalId;

    record.status = 'payment_creating';
    record.atmosAccount = account;
    await setPayment(record.checkoutId, record);

    const created = await atmosJson('/merchant/pay/create', createBody);
    assertAtmosResult(created, 'ATMOS create payment');
    const transactionId = Number(created.transaction_id || 0);
    if (!transactionId) {
      throw Object.assign(new Error('ATMOS did not return transaction_id'), { statusCode: 502 });
    }
    record.atmosTransactionId = transactionId;
    record.status = 'payment_created';
    await setPayment(record.checkoutId, record);
  }

  const cardToken = decryptCardToken(card.tokenEncrypted);
  if (!record.atmosPreAppliedAt) {
    const prepared = await atmosJson('/merchant/pay/pre-apply', {
      card_token: cardToken,
      store_id: cfg.atmosStoreId,
      transaction_id: Number(record.atmosTransactionId)
    });
    assertAtmosResult(prepared, 'ATMOS pre-apply');
    record.atmosPreAppliedAt = new Date().toISOString();
    record.status = 'payment_prepared';
    await setPayment(record.checkoutId, record);
  }

  record.atmosApplyStartedAt = record.atmosApplyStartedAt || new Date().toISOString();
  record.status = 'payment_applying';
  await setPayment(record.checkoutId, record);

  let applied;
  try {
    applied = await atmosJson('/merchant/pay/apply', {
      transaction_id: Number(record.atmosTransactionId),
      otp: 111111,
      store_id: cfg.atmosStoreId
    });
    assertAtmosResult(applied, 'ATMOS apply');
  } catch (error) {
    // ATMOS documentation says to query /merchant/pay/get when apply result is
    // uncertain (network interruption/timeout). If ATMOS confirms the same
    // transaction, treat it as paid instead of retrying a new charge.
    try {
      if (await verifyAtmosMerchantPayment(record)) return record;
    } catch (verifyError) {
      record.atmosLastVerifyError = verifyError.message;
      await setPayment(record.checkoutId, record);
    }
    throw error;
  }

  const storeTx = applied.store_transaction || {};
  record.atmosSuccessTransId = Number(storeTx.success_trans_id || applied.transaction_id || record.atmosTransactionId);
  record.status = 'paid_waiting_driver_credit';
  record.paidAt = record.paidAt || new Date().toISOString();
  record.paymentAttempts = Number(record.paymentAttempts || 0);
  record.lastPaymentError = null;
  record.nextPaymentAttemptAt = null;
  await setPayment(record.checkoutId, record);
  return record;
}


const paymentFile = new URL('./data/payments.json', import.meta.url);
let paymentsLoaded = false;
let paymentsLoadPromise = null;
let paymentStore = new Map();
const writePayments = createAtomicJsonWriter(paymentFile);
let atmosTokenCache = { token: '', expiresAt: 0 };

function atmosConfigured() {
  return Boolean(
    cfg.atmosEnabled &&
    cfg.atmosConsumerKey &&
    cfg.atmosConsumerSecret &&
    cfg.atmosStoreId > 0
  );
}

async function loadPayments() {
  if (paymentsLoaded) return;
  if (!paymentsLoadPromise) {
    paymentsLoadPromise = (async () => {
      try {
        const raw = await readFile(paymentFile, 'utf8');
        const parsed = JSON.parse(raw);
        paymentStore = new Map(Object.entries(parsed || {}));
      } catch (error) {
        if (error?.code !== 'ENOENT') throw error; // Never silently erase payment state.
        paymentStore = new Map();
      }
      paymentsLoaded = true;
    })().finally(() => { paymentsLoadPromise = null; });
  }
  return paymentsLoadPromise;
}

async function savePayments() {
  await loadPayments();
  return writePayments(Object.fromEntries(paymentStore.entries()));
}

async function setPayment(id, record) {
  await loadPayments();
  paymentStore.set(String(id), record);
  await savePayments();
}

async function getPayment(id) {
  await loadPayments();
  return paymentStore.get(String(id)) || null;
}

async function getAtmosAccessToken() {
  const now = Date.now();
  if (atmosTokenCache.token && now < atmosTokenCache.expiresAt - 60_000) {
    return atmosTokenCache.token;
  }
  if (!atmosConfigured()) {
    throw Object.assign(new Error('ATMOS is not configured'), { statusCode: 409 });
  }
  const basic = Buffer.from(`${cfg.atmosConsumerKey}:${cfg.atmosConsumerSecret}`, 'utf8').toString('base64');
  const response = await fetch('https://apigw.atmos.uz/token', {
    method: 'POST',
    headers: {
      Authorization: `Basic ${basic}`,
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json'
    },
    body: 'grant_type=client_credentials'
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || !payload.access_token) {
    throw Object.assign(new Error(payload.error_description || payload.error || `ATMOS token HTTP ${response.status}`), { statusCode: 502 });
  }
  atmosTokenCache = {
    token: String(payload.access_token),
    expiresAt: now + Math.max(60, Number(payload.expires_in || 3600)) * 1000
  };
  return atmosTokenCache.token;
}

async function atmosJson(path, body) {
  const token = await getAtmosAccessToken();
  const response = await fetch(`https://apigw.atmos.uz${path}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      Accept: 'application/json'
    },
    body: JSON.stringify(body)
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = makeAtmosError(payload, `ATMOS ${path}`, { httpStatus: response.status, path });
    if (error.atmosCode === 'UNKNOWN') error.message = `ATMOS ${path}: HTTP ${response.status}`;
    throw error;
  }
  return payload;
}


const driverCreditLocks = new Map();

function driverCreditMarker(record) {
  return `YANGI_CARD_ORDER_${Number(record.orderId)}`;
}

async function findExistingDriverCredit(record, driverId) {
  const marker = driverCreditMarker(record);
  try {
    const data = await tmGet('get_driver_operations', {
      driver_id: Number(driverId),
      start_time: tmDaysAgo(90),
      finish_time: tmTime(),
      account_kind: 0
    });
    return (data.operations || []).find((op) =>
      String(op.comment || '').split(';').some((part) => part.trim() === marker)
    ) || null;
  } catch (error) {
    // We deliberately fail closed here: if we cannot verify idempotency,
    // do not risk crediting the driver twice.
    throw error;
  }
}

async function settleFinishedCardPayment(record, { forcePaymentRetry = false } = {}) {
  if (!record?.orderId || record.paymentMethod !== 'card' || record.refundRequired) return record;
  if (record.status === 'order_aborted_no_charge' || record.status === 'driver_credited') return record;
  if (record.status === 'payment_debt' && !forcePaymentRetry) return record;

  const key = String(record.checkoutId);
  if (driverCreditLocks.has(key)) return driverCreditLocks.get(key);

  const task = (async () => {
    const state = await tmGet('get_order_state', { order_id: Number(record.orderId) });
    const stateKind = String(state.state_kind || '');

    if (state.crew_id && Number(state.crew_id) !== Number(record.crewId || 0)) {
      record.crewId = Number(state.crew_id);
      await setPayment(record.checkoutId, record);
    }

    if (stateKind === 'aborted' && !record.paidAt) {
      record.status = 'order_aborted_no_charge';
      record.abortedAt = record.abortedAt || new Date().toISOString();
      await setPayment(record.checkoutId, record);
      return record;
    }

    if (stateKind !== 'finished') return record;

    if (!record.finishedSeenAt) {
      record.finishedSeenAt = new Date().toISOString();
      record.status = record.paidAt ? 'paid_waiting_driver_credit' : 'finished_waiting_charge';
      await setPayment(record.checkoutId, record);
      console.log(new Date().toISOString(), `[CARD] order #${record.orderId} finished; waiting for final TaxiMaster cost`);
      return record;
    }

    if (!record.paidAt) {
      const chargeDelayMs = Math.max(0, Number(cfg.atmosPostRideChargeDelaySec || 0)) * 1000;
      const finishedSeenAt = Date.parse(record.finishedSeenAt);
      if (Number.isFinite(finishedSeenAt) && Date.now() - finishedSeenAt < chargeDelayMs) return record;

      const amount = finalOrderAmount(state);
      if (!amount) {
        record.status = 'finished_waiting_final_cost';
        record.lastPaymentError = 'TaxiMaster final total_cost is not ready';
        await setPayment(record.checkoutId, record);
        return record;
      }

      if (!forcePaymentRetry && record.nextPaymentAttemptAt) {
        const next = Date.parse(record.nextPaymentAttemptAt);
        if (Number.isFinite(next) && Date.now() < next) return record;
      }

      const { card } = await getStoredCard(record.clientId, record.cardId);
      record.finalAmount = amount;
      record.amount = amount;
      record.amountTiyin = Math.round(amount * 100);
      record.status = 'finished_payment_processing';
      await setPayment(record.checkoutId, record);
      console.log(new Date().toISOString(), `[CARD] order #${record.orderId} final cost ${amount} UZS; charging ATMOS`);

      try {
        await chargeAtmosStoredCard(record, card, amount);
        console.log(new Date().toISOString(), `[CARD] order #${record.orderId} ATMOS paid ${record.amount} UZS; waiting driver credit`);
      } catch (error) {
        record.paymentAttempts = Number(record.paymentAttempts || 0) + 1;
        record.lastPaymentError = error.message;
        record.lastPaymentAttemptAt = new Date().toISOString();
        const maxRetries = Math.max(1, Number(cfg.atmosPostRideMaxRetries || 10));
        if (record.paymentAttempts >= maxRetries) {
          record.status = 'payment_debt';
          record.nextPaymentAttemptAt = null;
        } else {
          record.status = 'payment_retry';
          record.nextPaymentAttemptAt = new Date(Date.now() + paymentRetryDelayMs(record.paymentAttempts)).toISOString();
        }
        await setPayment(record.checkoutId, record);
        console.warn(new Date().toISOString(), `[CARD] order #${record.orderId} payment ${record.status}; attempt ${record.paymentAttempts}: ${error.message}`);
        throw error;
      }
    }

    const waitMs = Math.max(0, Number(cfg.tmDriverCreditDelaySec || 0)) * 1000;
    const finishedSeenAt = Date.parse(record.finishedSeenAt);
    if (Number.isFinite(finishedSeenAt) && Date.now() - finishedSeenAt < waitMs) return record;

    const crewId = Number(record.crewId || state.crew_id || 0);
    if (!crewId) {
      record.status = 'finished_missing_crew';
      await setPayment(record.checkoutId, record);
      return record;
    }

    const crew = await tmGet('get_crew_info', { crew_id: crewId, fields: 'driver_id' });
    const driverId = Number(crew.driver_id || 0);
    if (!driverId) {
      record.status = 'finished_missing_driver';
      await setPayment(record.checkoutId, record);
      return record;
    }
    record.driverId = driverId;

    const existing = await findExistingDriverCredit(record, driverId);
    if (existing) {
      record.driverCreditOperId = Number(existing.oper_id || 0);
      record.driverCreditAmount = Number(record.amount);
      record.driverCreditedAt = record.driverCreditedAt || new Date().toISOString();
      record.status = 'driver_credited';
      delete record.lastSettlementError;
      delete record.lastSettlementAttemptAt;
      await setPayment(record.checkoutId, record);
      return record;
    }

    const marker = driverCreditMarker(record);
    const operation = await tmPostJson('create_driver_operation', {
      driver_id: driverId,
      oper_sum: Number(record.amount),
      oper_type: 'receipt',
      name: 'Yangi Taxi: оплата картой',
      comment: `${marker}; ATMOS checkout ${record.checkoutId}`,
      account_kind: 0
    });

    record.driverCreditOperId = Number(operation.oper_id || 0);
    record.driverCreditAmount = Number(record.amount);
    record.driverCreditedAt = new Date().toISOString();
    record.status = 'driver_credited';
    delete record.lastSettlementError;
    delete record.lastSettlementAttemptAt;
    await setPayment(record.checkoutId, record);
    console.log(new Date().toISOString(), `[CARD] order #${record.orderId} driver #${driverId} credited ${record.amount} UZS`);
    return record;
  })();

  driverCreditLocks.set(key, task);
  try {
    return await task;
  } finally {
    driverCreditLocks.delete(key);
  }
}

async function diagnoseAtmosCardBinding() {
  if (!cfg.atmosEnabled) {
    console.log('ATMOS: disabled');
    return;
  }
  if (!atmosConfigured()) {
    console.warn('ATMOS: enabled but Consumer Key / Consumer Secret / Store ID are incomplete [NOT READY]');
    return;
  }
  try {
    await getAtmosAccessToken();
    console.log('ATMOS authorization: OK');
  } catch (error) {
    console.warn(`ATMOS authorization: FAILED — ${error.message}`);
    return;
  }
  try {
    const payload = await atmosJson('/partner/list-cards', { page: 1, page_size: 1 });
    assertAtmosResult(payload, 'ATMOS /partner/list-cards');
    console.log('ATMOS card binding (/partner): READY');
  } catch (error) {
    console.warn(`ATMOS card binding (/partner): NOT READY — ${error.message}`);
    console.warn('ATMOS hint: ask ATMOS support to enable owner card binding/tokenization endpoints /partner/bind-card/* for this Consumer Key.');
  }
}

async function settleFinishedCardOrders() {
  await loadPayments();
  for (const record of paymentStore.values()) {
    if (!record?.orderId || record.paymentMethod !== 'card' || record.refundRequired) continue;
    if (['order_aborted_no_charge', 'driver_credited', 'payment_debt'].includes(record.status)) continue;
    try {
      await settleFinishedCardPayment(record);
    } catch (error) {
      record.lastSettlementError = error.message;
      record.lastSettlementAttemptAt = new Date().toISOString();
      try { await setPayment(record.checkoutId, record); } catch {}
      console.warn(new Date().toISOString(), `Post-ride card settlement failed for checkout ${record.checkoutId}:`, error.message);
    }
  }
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
  const profileHandled = await handleClientProfileRoute(req, res, path, session);
  if (profileHandled !== false) return profileHandled;

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
    return send(res, 201, {
      ok: true,
      data: {
        order_id: 40001,
        paymentMethod: String(body.paymentMethod || 'cash').toLowerCase(),
      },
    });
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
  async function requireOwnedOrder(orderId, state) {
    return assertOwnedOrder({
      orderId,
      clientId: session.clientId,
      state,
      loadCurrent: () => tmGet('get_current_orders', { client_id: session.clientId }),
      loadHistory: () => tmGet('get_finished_orders', {
        start_time: tmDaysAgo(90),
        finish_time: tmTime(),
        client_id: session.clientId,
        state_type: 'all',
      }),
    });
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

function registrationCodeHash(phone, code) {
  return crypto.createHmac('sha256', cfg.sessionSecret).update(phone + ':' + code).digest('hex');
}

function cleanupRegistrationCodes() {
  const now = Date.now();
  for (const [phone, entry] of registrationCodes.entries()) {
    if (!entry || now > entry.expiresAt) registrationCodes.delete(phone);
  }
}

async function sendRegistrationCode(phone) {
  cleanupRegistrationCodes();
  if (registrationSendLocks.has(phone)) {
    const e = new Error('SMS request already in progress');
    e.statusCode = 429;
    throw e;
  }
  const now = Date.now();
  const previous = registrationCodes.get(phone);
  if (previous && now - previous.sentAt < REG_CODE_RESEND_MS) {
    const e = new Error('SMS code was sent recently. Please wait before retrying.');
    e.statusCode = 429;
    throw e;
  }
  registrationSendLocks.add(phone);
  try {
    const code = String(crypto.randomInt(100000, 1000000));
    await tmPostForm('send_sms', { phone: tmPhoneDigits(phone), message: 'Yangi Taxi: kod ' + code });
    registrationCodes.set(phone, {
      hash: registrationCodeHash(phone, code),
      sentAt: now,
      expiresAt: now + REG_CODE_TTL_MS,
      attempts: 0,
    });
  } finally {
    registrationSendLocks.delete(phone);
  }
}

function verifyRegistrationCode(phone, code) {
  cleanupRegistrationCodes();
  const entry = registrationCodes.get(phone);
  if (!entry) {
    const e = new Error('SMS code is missing or expired');
    e.statusCode = 400;
    throw e;
  }
  entry.attempts += 1;
  if (entry.attempts > REG_CODE_MAX_ATTEMPTS) {
    registrationCodes.delete(phone);
    const e = new Error('Too many SMS code attempts');
    e.statusCode = 429;
    throw e;
  }
  const actual = registrationCodeHash(phone, String(code || '').trim());
  const a = Buffer.from(actual);
  const b = Buffer.from(entry.hash);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    const e = new Error('Invalid SMS code');
    e.statusCode = 400;
    throw e;
  }
  // Keep this verified code available if TaxiMaster registration fails.
  // The endpoint consumes the code only after registration succeeds.
}

async function realRoute(req, res, path, url) {
  if (req.method === 'GET' && path === '/api/payments/config') {
    return send(res, 200, {
      ok: true,
      data: {
        atmosEnabled: atmosConfigured(),
        provider: 'ATMOS',
        driverSettlement: 'tm-driver-balance-after-finish',
        cardFlow: 'atmos-linked-card-pay-after-ride',
        chargeMoment: 'after-tm-finished-final-cost',
        cardBindingAvailable: cardBindingConfigured(),
      },
    });
  }
  if (req.method === 'POST' && path === '/api/auth/register/request-code') {
    const body = await readJson(req);
    const phone = normalizePhone(body.phone);
    await sendRegistrationCode(phone);
    return send(res, 200, { ok: true, data: { sent: true, expiresInSeconds: Math.round(REG_CODE_TTL_MS / 1000) } });
  }

  if (req.method === 'POST' && path === '/api/auth/register/verify-code') {
    const body = await readJson(req);
    const phone = normalizePhone(body.phone);
    const name = String(body.name || '').trim();
    const password = String(body.password || '');
    if (!name) {
      const e = new Error('Name is required');
      e.statusCode = 400;
      throw e;
    }
    if (password.length < 6) {
      const e = new Error('Password must contain at least 6 characters');
      e.statusCode = 400;
      throw e;
    }
    verifyRegistrationCode(phone, body.code);
    const data = await tmPostJson('register_client2', {
      name,
      login: phone,
      password,
      phones: [{ phone: tmPhoneDigits(phone), is_default: true }],
      need_validate: true,
    });
    registrationCodes.delete(phone);
    return send(res, 201, { ok: true, data: { clientId: data.client_id, token: issueSession(data.client_id, phone) } });
  }

  if (req.method === 'POST' && path === '/api/auth/register') {
    const error = new Error('Registration requires SMS verification');
    error.statusCode = 403;
    throw error;
  }
  if (req.method === 'POST' && path === '/api/auth/login') {
    const body = await readJson(req);
    const phone = normalizePhone(body.phone);
    const data = await tmGet('check_authorization', { login: phone, password: String(body.password || '') });
    return send(res, 200, { ok: true, data: { clientId: data.client_id, token: issueSession(data.client_id, phone) } });
  }

  const session = auth(req);

  const profileHandled = await handleClientProfileRoute(req, res, path, session);
  if (profileHandled !== false) return profileHandled;

  if (req.method === 'GET' && path === '/api/cards') {
    const bundle = await cardsForClient(session.clientId);
    return send(res, 200, {
      ok: true,
      data: {
        provider: 'ATMOS',
        cardBindingAvailable: cardBindingConfigured(),
        defaultCardId: Number(bundle.defaultCardId || 0),
        cards: bundle.cards.map((card) => publicCard(card, bundle.defaultCardId)),
      },
    });
  }

  if (req.method === 'POST' && path === '/api/cards/bind/init') {
    const body = await readJson(req);
    if (!body.cardNumber || !body.expiry) {
      const e = new Error('cardNumber and expiry are required');
      e.statusCode = 400;
      throw e;
    }
    const data = await beginAtmosCardBind(session.clientId, body.cardNumber, body.expiry);
    return send(res, 200, { ok: true, data });
  }

  if (req.method === 'POST' && path === '/api/cards/bind/confirm') {
    const body = await readJson(req);
    if (!body.transactionId || !body.otp) {
      const e = new Error('transactionId and otp are required');
      e.statusCode = 400;
      throw e;
    }
    const card = await confirmAtmosCardBind(session.clientId, Number(body.transactionId), String(body.otp));
    return send(res, 201, { ok: true, data: { card } });
  }

  const setDefaultCardMatch = /^\/api\/cards\/(\d+)\/default$/.exec(path);
  if (req.method === 'POST' && setDefaultCardMatch) {
    const cardId = Number(setDefaultCardMatch[1]);
    const bundle = await cardsForClient(session.clientId);
    if (!bundle.cards.some((c) => Number(c.cardId) === cardId)) {
      const e = new Error('Card not found');
      e.statusCode = 404;
      throw e;
    }
    bundle.defaultCardId = cardId;
    await saveClientCards(session.clientId, bundle);
    return send(res, 200, { ok: true, data: { defaultCardId: cardId } });
  }

  const removeCardMatch = /^\/api\/cards\/(\d+)\/remove$/.exec(path);
  if (req.method === 'POST' && removeCardMatch) {
    const cardId = Number(removeCardMatch[1]);
    await loadPayments();
    const active = [...paymentStore.values()].find((p) =>
      Number(p?.clientId || 0) === Number(session.clientId) &&
      Number(p?.cardId || 0) === cardId &&
      p?.paymentMethod === 'card' &&
      !p?.paidAt &&
      String(p?.status || '') !== 'order_aborted_no_charge'
    );
    if (active) {
      const e = new Error(`Карта используется в активном заказе #${active.orderId || ''}. Удалить её можно после завершения оплаты.`);
      e.statusCode = 409;
      throw e;
    }
    const data = await removeAtmosCard(session.clientId, cardId);
    return send(res, 200, { ok: true, data });
  }

  if (req.method === 'GET' && path === '/api/crews/nearby') {
    const lat = Number(url.searchParams.get('lat'));
    const lon = Number(url.searchParams.get('lon'));
    const radiusKm = Math.min(20, Math.max(0.5, Number(url.searchParams.get('radius') || 6)));
    const limit = Math.min(30, Math.max(1, Number(url.searchParams.get('limit') || 15)));
    if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
      const e = new Error('lat/lon are required');
      e.statusCode = 400;
      throw e;
    }
    let coords;
    try {
      coords = await tmGet('get_crews_coords');
    } catch (error) {
      if (Number(error.tmCode) === 100) return send(res, 200, { ok: true, data: [] });
      throw error;
    }
    const waiting = (coords.crews_coords || [])
      .map((c) => {
        const crewLat = Number(c.lat);
        const crewLon = Number(c.lon);
        if (!Number.isFinite(crewLat) || !Number.isFinite(crewLon)) return null;
        return {
          crewId: Number(c.crew_id || 0),
          code: String(c.crew_code || ''),
          lat: crewLat,
          lon: crewLon,
          speed: Number(c.speed || 0),
          direction: Number(c.direction ?? -1),
          stateKind: String(c.state_kind || ''),
          coordsTime: c.coords_time || null,
          distanceKm: Number(haversineKm(lat, lon, crewLat, crewLon).toFixed(3)),
        };
      })
      .filter(Boolean)
      .filter((c) => c.stateKind === 'waiting')
      .sort((a, b) => a.distanceKm - b.distanceKm);
    let crews = waiting.filter((c) => c.distanceKm <= radiusKm).slice(0, limit);
    if (crews.length === 0) crews = waiting.filter((c) => c.distanceKm <= 50).slice(0, Math.min(limit, 8));
    return send(res, 200, { ok: true, data: crews });
  }

  if (req.method === 'GET' && path === '/api/me') {
    let data;
    try {
      data = await tmGet('get_client_info', { client_id: session.clientId });
    } catch (error) {
      if (Number(error.tmCode) === 100) {
        const e = new Error('Session client not found');
        e.statusCode = 401;
        throw e;
      }
      throw error;
    }
    try {
      const photo = await tmGet('get_client_info', {
        client_id: session.clientId,
        fields: 'client_photo',
      });
      if (photo.client_photo != null) data.client_photo = photo.client_photo;
    } catch (error) {
      console.warn('[profile] client_photo is unavailable:', error.message || error);
    }
    const clientProfile = await profileForClient(session.clientId);
    data.yangi_profile = {
      favorite_addresses_count: clientProfile.favorites.length,
      promo_saved: Boolean(clientProfile.promo?.code),
      settings: {
        lang: clientProfile.settings.lang || null,
        theme: clientProfile.settings.theme || null,
      },
    };
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
    const list = (data.addresses || []).map((a) => {
      const fullLabel = addressLabel(a);
      return {
        label: fullLabel,
        fullLabel,
        shortLabel: shortAddressLabel(a),
        street: String(a.street || '').trim(),
        house: String(a.house || '').trim(),
        lat: Number(a.coords?.lat || 0),
        lon: Number(a.coords?.lon || 0),
        source: a.address_source || '',
      };
    });
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
        available: tariffEnabled(definition) && crewAvailable && fixedTariffAvailable,
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
    const requestId = normalizeOrderRequestId(body.requestId);
    const incomingPromoCode = String(body.promoCode || '').trim();
    if (incomingPromoCode) {
      const code = validatePromoCode(incomingPromoCode);
      const profile = await profileForClient(session.clientId);
      const now = new Date().toISOString();
      profile.promo = {
        code,
        savedAt: profile.promo?.savedAt || now,
        updatedAt: now,
      };
      await persistClientProfile(session.clientId, profile);
    }
    const paymentMethod = String(body.paymentMethod || 'cash').toLowerCase();
    if (!['cash', 'card', 'bonus'].includes(paymentMethod)) {
      const e = new Error('Unsupported payment method');
      e.statusCode = 400;
      throw e;
    }

    const source = point(body, 'source');
    const tariffKey = String(body.tariffKey || 'start').toLowerCase();
    const definition = tariffDefinition(tariffKey);
    if (!tariffEnabled(definition)) {
      const e = new Error('Tariff is not enabled yet: ' + tariffKey);
      e.statusCode = 409;
      throw e;
    }
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
    if (!tariff || tariff.is_active === false) throw new Error('TaxiMaster tariff is unavailable for ' + tariffKey);

    const payload = {
      phone: orderPhoneDigits(session.phone),
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
      if (!Number.isFinite(startAmount) || startAmount <= 0) throw new Error('TaxiMaster returned invalid Start cost');
      payload.total_cost = Math.max(0, Math.round(startAmount * (1 - cfg.togetherDiscountPercent / 100)));
      payload.cost_freeze = true;
    }

    // A requestId is valid only for exactly one set of order details.
    // Ignore generated source_time, which legitimately changes between retries.
    const requestFingerprint = JSON.stringify({
      source: routeAddress(source),
      destination: destination ? routeAddress(destination) : null,
      tariffKey,
      paymentMethod,
      cardId: paymentMethod === 'card' ? Number(body.cardId || 0) : null,
      promoCode: incomingPromoCode,
      comment: String(body.comment || ''),
    });

    if (paymentMethod === 'cash') {
      const responseData = await runIdempotentOrderRequest(
        session.clientId,
        requestId,

        requestFingerprint,
        async () => {
          const data = await tmPostJson('create_order2', payload);
          return {
            ...data,
            paymentMethod: 'cash',
            paymentStatus: 'cash',
            tariffId,
            crewGroupId: definition.crewGroupId,
            tariffKey,
          };
        },
      );
      return send(res, 201, { ok: true, data: responseData });
    }

    if (paymentMethod === 'bonus') {
      payload.use_bonus = true;
      payload.use_cashless = false;
      const responseData = await runIdempotentOrderRequest(
        session.clientId,
        requestId,

        requestFingerprint,
        async () => {
          const data = await tmPostJson('create_order2', payload);
          return {
            ...data,
            paymentMethod: 'bonus',
            paymentStatus: 'bonus',
            bonusMode: 'use_available_balance',
            tariffId,
            crewGroupId: definition.crewGroupId,
            tariffKey,
          };
        },
      );
      return send(res, 201, { ok: true, data: responseData });
    }

    if (!cardBindingConfigured()) {
      const e = new Error('ATMOS card payments are not configured yet');
      e.statusCode = 409;
      throw e;
    }
    const responseData = await runIdempotentOrderRequest(
      session.clientId,
      requestId,

      requestFingerprint,
      async () => {
        const { card } = await getStoredCard(session.clientId, Number(body.cardId || 0));
        const checkoutId = crypto.randomUUID();
        payload.comment = [
          body.comment ? String(body.comment) : '',
          `[Yangi Taxi] Класс: ${tariffKey}`,
          !destination && tariffKey === 'delivery' ? '[Yangi Taxi] Доставка: конечный адрес не указан' : '',
          `[Yangi Taxi] Оплата: карта ATMOS после поездки; checkout ${checkoutId}`,
        ].filter(Boolean).join('\n');

        const data = await tmPostJson('create_order2', payload);
        const orderId = Number(data.order_id || 0);
        if (!orderId) {
          const e = new Error('TaxiMaster did not return order_id');
          e.statusCode = 502;
          throw e;
        }
        const record = {
          checkoutId,
          clientId: Number(session.clientId),
          phone: String(session.phone || ''),
          paymentMethod: 'card',
          paymentKind: 'stored_card_post_ride',
          tariffId: Number(tariffId),
          crewGroupId: Number(definition.crewGroupId),
          tariffKey,
          addresses: payload.addresses,
          cardId: Number(card.cardId),
          maskedPan: String(card.maskedPan || ''),
          estimatedAmount: Number(payload.total_cost || 0),
          amount: 0,
          amountTiyin: 0,
          orderId,
          status: 'order_created_waiting_finish',
          createdAt: new Date().toISOString(),
          orderCreatedAt: new Date().toISOString(),
        };
        await setPayment(checkoutId, record);
        console.log(new Date().toISOString(), `[CARD] order #${orderId} created; ATMOS charge deferred until finished`);
        return {
          ...data,
          paymentRequired: false,
          paymentMethod: 'card',
          provider: 'ATMOS',
          checkoutId,
          maskedPan: record.maskedPan,
          paymentStatus: 'waiting_finish',
          chargeMoment: 'after_ride',
          tariffId,
          crewGroupId: definition.crewGroupId,
          tariffKey,
        };
      },
    );
    return send(res, 201, { ok: true, data: responseData });
  }

  const paymentStatusMatch = /^\/api\/payments\/([^/]+)\/status$/.exec(path);
  if (req.method === 'GET' && paymentStatusMatch) {
    const checkoutId = decodeURIComponent(paymentStatusMatch[1]);
    const record = await getPayment(checkoutId);
    if (!record || Number(record.clientId) !== Number(session.clientId)) {
      const e = new Error('Payment not found');
      e.statusCode = 404;
      throw e;
    }
    return send(res, 200, { ok: true, data: {
      status: record.status || 'order_created_waiting_finish',
      orderId: record.orderId || null,
      paid: Boolean(record.paidAt),
      amount: Number(record.amount || 0) || null,
      finalAmount: Number(record.finalAmount || 0) || null,
      maskedPan: record.maskedPan || '',
      paymentAttempts: Number(record.paymentAttempts || 0),
      lastPaymentError: record.lastPaymentError || null,
      nextPaymentAttemptAt: record.nextPaymentAttemptAt || null,
      driverCreditOperId: record.driverCreditOperId || null,
      driverCreditStatus: record.driverCreditOperId ? 'credited' : (record.paidAt ? 'waiting_credit' : 'not_paid_yet'),
    } });
  }

  const orderPaymentMatch = /^\/api\/orders\/(\d+)\/payment$/.exec(path);
  if (req.method === 'GET' && orderPaymentMatch) {
    const orderId = Number(orderPaymentMatch[1]);
    await loadPayments();
    const record = [...paymentStore.values()].find((p) => Number(p?.orderId || 0) === orderId);
    if (!record || Number(record.clientId) !== Number(session.clientId)) {
      const e = new Error('Payment not found');
      e.statusCode = 404;
      throw e;
    }
    return send(res, 200, { ok: true, data: {
      checkoutId: record.checkoutId,
      orderId,
      status: record.status,
      paid: Boolean(record.paidAt),
      amount: Number(record.amount || 0) || null,
      finalAmount: Number(record.finalAmount || 0) || null,
      maskedPan: record.maskedPan || '',
      paymentAttempts: Number(record.paymentAttempts || 0),
      lastPaymentError: record.lastPaymentError || null,
      nextPaymentAttemptAt: record.nextPaymentAttemptAt || null,
      driverCredited: Boolean(record.driverCreditOperId),
    } });
  }

  const retryPaymentMatch = /^\/api\/payments\/([^/]+)\/retry$/.exec(path);
  if (req.method === 'POST' && retryPaymentMatch) {
    const checkoutId = decodeURIComponent(retryPaymentMatch[1]);
    const record = await getPayment(checkoutId);
    if (!record || Number(record.clientId) !== Number(session.clientId)) {
      const e = new Error('Payment not found');
      e.statusCode = 404;
      throw e;
    }
    if (record.paidAt) return send(res, 200, { ok: true, data: { status: record.status, paid: true, orderId: record.orderId } });
    record.paymentAttempts = 0;
    record.nextPaymentAttemptAt = null;
    record.status = 'payment_retry';
    await setPayment(checkoutId, record);
    try { await settleFinishedCardPayment(record, { forcePaymentRetry: true }); } catch (_) {}
    return send(res, 200, { ok: true, data: {
      status: record.status,
      paid: Boolean(record.paidAt),
      orderId: record.orderId,
      amount: Number(record.amount || 0) || null,
      lastPaymentError: record.lastPaymentError || null,
      nextPaymentAttemptAt: record.nextPaymentAttemptAt || null,
    } });
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
    await requireOwnedOrder(orderId, state);
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
    await requireOwnedOrder(orderId, state);

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
    await requireOwnedOrder(orderId, state);
    const stateId = await getCancelStateId();
    const data = await tmGet('check_cancel_order_penalty', { order_id: orderId, cancel_order_state_id: stateId });
    return send(res, 200, { ok: true, data: { stateId, ...data } });
  }

  const cancel = /^\/api\/orders\/(\d+)\/cancel$/.exec(path);
  if (req.method === 'POST' && cancel) {
    const orderId = Number(cancel[1]);
    const state = await tmGet('get_order_state', { order_id: orderId });
    await requireOwnedOrder(orderId, state);
    const stateId = await getCancelStateId();
    const p = await tmGet('check_cancel_order_penalty', { order_id: orderId, cancel_order_state_id: stateId });
    const data = await tmPostQuery('change_order_state', {
      order_id: orderId,
      new_state: stateId,
      cancel_order_penalty_sum: p.cancel_order_penalty_sum || 0,
    });
    try {
      await loadPayments();
      const payment = [...paymentStore.values()].find((pmt) => Number(pmt?.orderId || 0) === orderId);
      if (payment && !payment.paidAt) {
        payment.status = 'order_aborted_no_charge';
        payment.abortedAt = new Date().toISOString();
        payment.cancelPenalty = Number(p.cancel_order_penalty_sum || 0);
        await setPayment(payment.checkoutId, payment);
      } else if (payment?.paidAt && !payment.driverCreditOperId) {
        payment.status = 'paid_order_aborted_refund_required';
        payment.refundRequired = true;
        await setPayment(payment.checkoutId, payment);
      }
    } catch (error) {
      console.warn(new Date().toISOString(), 'Could not update card payment after cancellation:', error.message);
    }
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
      if (cfg.mock) return send(res, 200, { ok: true, service: 'Yangi Taxi Backend', tmApi: 'demo', mock: true, timeZone: cfg.timeZone });
      await tmGet('ping');
      return send(res, 200, { ok: true, service: 'Yangi Taxi Backend', tmApi: 'ok', mock: false, timeZone: cfg.timeZone, sourceTime: tmTime() });
    }
    return cfg.mock ? await mockRoute(req, res, path, url) : await realRoute(req, res, path, url);
  } catch (e) {
    const status = e.statusCode || 500;
    if (status >= 500 || (e.tmCode != null && Number(e.tmCode) !== 100)) {
      console.error(new Date().toISOString(), e);
    } else {
      console.warn(new Date().toISOString(), status, e.message || 'Request rejected');
    }
    return send(res, status, {
      ok: false,
      error: {
        message: e.message || 'Internal error',
        tmCode: e.tmCode ?? null,
      },
    });
  }
});

server.listen(cfg.port, cfg.host, async () => {
  console.log('Yangi Taxi backend listening on http://' + cfg.host + ':' + cfg.port + ' mock=' + cfg.mock);
  if (!cfg.mock) {
    if (cfg.paymentSettlementEnabled) {
      let lockAcquired = false;
      try {
        lockAcquired = await acquireSettlementWorkerLock();
      } catch (error) {
        console.error('Post-ride settlement lock failed:', error.message || error);
      }

      if (lockAcquired) {
        const intervalMs = cfg.tmDriverSettlementIntervalSec * 1000;
        setTimeout(() => {
          settleFinishedCardOrders().catch((error) =>
            console.warn(new Date().toISOString(), 'Initial post-ride settlement check failed:', error.message)
          );
        }, 5000).unref();
        setInterval(() => {
          settleFinishedCardOrders().catch((error) =>
            console.warn(new Date().toISOString(), 'Post-ride settlement worker failed:', error.message)
          );
        }, intervalMs).unref();
        console.log(
          'Post-ride ATMOS/driver settlement: every ' +
          Math.round(intervalMs / 1000) +
          's; worker lock pid=' +
          process.pid
        );
      } else {
        console.warn(
          'Post-ride ATMOS/driver settlement: disabled in this process because another LIVE worker owns the lock'
        );
      }
    } else {
      console.log('Post-ride ATMOS/driver settlement: disabled for this process');
    }
    setTimeout(() => {
      diagnoseAtmosCardBinding().catch((error) =>
        console.warn('ATMOS diagnostics failed:', error.message)
      );
    }, 1200).unref();
  }
});
