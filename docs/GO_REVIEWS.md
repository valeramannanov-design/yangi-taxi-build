# GO reviews and complaints — 2026-10-18

Source stage only; production backend/schema5 and GO financial gate unchanged.
Additive013 requires source schema13. No TaxiMaster wire method, driver finance,
refund, SMS, push or external message is performed by this feature.

## Reuse and scope

The existing taxi feedback remains `/api/orders/:id/rating` → actual CommonAPI
`save_client_feed_back`. Its behavior is not changed or presented as GO support.
GO uses its existing authenticated passenger identity, owned SQLite orders,
transaction/idempotency framework, merchant/admin identity and portal. No second
account or duplicate order history was created. Feedback opens inside completed
GO details and the existing purchase history.

## Actual own backend contract

All paths below are under `/api/delivery`, implemented by `http.mjs` and
`reviews.mjs`; they are **our API**, not invented TaxiMaster endpoints.

- GET `/customer/orders/:id/reviews`: owned order, `eligible_targets` and saved
  `reviews`. Eligibility only after server status `completed`. Shop always;
  courier only for delivery with a positive final server-bound driver/transport.
  Pickup cannot rate a courier. No client-provided target ID is accepted.
- POST same path: JSON `{target:shop|courier,rating:1..5,comment?:string<=1000}`,
  valid `Idempotency-Key`. Exactly one immutable review per order/target. Retrying
  identical content with either the same key or another key cannot add a score;
  conflicting content is409. Ownership, final state and target are checked in
  the same SQLite write transaction.
- Ratings1–2 atomically create one `delivery_complaints` row and an immutable
  initial event, even with no comment. Any failure rolls back both review and
  complaint. Ratings3–5 do not create complaints. Reviews survive restarts.
- GET `/merchant/reviews`: only that merchant's shop reviews, without passenger
  IDs/phone, courier reviews or internal handling notes. Comments remain user
  text and are HTML-escaped in the portal.
- GET `/admin/reviews`, GET `/admin/complaints`: authenticated admin only.
  Complaints include target, order, shop, version and full event history.
- POST `/admin/complaints/:id`: `{status:open|in_review|resolved,version,note}` +
  key; nonempty handling note required. Optimistic version check and idempotency
  protect retries. Reopening is audited. No status change alters order, cash,
  stock, ledger or authorizes a refund.
- Public existing shop/catalog response adds `rating:{count,average}`. These are
  actual immutable shop reviews; an unrated shop has count0/average null, no
  fabricated five-star default. Courier scores never affect shop average.

Client fields/buttons lock while submitting; an uncertain outcome retains the
exact key/payload for retry. A fresh order screen reloads the saved server state.
Malformed acknowledgements and old/offline backends never display fake success.
Complaint open/in-review/resolved is shown from the saved backend response.

## Verification and remaining acceptance

114 backend tests including six new review tests and schema4–12→13 compatibility;
48 Flutter tests including eight new reviews/details tests. Analyzer0 errors,
same14 existing main.dart diagnostics. Portal syntax and diff checks passed.
Tests use isolated temporary TEST hosts, synthetic identities and offline TM
adapters; a complete existing courier cash cycle is reused without live calls.
Repeated/lost requests, tenancy, spoofed targets, zero reviews, immutable audit,
storage rollback, independent courier/shop scores and unchanged ledger covered.

Actual browser portal handling and native review flow have not been accepted.
They need a compatible approved isolated/pilot backend; installation alone is
not end-to-end proof. No production migration/deployment or live order was done.
General notifications/OS push remain next; complaints here are durable inbox
entries in the GO admin portal, not messages sent to TaxiMaster dispatchers.
