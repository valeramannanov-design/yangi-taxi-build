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

## In progress / next
- Next: responsive admin/merchant portal using the real Delivery API; then passenger Flutter integration, live TM transport adapter and Driver+ delivery display/actions, end-to-end tests and APK builds.

## Blockers / validation
- Flutter SDK not yet located. Running passenger backend differs from its manifest commit.
- No delivery changes deployed; no live orders or money affected.
- Delivery is opt-in (`DELIVERY_ENABLED=true`), requires Node 24+, a private absolute `DELIVERY_DB_PATH` and a strong existing passenger session secret. Fees are explicitly configured straight-line zone tariffs, not claimed road distances. All current transport tests use test-only simulated proof.
