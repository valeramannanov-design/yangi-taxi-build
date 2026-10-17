# Tariff27 acceptance — prepared, not completed

Date: 2026-10-17. The user confirmed that their production passenger order is a **technical test without preparation or delivery**.

## Production passenger checkout/cancellation

- User created order `a4bfb6f42cb48dc6eb37824a287cacf34f51` for shop1: one Шашлык25000 + delivery9800 =34800 UZS. Independently read snapshot proves `taximaster_road`, distance2160m, tariff27/group3. The agent did not submit this checkout.
- Before any merchant confirmation or transport assignment, used the existing authenticated admin management cancellation with version1 and a durable idempotency key. It completed as `cancelled`, `stock_restored=1`, transportID null. Stock independently verified back at85, zero cash receipts and ledger rows.
- Cancellation intent and original snapshot are private under `C:\Yangi-Taxi-client\delivery-private\launch-catalog-20261017`. **Do not replay the cancellation or reuse this terminal order.**
- User confirmed “Отменен”: passenger UI cancellation visibility is passed. Restart/network restoration is still unverified. Read-only TM check after this confirmation proves driver5/crew4 connected, on line, state1, zero current orders. The user has not yet confirmed opening Driver+ for manual test actions; do not infer that from the cancellation-only reply.

## Isolated continuation

- New private sandbox `C:\Yangi-Taxi-client\delivery-private\acceptance5`, loopback port18202, Node PID2152 at preparation; verify PID ownership before stopping it. Source copied from the actual deployed host, preserving its local fixes.
- Fresh SQLite/session/admin/merchant credentials. ATMOS and ordinary payment settlement disabled. Same real TM integration, allowed crew4/driver5 only. Reused synthetic TM client1640 and its unroutable test phone; **no new TM client created and no real customer's credentials/session copied**. Private test session is issued only with this sandbox's own secret.
- Sandbox-only adapter stages transport orders for tomorrow (`is_prior=true`) using the existing documented fields. Production adapter is unchanged. No order in TaxiMaster has been created in this checkpoint.
- Fixture copies the selected route and product price from the actual passenger snapshot, labels store/goods `TEST`, uses a no-zone shop and actual tariff27/group3 road pricing. Real TM recomputed the same2160m/9800 UZS; goods25000, total34800. Merchant confirmation and readiness succeeded through the partner API in the isolated DB.
- Isolated Delivery order `a041a946b65848e2e4e3b3fc2c9415271a17`, status `ready`, unassigned. Merchant readiness is not a claim that food was prepared.
- The active Driver+ Delivery bridge remains production `http://127.0.0.1:8788`; no gateway restart or bridge switch performed yet. Production order/restaurant accounting remains independent of the isolated test.

## Resume

1. Read `acceptance5/audit.json` and `fixture.private.json` privately. **Do not rerun seed/preparation.** Helpers: workspace `.local/prepare-delivery-acceptance5.py` and `.local/delivery-acceptance5-http.py` (only `inspect` is safe to repeat).
2. Wait for the user's Driver+5-on-line confirmation. Revalidate crew4 idle, driver5, group3 and active tariff27. Persist dispatch intent before the one creation request, reconcile unknown outcomes by reads.
3. Back up the current private production bridge config and route only the authorized test through the sandbox. The gateway loads its bridge at startup; ensure process ownership and preserve other configuration. Restore production bridge afterward.
4. Perform stationary driver accept/arrival/pickup/full receipt/finish with the test phone. Inspect real TM finished transportcash9800 and zero noncash plus sandbox receipt34800 and ledger(+34800,-9800,-24750,-250)=0. Do not post a fake cash receipt to the production restaurant order.
5. Check app/backend restart preserves terminal state without financial replay. Restore bridge8788, stop only the owned sandbox, document independent proofs. Road/GPS and mobile-network acceptance remain separate.

Phone app launch was previously rejected by automatic approval review. Do not retry the denied command through another tool; use the user's manual opening. Browser automation remains disabled.
