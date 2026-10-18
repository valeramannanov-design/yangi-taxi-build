# GO notifications / Android push — 2026-10-18

Source schema14. Production remains schema5, unchanged; no migration/deployment,
live order, financial operation, real FCM send or TaxiMaster UI action performed.

## Implemented inbox

Extend the existing012 pickup inbox instead of making another notification store.
014 preserves original IDs/read acknowledgements and adds unique event keys,
typed events, Android installations and durable outbox. Schema4–13→14 tested.

Only actual server transitions emit events: created, shop confirmed/ready, pickup
readiness/time change, courier assigned/accepted/picked up, completed, cancelled,
rejected. An admin's audited complaint status update also emits an owned notice;
internal handling notes are not exposed. No invented timestamps/statuses or
independent order/financial engine. Same-status cash acknowledgements do not
manufacture another order-state notice. Event + outbox + actual transition share
the existing SQLite transaction; retries cannot duplicate the same event.

Actual own API, under `/api/delivery` (not TaxiMaster endpoints):

- GET `/customer/notifications`: authenticated owner only, latest100; positive
  `before` cursor for older history. Kind/time/read state and owned order metadata.
- GET `/customer/notification-summary`: total unread across all history; public
  configured capability `{push:{available,project_id}}`. This is configuration,
  not provider connectivity/delivery proof.
- POST `/customer/notifications/:id/read`: same existing own acknowledgement and
  Idempotency-Key; retries preserve original read time. Cannot mark another
  customer's notice, change event content or revert read state.
- POST `/customer/push/register`: Android-only own contract
  `{installation_id,fid,lang:ru|uz}` + key; requires configured server push.
  Authenticated customer from existing session, never request identity. Reject
  an enabled installation/FID belonging to someone else. Maximum5 active own
  installations; generation fences queued sends after re-registration/revocation.
- POST `/customer/push/revoke`: `{installation_id}` + key; works even if sending
  is disabled. Revokes own device and discards its pending/retry/leased work.

GO home shows unread preview/count and opens the full persistent inbox; tapping
opens an order from that authenticated inbox, never an arbitrary URL/order from
FCM data. Existing pickup widget is a thin compatibility wrapper over the same
load/ack logic. Foreground polling30s, resume refresh, no polling in background
or inactive service; stale/session-changed results and callbacks discarded.
Pagination, retry and read history supported. Missing/old backend does not
fabricate inbox content or success.

## Android implementation and unconfigured boundary

User selected Android only. FlutterFire firebase_core5/firebase_messaging17 use
the current register/onRegistered FID API; actual HTTP v1 sends target `fid`.
No APNs/iOS/web push registration or sender payload is implemented/enabled.

`GoAndroidPushSetting` lives in existing application settings. With no real client
configuration it says service not connected, stays off, never initializes Firebase
or requests notification permission. With matching configured server project,
explicit opt-in requests Android permission, registers FID, persists preference
and owned installation in existing secure storage. Refresh events update backend;
foreground receipt reloads inbox. Initial/background taps open the owned inbox
when GO home is active; if inactive, navigation is deferred to home. No raw FCM
order ID is trusted. App force-stop/OS restrictions can prevent delivery.

Logout clears local preference, attempts server revocation and SDK unregister/
auto-init disable before clearing existing auth. Offline revocation is best effort;
an already accepted/in-flight push cannot be recalled. Lock-screen text therefore
contains only a generic GO update: no names, phone, addresses, price, internal
notes or financial commands. Fresh authentication/ownership is always required
for details. Android `tag` reduces duplicate visible notifications after uncertain
sends; do not claim exactly-once network delivery.

Existing pilot build now runs `scripts/configure-go-android.mjs` against the ignored
generated Android platform, and CI runs its default-disabled setup. It adds
POST_NOTIFICATIONS and default auto-init=false. When all public client defines
are supplied, it creates the documented native Firebase resources as well as
Dart options, so cold-process notification initialization is not Dart-only.
Rebuilding without configuration clears stale generated resources. Server private
keys are forbidden in build defines. The tracked lockfile now records the actual
resolved dependency graph; no Driver+ dependencies/signing files changed.

## Sender/outbox

`android-push.mjs`: opt-in actual FCM HTTP v1 adapter, Google OAuth RS256/service
account, cached short-lived token, pinned HTTPS endpoints/no redirects, bounded
timeouts, safe error codes only. No credential/provider response bodies logged.
Unknown network outcomes retry; FCM acceptance is stored separately from read.
Worker uses SQLite claims/60s leases, bounded batch20, retries30s→1h/max8,
24h expiry; skips read, expired, revoked, reassigned or stale-generation jobs.
UNREGISTERED disables only the matching current installation. Multiple workers
cannot claim the same active lease. Tests prohibit real provider in TEST hosts.

## Required to activate and accept (NOT done)

1. Firebase project with FCM API enabled, Android app registered for the exact
   installed package `uz.yangi.yangi_taxi.deliverydev` (production package has a
   separate configuration). No project/client/account settings were found in the
   searched project/local configuration locations. Do not invent these values.
2. Four public build defines, alongside existing private HTTPS/MapKit defines:
   GO_FIREBASE_API_KEY, GO_FIREBASE_APP_ID, GO_FIREBASE_SENDER_ID,
   GO_FIREBASE_PROJECT_ID. Optional absence keeps current APK push disabled.
3. Private backend service-account JSON outside Git/APK, permission to send FCM;
   DELIVERY_FCM_SERVICE_ACCOUNT_FILE absolute path, DELIVERY_PUSH_ENABLED=true,
   optional DELIVERY_FCM_PROJECT_ID. Service account is never an Android asset.
4. Reconciled approved compatible source14 isolated/pilot backend + consistent
   backup. Never overwrite local production fixes or enable TEST prices live.
5. Actual Android opt-in/denial, foreground/background/cold tap, SDK FID rotation,
   logout/account switch, revoked installation, force-stop and duplicate native
   notification acceptance. These are not proved by widget/OAuth stub tests.

Source checks:123 backend,56 Flutter tests and4 build/configuration tests; analyzer
0 errors/same14 existing diagnostics. Tests cover transactional rollback, owned
history/read, migration compatibility, retry/lease/revoke/read/expiry, scoped
UNREGISTERED, generic payload, real RS256 verification with a synthetic key,
pagination/lifecycle/session changes, pickup regression and disabled SDK config.
No real external push was sent. APK/device status is recorded separately.

## Primary references checked during implementation

- https://firebase.google.com/docs/cloud-messaging/flutter/get-started
- https://firebase.google.com/docs/cloud-messaging/flutter/receive-messages
- https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages
- https://firebase.google.com/docs/cloud-messaging/send/v1-api
- https://developers.google.com/identity/protocols/oauth2/service-account
- https://firebase.google.com/docs/android/google-services-plugin-and-file

Installed FlutterFire source was also inspected for actual register/onRegistered,
unregister, permission and tap-stream API signatures; deprecated getToken was not
used. Real FCM activation/native acceptance remains blocked by missing config.
