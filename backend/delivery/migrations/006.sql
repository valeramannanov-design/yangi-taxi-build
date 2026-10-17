-- Explicit GO classification; never infer a legacy store's service from its name.
ALTER TABLE delivery_shops ADD COLUMN service_kind TEXT CHECK(service_kind IN ('food','market'));
CREATE INDEX delivery_shops_service ON delivery_shops(service_kind,active,category_id);
