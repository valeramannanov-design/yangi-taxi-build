CREATE TABLE IF NOT EXISTS delivery_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);
CREATE TABLE delivery_users(
 id INTEGER PRIMARY KEY, login TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL,
 role TEXT NOT NULL CHECK(role IN ('admin','partner')), active INTEGER NOT NULL DEFAULT 1);
CREATE TABLE delivery_sessions(
 digest TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES delivery_users(id), expires_at INTEGER NOT NULL);
CREATE TABLE delivery_login_failures(login TEXT NOT NULL, peer TEXT NOT NULL, failed_at INTEGER NOT NULL);
CREATE INDEX delivery_login_failures_time ON delivery_login_failures(login,peer,failed_at);
CREATE TABLE delivery_categories(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, active INTEGER NOT NULL DEFAULT 1);
CREATE TABLE delivery_zones(
 id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, south REAL NOT NULL, north REAL NOT NULL,
 west REAL NOT NULL, east REAL NOT NULL, base_uzs INTEGER NOT NULL CHECK(base_uzs>=0),
 per_km_uzs INTEGER NOT NULL CHECK(per_km_uzs>=0), max_distance_m INTEGER NOT NULL CHECK(max_distance_m>0),
 active INTEGER NOT NULL DEFAULT 1);
CREATE TABLE delivery_shops(
 id INTEGER PRIMARY KEY, partner_id INTEGER NOT NULL UNIQUE REFERENCES delivery_users(id),
 category_id INTEGER NOT NULL REFERENCES delivery_categories(id), zone_id INTEGER NOT NULL REFERENCES delivery_zones(id),
 name TEXT NOT NULL, address TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
 commission_bps INTEGER NOT NULL CHECK(commission_bps BETWEEN 0 AND 10000), active INTEGER NOT NULL DEFAULT 0);
CREATE TABLE delivery_images(
 id TEXT PRIMARY KEY, shop_id INTEGER NOT NULL REFERENCES delivery_shops(id), mime TEXT NOT NULL, data BLOB NOT NULL);
CREATE TABLE delivery_products(
 id INTEGER PRIMARY KEY, shop_id INTEGER NOT NULL REFERENCES delivery_shops(id), sku TEXT NOT NULL,
 name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', price_uzs INTEGER NOT NULL CHECK(price_uzs>=0),
 stock INTEGER NOT NULL CHECK(stock>=0), active INTEGER NOT NULL DEFAULT 1,
 image_id TEXT REFERENCES delivery_images(id), UNIQUE(shop_id,sku));
CREATE TABLE delivery_quotes(
 id TEXT PRIMARY KEY, customer_id TEXT NOT NULL, shop_id INTEGER NOT NULL REFERENCES delivery_shops(id),
 snapshot TEXT NOT NULL, expires_at INTEGER NOT NULL);
CREATE TABLE delivery_orders(
 id TEXT PRIMARY KEY, customer_id TEXT NOT NULL, shop_id INTEGER NOT NULL REFERENCES delivery_shops(id),
 quote_id TEXT NOT NULL UNIQUE REFERENCES delivery_quotes(id), snapshot TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('pending_shop','confirmed','ready','assigned','accepted','picked_up','completed','cancelled','rejected')),
 version INTEGER NOT NULL DEFAULT 1, ready_at INTEGER, transport_order_id INTEGER UNIQUE,
 driver_id INTEGER, crew_id INTEGER, stock_restored INTEGER NOT NULL DEFAULT 0,
 created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE INDEX delivery_orders_customer ON delivery_orders(customer_id,created_at);
CREATE INDEX delivery_orders_shop ON delivery_orders(shop_id,created_at);
CREATE TABLE delivery_commands(
 actor TEXT NOT NULL, key_digest TEXT NOT NULL, fingerprint TEXT NOT NULL, response TEXT NOT NULL,
 PRIMARY KEY(actor,key_digest));
CREATE TABLE delivery_events(
 id INTEGER PRIMARY KEY, order_id TEXT NOT NULL REFERENCES delivery_orders(id),
 actor TEXT NOT NULL, action TEXT NOT NULL, reason TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL);
CREATE TABLE delivery_ledger(
 order_id TEXT NOT NULL REFERENCES delivery_orders(id), kind TEXT NOT NULL,
 shop_id INTEGER NOT NULL REFERENCES delivery_shops(id), driver_id INTEGER NOT NULL,
 amount_uzs INTEGER NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(order_id,kind));
