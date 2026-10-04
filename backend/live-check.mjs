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
    const key = line.slice(0, i).trim();
    let value = line.slice(i + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!(key in process.env)) process.env[key] = value;
  }
}
loadEnv();

const cfg = {
  base: (process.env.TM_API_BASE_URL || '').replace(/\/$/, ''),
  userId: process.env.TM_API_USER_ID || '',
  secret: process.env.TM_API_SECRET || '',
  verifyTls: String(process.env.TM_API_VERIFY_TLS || 'true').toLowerCase() !== 'false',
  timeout: Number(process.env.TM_API_TIMEOUT_MS || 12000),
  timeZone: process.env.TM_TIME_ZONE || 'Asia/Tashkent',
  groups: {
    start: Number(process.env.TM_CREW_GROUP_START_ID || 0),
    comfort: Number(process.env.TM_CREW_GROUP_COMFORT_ID || 0),
    business: Number(process.env.TM_CREW_GROUP_BUSINESS_ID || 0),
    delivery: Number(process.env.TM_CREW_GROUP_DELIVERY_ID || 0),
    cargo: Number(process.env.TM_CREW_GROUP_CARGO_ID || 0),
  },
  fixedTariffs: {
    delivery: Number(process.env.TM_TARIFF_DELIVERY_ID || 0),
    cargo: Number(process.env.TM_TARIFF_CARGO_ID || 0),
  },
};

function required(name, value) {
  if (!value) throw new Error(name + ' is required');
  return value;
}

function md5(value) {
  return crypto.createHash('md5').update(value + cfg.secret, 'utf8').digest('hex');
}

function queryString(params = {}) {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
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
      res.on('end', () => resolve({
        status: res.statusCode || 0,
        body: Buffer.concat(chunks).toString('utf8'),
      }));
    });
    req.on('timeout', () => req.destroy(new Error('TaxiMaster timeout')));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function tmCall(name, method, query, body, signed) {
  required('TM_API_BASE_URL', cfg.base);
  required('TM_API_SECRET', cfg.secret);

  const headers = {
    Accept: 'application/json',
    Signature: md5(signed),
  };
  if (cfg.userId) headers['X-User-Id'] = cfg.userId;
  if (body) {
    headers['Content-Type'] = 'application/json; charset=utf-8';
    headers['Content-Length'] = Buffer.byteLength(body);
  }

  const url = cfg.base + '/' + name + (query ? '?' + query : '');
  const response = await rawRequest(url, method, headers, body);
  let parsed;
  try {
    parsed = JSON.parse(response.body);
  } catch {
    throw new Error(name + ': non-JSON response, HTTP ' + response.status);
  }
  if (parsed.code !== 0) {
    throw new Error(name + ': TM code ' + parsed.code + ' — ' + (parsed.descr || 'error'));
  }
  return parsed.data || {};
}

async function tmGet(name, params = {}) {
  const q = queryString(params);
  return tmCall(name, 'GET', q, '', q);
}

async function tmPostJson(name, data = {}) {
  const body = JSON.stringify(data);
  return tmCall(name, 'POST', '', body, body);
}

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
    }).formatToParts(date)
      .filter((x) => x.type !== 'literal')
      .map((x) => [x.type, x.value]),
  );
  return parts.year + parts.month + parts.day +
    parts.hour + parts.minute + parts.second;
}

function n(name) {
  const value = Number(process.env[name] || '');
  return Number.isFinite(value) ? value : null;
}

function compactGroup(x) {
  return {
    id: Number(x.id || x.crew_group_id || 0),
    name: x.name || '',
    is_active: x.is_active,
  };
}

function compactTariff(x) {
  return {
    id: Number(x.id || x.tariff_id || 0),
    name: x.name || '',
    is_active: x.is_active,
  };
}

async function main() {
  console.log('Yangi Taxi LIVE check');
  console.log('TaxiMaster:', cfg.base.replace(/:\/\/([^:@]+):[^@]+@/, '://$1:***@'));
  console.log('Time zone:', cfg.timeZone, 'source_time:', tmTime());
  console.log('TLS verify:', cfg.verifyTls);
  console.log('');

  await tmGet('ping');
  console.log('✓ ping');

  const [groupsData, tariffsData] = await Promise.all([
    tmGet('get_crew_groups_list'),
    tmGet('get_tariffs_list'),
  ]);

  const groups = (groupsData.crew_groups || groupsData.groups || []).map(compactGroup);
  const tariffs = (tariffsData.tariffs || []).map(compactTariff);
  const groupMap = new Map(groups.map((x) => [x.id, x]));
  const tariffMap = new Map(tariffs.map((x) => [x.id, x]));

  console.log('\nConfigured crew groups:');
  for (const [key, id] of Object.entries(cfg.groups)) {
    console.log('-', key, '=>', id || '(not set)', groupMap.get(id) || 'NOT FOUND');
  }

  console.log('\nConfigured fixed tariffs:');
  for (const [key, id] of Object.entries(cfg.fixedTariffs)) {
    console.log('-', key, '=>', id || '(not set)', tariffMap.get(id) || 'NOT FOUND');
  }

  console.log('\nAll active crew groups:');
  console.table(groups.filter((x) => x.is_active !== false));

  console.log('\nAll active tariffs:');
  console.table(tariffs.filter((x) => x.is_active !== false));

  const clientId = n('LIVE_TEST_CLIENT_ID');
  const sourceLat = n('LIVE_TEST_SOURCE_LAT');
  const sourceLon = n('LIVE_TEST_SOURCE_LON');
  const destLat = n('LIVE_TEST_DEST_LAT');
  const destLon = n('LIVE_TEST_DEST_LON');

  if (![clientId, sourceLat, sourceLon, destLat, destLon].every((x) => x !== null)) {
    console.log('\nRoute pricing test skipped.');
    console.log('Set LIVE_TEST_CLIENT_ID, LIVE_TEST_SOURCE_LAT, LIVE_TEST_SOURCE_LON,');
    console.log('LIVE_TEST_DEST_LAT and LIVE_TEST_DEST_LON to test real prices.');
    return;
  }

  const source = { lat: sourceLat, lon: sourceLon };
  const destination = { lat: destLat, lon: destLon };
  const sourceTime = tmTime();

  const route = await tmPostJson('analyze_route2', {
    get_full_route_coords: true,
    addresses: [source, destination],
  });

  console.log('\nRoute:');
  console.log({
    city_dist: route.city_dist,
    country_dist: route.country_dist,
    source_country_dist: route.source_country_dist,
    full_route_coords_count: Array.isArray(route.full_route_coords)
      ? route.full_route_coords.length
      : 0,
  });

  const definitions = [
    { key: 'start', group: cfg.groups.start },
    { key: 'comfort', group: cfg.groups.comfort },
    { key: 'business', group: cfg.groups.business },
    { key: 'delivery', group: cfg.groups.delivery, fixed: cfg.fixedTariffs.delivery },
    { key: 'cargo', group: cfg.groups.cargo, fixed: cfg.fixedTariffs.cargo },
  ];

  const results = [];
  for (const def of definitions) {
    try {
      let tariffId = def.fixed || 0;
      if (!tariffId) {
        const selected = await tmPostJson('select_tariff_for_order', {
          client_id: clientId,
          crew_group_id: def.group,
          source_time: sourceTime,
          is_prize: false,
          addresses: [source, destination],
        });
        tariffId = Number(selected.tariff_id || selected.id || 0);
      }
      if (!tariffId) throw new Error('no tariff_id');

      const analyzed = route.addresses || [];
      const cost = await tmPostJson('calc_order_cost2', {
        tariff_id: tariffId,
        crew_group_id: def.group,
        source_time: sourceTime,
        is_prior: false,
        client_id: clientId,
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

      results.push({
        key: def.key,
        crew_group_id: def.group,
        crew_group_name: groupMap.get(def.group)?.name || '',
        tariff_id: tariffId,
        tariff_name: tariffMap.get(tariffId)?.name || '',
        sum: Number(cost.sum),
      });
    } catch (error) {
      results.push({
        key: def.key,
        crew_group_id: def.group,
        error: error.message || String(error),
      });
    }
  }

  console.log('\nLIVE prices:');
  console.table(results);
}

main().catch((error) => {
  console.error('\nLIVE CHECK FAILED:', error.message || error);
  process.exitCode = 1;
});
