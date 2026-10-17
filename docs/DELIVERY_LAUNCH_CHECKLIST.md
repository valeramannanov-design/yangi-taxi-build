# Delivery launch checkpoint — 2026-10-17

The pilot is prepared; full production acceptance is still pending. Continue from the unchecked items below, not from historical progress entries.

## Completed in this checkpoint

- Real shop 1, “Париж Ресторан”, was created and activated by the operator. Existing address `Samarkand MFY`, coordinates `40.042562, 65.963264` and commission 1% were preserved.
- Added the operator-specified product “Шашлык”: 25,000 UZS, stock 85. Public HTTPS shop response independently confirms the saved product. No product photo was supplied or invented.
- Admin portal now has a “Товары” section with store selection, product creation/editing, image upload, price, visibility and stock. Partner accounts retain their existing isolated product interface. Admin operations reuse the same image ownership, SKU uniqueness and optimistic stock version checks. A failed store switch restores the previous selection.
- Deployed only `delivery/store.mjs`, `delivery/http.mjs`, `delivery/portal/portal.js`; preserved the actual host `server.mjs`, environment and database schema. Health proves real TM and a single settlement worker. Backup: `C:\Yangi-Taxi-client\delivery-private\launch-catalog-20261017`. Rollback restores these modules only, never an old database over new merchant/order data.
- Found and corrected the local build configuration: previous passenger checkpoint omitted `BACKEND_URL` and consequently defaulted to demo on a fresh installation. Private defines now specify `https://api.yangi-taxi.uz`.
- Added `scripts/build-delivery-pilot.ps1`, configuration/HTTPS/real-TM/catalog preflight and APK package/signature verification. Missing MapKit key, demo, malformed/non-HTTPS URL, credential-bearing URL and wrong passenger signing key fail the build pipeline. CI explicitly uses Node 24, matching the SQLite runtime requirement.
- Installed the updated passenger APK preserving data. Initial update with the Driver+ debug key was correctly rejected by Android; rebuilding with the passenger key succeeded. **Passenger builds use `ANDROID_USER_HOME=C:\Users\user\.android`; Driver+ uses its separate `.local/android-user`. Do not uninstall to solve signing mismatches.**
- Installed Windows logon task “Yangi Taxi Passenger Backend” under the current user's limited account. Private supervisor uses an OS file lock, adopts an existing host, never kills a listener, blocks startup while a financial worker is alive or its lock is unreadable, and waits at least 60 seconds between starts. Starting it preserved backend PID5772 and real-TM health. Three isolated supervisor tests pass. A machine reboot/crash was not forced on the working service; real restart acceptance remains pending. Task XML/private supervisor are under `C:\Yangi-Taxi-client\delivery-private`.
- Created a consistent SQLite backup after catalog setup: private `launch-catalog-20261017/catalog-ready.sqlite`. Backup integrity and foreign keys pass; one store/product, zero orders/receipts/ledger rows. This is a checked backup, not proof of a complete service restore exercise.

## Artifact and verification

- APK: `C:\Yangi Taxi DEV\artifacts\YangiDelivery-Passenger-pilot-20261017.apk`.
- SHA256: `8cf366e696615c2cee8cd130944036a55f268245f920959aef8d95fca01dbe8c`.
- Package `uz.yangi.yangi_taxi.deliverydev`, version 1.9.4+70, minSdk26 / targetSdk36, label “Yangi Delivery Test”. This is a debug pilot, not a production release APK.
- Passenger signing certificate SHA256 `7c41284d1df4efc72e838f4c1cbd632c9c0f94ab194849fe0e0242de3d98f997`; verified against the prior APK. Installed update timestamp 2026-10-17 16:17:08.
- Backend: **60/60 tests** pass. Build guard: **3/3 tests** pass. Portal JS parses; Git diff has no whitespace errors. Existing Flutter widget proof remains 5/5; Flutter sources were not changed in this checkpoint.
- APK scan: six configured backend secret values checked, zero matches. Actual backend URL is present in the artifact. MapKit client key is intentionally a client configuration value, not a backend secret.
- Production database independently read after changes: zero Delivery orders, cash receipts and ledger rows. No restaurant checkout, stock reservation, real delivery or financial command was sent during this checkpoint.
- Public GET health/catalog/shop work. A Python HTTP probe was blocked by Cloudflare 1010 ([official explanation](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/)); the ordinary Dart HTTP client reaches the login endpoint. The old synthetic client1640 has a technical login rather than a passenger phone login, so it cannot prove the normal passenger authentication flow. Do not forge a production passenger session or alter a real customer's credentials to bypass this.

## Remaining acceptance / rollout

- [x] User confirmed on 2026-10-17 that the installed passenger app shows “Париж Ресторан” and “Шашлык”25,000 UZS after the requested normal sign-in check. This is user-reported catalog acceptance; address picker/quote/checkout are not yet confirmed.
- [x] Passenger quote and checkout persisted for actual shop1: user supplied portal screenshot, independently verified order `a4bfb6f42cb48dc6eb37824a287cacf34f51`, status `pending_shop`, version1, goods25000 + delivery9800 =34800 UZS, tariff27. One product reserved (stock84), no TM transport/driver assigned, no receipt/ledger rows. User created this order; the agent did not submit checkout. Await clarification whether this is a technical test or a real meal before merchant actions/dispatch. Do not treat it as an isolated synthetic fixture.
- [ ] Confirm actual Yandex map/address selection and passenger order restoration after restart/network interruption. The stored order proves destination/quote/checkout persistence, not correct interactive map behavior or recovery.
- [ ] Merchant/admin form interaction and screenshots. Native browser control is disabled by Work settings; do not bypass it with another automation mechanism. HTTP authorization/ownership/version tests are passed, visual acceptance is not.
- [ ] New end-to-end restaurant delivery with tariff27, test driver5/crew4, full cash receipt and TM transport amount independently reconciled. Earlier completed TM11708 is historical proof with another frozen tariff; never reuse/reopen it.
- [ ] Delivery-specific courier refusal and safe dispatcher recovery. Legacy taxi refusal is intentionally blocked for Delivery; dispatcher cancellation/reassignment has backend tests, no live refusal acceptance yet.
- [ ] Road/GPS test and mobile-network reachability. Stationary Wi-Fi proof does not establish either.
- [ ] Confirm backend and gateway recovery after restart/logon, private backups and restoration procedure before unattended use. This checkpoint did not reboot the working TaxiMaster computer.
- [ ] Production signing/distribution and rollout after acceptance. Pilot remains driver5/crew4; do not remove the restriction merely because the catalog is populated.

The tool's automatic approval review rejected the app-launch command without a detailed reason. Installation and read-only package verification succeeded separately. App launch/UI acceptance therefore requires the user's manual opening or an available authorized control route; do not retry the denied command through another tool.
