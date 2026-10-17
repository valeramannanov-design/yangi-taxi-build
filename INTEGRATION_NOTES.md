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
