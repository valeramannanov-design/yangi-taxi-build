CREATE TABLE delivery_product_recommendations(
 product_id INTEGER NOT NULL REFERENCES delivery_products(id) ON DELETE CASCADE,
 recommended_id INTEGER NOT NULL REFERENCES delivery_products(id) ON DELETE CASCADE,
 position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 9),
 PRIMARY KEY(product_id,recommended_id), UNIQUE(product_id,position),
 CHECK(product_id<>recommended_id));
