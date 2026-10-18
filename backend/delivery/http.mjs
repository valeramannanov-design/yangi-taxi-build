import { DeliveryError } from './store.mjs';
import { createRoadQuotes } from './road-pricing.mjs';
import { readFileSync } from 'node:fs';

const error = (status, message) => { throw new DeliveryError(status, message); };
async function bytes(req, limit) {
  if (Number(req.headers['content-length'] || 0) > limit) error(413, 'Request too large');
  const parts = []; let length = 0;
  for await (const part of req) {
    length += part.length;
    if (length > limit) error(413, 'Request too large');
    parts.push(part);
  }
  return Buffer.concat(parts);
}
async function json(req) {
  if (!String(req.headers['content-type'] || '').toLowerCase().startsWith('application/json')) error(415, 'JSON required');
  try { const value = JSON.parse((await bytes(req, 64 * 1024)).toString('utf8')); if (!value || Array.isArray(value) || typeof value !== 'object') error(400, 'JSON object required'); return value; }
  catch (e) { if (e instanceof DeliveryError) throw e; error(400, 'Invalid JSON'); }
}
function bearer(req) {
  const header = req.headers.authorization;
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) error(401, 'Authentication required');
  return header.slice(7);
}
function send(res, status, data) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
  res.end(JSON.stringify(data));
}

/** Reuses the host's authenticated passenger session, never trusts identity headers.
 * It returns false for all non-delivery routes so taxi behavior stays with the host.
 */
export function createDeliveryHandler({ store, passengerIdentity, transport = null, pricingProvider = null }) {
  if (typeof passengerIdentity !== 'function') throw new TypeError('Passenger authentication adapter required');
  const roadQuote=createRoadQuotes(store,pricingProvider);
  return async function handle(req, res) {
    const url = new URL(req.url, 'http://local'), path = url.pathname, method = req.method;
    const files = { '/delivery': ['index.html', 'text/html; charset=utf-8'], '/delivery/': ['index.html', 'text/html; charset=utf-8'], '/delivery/portal.css': ['portal.css', 'text/css; charset=utf-8'], '/delivery/portal.js': ['portal.js', 'text/javascript; charset=utf-8'] };
    if (method === 'GET' && Object.hasOwn(files, path)) {
      const [file, mime] = files[path];
      res.writeHead(200, { 'content-type': mime, 'x-content-type-options': 'nosniff', 'cache-control': 'no-store',
        'content-security-policy': "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'" });
      res.end(readFileSync(new URL('./portal/' + file, import.meta.url))); return true;
    }
    const prefix = '/api/delivery';
    if (path !== prefix && !path.startsWith(prefix + '/')) return false;
    const route = path.slice(prefix.length), key = req.headers['idempotency-key'];
    try {
      let result;
      if (method === 'GET' && route === '/catalog') result = store.catalog(url.searchParams.has('category') ? Number(url.searchParams.get('category')) : undefined, url.searchParams.get('q') || '', url.searchParams.get('service'));
      else if (method === 'GET' && /^\/shops\/[1-9][0-9]*$/.test(route)) result = store.shop(Number(route.split('/')[2]), url.searchParams.get('service'));
      else if (method === 'GET' && /^\/shops\/[1-9][0-9]*\/products\/[1-9][0-9]*$/.test(route)) result = store.productDetail(Number(route.split('/')[2]),Number(route.split('/')[4]),url.searchParams.get('service'));
      else if (method === 'GET' && /^\/images\/[a-f0-9]{36}$/.test(route)) {
        const image = store.publicImage(route.split('/')[2]);
        res.writeHead(200, { 'content-type': image.mime, 'content-length': image.data.length, 'cache-control': 'private,max-age=300', 'x-content-type-options': 'nosniff' });
        res.end(image.data); return true;
      } else if (method === 'POST' && route === '/auth/login') {
        const input = await json(req);
        // Deliberately ignore X-Forwarded-For. Only a separately configured trusted proxy may supply it.
        result = store.login(input.login, input.password, req.socket.remoteAddress || 'unknown');
      } else if (route.startsWith('/customer/')) {
        const customer = await passengerIdentity(req);
        if (method === 'POST' && route === '/customer/quotes') result = await roadQuote(customer, await json(req));
        else if (method === 'POST' && route === '/customer/orders') result = store.checkout(customer, await json(req), key);
        else if (method === 'GET' && route === '/customer/orders') result = store.ordersForCustomer(customer);
        else if (method === 'GET' && /^\/customer\/orders\/[a-f0-9]{36}\/reviews$/.test(route)) result=store.reviews.forCustomer(customer,route.split('/')[3]);
        else if (method === 'POST' && /^\/customer\/orders\/[a-f0-9]{36}\/reviews$/.test(route)) result=store.reviews.submit(customer,route.split('/')[3],await json(req),key);
        else if (method === 'GET' && route === '/customer/notifications') result = store.pickup.notifications(store.customer(customer));
        else if (method === 'POST' && /^\/customer\/notifications\/[1-9][0-9]*\/read$/.test(route)) {await json(req);result=store.pickup.readNotification(store.customer(customer),Number(route.split('/')[3]),key);}
        else if (method === 'GET' && /^\/customer\/orders\/[a-f0-9]{36}$/.test(route)) result = store.orderForCustomer(customer, route.split('/')[3]);
        else if (method === 'POST' && /^\/customer\/orders\/[a-f0-9]{36}\/cancel$/.test(route)) result = store.cancel(customer, route.split('/')[3], await json(req), key);
        else error(404, 'Delivery route not found');
      } else {
        const token = bearer(req), user = store.identity(token);
        if (method === 'GET' && route === '/me') result = user;
        else if (method === 'POST' && route === '/auth/logout') { store.logout(token); result = { logged_out: true }; }
        else if (route.startsWith('/admin/')) {
          store.admin(user);
          if (method === 'GET' && route === '/admin/config') result = { categories: store.all('SELECT * FROM delivery_categories'), zones: store.all('SELECT * FROM delivery_zones'), shops: store.all('SELECT * FROM delivery_shops'), pricing:store.pricing() };
          else if(method==='GET'&&route==='/admin/pricing-options') { if(!pricingProvider)error(503,'Road pricing is not connected');result=await pricingProvider.options(); }
          else if(method==='PUT'&&route==='/admin/pricing') {
            const input=await json(req);
            if(input.enabled===true){if(!pricingProvider)error(503,'Road pricing is not connected');const choices=await pricingProvider.options();if(!choices.tariffs.some(t=>t.id===input.tariff_id)||!choices.groups.some(g=>g.id===input.crew_group_id))error(422,'Select an active TaxiMaster tariff and crew group');}
            result=store.savePricing(user,input);
          }
          else if (method === 'POST' && route === '/admin/categories') result = store.category(user, await json(req));
          else if (method === 'PUT' && /^\/admin\/categories\/[1-9][0-9]*$/.test(route)) result = store.category(user, await json(req), Number(route.split('/')[3]));
          else if (method === 'POST' && route === '/admin/zones') result = store.zone(user, await json(req));
          else if (method === 'PUT' && /^\/admin\/zones\/[1-9][0-9]*$/.test(route)) result = store.zone(user, await json(req), Number(route.split('/')[3]));
          else if (method === 'POST' && route === '/admin/shops') result = store.createShop(user, await json(req));
          else if (method === 'PUT' && /^\/admin\/shops\/[1-9][0-9]*$/.test(route)) result = store.updateShop(user, Number(route.split('/')[3]), await json(req));
          else if (method === 'GET' && /^\/admin\/shops\/[1-9][0-9]*\/products$/.test(route)) result = store.adminProducts(user, Number(route.split('/')[3]));
          else if (method === 'GET' && /^\/admin\/shops\/[1-9][0-9]*\/coupons$/.test(route)) result = store.adminCoupons(user, Number(route.split('/')[3]));
          else if (method === 'POST' && /^\/admin\/shops\/[1-9][0-9]*\/coupons$/.test(route)) result = store.adminSaveCoupon(user, Number(route.split('/')[3]), await json(req));
          else if (method === 'PUT' && /^\/admin\/shops\/[1-9][0-9]*\/coupons\/[1-9][0-9]*$/.test(route)) result = store.adminSaveCoupon(user, Number(route.split('/')[3]), await json(req), Number(route.split('/')[5]));
          else if (method === 'POST' && /^\/admin\/shops\/[1-9][0-9]*\/products$/.test(route)) result = store.adminSaveProduct(user, Number(route.split('/')[3]), await json(req));
          else if (method === 'POST' && /^\/admin\/shops\/[1-9][0-9]*\/images$/.test(route)) result = store.adminImage(user, Number(route.split('/')[3]), await bytes(req, 2 * 1024 * 1024));
          else if (method === 'PUT' && /^\/admin\/shops\/[1-9][0-9]*\/products\/[1-9][0-9]*$/.test(route)) result = store.adminSaveProduct(user, Number(route.split('/')[3]), await json(req), Number(route.split('/')[5]));
          else if (method === 'GET' && route === '/admin/orders') result = store.ordersForStaff(user);
          else if (method === 'POST' && /^\/admin\/orders\/[a-f0-9]{36}\/dispatch$/.test(route)) {
            if (!transport) error(503, 'TaxiMaster delivery dispatch is not enabled');
            result = transport.dispatch(user, route.split('/')[3], await json(req), key);
          }
          else if (method === 'POST' && /^\/admin\/orders\/[a-f0-9]{36}\/manage$/.test(route)) {
            if(!transport)error(503,'TaxiMaster delivery dispatch is not enabled');
            result=transport.management.request(user,route.split('/')[3],await json(req),key);
          }
          else if(method==='GET' && route==='/admin/management')result=store.all('SELECT id,order_id,action,phase,last_error,updated_at FROM delivery_management ORDER BY created_at DESC LIMIT 200');
          else if (method === 'GET' && route === '/admin/transport') result = { enabled: !!transport, jobs: store.all('SELECT order_id,crew_id,tariff_id,phase,transport_order_id,last_error,updated_at FROM delivery_transport_jobs ORDER BY created_at DESC LIMIT 200') };
          else if (method === 'GET' && route === '/admin/transport-options') {
            if (!transport) error(503, 'TaxiMaster delivery dispatch is not enabled');
            result = await transport.adapter.options();
          }
          else if (method === 'GET' && route === '/admin/reviews') result=store.reviews.forStaff(user);
          else if (method === 'GET' && route === '/admin/complaints') result=store.reviews.complaints(user);
          else if (method === 'POST' && /^\/admin\/complaints\/[1-9][0-9]*$/.test(route)) result=store.reviews.updateComplaint(user,Number(route.split('/')[3]),await json(req),key);
          else if (method === 'GET' && route === '/admin/finance') result = store.finance(user);
          else error(404, 'Delivery route not found');
        } else if (route.startsWith('/merchant/')) {
          store.partner(user);
          if (method === 'GET' && route === '/merchant/products') result = store.products(user);
          else if (method === 'GET' && route === '/merchant/coupons') result = store.coupons(user);
          else if (method === 'POST' && route === '/merchant/coupons') result = store.saveCoupon(user, await json(req));
          else if (method === 'PUT' && /^\/merchant\/coupons\/[1-9][0-9]*$/.test(route)) result = store.saveCoupon(user, await json(req), Number(route.split('/')[3]));
          else if (method === 'POST' && route === '/merchant/products') result = store.saveProduct(user, await json(req));
          else if (method === 'PUT' && /^\/merchant\/products\/[1-9][0-9]*$/.test(route)) result = store.saveProduct(user, await json(req), Number(route.split('/')[3]));
          else if (method === 'POST' && route === '/merchant/images') result = store.image(user, await bytes(req, 2 * 1024 * 1024));
          else if (method === 'GET' && route === '/merchant/orders') result = store.ordersForStaff(user);
          else if (method === 'POST' && /^\/merchant\/orders\/[a-f0-9]{36}\/action$/.test(route)) result = store.merchantAction(user, route.split('/')[3], await json(req), key);
          else if (method === 'GET' && route === '/merchant/reviews') result=store.reviews.forStaff(user);
          else if (method === 'GET' && route === '/merchant/finance') result = store.finance(user);
          else error(404, 'Delivery route not found');
        } else error(404, 'Delivery route not found');
      }
      send(res, 200, { ok: true, data: result });
    } catch (e) {
      const status = e instanceof DeliveryError || e.statusCode === 401 ? e.statusCode : 500;
      send(res, status, { ok: false, error: { message: status < 500 ? e.message : 'Delivery service error' } });
    }
    return true;
  };
}
