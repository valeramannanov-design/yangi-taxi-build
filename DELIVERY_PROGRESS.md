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

## In progress / next
- Next concrete step: integrate a Delivery catalog/cart/history screen and `ТАКСИ | ДОСТАВКА` switch into `flutter/lib/main.dart`, reusing `MapPointPickerScreen`, `ApiClient` and passenger sessions. Keep pending checkout idempotency keys in secure storage across network failures/restarts.
- Then build the durable TM transport outbox and reconciliation (unknown create outcome must not be retried blindly), reuse actual driver/crew assignment proof, integrate Driver+ delivery labels/actions, test taxi/delivery conflict handling, full flow and financial settlement, build APKs.

## Blockers / validation
- Flutter SDK absent initially; cloned official stable Flutter into `C:\Yangi Taxi DEV\.local\tools\flutter`, first Dart/tool initialization in progress. APKs not built for Delivery yet. Running passenger backend differs from its manifest commit.
- Browser UI verification blocked: CUA reports `Local browser use is disabled in Work settings`. Do not bypass that setting with another browser automation route. Portal visual/form acceptance remains unverified.
- No delivery changes deployed; no live orders or money affected.
- Delivery is opt-in (`DELIVERY_ENABLED=true`), requires Node 24+, a private absolute `DELIVERY_DB_PATH` and a strong existing passenger session secret. Fees are explicitly configured straight-line zone tariffs, not claimed road distances. All current transport tests use test-only simulated proof.
- Baseline/backend commit: `b00944e`. Portal changes are the next isolated commit. Local git commit author is Codex; no global Git identity was changed. No pushes or CI runs were triggered.
