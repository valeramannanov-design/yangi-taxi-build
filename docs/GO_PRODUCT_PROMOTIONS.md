# Product promotions — source implementation / schema10

Reuses existing product CRUD, catalog/options, quote, checkout, courier buyout,
merchant receipt and cash journal. No new payment provider or TaxiMaster API.
Production remains schema5; this source has not been deployed or installed.

## Own backend contract

Merchant/admin product create/update accepts `promotion:null` to remove, or:

```json
{"promotion":{"kind":"percent","amount":20,"starts_at":1792191600000,"ends_at":1792278000000}}
```

`kind` is `percent` (integer1–100) or `fixed` (integer1–10000000 UZS per unit).
Timestamps are UTC epoch milliseconds; interval is [start,end). The merchant
portal uses local datetime inputs and converts to epoch. Existing store ownership,
role checks and product-version CAS apply; omitted promotion preserves it.
Only one product promotion applies to all its variants; no stacking.

These discounts are merchant funded: the courier pays the reduced goods price
and is reimbursed for that same amount. A fixed discount is capped at unit price;
percentage discount uses `floor(unitPrice * amount / 100)` whole UZS. Delivery
from TaxiMaster and its commission basis/rules are not modified by this module.
No platform-funded delivery discount, bank transfer or guessed TM commission.

Public product/variant `price_uzs` is the current effective price. Only when
discounted, the server includes `original_price_uzs`, `discount_uzs`, promotion
terms and `funding:merchant`. Staff retains base prices and configured terms.
No JSON storage field is exposed. Flutter shows a struck original price in
the product grid/details and uses the selected option's effective price.

Quote ignores client prices/promotions, freezes terms/base/discount/effective
unit price and quantity once. Subtotal is the sum of effective prices, not a
second discount deduction. Checkout revalidates active promotion price and
catalog revision inside the existing stock transaction. Changed/expired/newly
active prices require requote before stock writes. Accepted orders retain their
original snapshot even after a promotion changes. Existing idempotency,
cancellation/restoration and cash reimbursement use that immutable subtotal.

## Migration and verification

Additive010 adds product `promotion_json`, default JSONnull. No rewrite of cash008,
recommendations007 or variant009 data. Source now requires schema10; older code
must not open it. Dry schema4/5/6/7/8/9→10 upgrades preserve snapshots, receipts,
balanced ledger, cash journal and v9 option identities/metadata. Production
migration, consistent backup and rollback rules remain in DELIVERY_DEPLOYMENT.md.

Checks cover server-only pricing, exact interval boundaries, integer rounding,
fixed cap, invalid config, expiry/activation/revision checkout rollback, frozen
prices, variant stocks/restoration and complete isolated cash cycles with20%
and100% discounts (including zero goods cost), unchanged TEST transport6000 and
balanced journal. TEST tariffs are not claimed to be TaxiMaster live prices.
Flutter widget covers struck price at320px; native phone/portal visual acceptance
is still pending. Coupons,1+1 and gifts are not implemented in this stage.
