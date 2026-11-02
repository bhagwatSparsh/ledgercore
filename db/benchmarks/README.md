# Phase 8 Benchmarks

Two independent claims about this system are backed by real, captured evidence here rather than assertion:

## 1. Deadlock-free concurrency under contention

**Script:** `concurrency_stress_test.py`
**Claim:** because `process_transfer()` always locks the two accounts involved in a transfer in a fixed order (lower `account_id` first, `SELECT ... FOR UPDATE`), two concurrent transfers can never form a circular wait, so Postgres should report **zero** deadlocks no matter how hard the system is hammered.

**How it's tested:** a deliberately adversarial setup — a *small* shared pool of accounts (10–20) hit by 50–100 concurrent threads, each firing random transfers between random pairs in that pool as fast as possible. A small pool with many workers maximizes lock collisions; this is the access pattern most likely to deadlock a naively-written transfer function.

**Results obtained (see `stress_test_results.txt`):**
| Run | Accounts | Workers | Duration | Successful transfers | Deadlocks | Other errors | Money conserved | Accounts negative |
|---|---|---|---|---|---|---|---|---|
| 1 | 10 | 50 | 15s | 10,556 | **0** | **0** | exact | 0 |
| 2 | 20 | 100 | 20s | 14,342 | **0** | **0** | exact | 0 |

After each run, every account's `cached_balance_minor` is verified against `run_daily_reconciliation()` (which independently recomputes balances from ledger history) — zero drift both times. Total money in the pool before and after is checked bit-for-bit, not approximately.

Run it yourself:
```bash
python3 concurrency_stress_test.py --accounts 20 --workers 100 --duration 20
```

## 2. Indexing a real query, measured, not assumed

**Claim:** a compliance/AML-style report ("show every posting above amount X") had no supporting index and degenerated into a full scan of every monthly partition of `ledger_postings`. Adding one index fixes it, and partitioning doesn't break the fix for future partitions.

**Query benchmarked** (320 matching rows out of 277,544 — a realistic, selective "large transactions" report):
```sql
SELECT posting_id, account_id, amount_minor, created_at
FROM ledger_postings
WHERE amount_minor > 1900000
ORDER BY amount_minor DESC;
```

**Before** (`explain_before_index.txt`): `Parallel Seq Scan` on all 10 monthly partitions, `shared hit=3902` buffers, **15.470 ms** execution.

**After** (`explain_after_index.txt`, migration `019_amount_index_benchmark.sql` applied): `Bitmap Heap Scan` / `Index Scan Backward` using a new per-partition index on every partition, `shared hit=87 read=3` buffers, **0.495 ms** execution.

**~31x faster, ~45x fewer buffer reads.**

The index was created with a single `CREATE INDEX ... ON ledger_postings (amount_minor)` directly on the *parent* partitioned table — Postgres automatically built it on all 10 existing partitions, and (unlike a plain table) will automatically attach it to every future monthly partition created by `create_monthly_ledger_partition()`, so this fix needs zero ongoing maintenance.
