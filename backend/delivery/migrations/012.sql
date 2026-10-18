-- Additive self-pickup configuration, direct merchant cash and in-app readiness.
ALTER TABLE delivery_shops ADD COLUMN pickup_enabled INTEGER NOT NULL DEFAULT 0 CHECK(pickup_enabled IN (0,1));
ALTER TABLE delivery_orders ADD COLUMN ready_expected_at INTEGER;
CREATE TABLE delivery_store_pickup_journal(
 order_id TEXT NOT NULL REFERENCES delivery_orders(id),
 kind TEXT NOT NULL CHECK(kind IN ('cash_received','handed_over')),
 amount_uzs INTEGER NOT NULL CHECK(amount_uzs>=0), actor TEXT NOT NULL,
 created_at INTEGER NOT NULL, PRIMARY KEY(order_id,kind));
CREATE TRIGGER delivery_store_pickup_no_update BEFORE UPDATE ON delivery_store_pickup_journal BEGIN SELECT RAISE(ABORT,'Pickup journal is immutable'); END;
CREATE TRIGGER delivery_store_pickup_no_delete BEFORE DELETE ON delivery_store_pickup_journal BEGIN SELECT RAISE(ABORT,'Pickup journal is immutable'); END;
CREATE TABLE delivery_notifications(
 id INTEGER PRIMARY KEY, customer_id TEXT NOT NULL,
 order_id TEXT NOT NULL REFERENCES delivery_orders(id), kind TEXT NOT NULL CHECK(kind='pickup_ready'),
 created_at INTEGER NOT NULL, read_at INTEGER, UNIQUE(customer_id,order_id,kind));
CREATE INDEX delivery_notifications_customer ON delivery_notifications(customer_id,id);
