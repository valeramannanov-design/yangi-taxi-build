CREATE TABLE delivery_pickup_authorizations(
 order_id TEXT PRIMARY KEY REFERENCES delivery_orders(id),
 transport_order_id INTEGER NOT NULL, driver_id INTEGER NOT NULL, crew_id INTEGER NOT NULL,
 created_at INTEGER NOT NULL);
CREATE TABLE delivery_management(
 id TEXT PRIMARY KEY, order_id TEXT NOT NULL REFERENCES delivery_orders(id),
 action TEXT NOT NULL CHECK(action IN ('cancel','reassign')),
 phase TEXT NOT NULL CHECK(phase IN ('queued','sending','uncertain','applied','blocked','review')),
 payload TEXT NOT NULL, request_json TEXT, last_error TEXT NOT NULL DEFAULT '',
 created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE UNIQUE INDEX delivery_management_active ON delivery_management(order_id)
 WHERE phase IN ('queued','sending','uncertain','review');
CREATE TABLE delivery_transport_history(
 transport_order_id INTEGER PRIMARY KEY, order_id TEXT NOT NULL REFERENCES delivery_orders(id),
 job_json TEXT NOT NULL, action_id TEXT NOT NULL REFERENCES delivery_management(id),
 created_at INTEGER NOT NULL);
