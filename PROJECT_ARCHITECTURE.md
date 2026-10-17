# Yangi Taxi GO — existing architecture / audit 2026-10-17

Authoritative new scope: `docs/YANGI_TAXI_GO_SPEC.md`. Supersedes the previous Delivery cash settlement design. The supplied file ends at item “14.” in section44; no missing reference screenshots or remaining acceptance steps are assumed.

## Reuse map

| Component | Status | Source / action |
|---|---|---|
| Passenger authentication and existing TM client identity | ГОТОВ | `flutter/lib/main.dart` ApiClient/YangiTaxiApp; backend SMS/password/session APIs; retain secure storage and identifiers |
| Taxi booking, tariffs, route, active ride restoration | ГОТОВ, requires GO regression | OrderScreen/RideScreen/Shell, real CommonAPI; keep widgets mounted across service switches |
| Yandex map picker/geolocation | ЧАСТИЧНО ГОТОВ | TaxiYandexMap/MapPointPickerScreen; exact point support exists; GO visual/address reuse needs device acceptance |
| Profile, settings, languages/themes, photo, addresses, cards, promo UI | ТРЕБУЕТ ИНТЕГРАЦИИ | Existing ProfileScreen/SettingsScreen/CardsScreen/FavoriteAddressesScreen/PromoCodesScreen; one GO shell, no new account/card wallet |
| Unified GO home/navigation | ОТСУТСТВУЕТ before this stage | Replace two-service switch in the same Flutter app, not a separate product |
| Food/market catalog, shop/product/cart/quote/checkouts | ЧАСТИЧНО ГОТОВ | `flutter/lib/delivery.dart`, `backend/delivery`; typed catalogs, richer products/recommendations/pickup/ETA remain |
| Merchant/admin portal, tenancy and stock CAS | ЧАСТИЧНО ГОТОВ | `backend/delivery/portal`, http/store; preserve role and ownership checks; receipt-from-courier absent |
| Tariff27 road quote | ЧАСТИЧНО ГОТОВ | Existing analyze_route2/calc_order_cost2; 2160m/9800 verified; courier-to-store approach price inclusion not proved |
| GO cash/commission model | ТРЕБУЕТ ИЗМЕНЕНИЯ | Existing merchant-payable ledger is historical, not the new courier-pays-shop contract. No new GO financial completion until integration is confirmed |
| Driver+ lifecycle and isolated sessions | ЧАСТИЧНО ГОТОВ | Existing Android Driver+50 / gateway; missing shop-payment and client-arrival proofs, appropriate refusal/dispute flow |
| Parcel delivery | ЧАСТИЧНО ГОТОВ | Existing taxi delivery tariff and route can be reused; sender/recipient contacts, handover and allowed parcel rules not complete |
| Unified history/active service orders | ТРЕБУЕТ ИНТЕГРАЦИИ | Existing taxi history/current API plus owned Delivery orders; classify legacy purchases explicitly rather than calling them parcels |
| Reviews/complaints, promotions, notifications | ЧАСТИЧНО ГОТОВ / ОТСУТСТВУЕТ | Taxi feedback/promo mechanisms exist; restaurant/courier reviews, low-rating complaints, Delivery outbox and rules need extension |

## Repositories / access audit

- Passenger: `C:\Yangi Taxi DEV\yangi-taxi-client`, branch `feature/yangi-taxi-delivery`; clean before GO work, latest prior commit c7f220c. Remote passenger main baseline1.9.4; existing branch/commit inventory inspected, no merge or framework replacement.
- Driver: `C:\Yangi Taxi DEV\yangi-taxi-building`, same branch; extensive existing dirty/untracked work preserved. Do not stage it wholesale.
- Existing `yangi_platform` is a separate synthetic DEV platform (FastAPI/PostgreSQL/test SQLite), explicitly unrelated to live TM. It is not a ready GO client or an alternative production tariff engine. Other local Android/Flutter prototypes remain separate DEV; current real integration takes precedence.
- Passenger open PR30 (`review/passenger-sms-safety-v194`, head abb5da2) touches existing auth/backend/Flutter and is draft safety work; PR27 is older v1.8 payments/profile work. Audited metadata and PR30 changed-file list through GitHub API. No PR merged/overwritten. Driver remote PR API returned404 without authenticated repository access; remote PR review is unverified, not proof of no PRs.
- No relevant root AGENTS.md found. Driver design subdirectory instructions do not apply to passenger files. Shared runtime/dependencies remain unchanged.

## Runtime boundaries

Live backend `C:\Yangi-Taxi-client\backend` has extra local fixes; never replace it wholesale. GO changes are local source/tests only until deployment is explicitly authorized. Preserve production database, TM tariff configuration, driver scope and existing accounts. Debug `.deliverydev` is a separate pilot installation of this same passenger source, not a second Delivery codebase/product.

The isolated acceptance5 server was stopped after verifying PID2152/port18202/exact command ownership: its old cash model is superseded. No TM order was dispatched there; retain fixture evidence and do not rerun seed. Driver bridge remains production8788. Production host/DB/TM were not changed by the GO audit.
