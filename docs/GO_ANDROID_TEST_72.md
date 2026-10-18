# GO test APK72 — 2026-10-18

Artifact `C:\Yangi Taxi DEV\artifacts\YangiTaxiGO-Test-v72.apk` includes dynamic
ETA source in addition to APK71 features. Built through existing pilot script
with explicit BuildNumber72; original passenger Android signing home retained.

- Package uz.yangi.yangi_taxi.deliverydev; code72/version1.9.4.
- Label Yangi Taxi GO Test; minSDK26/target36.
- ABIs arm64-v8a/armeabi-v7a/x86_64.
- SHA256 11d988c705626a67615af481f1b318235bf1100b04206c2e892862189ce1b97d.
- Passenger signing certificate verified:
  7c41284d1df4efc72e838f4c1cbd632c9c0f94ab194849fe0e0242de3d98f997.

Read-only build preflight: production HTTPS health mock=false/TMAPIok and Delivery
catalog accessible (one shop). This does NOT prove GO financial contracts or
enable new checkout. Normal private build defines reused, no TEST tariff adapter
or mock login enabled in this APK. Production/backend/database untouched.

Source backend remains schema11; actual live host is older/schema5. Freshness
metadata is absent there, so native dynamic ETA acceptance requires compatible
separately approved staging. Device installation/visual results must be recorded
as actually observed; widgets/native compilation are not a real driving test.

## Actual device result

On2026-10-18, W4RO7DNVGAA6PVIN was online. adb install -r returned Success;
device metadata confirms72/version1.9.4. Authorized am start targeted only the
installed test app. First complete PNG showed a black app content area during
cold launch; own-process logs showed startup/ANR_LOG delay, not a diagnosed new
Dart failure. A subsequent complete PNG showed the real GO home, four service
cards and bottom navigation, with no active orders. No startup performance fix
or precise delay duration is claimed.

Evidence: C:\Yangi Taxi DEV\artifacts\GO72-initial-20261018.png (initial black)
and C:\Yangi Taxi DEV\artifacts\GO72-ready-20261018.png (rendered home).
These screenshots contain no order execution. MapKit/GPS/dynamic ETA and driver
cash flow remain unaccepted on native hardware; unchanged live backend does not
supply the new freshness contract. No login credentials, new order or financial
action was entered during this device observation.
