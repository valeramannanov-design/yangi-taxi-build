# GO cash checkout — 2026-10-17

## Former blocker

Shell in `flutter/lib/main.dart` always passed `checkoutEnabled:false`. Independently, `store.mjs:assertLegacyCashShop` rejected every mapped GO shop from roadQuoteContext, quote and checkout. This was a blanket financial-model gate, not a missing bank gateway.

## Implemented source (not deployed)

Migration008 adds an immutable cash journal without changing historical orders/ledger. The new `courier_buyout_v1` flow reuses existing TM assignment, acceptance and arrival:

1. Courier confirms paying the exact frozen goods subtotal with personal cash.
2. Authenticated shop partner acknowledges receipt; both proofs and readiness are required before goods pickup.
3. Courier confirms arrival at recipient and receipt of exact goods+delivery cash.
4. Existing TM finished proof, exact delivery cash and zero noncash authorize completion.

One record per order/event, exact driver/crew/amount/actor checks, transactions, existing merchant/checkout idempotency keys and the native pending-command journal prevent duplicate financial records. Repeated completed evidence is safe. First buyout claim blocks automatic cancellation/reassignment; external TM abortion enters durable dispatcher review without restoring stock or erasing money evidence. Compensation/dispute resolution is not guessed.

At merchant acknowledgement, balanced cash entries record merchant_cash_received +goods and courier_cash_advanced -goods. At verified completion: courier_cash_received +total, goods_reimbursement -goods, delivery_cash_earned -delivery. These are accounting evidence, not a wallet or TM balance debit. No merchant payable, local GO commission or bank transfer. Existing TM adapter sends **only delivery_uzs** as total_cost; goods never enter its fare/commission base. Commission remains explicitly unverified.

Merchant portal has received-money acknowledgement, timeline and finance labels. Passenger checkout follows the server capability, shows TEST amounts explicitly and displays cash history. Driver+ adds shop-payment/recipient-arrival controls and pickup protection using existing durable commands. No new APK/device acceptance or live deployment in this stage.

## Implemented own contracts, not TaxiMaster methods

- Catalog `go_checkout:{enabled,environment,reason}`; no passenger-controlled enable switch.
- Frozen quote has cash_model, environment and pricing_basis. TEST is never labelled taximaster_road.
- Existing merchant order action accepts `cash_received`, with shop ownership/version/Idempotency-Key. Admin/passenger cannot impersonate the merchant.
- Private loopback `/internal/delivery/shop-payment` accepts exact amount_uzs; `/client-arrival` accepts no amount. Driver/crew identity comes from authenticated fleet gateway. Existing info/pickup/cash remain. Public/passenger tokens are rejected.
- Order metadata includes cash evidence, at_store from real TM car_at_place and explicit courier recipient-arrival evidence. No GPS arrival is fabricated.

## Isolated TEST environment

`backend/delivery/testing/host.mjs` never imports the production host, credentials, SMS, ATMOS, TM connection or real DB. It binds **127.0.0.1 on an ephemeral port**, creates a new temporary `yangi-go-test-<uuid>.sqlite`, independent random access credentials and clearly labelled TEST catalog. Fixture delivery6000/goods25000 are NOT real TM tariffs. Fixture state control exists only in that host and requires its TEST admin token.

From repository root in PowerShell:

```powershell
$env:NODE_ENV='test'
$env:GO_ISOLATED_TEST='1'
& 'C:/Program Files/nodejs/node.exe' backend/delivery/testing/host.mjs
```

The host prints only its URL and local private access-file path in the temporary directory. Stop with Ctrl+C; do not share/commit access credentials. Clear the test environment before running normal services. Production server refuses GO_ISOLATED_TEST immediately after environment loading, before service initialization. TEST permits cannot target the production DB; TEST adapters cannot mix with real pricing/production store.

`node --test backend/delivery/go-cash-http.test.mjs` exercises the complete HTTP flow through the existing customer/merchant/admin/private APIs. It neither orders food nor changes TaxiMaster. Direct domain tests cover restart, retries, wrong amounts, foreign identities, cancellation after buyout and unpaid pickup.

## Actual TaxiMaster evidence and remaining contracts

Existing real methods reused: tariff/group/fleet catalogs, analyze_route2, calc_order_cost2, create_order2, get_order_state, native driver lifecycle and zero-penalty cancellation. Previously verified tariff27 quote: road2160m/delivery9800. No new live order was created here.

Fresh read-only check: get_order_state(11708) returned finished/total_sum6000/cash_sum6000. get_driver_operations(driver5) succeeded over the current two-day period and ±1h around its actual finish_time20261017153315, returning operations:[] both times. Adapter now exposes a validated read wrapper. Empty operations are NOT proof of zero commission or a confirmed debit.

The [official TM API reference](https://help.taximaster.ru/index.php/TM_API) documents source_distance_country as approach distance outside the city. This alone does not establish all courier-to-shop urban approach pricing/inclusion. No alternative tariff engine is added.

TODO(GO-TM-approach): prove installed3.16 method/parameters for courier-to-shop city/country approach, pre-assignment estimate, assigned-courier reconciliation and fare inclusion. Preserve customer consent for any changed price; no implicit free approach.

TODO(GO-TM-commission): prove actual order-linked assessed/debited commission evidence: order/account/operation identifiers, amount, type, reversal/duplicate semantics and required existing CommonAPI rights. Do not derive it from shop commission, labels or guessed percentages. Do not debit again with create_driver_operation.

After these contracts are implemented/tested, connect the real capability and deploy migration/backend/private bridge/Driver+ together, with device acceptance and post-buyout dispatcher dispute validation. There is deliberately no operator boolean bypassing unverified finance. Cash requires no new bank gateway.

## Verification / source ownership

70 backend tests,13 Flutter widget tests,43 targeted Driver Python tests (8 Delivery+19 mobile+16 fleet),6 Driver JS tests and offline Java debug compilation. Existing SDK/deprecation warnings remain. New native phone controls and production approach/commission acceptance are unverified.

Driver repository contains extensive pre-existing dirty/untracked files. Commit only owned tracked Delivery modules/tests and `tools/deploy/go-cash-driver-integration.patch`. That patch records the exact added edits to mobile gateway, index.html and untracked TmTripControlClient.java against the existing Driver+50 workspace; do not stage the dirty tree wholesale or apply against an unrelated baseline.
