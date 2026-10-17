# Yangi Taxi Delivery — progress

## Repositories and branch
- Passenger: `C:\Yangi Taxi DEV\yangi-taxi-client`, cloned from `valeramannanov-design/yangi-taxi-build`; branch `feature/yangi-taxi-delivery`, baseline `4eb8b3c` (1.9.4+70).
- Driver+: `C:\Yangi Taxi DEV\yangi-taxi-building`, branch `feature/yangi-taxi-delivery`; existing dirty files preserved, not included in delivery commits.
- Running passenger backend: `C:\Yangi-Taxi-client\backend`. It has local fixes beyond the repository baseline; do not overwrite or deploy the repository copy over it without reconciliation.
- TaxiMaster 3.16: CommonAPI and authenticated Driver+ gateway already exist. `yangi_platform` / independent Android clients are separate DEV projects, not the live fleet.

## Architecture
- Extend the real passenger Node backend. Delivery is opt-in and has its own SQLite database, migrations and integer-money ledger; no changes to live databases or service processes during development.
- Reuse passenger authentication. Separate hashed partner/admin sessions and store ownership checks. Only admin creates partners.
- One store per order; server-side quote snapshots; transactional stock, idempotency and cancellation. No online payments in this MVP.
- Courier integration must use a real TaxiMaster transport order and existing driver identity. Store/order status cannot independently claim a completed taxi journey. New internal delivery interfaces are not TaxiMaster API methods.

## Completed
- Located actual passenger and Driver+ sources, authenticated GitHub access, preserved working tree and created branches.
- Backend stage: native SQLite migrations; partner/admin authentication and tenant isolation; categories, stores, zones, image upload, Unicode product search, catalog; server quote snapshots, stock reservation, idempotent checkout, cancellation/rejection and merchant confirmation/readiness.
- Internal transport-binding and balanced cash-liability ledger implemented. These methods have no public completion endpoint; live TaxiMaster adapter is still required.
- Validation: `node --test` in `backend` passed 26 tests (12 Delivery and 14 existing taxi/payment safety tests). Includes separate-worker stock race, restart persistence, role/ownership, cancellation, price validation and duplicate settlement. No live network calls or real documents/payments used.
- Admin/merchant portal at `/delivery`: responsive light/system-dark layout, private login, category and zone/rate management, shop/partner creation, shop blocking/commission editing, product/photo/price/stock management, order confirm/reject/readiness, history and cash-liability summaries. Financial completion is deliberately not exposed as a public endpoint.
- Latest validation: `node --test` passed 28 tests (14 Delivery and 14 existing safety tests); portal JS syntax checked. The actual passenger HTTP server was started only in an isolated test directory, with synthetic authentication and no TM/ATMOS calls. Portal asset routing and CSP were checked.
- Passenger source: `ТАКСИ | ДОСТАВКА` switch preserves the existing taxi form in an IndexedStack; Delivery loads only on activation. Implemented server categories, shops, Unicode search, product photos, single-store cart, existing Yandex map address picker, server quote display, cash checkout, status/history and early cancellation. No catalog mocks were added to production.
- Checkout intent/quote ID/idempotency key are persisted in existing secure storage before sending, scoped to the authenticated customer. A 409 is reconciled against owned server history using `quote_id`; connection failures retain the key. Buttons block during commands.
- Passenger validation: 5 Flutter widget tests passed, including server totals, restart after network interruption and changing store after emptying the cart. Dart analysis has 0 errors, 9 pre-existing warnings and 5 info diagnostics in main.dart. Backend tests still pass 28/28 after the response contract addition.
- Additional stock protection: migration 002 adds optimistic product versions. Checkout and cancellation advance versions; stale merchant edits cannot overwrite reserved/restored stock. Forward migration preserves v1 data. All 11 current domain tests passed; unchanged HTTP/host and taxi-safety tests passed in the preceding 29-test run (its only failure was the subsequently fixed test input's numeric boolean). Portal requests now time out after 20 seconds while order command keys remain stable for retries.

## In progress / next
- Current step: local passenger debug APK build (separate `.deliverydev` application ID) in progress; do not claim it built until Gradle succeeds.
- Next concrete feature: durable TM transport outbox and reconciliation (unknown create outcome must not be retried blindly). Reuse the real passenger backend's `tmPost/create_order2`, real `get_order_state` and authenticated Driver+ assignment proof, not invented TM endpoints. Then Driver+ delivery labels/actions, admin courier assignment/cancellation, taxi/delivery conflict checks and full merchant → customer → driver → finance acceptance.
- Full MVP is NOT ready: no live transport worker/courier connection, no complete live delivery or real settlement acceptance yet. No Delivery APK installed on a real phone.

## Blockers / validation
- Flutter 3.47.7 / Dart 3.13.5 installed from official stable source at `C:\Yangi Taxi DEV\.local\tools\flutter`; PUB_CACHE `.local/pub-cache`. Use existing Windows 8.3 aliases (`C:\YANGIT~3\LOCAL~1\tools\flutter`, `C:\YANGIT~3\YANGI-~2\flutter`) for Flutter/Dart hooks: long SDK path with spaces causes native-hook invocation failure.
- Android platform generated locally using the existing CI pattern and ignored in Git. Local debug adds `.deliverydev` suffix and label `Yangi Delivery Test`, minSdk26/compileSdk36. SDK/JDK/Gradle caches use existing workspace tools. Private MapKit defines file is outside Git; do not print its contents or inline the key in argv. Only the path is passed via `--dart-define-from-file`. Reconcile build settings with CI before distribution.
- Standard Gradle wrapper distribution download stalled. Downloaded Gradle 9.3.1 from official `downloads.gradle.org`, verified published SHA-256 and pointed the ignored local wrapper to that archive. Test kernel cache was preserved under `build/test_cache-before-delivery-20261017` and regenerated after a stale cache produced spurious SearchOptions constructor diagnostics; no changes to map source were needed.
- Running passenger backend differs from its manifest commit; deployment reconciliation remains mandatory.
- Browser UI verification blocked: CUA reports `Local browser use is disabled in Work settings`. Do not bypass that setting with another browser automation route. Portal visual/form acceptance remains unverified.
- No delivery changes deployed; no live orders or money affected.
- Delivery is opt-in (`DELIVERY_ENABLED=true`), requires Node 24+, a private absolute `DELIVERY_DB_PATH` and a strong existing passenger session secret. Fees are explicitly configured straight-line zone tariffs, not claimed road distances. All current transport tests use test-only simulated proof.
- Baseline/backend commit: `b00944e`. Portal changes are the next isolated commit. Local git commit author is Codex; no global Git identity was changed. No pushes or CI runs were triggered.
