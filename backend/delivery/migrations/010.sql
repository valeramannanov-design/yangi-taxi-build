-- Merchant-funded product discounts only; no transport tariff changes.
ALTER TABLE delivery_products ADD COLUMN promotion_json TEXT NOT NULL DEFAULT 'null'
  CHECK(json_valid(promotion_json) AND json_type(promotion_json) IN ('object','null'));
