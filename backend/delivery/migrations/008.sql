-- Additive journal. Historical orders/ledger remain unchanged.
CREATE TABLE delivery_cash_journal(
 order_id TEXT NOT NULL REFERENCES delivery_orders(id),
 kind TEXT NOT NULL CHECK(kind IN ('shop_paid','shop_received','client_arrived','client_cash','completed')),
 driver_id INTEGER NOT NULL, crew_id INTEGER NOT NULL,
 amount_uzs INTEGER NOT NULL CHECK(amount_uzs>=0), actor TEXT NOT NULL,
 created_at INTEGER NOT NULL, PRIMARY KEY(order_id,kind));
CREATE TRIGGER delivery_cash_journal_no_update BEFORE UPDATE ON delivery_cash_journal BEGIN SELECT RAISE(ABORT,'Cash journal is immutable'); END;
CREATE TRIGGER delivery_cash_journal_no_delete BEFORE DELETE ON delivery_cash_journal BEGIN SELECT RAISE(ABORT,'Cash journal is immutable'); END;
