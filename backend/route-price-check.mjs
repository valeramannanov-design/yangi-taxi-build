import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import readline from 'node:readline/promises';
import { stdin as input, stdout as output } from 'node:process';

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
  city: process.env.TM_DEFAULT_CITY || '',
  searchTm: String(process.env.TM_ADDRESS_SEARCH_TM || 'true').toLowerCase() !== 'false',
  searchGeo: String(process.env.TM_ADDRESS_SEARCH_TMGEO || 'false').toLowerCase() === 'true',
  search2gis: String(process.env.TM_ADDRESS_SEARCH_2GIS || 'false').toLowerCase() === 'true',
  groups: {
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
  if (!cfg.base || !cfg.secret) throw new Error('TaxiMaster API is not configured');
  const headers = { Accept: 'application/json', Signature: md5(signed) };
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

function optionalNumber(name) {
  const raw = String(process.env[name] || '').trim();
  if (!raw) return null;
  const value = Number(raw);
  return Number.isFinite(value) ? value : null;
}

function addressLabel(a) {
  return [a.city, a.street, a.house, a.point]
    .filter((x) => String(x || '').trim())
    .join(', ') || a.address || a.name || '(без названия)';
}

function addressPoint(a) {
  const lat = Number(a.coords?.lat ?? a.lat ?? 0);
  const lon = Number(a.coords?.lon ?? a.lon ?? 0);
  if (!Number.isFinite(lat) || !Number.isFinite(lon) || (!lat && !lon)) return null;
  return {
    address: addressLabel(a),
    lat,
    lon,
  };
}

async function searchAddresses(query) {
  const data = await tmGet('get_addresses_like2', {
    get_streets: true,
    get_points: true,
    get_houses: true,
    address: query,
    city: cfg.city,
    max_addresses_count: 10,
    search_in_tm: cfg.searchTm,
    search_in_tmgeoservice: cfg.searchGeo,
    search_in_2gis: cfg.search2gis,
  });
  return (data.addresses || [])
    .map((a) => ({ raw: a, point: addressPoint(a) }))
    .filter((x) => x.point);
}

async function chooseAddress(rl, caption) {
  while (true) {
    const query = (await rl.question(caption + ': ')).trim();
    if (!query) continue;

    const found = await searchAddresses(query);
    if (!found.length) {
      console.log('Ничего не найдено. Попробуйте написать адрес иначе.');
      continue;
    }

    console.log('');
    found.forEach((item, i) => {
      const p = item.point;
      console.log(
        '[' + (i + 1) + '] ' + p.address +
        '  (' + p.lat.toFixed(6) + ', ' + p.lon.toFixed(6) + ')' +
        (item.raw.address_source ? ' [' + item.raw.address_source + ']' : '')
      );
    });
    console.log('');

    const answer = (await rl.question('Выберите номер [1-' + found.length + '], Enter = 1: ')).trim();
    const index = answer === '' ? 0 : Number(answer) - 1;
    if (Number.isInteger(index) && index >= 0 && index < found.length) {
      return found[index].point;
    }
    console.log('Неверный номер.');
  }
}

async function main() {
  const rl = readline.createInterface({ input, output });
  try {
    console.log('Yangi Taxi — LIVE route & price check');
    console.log('TaxiMaster:', cfg.base);
    console.log('TM_API_USER_ID:', cfg.userId || '(shared secret)');
    console.log('Time zone:', cfg.timeZone, 'source_time:', tmTime());
    console.log('');

    await tmGet('ping');
    console.log('✓ ping\n');

    const [groupsData, tariffsData] = await Promise.all([
      tmGet('get_crew_groups_list'),
      tmGet('get_tariffs_list'),
    ]);
    const groups = groupsData.crew_groups || groupsData.groups || [];
    const tariffs = tariffsData.tariffs || [];
    const groupMap = new Map(groups.map((x) => [Number(x.id || x.crew_group_id), x]));
    const tariffMap = new Map(tariffs.map((x) => [Number(x.id || x.tariff_id), x]));

    const source = await chooseAddress(rl, 'ОТКУДА');
    const destination = await chooseAddress(rl, 'КУДА');

    console.log('\nВыбран маршрут:');
    console.log('Откуда:', source.address, source.lat, source.lon);
    console.log('Куда:  ', destination.address, destination.lat, destination.lon);

    const sourceTime = tmTime();
    const route = await tmPostJson('analyze_route2', {
      get_full_route_coords: true,
      addresses: [source, destination],
    });

    const analyzed = route.addresses || [];
    const routeInfo = {
      city_dist: Number(route.city_dist || 0),
      country_dist: Number(route.country_dist || 0),
      source_country_dist: Number(route.source_country_dist || 0),
      full_route_coords_count: Array.isArray(route.full_route_coords)
        ? route.full_route_coords.length
        : 0,
    };
    console.log('\nTaxiMaster route:');
    console.table([routeInfo]);

    const clientId = optionalNumber('LIVE_TEST_CLIENT_ID');
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
            ...(clientId !== null ? { client_id: clientId } : {}),
            crew_group_id: def.group,
            source_time: sourceTime,
            is_prize: false,
            addresses: [
              { lat: source.lat, lon: source.lon },
              { lat: destination.lat, lon: destination.lon },
            ],
          });
          tariffId = Number(selected.tariff_id || selected.id || 0);
        }
        if (!tariffId) throw new Error('TaxiMaster returned no tariff_id');

        const cost = await tmPostJson('calc_order_cost2', {
          tariff_id: tariffId,
          source_time: sourceTime,
          is_prior: false,
          ...(clientId !== null ? { client_id: clientId } : {}),
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

    console.log('\nLIVE prices from TaxiMaster:');
    console.table(results);
    console.log('\nГотово. Пришлите сюда весь блок от "Выбран маршрут" до таблицы цен.');
  } finally {
    rl.close();
  }
}

main().catch((error) => {
  console.error('\nLIVE CHECK FAILED:', error.message || error);
  process.exitCode = 1;
});
