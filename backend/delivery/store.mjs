/** Durable Delivery domain. No TaxiMaster requests, driver credentials or live defaults.
 * Requires Node >=24. New transport methods below are private adapter interfaces,
 * never public endpoints and never claimed to be TaxiMaster wire/API fields.
 */
import { DatabaseSync } from 'node:sqlite';
import { randomBytes, scryptSync, timingSafeEqual, createHash } from 'node:crypto';
import { readFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { isTestIsolation } from './runtime-mode.mjs';
import { CashJournal } from './cash-journal.mjs';

export class DeliveryError extends Error {
  constructor(status, message) { super(message); this.statusCode = status; }
}
const fail = (status, message) => { throw new DeliveryError(status, message); };
const digest = value => createHash('sha256').update(value).digest('hex');
const id = () => randomBytes(18).toString('hex');
const text = (v, max = 240) => {
  if (typeof v !== 'string' || !v.trim() || v.trim().length > max || /[\x00-\x1f\x7f]/u.test(v)) fail(422, 'Invalid text');
  return v.trim();
};
const integer = (v, min = 0, max = 10_000_000) => {
  if (!Number.isSafeInteger(v) || v < min || v > max) fail(422, 'Invalid integer');
  return v;
};
const bool = v => { if (typeof v !== 'boolean') fail(422, 'Expected boolean'); return Number(v); };
const commerceService = value => { if (value !== null && !['food','market'].includes(value)) fail(422, 'Unknown shopping service'); return value; };
const point = v => {
  if (!v || !Number.isFinite(v.lat) || !Number.isFinite(v.lon) || Math.abs(v.lat) > 90 || Math.abs(v.lon) > 180) fail(422, 'Invalid coordinates');
  return { lat: v.lat, lon: v.lon };
};
const loginName = v => { v = text(v, 80).toLowerCase(); if (!/^[a-z0-9_.-]{3,80}$/.test(v)) fail(422, 'Invalid login'); return v; };
const passwordHash = value => {
  if (typeof value !== 'string' || value.length < 12 || value.length > 128) fail(422, 'Password must have 12–128 characters');
  const salt = randomBytes(16).toString('hex');
  return salt + ':' + scryptSync(value, salt, 32).toString('hex');
};
const passwordMatches = (value, encoded) => {
  const [salt, hash] = encoded.split(':');
  return timingSafeEqual(scryptSync(value, salt, 32), Buffer.from(hash, 'hex'));
};
const contains = (z, p) => p.lat >= z.south && p.lat <= z.north && p.lon >= z.west && p.lon <= z.east;
export function distanceMeters(a, b) {
  point(a); point(b); const rad = v => v * Math.PI / 180;
  const h = Math.sin(rad(b.lat - a.lat) / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(rad(b.lon - a.lon) / 2) ** 2;
  return Math.ceil(6371000 * 2 * Math.asin(Math.sqrt(Math.min(1, h))));
}

export class DeliveryStore {
  constructor(path, { now = () => Date.now(), testIsolation = null } = {}) {
    if (testIsolation && !isTestIsolation(testIsolation, path)) throw new Error('Invalid isolated TEST environment');
    this.testIsolation = testIsolation;
    this.testIsolationPath = path;
    this.cash = new CashJournal(this);
    this.now = now;
    if (path !== ':memory:') mkdirSync(dirname(resolve(path)), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.function('delivery_fold', { deterministic: true }, value => String(value).normalize('NFKC').toLocaleLowerCase());
    this.db.exec('PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;');
    this.db.exec('CREATE TABLE IF NOT EXISTS delivery_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)');
    if ((this.one('SELECT max(version) AS v FROM delivery_migrations').v || 0) > 8) { this.close(); throw new Error('Delivery database requires a newer service version'); }
    for (const version of [1, 2, 3, 4, 5, 6, 7, 8]) if (!this.one('SELECT 1 FROM delivery_migrations WHERE version=?', version)) {
      // SQLite table rebuild: disable FK enforcement outside the exclusive write
      // transaction, validate every reference before commit, then restore it.
      if(version===5)this.db.exec('PRAGMA foreign_keys=OFF');
      try { this.transaction(() => {
        // Another process may have migrated while this connection waited for its lock.
        if (this.one('SELECT 1 FROM delivery_migrations WHERE version=?', version)) return;
        this.db.exec(readFileSync(new URL('./migrations/' + String(version).padStart(3, '0') + '.sql', import.meta.url), 'utf8'));
        if(version===5 && this.all('PRAGMA foreign_key_check').length)throw new Error('Delivery migration has invalid references');
        this.run('INSERT INTO delivery_migrations VALUES(?,?)', version, now());
      }); } finally { if(version===5)this.db.exec('PRAGMA foreign_keys=ON'); }
    }
  }
  close() { this.db.close(); }
  one(sql, ...args) { return this.db.prepare(sql).get(...args); }
  all(sql, ...args) { return this.db.prepare(sql).all(...args); }
  run(sql, ...args) { return this.db.prepare(sql).run(...args); }
  transaction(fn) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const value = fn(); this.db.exec('COMMIT'); return value; }
    catch (e) { this.db.exec('ROLLBACK'); throw e; }
  }
  createAdmin(login, password) {
    login = loginName(login); const hash = passwordHash(password);
    return this.transaction(() => {
      if (this.one('SELECT 1 FROM delivery_users WHERE role=\'admin\'')) fail(409, 'Administrator already bootstrapped');
      return Number(this.run('INSERT INTO delivery_users(login,password_hash,role) VALUES(?,?,\'admin\')', login, hash).lastInsertRowid);
    });
  }
  login(login, password, peer) {
    login = loginName(login); peer = text(peer, 120);
    if (typeof password !== 'string' || password.length > 128) fail(401, 'Invalid credentials');
    const failures = this.one('SELECT count(*) AS n FROM delivery_login_failures WHERE (login=? OR peer=?) AND failed_at>?', login, peer, this.now() - 900_000).n;
    if (failures >= 10) fail(429, 'Too many login attempts');
    const user = this.one('SELECT * FROM delivery_users WHERE login=?', login);
    // Always do the expensive KDF, including for unknown names.
    const hash = user?.password_hash || '00000000000000000000000000000000:' + '0'.repeat(64);
    if (!passwordMatches(password, hash) || !user?.active) {
      this.run('INSERT INTO delivery_login_failures VALUES(?,?,?)', login, peer, this.now());
      fail(401, 'Invalid credentials');
    }
    const token = randomBytes(32).toString('base64url');
    this.transaction(() => {
      this.run('DELETE FROM delivery_login_failures WHERE failed_at<?', this.now() - 900_000);
      this.run('DELETE FROM delivery_sessions WHERE expires_at<=?', this.now());
      this.run('INSERT INTO delivery_sessions VALUES(?,?,?)', digest(token), user.id, this.now() + 43_200_000);
    });
    return { token, role: user.role, expires_at: this.now() + 43_200_000 };
  }
  identity(token) {
    if (typeof token !== 'string' || token.length > 150) fail(401, 'Authentication required');
    const user = this.one('SELECT u.id,u.login,u.role,s.id AS shop_id FROM delivery_sessions t JOIN delivery_users u ON u.id=t.user_id LEFT JOIN delivery_shops s ON s.partner_id=u.id WHERE t.digest=? AND t.expires_at>? AND u.active=1', digest(token), this.now());
    if (!user) fail(401, 'Session expired');
    return user;
  }
  logout(token) { this.run('DELETE FROM delivery_sessions WHERE digest=?', digest(token)); }
  admin(user) { if (user?.role !== 'admin') fail(403, 'Administrator required'); }
  partner(user) { if (user?.role !== 'partner' || !user.shop_id) fail(403, 'Partner required'); return user.shop_id; }
  category(user, input, categoryId) {
    this.admin(user); const name = text(input.name, 80), active = bool(input.active);
    if (categoryId) {
      if (!this.run('UPDATE delivery_categories SET name=?,active=? WHERE id=?', name, active, integer(categoryId, 1)).changes) fail(404, 'Category not found');
    } else categoryId = Number(this.run('INSERT INTO delivery_categories(name,active) VALUES(?,?)', name, active).lastInsertRowid);
    return { id: categoryId, name, active: !!active };
  }
  zone(user, input, zoneId) {
    this.admin(user); const south = point({ lat: input.south, lon: input.west }), north = point({ lat: input.north, lon: input.east });
    if (south.lat >= north.lat || south.lon >= north.lon) fail(422, 'Invalid delivery zone');
    const values = [text(input.name, 80), south.lat, north.lat, south.lon, north.lon, integer(input.base_uzs), integer(input.per_km_uzs), integer(input.max_distance_m, 1, 200_000), bool(input.active)];
    if (zoneId) {
      if (!this.run('UPDATE delivery_zones SET name=?,south=?,north=?,west=?,east=?,base_uzs=?,per_km_uzs=?,max_distance_m=?,active=? WHERE id=?', ...values, integer(zoneId, 1)).changes) fail(404, 'Zone not found');
    } else zoneId = Number(this.run('INSERT INTO delivery_zones(name,south,north,west,east,base_uzs,per_km_uzs,max_distance_m,active) VALUES(?,?,?,?,?,?,?,?,?)', ...values).lastInsertRowid);
    return this.one('SELECT * FROM delivery_zones WHERE id=?', zoneId);
  }
  createShop(user, input) {
    this.admin(user); const location = point(input), hash = passwordHash(input.password), login = loginName(input.login);
    const values = [integer(input.category_id, 1), (input.zone_id == null ? null : integer(input.zone_id, 1)), text(input.name, 100), text(input.address), location.lat, location.lon, integer(input.commission_bps, 0, 10000)];
    return this.transaction(() => {
      this.validateShopLocation(values[1], location);
      if (!this.one('SELECT 1 FROM delivery_categories WHERE id=?', values[0])) fail(422, 'Category not found');
      if (this.one('SELECT 1 FROM delivery_users WHERE login=?', login)) fail(409, 'Login already exists');
      const partnerId = Number(this.run('INSERT INTO delivery_users(login,password_hash,role) VALUES(?,?,\'partner\')', login, hash).lastInsertRowid);
      const shopId = Number(this.run('INSERT INTO delivery_shops(partner_id,category_id,zone_id,name,address,lat,lon,commission_bps) VALUES(?,?,?,?,?,?,?,?)', partnerId, ...values).lastInsertRowid);
      this.run('UPDATE delivery_shops SET service_kind=? WHERE id=?', commerceService(input.service_kind ?? null), shopId);
      return this.one('SELECT * FROM delivery_shops WHERE id=?', shopId);
    });
  }
  validateShopLocation(zoneId, location) {
    if (zoneId == null) return;
    const z = this.one('SELECT * FROM delivery_zones WHERE id=?', zoneId);
    if (!z || !contains(z, location)) fail(422, 'Store is outside configured zone');
  }
  updateShop(user, shopId, input) {
    this.admin(user); const location = point(input);
    return this.transaction(() => {
      this.validateShopLocation((input.zone_id == null ? null : integer(input.zone_id, 1)), location);
      if (!this.one('SELECT 1 FROM delivery_categories WHERE id=?', integer(input.category_id, 1))) fail(422, 'Category not found');
      if (!this.run('UPDATE delivery_shops SET category_id=?,zone_id=?,name=?,address=?,lat=?,lon=?,commission_bps=?,active=? WHERE id=?', input.category_id, input.zone_id ?? null, text(input.name, 100), text(input.address), location.lat, location.lon, integer(input.commission_bps, 0, 10000), bool(input.active), integer(shopId, 1)).changes) fail(404, 'Store not found');
      if (Object.hasOwn(input, 'service_kind')) this.run('UPDATE delivery_shops SET service_kind=? WHERE id=?', commerceService(input.service_kind), shopId);
      return this.one('SELECT * FROM delivery_shops WHERE id=?', shopId);
    });
  }
  catalog(categoryId, query = '', service = null) {
    commerceService(service);
    if (categoryId !== undefined) integer(categoryId, 1);
    if (typeof query !== 'string' || query.length > 100) fail(422, 'Invalid search');
    return { service, go_checkout:this.goCheckout(), categories: this.all('SELECT c.id,c.name FROM delivery_categories c WHERE c.active=1 AND (? IS NULL OR EXISTS(SELECT 1 FROM delivery_shops s WHERE s.category_id=c.id AND s.active=1 AND s.service_kind=?)) ORDER BY c.name', service, service),
      shops: this.all('SELECT s.id,s.name,s.address,s.category_id,s.lat,s.lon,s.service_kind FROM delivery_shops s JOIN delivery_categories c ON c.id=s.category_id WHERE s.active=1 AND c.active=1 AND (? IS NULL OR s.category_id=?) AND (? IS NULL OR s.service_kind=?) ORDER BY s.name', categoryId ?? null, categoryId ?? null, service, service),
      products: query.trim() ? this.all('SELECT p.id,p.shop_id,p.name,p.description,p.price_uzs,p.stock,p.image_id FROM delivery_products p JOIN delivery_shops s ON s.id=p.shop_id JOIN delivery_categories c ON c.id=s.category_id WHERE p.active=1 AND p.stock>0 AND s.active=1 AND c.active=1 AND (? IS NULL OR s.category_id=?) AND (? IS NULL OR s.service_kind=?) AND (instr(delivery_fold(p.name),delivery_fold(?))>0 OR instr(delivery_fold(p.description),delivery_fold(?))>0) ORDER BY p.name LIMIT 100', categoryId ?? null, categoryId ?? null, service, service, query.trim(), query.trim()) : [] };
  }
  shop(shopId, service = null) {
    commerceService(service);
    const shop = this.availableShop(shopId);
    if (service && shop.service_kind !== service) fail(404, 'Store not in this service');
    const { id, name, address, category_id, lat, lon } = shop;
    return { id, name, address, category_id, lat, lon, service_kind:shop.service_kind, products: this.all('SELECT id,sku,name,description,price_uzs,stock,image_id FROM delivery_products WHERE shop_id=? AND active=1 ORDER BY name', shopId) };
  }
  availableShop(shopId) {
    const shop = this.one('SELECT s.* FROM delivery_shops s JOIN delivery_categories c ON c.id=s.category_id WHERE s.id=? AND s.active=1 AND c.active=1', integer(shopId, 1));
    if (!shop) fail(409, 'Store unavailable');
    return shop;
  }
  products(user) { return this.#products(this.partner(user)); }
  adminProducts(user, shopId) { this.admin(user); return this.#products(this.#adminShop(shopId)); }
  adminSaveProduct(user, shopId, input, productId) { this.admin(user); return this.#saveProduct(this.#adminShop(shopId), input, productId); }
  #adminShop(shopId) {
    shopId = integer(shopId, 1);
    if (!this.one('SELECT 1 FROM delivery_shops WHERE id=?', shopId)) fail(404, 'Store not found');
    return shopId;
  }
  #products(shopId) {
    const rows=this.all('SELECT * FROM delivery_products WHERE shop_id=? ORDER BY name',shopId), byId=new Map();
    for(const row of this.all('SELECT r.product_id,r.recommended_id FROM delivery_product_recommendations r JOIN delivery_products p ON p.id=r.product_id JOIN delivery_products rp ON rp.id=r.recommended_id WHERE p.shop_id=? AND rp.shop_id=p.shop_id ORDER BY r.position',shopId)){
      if(!byId.has(row.product_id))byId.set(row.product_id,[]);byId.get(row.product_id).push(row.recommended_id);
    }
    return rows.map(p=>({...p,recommendation_ids:byId.get(p.id)||[]}));
  }
  productDetail(shopId, productId, service=null) {
    commerceService(service);const shop=this.availableShop(shopId);
    if(service&&shop.service_kind!==service)fail(404,'Store not in this service');
    const product=this.one('SELECT id,shop_id,sku,name,description,price_uzs,stock,image_id FROM delivery_products WHERE id=? AND shop_id=? AND active=1',integer(productId,1),shop.id);
    if(!product)fail(404,'Product not found');
    return {...product,recommendations:this.all('SELECT p.id,p.shop_id,p.sku,p.name,p.description,p.price_uzs,p.stock,p.image_id FROM delivery_product_recommendations r JOIN delivery_products p ON p.id=r.recommended_id WHERE r.product_id=? AND p.shop_id=? AND p.active=1 AND p.stock>0 ORDER BY r.position',product.id,shop.id)};
  }
  #setRecommendations(shopId,productId,ids) {
    if(!Array.isArray(ids)||ids.length>10||new Set(ids).size!==ids.length)fail(422,'Choose up to 10 unique recommendations');
    for(const value of ids){integer(value,1);if(value===productId||!this.one('SELECT 1 FROM delivery_products WHERE id=? AND shop_id=?',value,shopId))fail(422,'Recommendation must be another product in this store');}
    this.run('DELETE FROM delivery_product_recommendations WHERE product_id=?',productId);
    ids.forEach((value,index)=>this.run('INSERT INTO delivery_product_recommendations VALUES(?,?,?)',productId,value,index));
  }
  saveProduct(user, input, productId) { return this.#saveProduct(this.partner(user), input, productId); }
  #saveProduct(shopId, input, productId) {
    const imageId = input.image_id ?? null;
    const values = [text(input.sku, 80), text(input.name, 160), input.description ? text(input.description, 2000) : '', integer(input.price_uzs, 0), integer(input.stock, 0, 1_000_000), bool(input.active), imageId];
    return this.transaction(() => {
      if (imageId !== null && !this.one('SELECT 1 FROM delivery_images WHERE id=? AND shop_id=?', imageId, shopId)) fail(422, 'Image does not belong to store');
      const duplicate = this.one('SELECT id FROM delivery_products WHERE shop_id=? AND sku=? AND id<>?', shopId, values[0], productId ?? 0);
      if (duplicate) fail(409, 'SKU already exists');
      if (productId) {
        if (!this.one('SELECT 1 FROM delivery_products WHERE id=? AND shop_id=?', integer(productId, 1), shopId)) fail(404, 'Product not found');
        if (!this.run('UPDATE delivery_products SET sku=?,name=?,description=?,price_uzs=?,stock=?,active=?,image_id=?,version=version+1 WHERE id=? AND shop_id=? AND version=?', ...values, productId, shopId, integer(input.version, 1)).changes) fail(409, 'Product changed; refresh before editing stock');
      } else productId = Number(this.run('INSERT INTO delivery_products(shop_id,sku,name,description,price_uzs,stock,active,image_id) VALUES(?,?,?,?,?,?,?,?)', shopId, ...values).lastInsertRowid);
      if(Object.hasOwn(input,'recommendation_ids'))this.#setRecommendations(shopId,productId,input.recommendation_ids);
      return {...this.one('SELECT * FROM delivery_products WHERE id=?', productId),recommendation_ids:this.all('SELECT recommended_id FROM delivery_product_recommendations WHERE product_id=? ORDER BY position',productId).map(r=>r.recommended_id)};
    });
  }
  image(user, bytes) {
    return this.#image(this.partner(user), bytes);
  }
  adminImage(user, shopId, bytes) { this.admin(user); return this.#image(this.#adminShop(shopId), bytes); }
  #image(shopId, bytes) {
    if (!Buffer.isBuffer(bytes) || bytes.length < 12 || bytes.length > 2 * 1024 * 1024) fail(422, 'Image must be at most 2 MiB');
    let mime;
    if (bytes.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) mime = 'image/png';
    else if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) mime = 'image/jpeg';
    else if (bytes.toString('ascii', 0, 4) === 'RIFF' && bytes.toString('ascii', 8, 12) === 'WEBP') mime = 'image/webp';
    else fail(422, 'Only PNG, JPEG and WebP images are supported');
    return this.transaction(() => {
      const size = this.one('SELECT coalesce(sum(length(data)),0) AS n FROM delivery_images WHERE shop_id=?', shopId).n;
      if (size + bytes.length > 100 * 1024 * 1024) fail(409, 'Store image quota exceeded');
      const imageId = id(); this.run('INSERT INTO delivery_images VALUES(?,?,?,?)', imageId, shopId, mime, bytes);
      return { id: imageId };
    });
  }
  publicImage(imageId) {
    const image = this.one('SELECT i.mime,i.data FROM delivery_images i JOIN delivery_products p ON p.image_id=i.id JOIN delivery_shops s ON s.id=p.shop_id WHERE i.id=? AND s.active=1 AND p.active=1 LIMIT 1', text(imageId, 50));
    if (!image) fail(404, 'Image not found'); return image;
  }
  customer(identity) {
    if (!identity || !/^[1-9][0-9]{0,14}$/.test(String(identity.id)) || typeof identity.phone !== 'string' || !/^\+?[0-9]{7,15}$/.test(identity.phone)) fail(401, 'Passenger authentication required');
    return { id: String(identity.id), phone: identity.phone };
  }
  quote(identity, input, road = null) {
    const customer = this.customer(identity), location = point(input.destination), address = text(input.destination.address);
    return this.transaction(() => {
      const shop = this.availableShop(input.shop_id), z = this.one('SELECT * FROM delivery_zones WHERE id=?', shop.zone_id);
      this.assertCashShop(shop);
      if (road) {
        const current=this.pricing(),before=road.context;
        if(!current.enabled || current.version!==before.pricing.version || shop.address!==before.shop.address || shop.lat!==before.shop.lat || shop.lon!==before.shop.lon)fail(409,'Delivery settings or store changed; calculate again');
        integer(road.distance_m,0,current.max_distance_m);integer(road.delivery_uzs,1,100_000_000);
      } else if (!z || !z.active || !contains(z, location)) fail(422, 'Address outside delivery zone');
      const distance_m = road ? road.distance_m : distanceMeters(shop, location);
      if (!road && distance_m > z.max_distance_m) fail(422, 'Address too far from store');
      if (!Array.isArray(input.items) || input.items.length < 1 || input.items.length > 50) fail(422, 'Cart must have 1–50 items');
      const seen = new Set(), items = input.items.map(row => {
        const productId = integer(row.product_id, 1), quantity = integer(row.quantity, 1, 99);
        if (seen.has(productId)) fail(422, 'Duplicate cart product'); seen.add(productId);
        const product = this.one('SELECT * FROM delivery_products WHERE id=? AND shop_id=? AND active=1', productId, shop.id);
        if (!product || product.stock < quantity) fail(409, 'Product unavailable');
        return { product_id: product.id, name: product.name, price_uzs: product.price_uzs, quantity };
      }).sort((a, b) => a.product_id - b.product_id);
      const subtotal_uzs = items.reduce((sum, i) => sum + i.price_uzs * i.quantity, 0);
      // MVP straight-line zone tariff. This is not a road-route distance or taxi fare.
      const delivery_uzs = road ? road.delivery_uzs : z.base_uzs + Math.ceil(distance_m / 1000) * z.per_km_uzs;
      const go = shop.service_kind !== null;
      if (go && (!road || road.source !== 'TEST' || !this.testIsolation)) fail(503, 'GO requires a verified pricing adapter');
      const commission_uzs = go ? null : Math.floor((subtotal_uzs * shop.commission_bps + 5000) / 10000);
      const snapshot = { shop_name: shop.name, service_kind:shop.service_kind, pickup: { address: shop.address, lat: shop.lat, lon: shop.lon }, destination: { ...location, address }, phone: customer.phone,
        items, subtotal_uzs, delivery_uzs, total_uzs: subtotal_uzs + delivery_uzs, commission_bps: go ? null : shop.commission_bps, commission_uzs, ...(go?{cash_model:'courier_buyout_v1',environment:'TEST',commission_source:'TaxiMaster',commission_status:'not_verified'}:{}), distance_m, pricing_basis: go ? 'TEST' : road ? 'taximaster_road' : 'straight_line_zone', ...(road?{delivery_tariff_id:road.context.pricing.tariff_id,delivery_crew_group_id:road.context.pricing.crew_group_id,pricing_version:road.context.pricing.version}:{}), payment_method: 'cash' };
      const quoteId = id(), expires_at = this.now() + 300_000;
      this.run('INSERT INTO delivery_quotes VALUES(?,?,?,?,?)', quoteId, customer.id, shop.id, JSON.stringify(snapshot), expires_at);
      return { id: quoteId, expires_at, ...this.publicSnapshot(snapshot) };
    });
  }
  pricing() { return this.one('SELECT * FROM delivery_pricing WHERE id=1'); }
  savePricing(user,input) {
    this.admin(user);const enabled=bool(input.enabled);
    const values=enabled?[integer(input.tariff_id,1),integer(input.crew_group_id,1),integer(input.max_distance_m,1,200_000)]:[null,null,null];
    if(!this.run('UPDATE delivery_pricing SET enabled=?,tariff_id=?,crew_group_id=?,max_distance_m=?,version=version+1 WHERE id=1 AND version=?',enabled,...values,integer(input.version,1)).changes)fail(409,'Delivery settings changed; refresh');
    return this.pricing();
  }
  roadQuoteContext(identity,input) {
    const customer=this.customer(identity),shop=this.availableShop(input.shop_id),destination={...point(input.destination),address:text(input.destination.address)},pricing=this.pricing();
    this.assertCashShop(shop);
    if(!pricing.enabled)fail(503,'Configure the delivery tariff in administration first');
    if(!Array.isArray(input.items)||input.items.length<1||input.items.length>50)fail(422,'Cart must have 1–50 items');
    return {customer,shop,destination,pricing};
  }
  publicSnapshot(snapshot) { const { commission_bps, commission_uzs, ...publicData } = snapshot; return publicData; }
  goCheckout() {
    return this.testIsolation ? {enabled:true,environment:'TEST',reason:'Isolated TEST amounts; not real TaxiMaster tariffs'} :
      {enabled:false,environment:'production',reason:'TaxiMaster courier approach and commission accounting are not verified'};
  }
  assertCashShop(shop) {
    if(shop.service_kind!==null && !this.goCheckout().enabled)fail(503,'GO checkout requires verified TaxiMaster approach and commission accounting');
  }
  command(actor, key, payload, fn) {
    if (typeof key !== 'string' || !/^[A-Za-z0-9_-]{16,100}$/.test(key)) fail(422, 'Valid Idempotency-Key required');
    const keyHash = digest(key), fingerprint = digest(JSON.stringify(payload));
    return this.transaction(() => {
      const existing = this.one('SELECT fingerprint,response FROM delivery_commands WHERE actor=? AND key_digest=?', actor, keyHash);
      if (existing) { if (existing.fingerprint !== fingerprint) fail(409, 'Idempotency key reused with different data'); return JSON.parse(existing.response); }
      const response = fn();
      this.run('INSERT INTO delivery_commands VALUES(?,?,?,?)', actor, keyHash, fingerprint, JSON.stringify(response));
      return response;
    });
  }
  checkout(identity, input, key) {
    const customer = this.customer(identity), quoteId = text(input.quote_id, 50);
    return this.command('passenger:' + customer.id, key, { quote_id: quoteId }, () => {
      const quote = this.one('SELECT * FROM delivery_quotes WHERE id=? AND customer_id=?', quoteId, customer.id);
      if (!quote || quote.expires_at <= this.now()) fail(409, 'Quote expired; calculate again');
      if (this.one('SELECT 1 FROM delivery_orders WHERE quote_id=?', quoteId)) fail(409, 'Quote already used');
      const shop = this.availableShop(quote.shop_id), snapshot = JSON.parse(quote.snapshot);
      this.assertCashShop(shop);
      if (shop.service_kind !== (snapshot.service_kind ?? null) || (snapshot.cash_model==='courier_buyout_v1' ? !this.testIsolation || snapshot.environment!=='TEST' || snapshot.pricing_basis!=='TEST' : shop.commission_bps !== snapshot.commission_bps) || shop.address !== snapshot.pickup.address || shop.lat !== snapshot.pickup.lat || shop.lon !== snapshot.pickup.lon) fail(409, 'Store changed; calculate again');
      for (const i of snapshot.items) {
        const result = this.run('UPDATE delivery_products SET stock=stock-?,version=version+1 WHERE id=? AND shop_id=? AND active=1 AND price_uzs=? AND stock>=?', i.quantity, i.product_id, shop.id, i.price_uzs, i.quantity);
        if (!result.changes) fail(409, 'Price or availability changed; calculate again');
      }
      const orderId = id();
      this.run('INSERT INTO delivery_orders(id,customer_id,shop_id,quote_id,snapshot,status,created_at,updated_at) VALUES(?,?,?,?,?,\'pending_shop\',?,?)', orderId, customer.id, shop.id, quoteId, quote.snapshot, this.now(), this.now());
      this.event(orderId, 'passenger:' + customer.id, 'created');
      return this.orderForCustomer(customer, orderId);
    });
  }
  event(orderId, actor, action, reason = '') { this.run('INSERT INTO delivery_events(order_id,actor,action,reason,created_at) VALUES(?,?,?,?,?)', orderId, actor, action, reason, this.now()); }
  orderData(row, financial = false) {
    if (!row) fail(404, 'Order not found');
    const snapshot = JSON.parse(row.snapshot);
    return { id: row.id, quote_id: row.quote_id, shop_id: row.shop_id, status: row.status, version: row.version, created_at: row.created_at, updated_at: row.updated_at,
      ready_at: row.ready_at, transport_order_id: row.transport_order_id, driver_id: row.driver_id, cash:this.cash.summary(row.id), ...(financial ? snapshot : this.publicSnapshot(snapshot)) };
  }
  orderForCustomer(identity, orderId) {
    const customer = this.customer(identity);
    return this.orderData(this.one('SELECT * FROM delivery_orders WHERE id=? AND customer_id=?', text(orderId, 50), customer.id));
  }
  ordersForCustomer(identity) { const c = this.customer(identity); return this.all('SELECT * FROM delivery_orders WHERE customer_id=? ORDER BY created_at DESC LIMIT 100', c.id).map(r => this.orderData(r)); }
  ordersForStaff(user) {
    if (user.role === 'admin') return this.all('SELECT * FROM delivery_orders ORDER BY created_at DESC LIMIT 200').map(r => this.orderData(r, true));
    return this.all('SELECT * FROM delivery_orders WHERE shop_id=? ORDER BY created_at DESC LIMIT 200', this.partner(user)).map(r => this.orderData(r, true));
  }
  transition(order, status, actor, reason = '', action = status) {
    if (!this.run('UPDATE delivery_orders SET status=?,version=version+1,updated_at=? WHERE id=? AND version=?', status, this.now(), order.id, order.version).changes) fail(409, 'Order changed; refresh');
    this.event(order.id, actor, action, reason);
  }
  restoreStock(order) {
    if (order.stock_restored) return;
    for (const i of JSON.parse(order.snapshot).items) this.run('UPDATE delivery_products SET stock=stock+?,version=version+1 WHERE id=? AND shop_id=?', i.quantity, i.product_id, order.shop_id);
    this.run('UPDATE delivery_orders SET stock_restored=1 WHERE id=?', order.id);
  }
  merchantAction(user, orderId, input, key) {
    const shopId = this.partner(user), version = integer(input.version, 1), action = text(input.action, 16);
    if (!['confirm', 'reject', 'ready', 'cash_received'].includes(action)) fail(422, 'Unsupported action');
    const reason = action === 'reject' ? text(input.reason, 300) : '';
    return this.command('partner:' + user.id, key, { orderId, version, action, reason }, () => {
      const order = this.one('SELECT * FROM delivery_orders WHERE id=? AND shop_id=?', text(orderId, 50), shopId);
      if (!order) fail(404, 'Order not found');
      if (order.version !== version) fail(409, 'Order changed; refresh');
      if (action === 'cash_received') {
        this.cash.merchantReceived(order,user);
        return this.orderData(this.one('SELECT * FROM delivery_orders WHERE id=?',orderId),true);
      }
      if (action === 'ready' ? (!['confirmed', 'assigned', 'accepted'].includes(order.status) || order.ready_at !== null) : order.status !== 'pending_shop') fail(409, 'Action not allowed in current state');
      if (action !== 'reject') this.availableShop(shopId);
      if (action === 'reject') this.restoreStock(order);
      if (action === 'ready') this.run('UPDATE delivery_orders SET ready_at=? WHERE id=?', this.now(), orderId);
      const next = action === 'ready' && order.status !== 'confirmed' ? order.status : { confirm: 'confirmed', reject: 'rejected', ready: 'ready' }[action];
      this.transition(order, next, 'partner:' + user.id, reason, action);
      return this.orderData(this.one('SELECT * FROM delivery_orders WHERE id=?', orderId), true);
    });
  }
  cancel(identity, orderId, input, key) {
    const customer = this.customer(identity), version = integer(input.version, 1), reason = text(input.reason, 300);
    return this.command('passenger:' + customer.id, key, { orderId, version, reason, action: 'cancel' }, () => {
      const order = this.one('SELECT * FROM delivery_orders WHERE id=? AND customer_id=?', text(orderId, 50), customer.id);
      if (!order) fail(404, 'Order not found');
      if (order.version !== version || order.status !== 'pending_shop' || order.transport_order_id !== null) fail(409, 'Cancellation requires dispatcher after store confirmation');
      this.restoreStock(order); this.transition(order, 'cancelled', 'passenger:' + customer.id, reason);
      return this.orderForCustomer(customer, orderId);
    });
  }
  bindTransport(orderId, taxiMasterOrderId) {
    // TODO: call only from a reconciled TM outbox worker after real create_order2.
    integer(taxiMasterOrderId, 1, 2147483647);
    return this.transaction(() => {
      const o = this.one('SELECT * FROM delivery_orders WHERE id=?', orderId);
      if (o?.transport_order_id === taxiMasterOrderId) return;
      if (!o || !['confirmed', 'ready'].includes(o.status)) fail(409, 'Order is not ready for transport binding');
      if (o.transport_order_id !== null && o.transport_order_id !== taxiMasterOrderId) fail(409, 'Transport already bound');
      this.run('UPDATE delivery_orders SET transport_order_id=? WHERE id=?', taxiMasterOrderId, orderId);
    });
  }
  recordTransport(orderId, proof) {
    // PRIVATE adapter contract; no HTTP endpoint accepts this object from a client.
    // TODO: connect authenticated TM assignment/lifecycle proof before enabling couriers.
    return this.transaction(() => {
      const o = this.one('SELECT * FROM delivery_orders WHERE id=?', orderId);
      if (!o || !o.transport_order_id || o.transport_order_id !== proof.transport_order_id) fail(409, 'Transport proof does not match bound order');
      const driver = integer(proof.driver_id, 1, 2147483647), crew = integer(proof.crew_id, 1, 2147483647);
      if (o.driver_id !== null && o.driver_id !== driver) fail(409, 'Courier assignment changed; reconcile');
      if (o.crew_id !== null && o.crew_id !== crew) fail(409, 'Courier crew changed; reconcile');
      if (proof.status !== 'cancelled' && this.one("SELECT 1 FROM delivery_orders WHERE id<>? AND (driver_id=? OR crew_id=?) AND status IN ('assigned','accepted','picked_up')", orderId, driver, crew)) fail(409, 'Courier already has an active delivery');
      const allowed = { assigned: ['confirmed', 'ready'], accepted: ['assigned'], picked_up: ['accepted'], completed: ['picked_up'], cancelled: ['confirmed', 'ready', 'assigned', 'accepted'] };
      if (!allowed[proof.status]) fail(422, 'Unknown transport status');
      if (o.status === proof.status) return this.orderData(o, true);
      if (!allowed[proof.status].includes(o.status)) fail(409, 'Transport transition out of sequence');
      const snapshot = JSON.parse(o.snapshot);
      this.cash.assertTransition(o,proof);
      if (proof.status === 'completed' && proof.cash_collected_uzs !== snapshot.total_uzs) fail(409, 'Cash collection not confirmed');
      this.run('UPDATE delivery_orders SET driver_id=?,crew_id=? WHERE id=?', driver, crew, orderId);
      if (proof.status === 'cancelled') this.restoreStock(o);
      this.transition(o, proof.status, 'tm-transport:' + o.transport_order_id);
      if (proof.status === 'completed' && snapshot.cash_model==='courier_buyout_v1') {
        this.cash.finish(o,driver,crew);
      } else if (proof.status === 'completed') {
        const entries = { driver_cash_receivable: snapshot.total_uzs, courier_payable: -snapshot.delivery_uzs, merchant_payable: -(snapshot.subtotal_uzs - snapshot.commission_uzs), service_revenue: -snapshot.commission_uzs };
        for (const [kind, amount] of Object.entries(entries)) this.run('INSERT INTO delivery_ledger VALUES(?,?,?,?,?,?)', orderId, kind, o.shop_id, driver, amount, this.now());
      }
      return this.orderData(this.one('SELECT * FROM delivery_orders WHERE id=?', orderId), true);
    });
  }
  finance(user) {
    const shopId = user.role === 'admin' ? null : this.partner(user);
    return this.all('SELECT kind,count(*) AS entries,sum(amount_uzs) AS amount_uzs FROM delivery_ledger WHERE (? IS NULL OR shop_id=?) GROUP BY kind', shopId, shopId);
  }
}
