/** Private loopback interface to authenticated fleet workers. Not a TM API. */
import { timingSafeEqual } from 'node:crypto';
import { DeliveryError } from './store.mjs';

export function createDeliveryBridge({ transport, token }) {
  if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{43,128}$/.test(token)) throw new Error('Strong dedicated Delivery bridge token required');
  const expected = Buffer.from('Bearer ' + token);
  return async (req, res) => {
    const path = new URL(req.url, 'http://local').pathname;
    if (!path.startsWith('/internal/delivery/')) return false;
    const send = (code, value) => { res.writeHead(code, { 'content-type':'application/json', 'cache-control':'no-store' }); res.end(JSON.stringify(value)); };
    const peer = req.socket.remoteAddress, actual = Buffer.from(String(req.headers.authorization || ''));
    if (!['127.0.0.1','::1','::ffff:127.0.0.1'].includes(peer) || actual.length !== expected.length || !timingSafeEqual(actual, expected)) { send(403, { error:'Access denied' }); return true; }
    try {
      if (req.method !== 'POST' || !['/internal/delivery/info','/internal/delivery/cash','/internal/delivery/pickup','/internal/delivery/shop-payment','/internal/delivery/client-arrival'].includes(path)) throw new DeliveryError(404, 'Route not found');
      if (!String(req.headers['content-type'] || '').startsWith('application/json')) throw new DeliveryError(415, 'JSON required');
      const chunks = []; let size = 0;
      for await (const chunk of req) { size += chunk.length; if (size > 4096) throw new DeliveryError(413, 'Request too large'); chunks.push(chunk); }
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new DeliveryError(400, 'Invalid JSON'); }
      if (!body || Array.isArray(body) || typeof body !== 'object' || Object.keys(body).some(k => !['order_id','driver_id','crew_id', ...((path.endsWith('/cash') || path.endsWith('/shop-payment')) ? ['amount_uzs'] : [])].includes(k))) throw new DeliveryError(422, 'Invalid request');
      for (const name of ['order_id','driver_id','crew_id']) if (!Number.isSafeInteger(body[name]) || body[name] < 1) throw new DeliveryError(422, 'Invalid identifier');
      const result = path.endsWith('/shop-payment') ? await transport.confirmShopPayment(body.order_id,body,body.amount_uzs) : path.endsWith('/client-arrival') ? await transport.confirmClientArrival(body.order_id,body) : path.endsWith('/cash') ? await transport.confirmCash(body.order_id, body, body.amount_uzs) : path.endsWith('/pickup') ? await transport.authorizePickup(body.order_id,body) : await transport.info(body.order_id, body);
      send(200, { ok:true, data:result });
    } catch (e) { const code = e instanceof DeliveryError ? e.statusCode : 503; send(code, { error:code < 500 ? e.message : 'Delivery verification unavailable' }); }
    return true;
  };
}
