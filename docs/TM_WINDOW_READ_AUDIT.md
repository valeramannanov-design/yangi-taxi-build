# Existing TaxiMaster Enterprise window — 2026-10-17

Read-only inspection. No application launch, restart, termination, order creation,
tariff/configuration change or financial operation was performed in this check.

Windows process metadata at inspection:

| PID | Owner | Session | Main window handle reported by Windows |
| --- | --- | --- | --- |
| 21236 | WIN-412C4O5D4UJ\user | 1 | Historical handle deliberately not used |
| 24832 | WIN-412C4O5D4UJ\user | 1 | 994028 |

`query session` identifies session1 as the active `console` session for `user`.
The tool shell is also in session1. Process/session identity does **not** prove
which desktop owns a window. The supported Computer Use API has no desktop query;
the desktop of Enterprise remains unverified. No desktop switch or OS security
setting was automated.

`sky.list_windows()` exposes only Codex, Edge and TMControl (66574). Fresh
`sky.list_apps()` reports Enterprise running with `windows:[]`. After the user
manually restored Enterprise, a fresh window inventory still did not expose it.
The helper provides no explicit reason for this omission; it is not evidence
that Enterprise is stopped or that its window is on another desktop.

Because a returned target Window is required, 994028 was not fabricated into a
Computer Use Window. Obsolete655432 was never passed to an automation action.
No fallback UI Automation/Win32 control helper or second application launch was
used. Existing processes were left intact.

## What is still needed from the existing working client

Manual restoration alone did not resolve tool access. The user can provide
screenshots of these existing sections without changing their settings:

1. Tariff27 «Доставка»: relevant city/out-of-city approach and delivery settings,
   including any minimums/included approach and distance/time calculation pages.
2. Applicable «Правила расчётов с водителями»: commission basis, rate/fixed part,
   timing, applicability and exclusions.
3. Crew group3: which tariff/calculation rule applies.
4. Test crew4/driver5: individual calculation overrides and inherited rule.

Exclude credentials and working customer details. If Enterprise is on another
virtual desktop, switch to it manually and display the already-running client;
do not start another instance. Do not change security/Computer Use permissions
to bypass an access restriction.

Screenshots establish configuration, not an actual per-order debit. Actual
order-linked commission/debit/reversal evidence and courier approach pricing
still need verification; empty driver-operation responses do not prove zero
commission. Financial acceptance requires separate user authorization.

Real GO checkout stays closed. Continue independent source work and isolated
TEST acceptance; do not repeat catalog API probes for unavailable rule fields.
