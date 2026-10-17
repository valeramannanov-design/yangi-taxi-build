# Delivery pricing without mandatory zones

New customer quotes use the existing real TaxiMaster `analyze_route2` and `calc_order_cost2` host integration. The delivery service does not implement Yandex's private algorithm, invent demand multipliers, or supply a straight-line/locally calculated price when TM routing fails. Reference: https://help.taximaster.ru/index.php/TM_API.

## Current behavior

- Shops can be created without a zone. The portal replaces “Тарифы и зоны” with “Тариф доставки”; shop forms have no zone selector. Older zone associations/API are retained for compatibility/history, but the public quote handler always requires verified road pricing. Old direct-domain zone quotes remain a legacy compatibility path, not an HTTP fallback.
- Administration selects an active TM tariff, crew group and maximum road distance. Per-kilometre/minimum/time-based fare rules remain in TaxiMaster. Settings are stored server-side with optimistic versions; they are not hardcoded into the apps.
- Passenger supplies store/items/destination only. Existing client API response fields are retained, with added pricing provenance. No new Android APK is required for this backend contract. The driver cannot change delivery pricing.
- Route/cost calls finish before a short DB transaction rechecks store/settings/cart and persists the five-minute quote. No SQLite transaction spans network I/O. Missing/malformed routes, impossible distance, unavailable/inactive tariff, invalid money and excess road distance block a quote. No inventory is reserved until checkout.
- Checkout freezes the quoted goods/fee/commission and tariff. A later settings change does not rewrite an already confirmed quote/order. Courier assignment must use the quoted tariff and crew group; mismatch is rejected before TM transport creation. Regular taxi tariffs are not edited.
- In-flight quote requests are bounded and concurrent calculations for the same customer are rejected temporarily. Unknown network errors never produce a fallback price or a fake ETA.

## Local deployment / actual proof

Installed on the existing passenger backend, preserving its additional local fixes and exact `.env`. Schema5 makes shop zone nullable and adds `delivery_pricing`; migration rebuilds the shop table in a write transaction, checks all foreign keys before commit, and restores FK enforcement. Unit upgrade test includes old completed order, receipt and balanced ledger.

Selected the existing active tariff **27 “Доставка”**, crew group3, initial maximum road distance **30000m**. Limits can be changed in the portal. These are live DB settings selected after reading TM catalog; no tariff prices were changed. The driver5/crew4 pilot restriction remains.

Actual read-only TM route/cost probe: road680m /10 route points, TM fee5800 UZS. Isolated actual-host HTTP probe at loopback18201 created a shop with no zone, requested a quote with a deliberately false client fee1, received authoritative fee5800, goods10000, total15800 and successfully checked out twice under one key into one order. It created no TM transport or real financial entries. Probe stopped; production shops/orders/Delivery ledger remain empty. Its private proof is `C:\Yangi-Taxi-client\delivery-private\road-pricing\probe\result.json`.

58 backend tests pass, including route errors/limits, price freeze, races during network requests, role/version guards, migration data preservation, tariff/group binding and existing taxi/payment safety. Portal JS parses. Visual browser acceptance remains unverified because browser control is disabled. The previous Driver+50/TM11708 full stationary lifecycle remains valid historical evidence; the new road-priced tariff27 was verified through HTTP checkout, not a new phone settlement run.

Private deployment/rollback proof and fresh pre-migration DB/code backup: `delivery-private\road-pricing\deployment.json` and `before\`. Rollback requires restoring compatible code AND DB together; do not run v4 code against schema5. Deployment verified real-TM health, unchanged environment and the one settlement-worker lock.

Still required for production MVP: real merchants/products, passenger phone/map checkout and actual commercial/road/mobile-network acceptance. No automatic nearest-courier assignment, demand-based surge or predicted delivery times were added by this change.
