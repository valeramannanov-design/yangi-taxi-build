# GO test APK75 — 2026-10-18

Artifact `C:\Yangi Taxi DEV\artifacts\YangiTaxiGO-Test-v75.apk`.

- Package uz.yangi.yangi_taxi.deliverydev; version1.9.4/code75.
- Label Yangi Taxi GO Test; minSDK26/target36, existing three ABIs.
- SHA256 9f9258a9fedbd794e74c233da8bfcae7b270829426a154d772d6d6ec15294e05.
- Original passenger certificate verified:
  7c41284d1df4efc72e838f4c1cbd632c9c0f94ab194849fe0e0242de3d98f997.

Pilot HTTPS/backend preflight passed; build75 completed with new FlutterFire
dependencies in118.6s. Manifest merge confirms POST_NOTIFICATIONS and default
firebase_messaging_auto_init_enabled=false. No real Firebase settings supplied;
build helper explicitly reported FCM client disabled. Generated native resources
contain no project or private service account. No permission request/FCM SDK
initialization is called by the unconfigured Dart client.

adb install -r Success; device metadata75/version1.9.4 confirmed. Existing package
opened; data/signing retained, no uninstall or Driver+ replacement. Initial PNG
was black while dumpsys reported display OFF; safe KEYCODE_WAKEUP restored display
ON. Subsequent screenshot visually confirms existing authenticated GO home,
four services, bottom navigation and the new notifications entry in Uzbek.
No new order/payment, permission change or TaxiMaster operation was performed.

- Initial capture: `C:\Yangi Taxi DEV\artifacts\GO75-home-20261018.png`.
- Awake/home proof: `C:\Yangi Taxi DEV\artifacts\GO75-awake-20261018.png`.
- PNG bytes checked for complete IEND and decoded/visually inspected.

This is home/package proof, not native inbox/permission/background push acceptance.
Source requires14 while live backend remains5, unmodified; real checkout guard
closed. Compatible approved staging and actual FCM project/client/service-account
configuration are required for full native testing. SDK registration, cold tap,
permission denial, FID rotation/account switch and real delivery remain unaccepted.
Known earlier cold-start performance limitation is not claimed fixed.

Source checks:123 backend,56 Flutter,4 build/configuration tests passed; analyzer
0 errors/same14 existing warnings/info. Primary FCM references/config and protocol
details: GO_NOTIFICATIONS.md. No real external push was sent by this work.
