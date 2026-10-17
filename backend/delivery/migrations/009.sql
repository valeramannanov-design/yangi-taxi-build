-- Additive catalog metadata; schema7 recommendations and cash journal untouched.
ALTER TABLE delivery_products ADD COLUMN ingredients TEXT NOT NULL DEFAULT '';
ALTER TABLE delivery_products ADD COLUMN weight_g INTEGER CHECK(weight_g>0);
ALTER TABLE delivery_products ADD COLUMN volume_ml INTEGER CHECK(volume_ml>0);
ALTER TABLE delivery_products ADD COLUMN variants_json TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(variants_json) AND json_type(variants_json)='array');
ALTER TABLE delivery_products ADD COLUMN catalog_version INTEGER NOT NULL DEFAULT 1;
