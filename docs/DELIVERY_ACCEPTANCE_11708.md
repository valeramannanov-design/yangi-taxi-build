# Stationary Delivery acceptance — TM11708, 2026-10-17

The authenticated Driver+50 app completed the real TaxiMaster transport lifecycle on test driver5 / crew4. Store/customer operations used the real Delivery HTTP API in a separate loopback sandbox with its own database, credentials and session secret. This was a technical stationary fixture, not a physical goods handover, road/GPS-distance trial or real cash collection.

## Evidence

- Exact APK50 installed with preserved data; package version50 independently verified. Native presentation instrumentation passed **48 assertions**, including real pointer gestures through visible/hidden notification overlays, short-screen action bounds and expanded goods. Screenshots at `C:\Yangi Taxi DEV\.local\delivery50-ui` were pulled; the dark offer screenshot was visually inspected.
- Private sandbox: `C:\Yangi-Taxi-client\delivery-private\acceptance4`; synthetic TM client1640 reused, Delivery order `4a9aa8d1b784e72b960990965765e8d24aba`, TM transport11708. No synthetic catalog/orders were inserted into production.
- Store readiness confirmed through merchant API. Real incoming order accepted by a phone swipe; TM state7 / `driver_assigned`, `confirmed_by_oper`. That flag alone was not used as proof of driver acceptance by the transport worker.
- Phone arrival swipe produced TM state10 / `car_at_place`.
- Phone goods-pickup swipe first persisted exactly one authenticated pickup authorization, then produced TM state11 / `client_inside`. Delivery worker restored status `picked_up`.
- Phone completion hold opened the real confirmation dialog for **12000 UZS**. After confirmation, TM returned state4 / `finished`, frozen transport sum6000/cash6000, cashless0/bonus0/bank-card0. The app displayed that payment and completion were confirmed by TM.
- Delivery worker independently required the full authenticated receipt and exact finished TM cash proof before completing the order. One receipt12000, one pickup proof, four ledger rows; no public customer/admin completion API was used.

| Entry | UZS |
|---|---:|
| Driver cash receivable | +12000 |
| Courier payable | -6000 |
| Merchant payable | -5250 |
| Service revenue | -750 |
| Sum | 0 |

The fixture's configured merchant commission was1250 basis points of goods6000. Goods6000 and transport6000 remained separate; goods were not added to the TM transport fare.

## Recovery / cleanup

The sandbox backend was restarted, followed by force-stop/reopen/login of Driver+. Authenticated customer history still returned `completed`; the gateway reported the previous trip completed and no active order. Receipt count remained1 and ledger count4/sum0 after restart. No financial command was replayed to test idempotency.

Private evidence includes `acceptance-result.json`, `fixture.private.json` and TM read proofs after acceptance/arrival/pickup/completion. These contain audit state, not reusable mutation instructions. TM11708 remains correctly **finished**: do not cancel, reopen, reuse or recreate it.

Production bridge was restored to8788, gateway restarted with its original config, and sandbox stopped. Production catalog/orders/Delivery ledger remain empty. Restricted rollout driver5/crew4 remains enabled; ordinary taxi access rules were retained.

## Remaining acceptance

This completes the stationary backend/merchant HTTP → authenticated Driver+ → real TM finish → balanced-ledger test. It does **not** certify the whole production MVP. Still required: passenger Android checkout/address picker against the intended backend, real merchant/product/zone configuration, portal visual/form checks (browser control remains disabled), an actual road/GPS trial if distance-based behavior is used, and mobile-network reachability. Do not open Delivery to the fleet solely on this technical fixture result.
