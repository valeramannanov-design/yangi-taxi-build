# Yangi Taxi

Demo Android app for Yangi Taxi. APK is built automatically by GitHub Actions.

Build check branch for APK CI.


## LIVE TaxiMaster check

Run this only on a machine that can reach the TaxiMaster CommonAPI.

```bash
cd backend
cp .env.example .env
# edit .env and set the real TM_API_SECRET; keep TM_API_MOCK=false
node live-check.mjs
```

The first run is read-only. It checks `ping`, crew groups and tariffs and prints whether the IDs configured for Yangi Taxi exist in this TaxiMaster installation.

To also test real prices for one route, add these temporary values to `.env`:

```env
LIVE_TEST_CLIENT_ID=<real TaxiMaster client id>
LIVE_TEST_SOURCE_LAT=<pickup latitude>
LIVE_TEST_SOURCE_LON=<pickup longitude>
LIVE_TEST_DEST_LAT=<destination latitude>
LIVE_TEST_DEST_LON=<destination longitude>
```

Then run:

```bash
node live-check.mjs
```

The script calls `analyze_route2`, `select_tariff_for_order` and `calc_order_cost2` for Start, Comfort, Business, Delivery and Cargo. It does not create or cancel any order. Do not paste `TM_API_SECRET` into chat; only share the command output.
