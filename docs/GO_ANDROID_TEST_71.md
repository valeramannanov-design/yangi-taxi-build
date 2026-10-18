# GO passenger test APK71 — 2026-10-18

Artifact: `C:\Yangi Taxi DEV\artifacts\YangiTaxiGO-Test-v71.apk`

- Package uz.yangi.yangi_taxi.deliverydev; version1.9.4/code71; minSDK26/target36.
- Label Yangi Taxi GO Test; arm64-v8a/armeabi-v7a/x86_64.
- SHA256 b2f15af9a6495387d50f3c878ec030ef5e02be2ba403757638b37e7b71f702a2.
- Original passenger signing certificate SHA256:
  7c41284d1df4efc72e838f4c1cbd632c9c0f94ab194849fe0e0242de3d98f997.

Debug build completed with existing private production-HTTPS backend/MapKit
defines; no demo pricing or public TEST adapter was enabled. Existing generated
Android platform is ignored by Git: preserve its debug applicationIdSuffix
`.deliverydev`, INTERNET permission and debug label above when regenerating.
Passenger signing uses ANDROID_USER_HOME=C:\Users\user\.android; never use the
Driver+ signing home or uninstall to fix a signature mismatch. Existing pilot
build script now accepts explicit -BuildNumber71 (pass as `-BuildNumber 71`).

2026-10-18: ADB device W4RO7DNVGAA6PVIN returned `device`; `adb install -r`
returned Success. Device package metadata confirms code71/version1.9.4.
No uninstall/data reset, new order, payment, TaxiMaster change or production
backend/schema migration. Phone was on the launcher after update; user asked to
open the test app manually for visual observation.

## Acceptance boundary

This APK includes source GO catalog/options/promotions/coupons/address/cash UI.
Source backend requires schema11; unchanged live host remains schema5. New GO
catalog/checkout therefore is **not** accepted end-to-end on the device: existing
compatibility and financial guards must reject unsupported server contracts.
Installed package/signature and passing Flutter widgets are not proof of MapKit,
GPS, actual courier screen or live commission. Do not enable a TEST adapter in
production or run acceptance5 to make the app appear functional. Compatible
isolated/pilot staging plus separately authorized TM financial evidence remains.


Follow-up2026-10-18: user explicitly authorized opening the installed test app;
`am start` returned Starting Intent. Screenshot capture was incomplete and the
device then reported offline. The PNG is unusable; app-start command acceptance
is not proof of a rendered screen or successful login. No native visual check
has passed. Latest mobile Yandex Go reference request remains pending: current
RMX2021 package inventory shows Navigator, not the Go passenger app.
