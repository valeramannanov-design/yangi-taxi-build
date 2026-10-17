import { parentPort, workerData } from 'node:worker_threads';
import { DeliveryStore } from './store.mjs';
const store = new DeliveryStore(workerData.file, { now: () => 1000000 });
try { const order = store.checkout(workerData.customer, { quote_id: workerData.quote_id }, workerData.key); parentPort.postMessage({ ok: true, id: order.id }); }
catch (e) { parentPort.postMessage({ ok: false, status: e.statusCode || 500 }); }
finally { store.close(); }
