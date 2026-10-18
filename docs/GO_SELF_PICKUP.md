# Self-pickup — source / schema12 / 2026-10-18

Reuses existing catalog/options/promotions/coupons, stock reservations, quote
ownership, idempotent checkout and merchant order actions. No second app/cart,
customer map requirement, courier assignment, road quote or bank payment.
Production remains schema5; real GO checkout gate is unchanged and CLOSED.

## Implemented contracts (our backend, not TaxiMaster fields)

- Admin existing shop create/update: optional boolean pickup_enabled, default
  false. Catalog/shop DTO returns boolean capability. Only explicitly mapped
  food/market shops with this capability can accept pickup.
- Existing customer quote accepts fulfillment=pickup (default delivery remains
  compatible). It does not require/send customer destination or call a routing
  provider. Quote freezes store pickup address, actual goods/options/promotion/
  coupon prices, fulfillment, cash_model=store_pickup_cash_v1,
  pricing_basis=self_pickup, destination=null, delivery_uzs=0, distance_m=null.
  Zero transport means no transport service, not a test TM fare. No tariff ID or
  guessed pickup commission is inserted. In isolation environment is TEST.
- Existing checkout validates quote owner, expiry, shop capability/address,
  catalog/stock/coupon versions/limits within the existing transaction. Global
  production guard still runs; the mode cannot bypass it. Idempotency survives
  restart and wrong requests cannot consume losing stock.
- Existing merchant action accepts the following explicit pickup controls, with
  current order version and existing Idempotency-Key:

| Action | Preconditions / result |
| --- | --- |
| confirm + ready_in_minutes1–1440 | pending_shop → confirmed; server ready_expected_at from merchant input |
| set_ready_time + ready_in_minutes | confirmed; revises actual merchant preparation estimate |
| ready | confirmed → ready; actual ready_at and one durable owned readiness notice |
| pickup_cash_received + exact amount_uzs | ready; immutable actual merchant cash receipt, status still ready |
| pickup_handed_over | ready plus cash receipt → completed; immutable goods handover |
| reject + reason | pending_shop; stock restored once |
| pickup_cancel + reason | confirmed/ready with no cash journal; stock restored once |

Payment is actual cash directly to the merchant. Exact reduced goods total is
required; zero total after a genuine promotion/coupon still has explicit
acknowledgement. Receipt and handover are separate; a customer cannot submit
either as a forged passenger action. Merchant ownership/version and transaction
checks remain. Portal asks explicit confirmation of actual cash/handover and
blocks repeated commands; prepared time comes from merchant, never a default15.

Paid pickup cannot be cancelled/refunded/re-stocked through generic courier or
customer cancellation. TODO in store-pickup.mjs: actual merchant cash-refund
acknowledgement, immutable reversal, authority/idempotency and goods-return
reconciliation contract. Until implemented this operation is unavailable. No
receipt is erased and no fake bank/TM transfer is generated.

All courier dispatch/bind/transport-proof/management paths reject pickup orders
before creating jobs/reserving a crew. Pickup has no driver/crew/transport ID.
Journal is separate from courier_cash and driver liabilities. Existing finance
view adds merchant_pickup_cash_received from actual receipt records; it is direct
store revenue, not a service debt or invented commission. No driver0 placeholder
or second commission engine.

## Readiness / client behavior

Existing authenticated customer API extended with GET /customer/notifications
and POST /customer/notifications/:id/read, under /api/delivery. Server filters by
authenticated customer and idempotently acknowledges only their notice.
Unique(customer,order,kind) prevents duplicate readiness entries. Journal survives
restart. Notification returns current order status, so cancellation/completion
does not look like current readiness.

GoHome foreground polls this API every30s and shows up to3 unread current-ready
cards. Tap marks read and opens existing owned purchase details. Failed/older
backend reads clear stale cards; no invented readiness. **This is in-app
notification only. OS background push/FCM is not implemented or claimed.**

Cart shows pickup only when the shop capability is true. Selecting it hides
customer map/address controls, shows frozen store address and cash-in-store.
Server must confirm the exact pickup contract before exposing checkout; old
servers cannot silently treat it as a delivery. Switching modes invalidates the
quote and restores delivery address rules. Persistent checkout keeps the server
quote/key; history/details show actual pickup mode, expected/actual readiness
and merchant payment state. No courier ETA appears for this mode.

## Migration / acceptance

Additive012: pickup_enabled,ready_expected_at,immutable
delivery_store_pickup_journal,owned delivery_notifications+read_at. No existing
order status rebuild or changes to008/009/010/011. Source now requires12; older
code must not open12. Dry schema4–11→12 preserves historical finance/options/
promotions/coupons. No production migration or backend restart performed.

Checks:107 backend tests (6 pickup + extra migration baseline),40 Flutter tests
(7 pickup/notice),0 analyzer errors/same14 existing main.dart diagnostics.
Pickup full cash cycle, empty routing provider, no map, capability TOCTOU,
production rejection of an isolated quote, exact/free cash, immutable/restart
journal, variant restock, notification tenancy/idempotency and no courier paths
are covered. Existing courier/ETA/address/coupon tests remain green. Portal JS
parses; actual portal/native pickup UI and real cash handover remain unaccepted.

Launch still requires approved compatible staging, backup/rollback and explicit
pickup payment/commission policy; no configuration proof replaces actual TM
commission proof for courier delivery. Never resume acceptance5 or enable TEST
prices as real to bypass those requirements.
