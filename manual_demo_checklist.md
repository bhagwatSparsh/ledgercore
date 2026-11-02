# LedgerCore — Manual Demo Checklist

Everything LedgerCore does, with exactly how to trigger each one live. Two honest things up front:

- **Run `faculty_live_demo.py` once at the start** (`python3 faculty_live_demo.py`, with the stack up). It performs every single thing on this list in about 15 seconds, narrated. Use it either as your actual live proof (run it on screen, talk through the printed output), or run it quietly beforehand so the UI already has rich data to click through — your call on the day.
- **Not every operation has a UI button**, and that's deliberate, not a gap. INSERT and DELETE are customer self-service, so they're full click-through experiences. UPDATE of account limits/status and schema MODIFICATION are administrative/engineering actions with no customer-facing button at all — by design, enforced by RLS and `requireRole("admin")` on the backend, not just hidden in the frontend. Say that sentence out loud if asked why there's no "freeze account" button — it's a stronger answer than having one.

---

## Priority 1 — INSERTION

| Action | How, live, in the UI |
|---|---|
| New account | Dashboard → **"+ New account"** → pick type/currency → Create |
| Deposit | Any account card → **"Add money"** → enter amount |
| New beneficiary | Sidebar → **Beneficiaries** → fill the inline form (account number, nickname, limit) → **Add** |
| Transfer | Open an account → **"Send money"** → pick a saved beneficiary or type an account number → Send |

Everything above is a real `INSERT INTO ...` — `accounts`, `ledger_postings`/`journal_entries` (via `process_deposit()`/`process_transfer()`), `saved_beneficiaries`.

## Priority 2 — UPDATION

No dedicated UI button for this one — these are administrative actions, not customer self-service. Show them one of two ways:

**Easiest: point to the terminal.** Run `faculty_live_demo.py` and narrate the "PRIORITY 2/4 — UPDATION" section as it prints: beneficiary nickname renamed, an account's per-transaction limit changed, then an account frozen and reactivated (admin-only, fires an audit-log trigger each time).

**If you want to trigger one yourself live**, open a second terminal and run (replace the two placeholders — your JWT is in the browser's DevTools → Application → Local Storage after logging in; the account ID is in the URL when you're on that account's page):
```bash
curl -X PATCH http://localhost:4000/accounts/<ACCOUNT_ID>/limits \
  -H "Authorization: Bearer <YOUR_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"perTxnLimitMinor": 1500000}'
```

## Priority 3 — DELETION

| What | How |
|---|---|
| A real, working DELETE | Beneficiaries page → **"Remove"** next to any saved beneficiary. Row disappears — that's `DELETE FROM saved_beneficiaries`. |
| A DELETE that's architecturally blocked | Terminal only — this is the strongest single moment in the whole demo. Run: |
```bash
docker exec ledgercore-postgres-1 psql -U postgres -d ledgercore -c "DELETE FROM ledger_postings WHERE posting_id = (SELECT posting_id FROM ledger_postings LIMIT 1);"
```
Postgres refuses it with `CRITICAL: ledger_postings is append-only...` — and the attempt itself gets logged to `audit_logs` automatically. Show that log entry afterward in Admin Console → Audit.

## Priority 4 — MODIFICATION (schema-level)

No UI, obviously — this is DDL, not data. Live and safe, in the terminal:
```bash
docker exec ledgercore-postgres-1 psql -U postgres -d ledgercore -c "ALTER TABLE accounts ADD COLUMN demo_note TEXT;"
docker exec ledgercore-postgres-1 psql -U postgres -d ledgercore -c "\d accounts"
docker exec ledgercore-postgres-1 psql -U postgres -d ledgercore -c "ALTER TABLE accounts DROP COLUMN demo_note;"
```
Adds a real column, shows it in the table structure, drops it again — fully reversible, zero risk to your data. If asked for a *permanent* real example instead of a live one: `db/migrations/007_fx_rates.sql` adds `fx_rate_applied`/`source_currency`/`target_currency` to `journal_entries` after that table already existed and had data.

---

## Everything else

| Feature | How to show it |
|---|---|
| FX transfer | Open an account → **"FX transfer"** → type a different-currency account's number |
| Idempotency | After any "Send money", the modal shows a **"Replay same request"** button — click it, same journal ID comes back, HTTP 200 not 201, no money moved twice |
| Live-updating statement | Open an account, leave it open, send money from another tab — the "Live feed" toggle polls every 5s and the new row flashes in |
| Cache-aside balance | The balance panel shows **"served from Redis cache"** or **"served from PostgreSQL"** depending on whether it was just read |
| Fraud detection | Send 6+ rapid small transfers from one account, then Admin Console → **Fraud** tab shows the `HIGH_VELOCITY` flag |
| Reconciliation | Admin Console → **Reconciliation** tab — shows every account's `MATCH`/`DRIFT` status |
| Settlement chart | Admin Console → **Overview** tab — bar chart from `mv_daily_settlement` |
| Audit trail | Admin Console → **Audit** tab — every status change, KYC change, and blocked tampering attempt, logged automatically |
| Row-Level Security | Log in as two different customers in two browser windows — neither can see the other's accounts, with no `WHERE user_id` filter written anywhere in the frontend; the database itself refuses the rows |
| Deadlock-free concurrency | `python3 db/benchmarks/concurrency_stress_test.py --accounts 10 --workers 50 --duration 15` — run this in a separate terminal as your closing "proof" moment |

---

## If asked "what's the point of this project"

One sentence: **a database that makes incorrect financial state structurally impossible, not just unlikely** — money can't be created, destroyed, double-spent under concurrency, double-charged on retry, or silently rewritten in history, and every one of those guarantees lives in PostgreSQL itself (constraints, triggers, row locking), not in application code that could have a bug. The dashboard and API exist only to prove the database design holds up under real, live use — not the other way around.
