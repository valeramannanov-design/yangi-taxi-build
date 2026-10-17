# Delivery pilot deployment — 2026-10-17

Portal: https://driver-api.yangi-taxi.uz/delivery

The existing passenger server at `C:\Yangi-Taxi-client\backend` now hosts Delivery alongside taxi. Its previous local fixes were merged and preserved. Existing ATMOS/env settings were retained; the old process was replaced and its single financial-worker lock was verified against the new process. The first attempt rolled back automatically; the retry succeeded after port-close/ownership verification fixes.

## Private operator data

- Administrator credentials: `C:\Yangi-Taxi-client\delivery-private\admin-access.private.json`.
- Database: `C:\Yangi-Taxi-client\delivery-private\delivery.sqlite`, schema 4.
- Backup paths and deployment status: `C:\Yangi-Taxi-client\delivery-private\deployment.json`.
- Driver bridge: `C:\Yangi Taxi DEV\.local\delivery-driver-bridge.private.json`.
- Credentials/token files are local only and protected by Windows ACL. They are not APK assets, Git content or public URLs.

The database currently has one administrator, no shops and no delivery orders. No synthetic catalog was seeded. Configure real categories/zones, merchants and products through the portal before real acceptance. Do not treat the empty catalog as a finished operational release.

## Pilot limits

`DELIVERY_ALLOWED_CREW_IDS=4` and `DELIVERY_ALLOWED_DRIVER_IDS=5` limit choices and transport creation to the existing test crew. Tests reject another crew/driver even when submitted directly. Keep these limits until the full delivery and settlement cycle is accepted. Ordinary TaxiMaster/Driver+ taxi sessions use their existing access rules.

`DELIVERY_ENABLED` and `DELIVERY_TRANSPORT_ENABLED` are enabled for the pilot. Rollback copies of the exact original server and env are located through the private deployment state. Preparation/apply helpers live at `.local/deploy-delivery-local.py` and `.local/deploy-delivery-apply.ps1`; they use fixed paths, hash/ownership checks and private backups, and are not generic unattended deployment tools.

Caddy now proxies Delivery paths to 8788 and preserves existing driver gateway paths to 18158. Certificate data directories and admin-disabled configuration are unchanged. The pre-existing hidden supervisor was restored for driver services/HTTPS. Existing passenger startup scripts still start the updated server using its existing data/env directory.

## Verification and gaps

Current follow-up: exact Driver+50 is installed. Its native fixture passed48 assertions, and a separate stationary Delivery/Driver+/real-TM cycle completed successfully on TM11708, including exact cash proofs, balanced ledger and backend/app restart. See `DELIVERY_ACCEPTANCE_11708.md`. Production catalog/orders remain empty; bridge restored and sandbox stopped. Keep the driver5/crew4 scope until passenger Android/real merchant and other outstanding acceptance is complete. Earlier follow-up paragraphs below describe intermediate failures, not the current driver/backend result.

Acceptance follow-up: a separate loopback-only sandbox under `delivery-private\acceptance` exercised merchant checkout/readiness and actual Driver+ swipe acceptance on TM order 11691 / synthetic client 1640. USB then disconnected, so arrival, goods pickup, cash receipt and completion were not verified. The TM test order is independently confirmed aborted after a zero-fee cancellation preflight. Sandbox process is stopped, production bridge restored, production catalog/orders/ledger remain empty. Private fixture/cleanup intents must not be replayed blindly.

Two discovered corrections are now active: fleet gateway resolves the private bridge relative to the workspace, and an already-bound assignment review can recover through exact TM read proofs before goods pickup. Unknown creation, financial reviews, foreign ownership, changed amounts and pending management remain blocked. The production patch changed only `delivery/transport.mjs`; `server.mjs` and `.env` hashes were preserved and the replacement process owns the single settlement lock. Private rollback/proof: `delivery-private\acceptance\production-recovery-deployment.json`. Validation now passes 52 Node and 72 targeted Python tests.

- 50 Node tests pass. The merged server also passed isolated host/auth/catalog/portal smoke testing before deployment.
- Live real-TM health, administrator login/role/logout, empty catalog, schema 4, preserved non-Delivery config, single settlement worker and driver scope verified.
- Live choices returned test crew 4, thirteen actual tariffs and four actual cancellation states; IDs/names are loaded from TM.
- HTTPS gateway health, portal HTTP200 and catalog verified via the LAN with the real hostname/certificate. The outside web-fetch connector could not access this hostname; mobile-network access is not independently confirmed.
- Final Driver+ 48 APK installed with original signing key, retaining data. The phone uses the HTTPS driver endpoint; driver 5 is connected/on line with zero current orders.
- Full live delivery, actual cash/ledger settlement, passenger APK installation and real address-picker restrictions remain unverified. No delivery order or delivery financial record was created in this deployment stage.
