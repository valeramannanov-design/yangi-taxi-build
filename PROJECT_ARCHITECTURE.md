# Yangi Taxi GO — existing architecture / audit 2026-10-17

Authoritative new scope: `docs/YANGI_TAXI_GO_SPEC.md`. Supersedes the previous Delivery cash settlement design. The supplied file ends at item “14.” in section44; no missing reference screenshots or remaining acceptance steps are assumed.

## Reuse map

| Component | Status | Source / action |
|---|---|---|
| Passenger authentication and existing TM client identity | ГОТОВ | `flutter/lib/main.dart` ApiClient/YangiTaxiApp; backend SMS/password/session APIs; retain secure storage and identifiers |
| Taxi booking, tariffs, route, active ride restoration | ГОТОВ, requires GO regression | OrderScreen/RideScreen/Shell, real CommonAPI; keep widgets mounted across service switches |
| Yandex map picker/geolocation | ЧАСТИЧНО ГОТОВ | TaxiYandexMap/MapPointPickerScreen; exact point support exists; GO visual/address reuse needs device acceptance |
| Profile, settings, languages/themes, photo, addresses, cards, promo UI | ТРЕБУЕТ ИНТЕГРАЦИИ | Existing ProfileScreen/SettingsScreen/CardsScreen/FavoriteAddressesScreen/PromoCodesScreen; one GO shell, no new account/card wallet |
| Unified GO home/navigation | ЧАСТИЧНО ГОТОВ | `flutter/lib/go.dart`, same Shell; local widget proof, no GO device/release acceptance |
| Food/market catalog, shop/product/cart/quote/checkouts | ЧАСТИЧНО ГОТОВ | `flutter/lib/delivery.dart`, `backend/delivery`; typed catalogs, schema7 recommendations and source009 variants/composition/grams/ml/grid,010 promotions,011 coupons and real-route dynamic ETA implemented; source012 self-pickup/in-app readiness implemented; native GPS/pickup acceptance remain |
| Merchant/admin portal, tenancy and stock CAS | ЧАСТИЧНО ГОТОВ | Receipt-from-courier action/timeline now implemented in source; role/ownership preserved. GO release/device acceptance pending |
| Tariff27 road quote | ЧАСТИЧНО ГОТОВ | Existing analyze_route2/calc_order_cost2; 2160m/9800 verified; courier-to-store approach price inclusion not proved |
| GO cash/commission model | ЧАСТИЧНО ГОТОВ | New buyout journal/reimbursement and isolated TEST completion verified. Historical ledger retained. Actual TM approach/commission/debit contract still blocks production; see docs/GO_CASH_CHECKOUT.md |
| Driver+ lifecycle and isolated sessions | ЧАСТИЧНО ГОТОВ | Driver+50 baseline extended with shop-payment and recipient-arrival controls/private proofs; compiled/tested locally. Phone acceptance and post-buyout dispute resolution pending |
| Parcel delivery | ЧАСТИЧНО ГОТОВ | Existing taxi delivery tariff and route can be reused; sender/recipient contacts, handover and allowed parcel rules not complete |
| Unified history/active service orders | ТРЕБУЕТ ИНТЕГРАЦИИ | Existing taxi history/current API plus owned Delivery orders; classify legacy purchases explicitly rather than calling them parcels |
| GO shared profile/history and manual recommendations | ЧАСТИЧНО ГОТОВ | Local source/tests connected; see `docs/GO_FOUNDATION.md`; visual/device/final metadata remain |
| Reviews/complaints, promotions, notifications | ЧАСТИЧНО ГОТОВ / ОТСУТСТВУЕТ | Taxi feedback/promo mechanisms exist; GO restaurant/courier reviews and low-rating complaint inbox implemented in source013 (docs/GO_REVIEWS.md); general inbox and Android FCM/outbox prepared in source014 (docs/GO_NOTIFICATIONS.md); actual Firebase config/background push activation and native/browser acceptance remain |

## Repositories / access audit

- Passenger: `C:\Yangi Taxi DEV\yangi-taxi-client`, branch `feature/yangi-taxi-delivery`; clean before GO work, latest prior commit c7f220c. Remote passenger main baseline1.9.4; existing branch/commit inventory inspected, no merge or framework replacement.
- Driver: `C:\Yangi Taxi DEV\yangi-taxi-building`, same branch; extensive existing dirty/untracked work preserved. Do not stage it wholesale.
- Existing `yangi_platform` is a separate synthetic DEV platform (FastAPI/PostgreSQL/test SQLite), explicitly unrelated to live TM. It is not a ready GO client or an alternative production tariff engine. Other local Android/Flutter prototypes remain separate DEV; current real integration takes precedence.
- Passenger open PR30 (`review/passenger-sms-safety-v194`, head abb5da2) touches existing auth/backend/Flutter and is draft safety work; PR27 is older v1.8 payments/profile work. Audited metadata and PR30 changed-file list through GitHub API. No PR merged/overwritten. Driver remote PR API returned404 without authenticated repository access; remote PR review is unverified, not proof of no PRs.
- No relevant root AGENTS.md found. Driver design subdirectory instructions do not apply to passenger files. Shared runtime/dependencies remain unchanged.

## Runtime boundaries

Live backend `C:\Yangi-Taxi-client\backend` has extra local fixes; never replace it wholesale. GO changes are local source/tests only until deployment is explicitly authorized. Preserve production database, TM tariff configuration, driver scope and existing accounts. Debug `.deliverydev` is a separate pilot installation of this same passenger source, not a second Delivery codebase/product.

The isolated acceptance5 server was stopped after verifying PID2152/port18202/exact command ownership: its old cash model is superseded. No TM order was dispatched there; retain fixture evidence and do not rerun seed. Driver bridge remains production8788. Production host/DB/TM were not changed by the GO audit.
