# Merchant coupons — schema11 / source only

Extends existing product promotions010, quote/checkout, merchant portal and the
same Flutter cart/history. No replacement catalog, new wallet, TM tariff or
commission engine. Production database/backend remain untouched; real GO gate
remains closed pending real approach and order-linked commission evidence.

## Implemented own API

- Merchant `GET/POST /api/delivery/merchant/coupons`, `PUT .../coupons/:id`.
- Admin `GET/POST /api/delivery/admin/shops/:shopId/coupons`, `PUT .../coupons/:id`.
- Existing authenticated `POST /api/delivery/customer/quotes` accepts optional
  `coupon_code`. No public list of coupons and no unauthenticated redemption.

Create/update fields: code (3–32 ASCII letters/digits/_/-; trimmed/uppercased),
kind (`percent` or `fixed`), amount, starts_at/ends_at (epoch milliseconds),
min_goods_uzs, max_uses, per_customer, active boolean. Updates require current
version. Same shop cannot reuse a code for a second row. IDs are server owned;
merchant ownership is taken from the authenticated session. No delete operation.
Merchant/admin can deactivate or revise a coupon using existing tenancy/CAS.

Percent1–100; fixed1–10000000 UZS **per order**, capped at eligible goods amount.
Active interval [starts_at,ends_at). Percentage discount rounds down to whole
UZS as in existing product promotions. Limits are positive explicit integers;
minimum eligible goods amount may be0. Portal labels explain funding and scope.

## Money and usage policy

Merchant-funded: courier buys goods at the reduced subtotal and receives that
same reimbursement from client cash. Delivery stays the authoritative TM/TEST
transport result; coupons never reduce it or alter TM commission configuration.
Product-promoted lines are excluded from coupon eligibility. Non-promoted lines
can receive a coupon in the same basket. Minimum applies to eligible goods.
No eligible discount / expired / inactive / wrong-shop / exhausted coupon fails
with409; no silent fallback to the undiscounted order.

Quote freezes coupon ID/version/code/terms/funding/eligible amount/discount and
goods_before_coupon_uzs. Existing items retain per-unit product prices, including
any separate product promotion; the order subtotal subtracts coupon once.
Merchant and passenger order views explicitly show the order coupon. Driver+
already consumes the frozen reduced subtotal for buyout and total for cash;
there is no client-side final-price calculation.

Quote does not reserve a coupon use. Checkout checks current terms/limits in
the same BEGIN IMMEDIATE transaction as stock reservation and order creation.
Stale/expired/exhausted coupon rolls back the whole transaction. A unique
order-linked immutable redemption records customer/discount/time; retries reuse
the existing command response. Global and per-customer limits count accepted
checkouts, **including subsequently cancelled/rejected orders**. Usage is not
silently reset on cancellation; stock restoration remains the existing flow.
Merchant portal explicitly states this policy. There are no bank payments or
extra coupon reimbursement liabilities in the new cash journal.

Accepted order snapshots and redemptions survive later coupon changes/restarts.
Legacy quotes without coupons continue to work. Flutter requires a matching
server coupon confirmation before exposing checkout; old servers cannot ignore
a submitted code. Editing/removing code invalidates the displayed quote. Pending
checkout keeps its persisted quote/key and cannot change the coupon.

## Migration and checks

Additive011 creates delivery_coupons and delivery_coupon_redemptions + immutable
redemption triggers/index. Nothing rebuilds007/008/009/010. Source requires11;
older service versions must not open11. Production remains5 and unmodified.
Dry4/5/6/7/8/9/10→11 preserves historical money, v9 options and v10 terms.

98 backend tests;23 Flutter tests. Seven coupon cases include authoritative
fixed/percent bounds, no stacking, actual coupon expiry inside quote lifetime,
stock rollback, merchant HTTP isolation/CAS, cancellation/restart durability,
independent-worker race for last use and full isolated cash completion. TEST
route/fee6000 is a fixture, never a claimed live TM tariff. Widget cases cover
quote invalidation, old-backend rejection and history. Analyzer:0 errors, same14
existing main.dart diagnostics. Native MapKit/GPS/GO acceptance is separate.

Still outstanding:1+1/gifts, dynamic ETA, pickup, reviews/complaints,
notifications, parcel handover and remaining history/visual/native checks.
