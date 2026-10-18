# GO dynamic courier travel time — source / 2026-10-18

Reuses existing authenticated `GET /api/orders/:id/driver-location` and its
`assertOwnedOrder` check, actual CommonAPI `get_order_state`/`get_crews_coords`,
and the already-installed Yandex MapKit4.45 DrivingRouter. No new TM method,
external routing key, speed formula, order creation or finance mutation.

## Actual inputs and additive own response

The existing location read now selects the coordinate whose crew_id exactly
matches the owned order state, instead of taking the first returned coordinate.
The original state/location response stays compatible. New **own backend**
`tracking` metadata includes source=TaxiMaster, checked_at (UTC epoch ms),
location_observed_at (UTC epoch ms or null), location_age_seconds and available.
These are implemented host fields, not claimed CommonAPI parameters.

`driver-tracking.mjs` interprets actual coords_time YYYYMMDDhhmmss using configured
TM_TIME_ZONE (the same timezone used for outgoing source_time). Invalid calendar
dates, unknown zone and ambiguous/nonexistent DST times fail closed. Coordinate
availability requires matching crew, numeric bounded lat/lon and age0–120s.
Future/unknown/stale coordinates are unavailable; phone wall-clock skew does not
make them fresh. Official field reference:
[TM API — get_crews_coords](https://help.taximaster.ru/index.php/TM_API).

Existing customer delivery snapshots now include existing crew_id alongside
driver_id and transport_order_id. No migration beyond current schema11 needed.

## Client behavior

GoPurchaseDetails refreshes authoritative delivery status every20s while visible
and foreground. GoCourierEta reads the owned transport location on that interval.
It checks crew/driver and any returned order ID against the delivery assignment;
missing or changed identity never routes the previous courier. Old backends
without the freshness metadata produce no estimate.

| Own delivery status / confirmed TM state | Presentation |
| --- | --- |
| Before assignment / missing valid tracking | Время уточняется |
| assigned/accepted + driver_assigned | Courier coordinate → store, Курьер до магазина |
| assigned/accepted + car_at_place | Курьер в магазине, no invented zero-minute route |
| picked_up + client_inside | Courier coordinate → destination, Путь до вас |
| picked_up + client_inside + own server client_arrived | Курьер прибыл |
| Completed/cancelled/rejected | ETA hidden |

Native router returns actual route metadata.weight.timeWithTraffic.value
(seconds, installed SDK's documented SI unit). UI rounds up to approximate
minutes and labels this **travel time**, excluding preparation. No constant
speed, silently decreasing counter, total food-preparation promise or local
price calculation. At least1 approximate minute is shown for a subminute route;
actual arrival is a confirmed state rather than guessed from distance.

Missing route/MapKit key/SDK permission, route error, old API, missing GPS,
assignment mismatch or unavailable order update clears old minutes. Coordinate
age includes elapsed request/routing time. Expiry runs even during a slow route;
late results after expiry/reassignment/background/dispose are ignored. Native
session is cancelled on invalidation. Background stops reads and clears data;
resume requests fresh data. Pending HTTP/native work is bounded by timeouts.

## Verification / deployment boundary

100 backend tests and33 Flutter tests pass. Two new backend cases cover zone,
age, strict identity/coordinates, invalid dates and DST ambiguity/gap. Ten ETA
tests cover route source/target,20s refresh/no countdown, stale/old backend,
network and route errors, stage/arrival/completion, pause/resume, slow-route
expiry, late reassignment, accessible320px layout and parent status polling.
Analyzer0 errors; same14 legacy main.dart diagnostics.

Widgets inject durations only in tests; production always uses MapKit. These
tests do not prove native route/GPS operation or a moving-courier field test.
APK71 predates ETA. APK72 is built from this stage; record its actual package,
signature/install result separately. No production deploy/migration/host
restart, live order or TM UI control. Live schema5/backend remains unchanged.
Reconcile local production fixes and include driver-tracking.mjs with any
separately approved compatible backend staging; do not replace it wholesale.
Real GO gate remains CLOSED until approach/commission proof is accepted.
