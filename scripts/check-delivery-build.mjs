import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function checkDeliveryBuild(config) {
  let url;
  try { url = new URL(config.BACKEND_URL); } catch { throw new Error('BACKEND_URL must be an explicit HTTPS URL; demo is not allowed'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) {
    throw new Error('BACKEND_URL must use HTTPS without credentials, query or fragment');
  }
  if (!String(config.MAPKIT_API_KEY || '').trim()) throw new Error('MAPKIT_API_KEY is required');
  return url.href.replace(/\/$/, '');
}

export async function probeDeliveryBuild(base, request = fetch) {
  async function get(path) {
    const response = await request(base + path, { signal: AbortSignal.timeout(15000), redirect: 'error' });
    if (!response.ok) throw new Error(`Build preflight failed at ${path}: HTTP ${response.status}`);
    return response.json();
  }
  const health = await get('/health');
  if (health.ok !== true || health.mock !== false || health.tmApi !== 'ok') throw new Error('Real TaxiMaster backend is not healthy');
  const catalog = await get('/api/delivery/catalog');
  if (catalog.ok !== true || !Array.isArray(catalog.data?.shops) || !Array.isArray(catalog.data?.categories)) {
    throw new Error('Delivery catalog is unavailable');
  }
  return { backend: base, shops: catalog.data.shops.length, realTaxiMaster: true };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const args = process.argv.slice(2);
    const file = args.indexOf('--file');
    const config = file >= 0 ? JSON.parse(readFileSync(args[file + 1], 'utf8').replace(/^\uFEFF/, '')) : process.env;
    const base = checkDeliveryBuild(config);
    console.log(JSON.stringify(args.includes('--probe') ? await probeDeliveryBuild(base) : { valid: true, backend: base }));
  } catch (error) {
    // Never echo the configuration or remote response bodies: they may contain credentials.
    const message = error instanceof SyntaxError ? 'Build configuration is not valid JSON' : error.message;
    console.error(message);
    process.exitCode = 1;
  }
}
