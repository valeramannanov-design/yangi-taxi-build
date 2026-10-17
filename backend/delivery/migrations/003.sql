CREATE TABLE delivery_transport_jobs(
 order_id TEXT PRIMARY KEY REFERENCES delivery_orders(id),
 marker TEXT NOT NULL UNIQUE, crew_id INTEGER NOT NULL, tariff_id INTEGER NOT NULL,
 phase TEXT NOT NULL CHECK(phase IN ('queued','creating','uncertain','bound','blocked','review')),
 request_json TEXT, transport_order_id INTEGER UNIQUE,
 last_error TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE INDEX delivery_transport_jobs_phase ON delivery_transport_jobs(phase,updated_at);
CREATE TABLE delivery_cash_receipts(
 order_id TEXT PRIMARY KEY REFERENCES delivery_orders(id),
 driver_id INTEGER NOT NULL, crew_id INTEGER NOT NULL, amount_uzs INTEGER NOT NULL,
 created_at INTEGER NOT NULL);
