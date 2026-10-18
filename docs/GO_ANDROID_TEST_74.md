# GO test APK74 — 2026-10-18

Artifact `C:\Yangi Taxi DEV\artifacts\YangiTaxiGO-Test-v74.apk`.

- Package uz.yangi.yangi_taxi.deliverydev; version1.9.4/code74.
- Label Yangi Taxi GO Test; minSDK26/target36.
- ABIs arm64-v8a/armeabi-v7a/x86_64.
- SHA256 756d4d8fe0675b14f271a387d115ac6c446f91d76a3a35da1f253e6f01909cdd.
- Original passenger certificate verified:
  7c41284d1df4efc72e838f4c1cbd632c9c0f94ab194849fe0e0242de3d98f997.

Existing pilot script with BuildNumber74 passed read-only HTTPS preflight and
built debug APK with the existing private MapKit/backend defines. No fixture
login, mock catalog, TEST tariff or server secrets were added to APK source.
adb install -r returned Success; device metadata confirms74/version1.9.4.
Known installed GO component was opened; no uninstall/data wipe or order/finance
actions occurred. Driver+ package and working backend were not modified.

New source: completed-order shop/courier reviews, owned persisted acknowledgments,
shop rating/count and automatic low-rating complaint inbox/handling. See
GO_REVIEWS.md. 114 backend and48 Flutter tests passed; analyzer0 errors/same14
existing diagnostics. Full suite passed after preserving/regenerating ignored
Flutter test cache; stale MapKit SearchOptions diagnostics did not require source
changes. Portal syntax/diff checked; no native/browser review acceptance claimed.

Source requires schema13; live host remains5 with checkout financial gate closed.
An older backend cannot save GO reviews; client displays unavailable/retry rather
than success. Compatible approved isolated/pilot staging is needed for native
review, pickup/ETA/GPS and Driver+ acceptance. No production migration/deployment,
real order, commission write or refund performed. General OS push remains next.
