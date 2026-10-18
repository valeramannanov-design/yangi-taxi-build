# Confirmed integration contracts — GO / 2026-10-17

## Reuse existing TM adapter

- Tariff/group catalog: existing `get_tariffs_list`, `get_crew_groups_list`; driver availability via `get_crews_info`, `get_crew_info`, `get_driver_info`, `get_current_orders`.
- Coordinates/road route: existing host `analyzeLiveRoute` → `analyze_route2`, exact selected source/destination points; `calculateLiveCost` → `calc_order_cost2` using tariff/group/time/client, route city/country distances. No zone drawing required for current road pricing. New GO must not restore mandatory zones or calculate its own tariffs.
- Existing `create_order2`, `get_order_state`, current-order reconciliation, verified finish/cash proof. Idempotent outbox blocks repeated unknown writes. Cancellation uses real `check_cancel_order_penalty`/`change_order_state` and confirmed zero fees. Driver bridge remains private; public passenger/admin cannot forge cash completion.
- Shared client auth/profile/history/payment/address APIs are implemented already in the host and Flutter. ATMOS taxi payment support is not a ready shopping payment flow. GO first cash flow must not automatically charge a taxi-linked card.

## Original financial audit — cash evidence now implemented below

1. **Courier approach to store:** current road quote is store→recipient. Existing calc_order_cost2 payload has no verified assigned-courier approach calculation. Need documented TM3.16 contract for pre-assignment approach, assigned-courier repricing and whether approach is already included. Preserve client price consent; no free approach default or extra locally calculated charge.
2. **Aggregator commission:** no verified TM commission-result/balance-movement contract found in the current adapter. Need actual documented method/response identifiers for the applicable order/tariff and confirmed debit; do not invent commission fields or APIs. Existing shop commission_bps is an explicit previous partner setting, not TM courier commission. Do not reinterpret it or charge again.
3. **Cash paid to shop:** need durable own-backend journal with driver and merchant confirmations, exact amount/order/actor/idempotency, conflict handling and recovery. This is an extension to our own API, not a claimed TM endpoint. Current receipt records only cash collected from customer and is insufficient.
4. **After buyout:** cancellation/reassignment must preserve the courier's outlay and create an admin dispute; current pickup-only boundary must be extended to the earlier paid-to-shop event. Never infer compensation or erase history.

Previous +cash/-courier/-merchant/-service ledger is historical proof for the previous model; it cannot be accepted as proof of the new cash flow. GO checkout/financial completion must remain unavailable until the above are integrated and tested. No production ledger migration/rewrite, tariff change or fee-bearing cancellation authorized by this new document alone.

## Catalog classification

GO food/market are own-backend service classifications, not TM tariff names or inferred category translations. Legacy stores/orders require explicit mapping; do not guess “food” from a name or present purchases as parcels. Any new contract is documented with its implementation and compatibility tests before client integration.

Implemented source contract: `GET /api/delivery/catalog?service=food|market`, scoped shop/product detail reads, shop `service_kind`, frozen snapshot classification (schema6), ordered `recommendation_ids` on own merchant/admin product writes and public available `recommendations` (schema7). These are our actual implemented backend contracts, not TM fields. GO quote/checkout is closed on mapped shops until the financial contract is ready. Production remains schema5; do not deploy the UI alone against an older filter-ignoring server.

Public reference inspected: [official TM API documentation](https://help.taximaster.ru/index.php/TM_API), including catalog, calculation and driver-operation sections. It is a reference, not proof of every feature in installed3.16.115. Existing driver read allowlist includes `get_driver_operations`; exact per-order commission attribution and approach inclusion are still unverified. Their absence from our adapter is not a claim that TaxiMaster can never support them.

## Cash implementation update2026-10-17

Dual shop cash evidence, buyout cancellation guard, reimbursement journal and capability-driven isolated TEST checkout now work. Original items3/4 are no longer missing cash core. See `docs/GO_CASH_CHECKOUT.md` for implemented own contracts. Cash requires no new bank gateway. Production remains gated specifically on unverified courier approach and per-order TM commission/debit. Fresh get_driver_operations reads succeeded but returned no operations for driver5; no commission is inferred. No live deployment/order/financial mutations in this stage.


## Installed TM contract delta / address stage2026-10-17

Read-only installed API check: tariff27 is present among14 tariffs, row keys=id/is_active/name; group3 among6 groups, keys=id/name. These catalog responses expose no monetary approach/commission rules. Diagnostic GET calc_order_cost(tariff27,distance_city2,distance_country0,is_country=false) returned sum9200 both with source_distance_country0 and2. These synthetic calculation inputs are not a customer quote; unchanged output does NOT establish free approach, out-of-city behavior, assigned-courier repricing or commission. No request with guessed city-approach/commission fields was added. Actual rule/debit/reversal/order-link evidence remains required; no live test orders or account operations were created.

Shared profile address extension is our API: entrance<=32,floor<=16,apartment<=32,landmark<=300; optional strings, controls/type/length validated, partial updates preserve omitted fields and explicit null/empty clears. Existing profile JSON and frozen delivery snapshot carry them. TM create addresses stay exactly address/lat/lon. Backend deploy must include new backend/address-details.mjs together with server/delivery modules and compatible clients. No production migration/deployment authorized/performed. New native device acceptance remains pending even though ADB is online.


## Product options source contract — 2026-10-17

Own catalog APIs, not TaxiMaster fields: product ingredients/weight_g/volume_ml/has_variants/variants; stable server-issued option id, name, unit price_uzs, stock, active, optional grams/ml. Existing merchant/admin product writes accept variants; each existing ID must belong to that exact product. Up to50 active/100 retained options. Omitted options deactivate rather than erase history. Public lists omit inactive options; displayed starting price uses in-stock options only. Empty measurements mean null. Legacy products continue without options.

Migration009 adds product columns/JSON and catalog_version only; schema7 recommendation rows and journal008 stay intact. Parent stock is the sum of active option stocks. Checkout atomically reserves each selected option under the existing transaction; cancellation restores exactly that option once, including retained inactive options (without republishing them). Converting an existing base SKU is blocked while active base-product reservations exist. Saving catalog metadata changes catalog_version, whereas reservations only advance the existing stock-edit version. No local delivery tariff or commission calculation added.

Cart request uses existing product_id/quantity plus variant_id when required. Server ignores forged option names/prices and freezes real name/price/composition/measurement in existing quote/order JSON. Selecting two options creates two lines for the same product. Existing Driver+ info combines base and option name so the current item renderer can display it. Promotions/coupons are not implemented by this stage; no duplicate discount deduction or mock production feature.

UI rule verification remains blocked by a nontargetable main TaxiMaster window: launched minimized Enterprise handle disappeared on restore (`window id 655432 was not found`). Catalog API queries were not repeated, and no real finance/settings changes made. Need actual readable rules/debit/reversal evidence, not another incomplete API catalog response.

## ETA source contract — 2026-10-18

Existing owned /api/orders/:id/driver-location now includes own tracking metadata:
source, checked_at, location_observed_at, location_age_seconds, available. These
are host response fields, not invented TM wire fields. Real TM reads remain
get_order_state/get_crews_coords. Exact crew match replaces first-coordinate
selection. TM_TIME_ZONE normalizes coords_time; invalid/ambiguous/old/future GPS
cannot produce ETA. Existing delivery DTO exposes existing crew_id for assignment
matching. MapKit4.45 weight.timeWithTraffic.value supplies actual travel seconds;
no new TM tariff/payment API and no speed formula. See docs/GO_DYNAMIC_ETA.md.
Source schema11 unchanged, live backend/schema5 untouched. Include new
backend/driver-tracking.mjs when separately staging compatible reconciled code;
never deploy UI alone expecting freshness from an older response. APK71 lacks
ETA; next build72 needs package/install/native checks, not just widget success.

## Self-pickup source contract — 2026-10-18 / schema12

Our existing quote API now supports explicit fulfillment=pickup, real catalog
prices/coupons, store_pickup_cash_v1 and self_pickup basis; no destination, route,
TM price request or courier. Admin pickup_enabled controls availability. Merchant
owns ready_in_minutes/readiness/exact cash/handover commands; new immutable
pickup journal is direct-store cash, no driver0 ledger or invented commission.
Actual paid refund/reversal remains TODO/unavailable. Existing courier paths
reject pickup orders. Own /customer/notifications+owned read ack supply in-app
readiness only, no OS push. See docs/GO_SELF_PICKUP.md for exact contracts and
launch limits. Production gate unchanged, live schema5/backend untouched.
Source schema12 must be staged with matching modules/clients after code/backup
reconciliation; do not run source over the live DB or resume acceptance5.
