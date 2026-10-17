# Delivery pilot deployment — 2026-10-17

Portal: https://driver-api.yangi-taxi.uz/delivery

The existing passenger server at `C:\Yangi-Taxi-client\backend` now hosts Delivery alongside taxi. Its previous local fixes were merged and preserved. Existing ATMOS/env settings were retained; the old process was replaced and its single financial-worker lock was verified against the new process. The first attempt rolled back automatically; the retry succeeded after port-close/ownership verification fixes.

## Private operator data

- Administrator credentials: `C:\Yangi-Taxi-client\delivery-private\admin-access.private.json`.
- Database: `C:\Yangi-Taxi-client\delivery-private\delivery.sqlite`, schema 5 (road pricing upgrade).
- Backup paths and deployment status: `C:\Yangi-Taxi-client\delivery-private\deployment.json`.
- Driver bridge: `C:\Yangi Taxi DEV\.local\delivery-driver-bridge.private.json`.
- Credentials/token files are local only and protected by Windows ACL. They are not APK assets, Git content or public URLs.

The database currently has one administrator, no shops and no delivery orders. No synthetic catalog was seeded. Configure real categories/zones, merchants and products through the portal before real acceptance. Do not treat the empty catalog as a finished operational release.

## Pilot limits

`DELIVERY_ALLOWED_CREW_IDS=4` and `DELIVERY_ALLOWED_DRIVER_IDS=5` limit choices and transport creation to the existing test crew. Tests reject another crew/driver even when submitted directly. Keep these limits until the full delivery and settlement cycle is accepted. Ordinary TaxiMaster/Driver+ taxi sessions use their existing access rules.

`DELIVERY_ENABLED` and `DELIVERY_TRANSPORT_ENABLED` are enabled for the pilot. Rollback copies of the exact original server and env are located through the private deployment state. Preparation/apply helpers live at `.local/deploy-delivery-local.py` and `.local/deploy-delivery-apply.ps1`; they use fixed paths, hash/ownership checks and private backups, and are not generic unattended deployment tools.

Caddy now proxies Delivery paths to 8788 and preserves existing driver gateway paths to 18158. Certificate data directories and admin-disabled configuration are unchanged. The pre-existing hidden supervisor was restored for driver services/HTTPS. Existing passenger startup scripts still start the updated server using its existing data/env directory.

## Verification and gaps

Latest pricing upgrade: no required geographic zones for shops, public quotes use real TM road/cost calculation. Current server settings are tariff27 “Доставка” / group3 / road limit30km; tariff monetary parameters unchanged. 58 backend tests pass; actual isolated no-zone HTTP quote/checkout verified road680m/fee5800. Production remains empty, existing env preserved and one settlement owner verified. See `DELIVERY_ROAD_PRICING.md`; rollback must use that upgrade's matching pre-migration code AND DB backup.

Current follow-up: exact Driver+50 is installed. Its native fixture passed48 assertions, and a separate stationary Delivery/Driver+/real-TM cycle completed successfully on TM11708, including exact cash proofs, balanced ledger and backend/app restart. See `DELIVERY_ACCEPTANCE_11708.md`. Production catalog/orders remain empty; bridge restored and sandbox stopped. Keep the driver5/crew4 scope until passenger Android/real merchant and other outstanding acceptance is complete. Earlier follow-up paragraphs below describe intermediate failures, not the current driver/backend result.

Acceptance follow-up: a separate loopback-only sandbox under `delivery-private\acceptance` exercised merchant checkout/readiness and actual Driver+ swipe acceptance on TM order 11691 / synthetic client 1640. USB then disconnected, so arrival, goods pickup, cash receipt and completion were not verified. The TM test order is independently confirmed aborted after a zero-fee cancellation preflight. Sandbox process is stopped, production bridge restored, production catalog/orders/ledger remain empty. Private fixture/cleanup intents must not be replayed blindly.

Two discovered corrections are now active: fleet gateway resolves the private bridge relative to the workspace, and an already-bound assignment review can recover through exact TM read proofs before goods pickup. Unknown creation, financial reviews, foreign ownership, changed amounts and pending management remain blocked. The production patch changed only `delivery/transport.mjs`; `server.mjs` and `.env` hashes were preserved and the replacement process owns the single settlement lock. Private rollback/proof: `delivery-private\acceptance\production-recovery-deployment.json`. Validation now passes 52 Node and 72 targeted Python tests.

- 50 Node tests pass. The merged server also passed isolated host/auth/catalog/portal smoke testing before deployment.
- Live real-TM health, administrator login/role/logout, empty catalog, schema 4, preserved non-Delivery config, single settlement worker and driver scope verified.
- Live choices returned test crew 4, thirteen actual tariffs and four actual cancellation states; IDs/names are loaded from TM.
- HTTPS gateway health, portal HTTP200 and catalog verified via the LAN with the real hostname/certificate. The outside web-fetch connector could not access this hostname; mobile-network access is not independently confirmed.
- Final Driver+ 48 APK installed with original signing key, retaining data. The phone uses the HTTPS driver endpoint; driver 5 is connected/on line with zero current orders.
- Full live delivery, actual cash/ledger settlement, passenger APK installation and real address-picker restrictions remain unverified. No delivery order or delivery financial record was created in this deployment stage.


## GO schema8 / address pilot preparation — not executed

- Obtain production migration permission; first prove actual TM approach/commission and agree the controlled end-to-end test. Never resume acceptance5.
- Before cutover, stop new GO checkout and quiesce relevant outbox writes without interrupting uncertain financial commands. Inventory active transport mappings and cash evidence.
- Make a consistent SQLite backup using SQLite backup API (including committed WAL), plus existing shared client-profile JSON and matching deployed code/config backups stored privately. Do not copy a live SQLite main file alone or commit private data.
- Rehearse upgrade on a separate copy. Automated schema4/5/6/7→8 tests now preserve snapshot bytes, receipts, ledger sums and FK integrity. Verify real backup counts/hashes separately before any authorized cutover.
- Deploy compatible server plus backend/address-details.mjs/delivery modules, bridge/Driver+ and passenger client together. Test shared profile metadata echo; old servers must not silently drop delivery details. No new address-specific DB migration is required.
- Before new writes, rollback can restore the matching old code+DB+profile snapshot. After any new cash event/order, DO NOT restore a stale DB or delete evidence: freeze new checkout, retain schema8/journal/receipts, reconcile and recover forward. Older code must not open schema8. Keep a complete post-cutover snapshot for investigation.
- Device/native map/location, active taxi restore and new courier cash actions remain pending acceptance. ADB online is not a completed GUI test. No production changes were made by this stage.
