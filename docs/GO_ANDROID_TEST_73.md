# GO test APK73 — 2026-10-18

Artifact `C:\Yangi Taxi DEV\artifacts\YangiTaxiGO-Test-v73.apk`.

- Package uz.yangi.yangi_taxi.deliverydev; version1.9.4/code73.
- Label Yangi Taxi GO Test; minSDK26/target36.
- ABIs arm64-v8a/armeabi-v7a/x86_64.
- SHA256 087ce30a7b58d7208e00ee390bfa3318b3a94296375524941af41da970f154c4.
- Original passenger certificate verified:
  7c41284d1df4efc72e838f4c1cbd632c9c0f94ab194849fe0e0242de3d98f997.

Existing pilot script with BuildNumber73 passed read-only HTTPS health/catalog
preflight and completed the debug build. Normal private backend/MapKit defines
were reused; no TEST pricing, fixture login or mock values enabled in APK.
adb install -r returned Success; device metadata confirms73/version1.9.4.
No uninstall, data wipe, production backend update, schema migration, order or
financial action was performed. Driver+ package was not modified.

New in source: capability-driven self-pickup, no customer map/delivery routing,
server preparation estimate, direct merchant cash receipt/handover journal,
foreground in-app ready notices and matching history. See GO_SELF_PICKUP.md.

Production remains schema5/older backend, source now requires12. Old server
capabilities keep pickup hidden/checkout guarded and missing notices are handled
without inventing readiness. Installation is not a native end-to-end pickup or
MapKit/GPS proof. Those need approved compatible isolated/pilot staging; do not
enable TEST prices on the real host to bypass the gate. OS push and actual paid
cash refund/reversal remain unimplemented. APK72 home proof and cold-start delay
remain documented separately, not retroactively claimed as pickup acceptance.
