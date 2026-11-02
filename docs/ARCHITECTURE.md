# LedgerCore — Architecture & Design Rationale

This document goes one level deeper than the root README: *why* the schema and concurrency model look the way they do, and — because this was built with continuous live testing against a running database rather than written once and assumed correct — the genuine, non-obvious bugs that live testing surfaced, in the order they were found.

## 1. Schema design

### Money as BIGINT minor units, never float

Every amount column (`amount_minor`, `cached_balance_minor`, ...) is a `BIGINT` counted in the currency's smallest unit (paise, cents). Floating point cannot represent most decimal fractions exactly, so repeated arithmetic on `FLOAT`/`DOUBLE` money values eventually drifts by fractions of a cent — intolerable in a ledger where the zero-sum invariant is checked exactly. The *only* place a minor-unit integer becomes a decimal string is the final UI render (`frontend/src/utils/money.ts`), never in a calculation.

### Double-entry: header + immutable legs

- `journal_entries` is the transaction header (what happened, when, by whom).
- `ledger_postings` holds the individual debit/credit legs. A transfer between two accounts in the same currency produces exactly two postings (one DEBIT, one CREDIT) that must sum to zero; a cross-currency FX transfer produces four (two per currency, routed through a system clearing account) so the zero-sum invariant holds *per currency*, not just in aggregate.
- `ledger_postings` is append-only by design: a `BEFORE UPDATE OR DELETE` trigger (`prevent_ledger_tampering()`) rejects any attempt to alter history, logging the blocked attempt to `audit_logs` first. Corrections are new reversal entries, exactly like a real accounting ledger.

### Why `account_limits` is a separate table from `accounts`

Splitting daily/per-transaction limits into their own table, rather than extra columns on `accounts`, avoids lock contention between limit-management writes (an admin adjusting someone's daily limit) and the hot transfer-locking path (`SELECT ... FOR UPDATE` on `accounts` during every transfer). Two different access patterns, two different tables, no shared row lock between them.

### Partitioning

`ledger_postings` is `PARTITION BY RANGE (created_at)`, monthly. A helper function creates future partitions ahead of need (and the worker's `partitionMaintenance` job calls it daily). Migration 019's benchmark specifically proves this partitioning doesn't complicate indexing: an index created on the *parent* table automatically propagates to every existing partition and attaches to every future one created through the normal partition-creation path.

## 2. Concurrency control

### Deadlock-free locking by construction

`process_transfer()`, `process_fx_transfer()`, `process_withdrawal()`, and `process_deposit()` all lock the accounts they touch with `SELECT ... FOR UPDATE`, **always in ascending `account_id` order** regardless of which account is sender or receiver. If every transaction acquires locks in the same global order, a circular wait — the structural precondition for a deadlock — is impossible. This isn't "retried until it works"; it's "cannot happen," and `db/benchmarks/concurrency_stress_test.py` deliberately maximizes lock contention (many threads, a tiny shared account pool) to try to prove that wrong. It hasn't.

### Idempotency: surviving client retries

A client that times out waiting for a transfer response and retries must never cause the money to move twice. `idempotency_keys` tracks each key through `PROCESSING → COMPLETED` or `FAILED`:
- A new key inserts a `PROCESSING` row, then attempts the transfer.
- A retry with the **same key and same request body** while the original is `COMPLETED` replays the cached response (HTTP 200, not 201) — proven live via the dashboard's "replay same request" button, which calls the exact same endpoint with the exact same key and gets back the *same* `journal_id* without moving money again.
- A retry with the same key but a **different** request body is rejected outright (409) — reusing a key for a different transfer is treated as a client bug, not silently allowed.
- A retry while the original is still `PROCESSING` (a genuine concurrent duplicate, not a sequential retry) is rejected rather than raced.
- If `process_transfer()` raises (insufficient funds, frozen account, ...), a `SAVEPOINT` taken just before the call means only that call's work rolls back — the `PROCESSING` row inserted earlier in the same transaction survives to be marked `FAILED`, instead of the whole transaction aborting and masking the real error behind a generic 500.

### Transactional outbox

Notification-worthy events are written to `outbox_events` in the *same database transaction* as the ledger posting that caused them. A separate worker polls and dispatches (`FOR UPDATE SKIP LOCKED`, safe even if multiple worker instances ever run). This guarantees "the event for this transfer will eventually be sent" without a distributed transaction: either the whole posting+event insert commits together, or neither does.

## 3. Security model: RLS + `SECURITY DEFINER`, and why that combination is subtle

Every table has Row-Level Security policies keyed off two session-scoped settings — `app.session_role` and `app.current_user_id` — set per-request via `SELECT set_config('app.session_role', $1, true)` (the `true` argument scopes it to the current transaction, which matters enormously under connection pooling: without it, a setting from one request could leak into the next request that happens to reuse the same pooled connection).

The subtlety: several operations legitimately need to act *across* RLS boundaries — looking up a user by email before their identity is known (login), resolving a stranger's account number to its id for a transfer, refreshing a materialized view that requires Postgres object ownership RLS knows nothing about. These use `SECURITY DEFINER` functions, which run with the *function owner's* privileges rather than the caller's. That's the correct tool — but it has a sharp edge documented below (bug #8), which is exactly the kind of interaction that's easy to get subtly wrong and only live testing reliably catches.

## 4. Bugs found and fixed during development

Every item below was found by *running the actual system* — a live SQL smoke test, a real HTTP request against the running API, or the React dashboard rendering real data — not by code review alone. That's deliberate: this class of bug (RLS × SECURITY DEFINER × connection pooling × deferred triggers) does not reliably show up by reading the code.

| # | Bug | How it was found | Fix |
|---|---|---|---|
| 1 | `current_role` is a reserved PostgreSQL keyword | Migration failed on apply | Renamed the RLS session variable to `app.session_role` |
| 2 | Ambiguous column reference + type mismatch in `run_daily_reconciliation()` | Function call errored | Renamed the `OUT` parameter, added an explicit `::TEXT` cast |
| 3 | Mock-data and early code paths wrote `accounts.cached_balance_minor` directly, bypassing the ledger entirely | Manual review during Phase 3 — balances with no corresponding postings | Built `process_deposit()`/`process_withdrawal()` as the *only* sanctioned way to fund an account; mock data generator rewritten to call them |
| 4 | Mock data generator could spend more than an account's simulated balance | Generated transfers failed `Insufficient funds` mid-run | Added Python-side balance tracking before emitting each transfer |
| 5 | Mock data generator assigned overlapping timestamps across accounts | Reconciliation showed spurious drift | Non-overlapping time windows per account, transfers sorted chronologically before bulk load |
| 6 | `SET LOCAL app.session_role = $1` — `SET LOCAL` doesn't accept bind parameters | Query threw a syntax error | Switched to `SELECT set_config('app.session_role', $1, true)` everywhere |
| 7 | `INSERT ... RETURNING` on `/auth/register` returned nothing | RLS's `SELECT` policy evaluates against the row being returned too, and at registration time `app.current_user_id` isn't set yet, so `users_self_select` matched nothing | Registration runs with `role: "admin"` session context |
| 8 | **Real security hole**: making `process_transfer()` `SECURITY DEFINER` (needed to resolve a stranger's account) silently removed RLS's *accidental* enforcement that a sender could only transfer from their own account | Deliberately tested: could user B drain user A's account by calling the function with A's `account_id`? Yes, until fixed | Added an explicit `IF v_sender.user_id <> p_initiated_by THEN RAISE EXCEPTION ...` ownership check inside every `SECURITY DEFINER` money-movement function — the real authorization boundary, once RLS's incidental protection is bypassed by design |
| 9 | The zero-sum `DEFERRABLE INITIALLY DEFERRED` constraint trigger fires at `COMMIT` time, *after* a `SECURITY DEFINER` caller has already returned and its elevated privilege context has ended | Deferred trigger failed RLS checks only at commit, intermittently, depending on what ran afterward | Made `check_journal_balance()` itself `SECURITY DEFINER` |
| 10 | A failed `process_transfer()` call aborted the *entire* enclosing transaction, including the idempotency-key bookkeeping meant to record the failure | API returned a generic 500 instead of the real rejection reason | `SAVEPOINT before_transfer` / `ROLLBACK TO SAVEPOINT` around the call in `transfers.ts` |
| 11 | `GET /beneficiaries` returned an empty list for every user with saved beneficiaries | RLS correctly hides a beneficiary's *own* account row from the viewer (it belongs to someone else), so a plain `JOIN accounts` silently dropped every row | Added `get_account_public_info()`, a narrow `SECURITY DEFINER` function exposing only account number + currency, called via `CROSS JOIN LATERAL` |
| 12 | `REFRESH MATERIALIZED VIEW` requires the calling *Postgres role* to own the object — a privilege check entirely separate from the `app.session_role='admin'` RLS context | Worker's settlement refresh job failed | `refresh_daily_settlement()` SECURITY DEFINER wrapper, same pattern as #8/#9 |
| 13 | `reconciliation_logs` had a `SELECT` policy for staff but no `INSERT` policy at all — the nightly job's own write to its own audit table was rejected | First real (non-superuser) run of the worker's reconciliation job | `run_daily_reconciliation()` made `SECURITY DEFINER` |
| 14 | A real-world "large transactions" compliance query degenerated into a full parallel sequential scan across every monthly partition | Deliberate `EXPLAIN ANALYZE` benchmark (Phase 8) | Added an index on `amount_minor` *on the parent partitioned table*, confirmed it auto-propagated to all partitions: 15.47ms → 0.495ms |
| 15 | React admin console: "Encountered two children with the same key" console warning on the Reconciliation tab | Caught running a headless-browser pass over the dashboard, not by inspection | The admin API's reconciliation query could return more than one row per account if reconciliation had been re-run manually on the same day; rewrote it with `DISTINCT ON (account_id) ... ORDER BY created_at DESC` to return each account's single most recent result, and exposed the real `recon_id` primary key as the React list key instead of the non-unique `account_id` |
| 16 | Fraud flag `detail` is a JSONB object; the dashboard's type declared it as `string` and rendered it directly — would have crashed React ("Objects are not valid as a React child") the first time a real fraud flag was displayed | Caught before it shipped, while wiring up the Fraud tab against live data | Typed `detail` correctly as `Record<string, unknown>` and added a small formatter instead of rendering the raw object |
| 17 | Fraud velocity detection permanently flagged the system's own clearing/external accounts as "high velocity" — they legitimately touch *every* deposit, withdrawal, and FX conversion in the system by design | Reviewing real output on the Fraud tab after a concurrency stress test | `detect_fraud_velocity()` now excludes accounts owned by the reserved system user; in a real deployment this is the difference between a fraud queue analysts trust and one they learn to ignore |
| 18 | Admin reconciliation table hardcoded the INR symbol for every row regardless of the account's actual currency | Code review while fixing #15/#17 | API now returns each account's real `currency`; the dashboard formats accordingly |
| 19 | The "send money" modal auto-closed ~900ms after a successful transfer, which meant the idempotency-replay demo button was rendered but never actually clickable | A scripted browser test clicked "Send", waited, then couldn't find the replay button — it had already vanished | Removed the auto-close; the modal now stays open on success with explicit "Replay" and "Done" actions, so the idempotency guarantee can actually be demonstrated, not just coded |

## 5. What was deliberately left out of scope

- **No real payment rails** — deposits/withdrawals simulate external money movement via a system "external account," which is the standard way to demo a ledger's internal correctness without needing a live banking integration.
- **No multi-region/replication** — the concurrency and locking story here is about a single primary Postgres instance; horizontal scaling (read replicas, sharding) is a different and separable problem from the one this project demonstrates.
- **Fixed, seeded FX rates** rather than a live rate feed — the point being demonstrated is the *accounting* correctness of multi-currency transfers (independent per-currency zero-sum), not rate-sourcing.
