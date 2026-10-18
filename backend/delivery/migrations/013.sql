-- GO feedback is separate from TaxiMaster taxi ratings and all financial records.
CREATE TABLE delivery_reviews(
 id INTEGER PRIMARY KEY,
 order_id TEXT NOT NULL REFERENCES delivery_orders(id),
 customer_id TEXT NOT NULL,
 target TEXT NOT NULL CHECK(target IN ('shop','courier')),
 target_id INTEGER NOT NULL CHECK(target_id>0),
 rating INTEGER NOT NULL CHECK(rating BETWEEN 1 AND 5),
 comment TEXT NOT NULL CHECK(length(comment)<=1000),
 created_at INTEGER NOT NULL,
 UNIQUE(order_id,target));
CREATE INDEX delivery_reviews_target ON delivery_reviews(target,target_id);
CREATE TRIGGER delivery_reviews_no_update BEFORE UPDATE ON delivery_reviews BEGIN SELECT RAISE(ABORT,'Review is immutable'); END;
CREATE TRIGGER delivery_reviews_no_delete BEFORE DELETE ON delivery_reviews BEGIN SELECT RAISE(ABORT,'Review is immutable'); END;
CREATE TABLE delivery_complaints(
 id INTEGER PRIMARY KEY,
 review_id INTEGER NOT NULL UNIQUE REFERENCES delivery_reviews(id),
 status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','in_review','resolved')),
 version INTEGER NOT NULL DEFAULT 1,
 created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE delivery_complaint_events(
 id INTEGER PRIMARY KEY,
 complaint_id INTEGER NOT NULL REFERENCES delivery_complaints(id),
 actor TEXT NOT NULL, status TEXT NOT NULL,
 note TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TRIGGER delivery_complaint_events_no_update BEFORE UPDATE ON delivery_complaint_events BEGIN SELECT RAISE(ABORT,'Complaint history is immutable'); END;
CREATE TRIGGER delivery_complaint_events_no_delete BEFORE DELETE ON delivery_complaint_events BEGIN SELECT RAISE(ABORT,'Complaint history is immutable'); END;
