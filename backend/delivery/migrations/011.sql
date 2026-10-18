-- Own merchant-funded coupons; no TaxiMaster tariff/commission parameters.
CREATE TABLE delivery_coupons(
 id INTEGER PRIMARY KEY, shop_id INTEGER NOT NULL REFERENCES delivery_shops(id),
 code TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('percent','fixed')),
 amount INTEGER NOT NULL CHECK(amount>0 AND amount<=10000000 AND (kind<>'percent' OR amount<=100)),
 starts_at INTEGER NOT NULL CHECK(starts_at>=0), ends_at INTEGER NOT NULL CHECK(ends_at>starts_at),
 min_goods_uzs INTEGER NOT NULL CHECK(min_goods_uzs>=0),
 max_uses INTEGER NOT NULL CHECK(max_uses>0), per_customer INTEGER NOT NULL CHECK(per_customer>0),
 active INTEGER NOT NULL CHECK(active IN (0,1)), version INTEGER NOT NULL DEFAULT 1,
 UNIQUE(shop_id,code));
CREATE TABLE delivery_coupon_redemptions(
 order_id TEXT PRIMARY KEY REFERENCES delivery_orders(id),
 coupon_id INTEGER NOT NULL REFERENCES delivery_coupons(id), customer_id TEXT NOT NULL,
 discount_uzs INTEGER NOT NULL CHECK(discount_uzs>0), created_at INTEGER NOT NULL);
CREATE INDEX delivery_coupon_usage ON delivery_coupon_redemptions(coupon_id,customer_id);
CREATE TRIGGER delivery_coupon_no_update BEFORE UPDATE ON delivery_coupon_redemptions BEGIN SELECT RAISE(ABORT,'Coupon redemption is immutable'); END;
CREATE TRIGGER delivery_coupon_no_delete BEFORE DELETE ON delivery_coupon_redemptions BEGIN SELECT RAISE(ABORT,'Coupon redemption is immutable'); END;
