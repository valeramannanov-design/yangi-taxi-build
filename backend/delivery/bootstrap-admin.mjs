/** Local bootstrap only. Read credentials from stdin JSON, never argv or logs. */
import { isAbsolute } from 'node:path';
import { DeliveryStore } from './store.mjs';
const path = process.env.DELIVERY_DB_PATH;
if (!path || !isAbsolute(path)) throw new Error('Absolute DELIVERY_DB_PATH required');
let raw = '';
for await (const part of process.stdin) {
  raw += part.toString('utf8');
  if (raw.length > 4096) throw new Error('Bootstrap input too large');
}
const input = JSON.parse(raw), store = new DeliveryStore(path);
try { store.createAdmin(input.login, input.password); console.log('Delivery administrator created'); }
finally { store.close(); raw = ''; input.password = ''; }
