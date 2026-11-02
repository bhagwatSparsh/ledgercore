#!/usr/bin/env python3
"""
concurrency_stress_test.py -- proves the deadlock-free locking claim.

Spawns many threads, each repeatedly firing transfers between a SMALL
shared pool of accounts (so collisions are frequent and likely --
that's the point: a naive implementation would deadlock constantly
under this access pattern). Each call goes through process_transfer(),
which locks both accounts in a deterministic (sorted-by-id) order.

After the run, three things are verified:
  1. Zero Postgres deadlock errors (error code 40P01) -- not "deadlocks
     happened but were retried", genuinely zero, because the locking
     order makes a circular wait impossible.
  2. Total money across the account pool is EXACTLY conserved -- no
     transfer can create or destroy money, so the pool's sum before and
     after must match to the paisa.
  3. No account went negative.

Usage:
    python3 concurrency_stress_test.py --accounts 10 --workers 50 --duration 15
"""

import argparse
import os
import random
import threading
import time
import uuid

import psycopg2

DB_DSN = os.environ.get(
    "LEDGERCORE_DSN",
    "dbname=ledgercore user=postgres password=postgres host=localhost port=5432",
)

stats_lock = threading.Lock()
stats = {"success": 0, "rejected_insufficient_funds": 0, "deadlocks": 0, "other_errors": 0}


def setup_pool(n_accounts: int, funding_minor: int = 10_000_00):
    """Creates a fresh, isolated pool of accounts just for this stress run,
    each funded identically via process_deposit() (never a direct column write)."""
    conn = psycopg2.connect(DB_DSN)
    conn.autocommit = True
    cur = conn.cursor()

    user_id = str(uuid.uuid4())
    cur.execute(
        "INSERT INTO users (user_id, full_name, email, phone, password_hash, kyc_status) "
        "VALUES (%s, 'Stress Test Pool Owner', %s, '0000000000', 'n/a', 'VERIFIED')",
        (user_id, f"stress-{user_id}@test.local"),
    )

    account_ids = []
    for i in range(n_accounts):
        account_id = str(uuid.uuid4())
        acc_number = f"STRESS{i:06d}{random.randint(1000,9999)}"
        cur.execute(
            "INSERT INTO accounts (account_id, user_id, account_number, currency) VALUES (%s, %s, %s, 'INR')",
            (account_id, user_id, acc_number),
        )
        cur.execute("INSERT INTO account_limits (account_id, daily_limit_minor) VALUES (%s, 999999999)", (account_id,))
        cur.execute("SELECT process_deposit(%s, %s, 'INR', %s)", (account_id, funding_minor, user_id))
        account_ids.append(account_id)

    cur.close()
    conn.close()
    return account_ids, user_id


def worker(account_ids, user_id, stop_at: float):
    conn = psycopg2.connect(DB_DSN)
    conn.autocommit = True
    cur = conn.cursor()
    while time.time() < stop_at:
        sender, receiver = random.sample(account_ids, 2)
        amount = random.randint(1, 500)  # small amounts, high contention
        idem_key = str(uuid.uuid4())
        try:
            cur.execute(
                "SELECT process_transfer(%s, %s, %s, 'INR', %s, %s, 'stress test')",
                (sender, receiver, amount, idem_key, user_id),
            )
            with stats_lock:
                stats["success"] += 1
        except psycopg2.errors.RaiseException as e:
            msg = str(e)
            if "Insufficient funds" in msg:
                with stats_lock:
                    stats["rejected_insufficient_funds"] += 1
            else:
                with stats_lock:
                    stats["other_errors"] += 1
                print(f"  unexpected RAISE: {msg.strip()}")
        except psycopg2.errors.DeadlockDetected:
            with stats_lock:
                stats["deadlocks"] += 1
        except Exception as e:
            with stats_lock:
                stats["other_errors"] += 1
            print(f"  unexpected error ({type(e).__name__}): {e}")
    cur.close()
    conn.close()


def verify(account_ids, funding_minor):
    conn = psycopg2.connect(DB_DSN)
    cur = conn.cursor()
    cur.execute(
        "SELECT account_id, cached_balance_minor FROM accounts WHERE account_id = ANY(%s::uuid[])",
        (account_ids,),
    )
    rows = dict(cur.fetchall())
    total = sum(rows.values())
    expected_total = funding_minor * len(account_ids)
    negative = [aid for aid, bal in rows.items() if bal < 0]

    # Also verify against the ledger directly (not just the cache), via reconciliation.
    cur.execute("SELECT out_account_id, recon_status FROM run_daily_reconciliation() WHERE out_account_id = ANY(%s::uuid[])", (account_ids,))
    recon = cur.fetchall()
    drifted = [r for r in recon if r[1] == "DRIFT"]

    cur.close()
    conn.close()
    return total, expected_total, negative, drifted


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--accounts", type=int, default=10)
    parser.add_argument("--workers", type=int, default=50)
    parser.add_argument("--duration", type=int, default=15, help="seconds")
    args = parser.parse_args()

    print(f"Setting up {args.accounts} freshly-funded accounts ...")
    funding_minor = 10_000_00
    account_ids, user_id = setup_pool(args.accounts, funding_minor)

    print(f"Launching {args.workers} concurrent worker threads for {args.duration}s, "
          f"all hammering the same {args.accounts} accounts ...")
    stop_at = time.time() + args.duration
    threads = [threading.Thread(target=worker, args=(account_ids, user_id, stop_at)) for _ in range(args.workers)]
    t0 = time.time()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.time() - t0

    print(f"\nCompleted in {elapsed:.1f}s.")
    print(f"  Successful transfers:          {stats['success']}")
    print(f"  Rejected (insufficient funds):  {stats['rejected_insufficient_funds']} (expected -- small pool, small balances)")
    print(f"  Deadlocks detected:              {stats['deadlocks']}  <-- should be ZERO")
    print(f"  Other/unexpected errors:         {stats['other_errors']}  <-- should be ZERO")
    print(f"  Throughput:                      {stats['success'] / elapsed:.1f} successful transfers/sec")

    print("\nVerifying money conservation and reconciliation ...")
    total, expected_total, negative, drifted = verify(account_ids, funding_minor)
    print(f"  Total in pool now:   {total}")
    print(f"  Total in pool before: {expected_total}")
    print(f"  Conserved exactly:    {total == expected_total}")
    print(f"  Accounts gone negative: {len(negative)}  <-- should be ZERO")
    print(f"  Accounts with ledger drift: {len(drifted)}  <-- should be ZERO")

    ok = (
        stats["deadlocks"] == 0
        and stats["other_errors"] == 0
        and total == expected_total
        and len(negative) == 0
        and len(drifted) == 0
    )
    print(f"\n{'PASS' if ok else 'FAIL'}: stress test {'succeeded' if ok else 'found a problem'}.")
    return 0 if ok else 1


if __name__ == "__main__":
    exit(main())
