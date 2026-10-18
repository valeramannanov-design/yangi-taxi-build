-- Extend the existing owned inbox, preserving IDs and read acknowledgements.
ALTER TABLE delivery_notifications RENAME TO delivery_notifications_v12;
CREATE TABLE delivery_notifications(
 id INTEGER PRIMARY KEY, customer_id TEXT NOT NULL,
 order_id TEXT NOT NULL REFERENCES delivery_orders(id),
 kind TEXT NOT NULL CHECK(kind IN ('order_created','order_confirmed','order_ready','pickup_ready','pickup_time_changed','courier_assigned','courier_accepted','goods_picked_up','order_completed','order_cancelled','order_rejected','complaint_updated')),
 event_key TEXT NOT NULL UNIQUE, reference_id INTEGER,
 created_at INTEGER NOT NULL, read_at INTEGER);
INSERT INTO delivery_notifications(id,customer_id,order_id,kind,event_key,created_at,read_at)
 SELECT id,customer_id,order_id,kind,'pickup-ready:'||order_id,created_at,read_at FROM delivery_notifications_v12;
DROP TABLE delivery_notifications_v12;
CREATE INDEX delivery_notifications_customer ON delivery_notifications(customer_id,id);
CREATE TRIGGER delivery_notifications_content BEFORE UPDATE ON delivery_notifications
 WHEN NEW.customer_id IS NOT OLD.customer_id OR NEW.order_id IS NOT OLD.order_id OR NEW.kind IS NOT OLD.kind OR NEW.event_key IS NOT OLD.event_key OR NEW.reference_id IS NOT OLD.reference_id OR NEW.created_at IS NOT OLD.created_at OR (OLD.read_at IS NOT NULL AND NEW.read_at IS NOT OLD.read_at)
 BEGIN SELECT RAISE(ABORT,'Notification content is immutable'); END;
CREATE TABLE delivery_push_devices(
 id TEXT PRIMARY KEY, customer_id TEXT NOT NULL, fid TEXT NOT NULL UNIQUE,
 lang TEXT NOT NULL CHECK(lang IN ('ru','uz')), enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
 generation INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE INDEX delivery_push_devices_customer ON delivery_push_devices(customer_id);
CREATE TABLE delivery_push_outbox(
 id INTEGER PRIMARY KEY, notification_id INTEGER NOT NULL REFERENCES delivery_notifications(id),
 device_id TEXT NOT NULL REFERENCES delivery_push_devices(id), generation INTEGER NOT NULL,
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','sending','sent','retry','discarded','failed')),
 attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NOT NULL,
 lease_until INTEGER, claim TEXT, last_error TEXT, provider_message_id TEXT,
 created_at INTEGER NOT NULL, UNIQUE(notification_id,device_id,generation));
CREATE INDEX delivery_push_outbox_due ON delivery_push_outbox(status,next_attempt_at);
