-- Retain old zone associations/history, but new shops need no geographic zone.
CREATE TABLE delivery_shops_new(
 id INTEGER PRIMARY KEY, partner_id INTEGER NOT NULL UNIQUE REFERENCES delivery_users(id),
 category_id INTEGER NOT NULL REFERENCES delivery_categories(id), zone_id INTEGER REFERENCES delivery_zones(id),
 name TEXT NOT NULL, address TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
 commission_bps INTEGER NOT NULL CHECK(commission_bps BETWEEN 0 AND 10000), active INTEGER NOT NULL DEFAULT 0);
INSERT INTO delivery_shops_new SELECT * FROM delivery_shops;
DROP TABLE delivery_shops;
ALTER TABLE delivery_shops_new RENAME TO delivery_shops;
CREATE TABLE delivery_pricing(
 id INTEGER PRIMARY KEY CHECK(id=1), enabled INTEGER NOT NULL DEFAULT 0,
 tariff_id INTEGER, crew_group_id INTEGER, max_distance_m INTEGER,
 version INTEGER NOT NULL DEFAULT 1);
INSERT INTO delivery_pricing(id) VALUES(1);
