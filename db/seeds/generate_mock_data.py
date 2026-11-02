#!/usr/bin/env python3
"""
generate_mock_data.py -- bulk mock-data generator for LedgerCore.

Strategy
--------
Running 100k+ transfers through process_transfer() one call at a time
would be realistic but slow (every call takes a row lock and fires
triggers individually) -- fine for the live demo path, bad for building
a benchmarking dataset. So this script generates HISTORICAL data two
ways:

  1. Users / accounts / limits -- bulk-inserted directly (no ledger
     involvement yet).
  2. Journal entries + ledger postings -- the per-row triggers
     (apply_posting_to_balance, check_journal_balance) are temporarily
     DISABLED, the postings are loaded via COPY (the fastest path
     Postgres offers), and then:
       - accounts.cached_balance_minor is recomputed in one bulk UPDATE
         from the actual posting history (so every account is correct,
         not just trusted).
       - triggers are re-enabled.

This is a standard, defensible technique for seeding/backfilling a
ledger-style table: disable the row-by-row triggers for the bulk load,
then recompute the derived state once at the end. It's documented here
rather than hidden because "when is it OK to bypass your own triggers"
is itself a real engineering judgment call worth being explicit about.

Usage:
    python3 generate_mock_data.py --accounts 3000 --transfers 100000
"""

import argparse
import io
import random
import uuid
import time
from datetime import datetime, timedelta, timezone

import psycopg2
from psycopg2.extras import execute_values
from faker import Faker

fake = Faker()

CURRENCIES = ["INR", "INR", "INR", "USD", "USD", "EUR"]  # weighted: mostly INR

import os
DB_DSN = os.environ.get(
    "LEDGERCORE_DSN",
    "dbname=ledgercore user=postgres password=postgres host=localhost port=5432",
)


def connect():
    conn = psycopg2.connect(DB_DSN)
    conn.autocommit = False
    return conn


def get_external_account_ids(cur):
    cur.execute("SELECT account_number, account_id FROM accounts WHERE account_number LIKE 'SYS-EXT-%'")
    return {row[0].replace("SYS-EXT-", ""): row[1] for row in cur.fetchall()}


def generate_users_and_accounts(cur, n_accounts):
    """Bulk-create users (1 account each, simplest model) and accounts."""
    print(f"Generating {n_accounts} users + accounts ...")
    users = []
    accounts = []
    limits = []
    for _ in range(n_accounts):
        uid = uuid.uuid4()
        aid = uuid.uuid4()
        currency = random.choice(CURRENCIES)
        users.append((
            str(uid), fake.name(), fake.unique.email(), fake.phone_number()[:20],
            "demo_hash_not_a_real_password", "VERIFIED", True,
        ))
        accounts.append((
            str(aid), str(uid), f"ACC{fake.unique.random_number(digits=10, fix_len=True)}",
            random.choice(["SAVINGS", "SAVINGS", "CURRENT", "WALLET"]), currency, 0, "ACTIVE",
        ))
        limits.append((str(aid), 5_000_000, 2_500_000))

    execute_values(cur, """
        INSERT INTO users (user_id, full_name, email, phone, password_hash, kyc_status, is_active)
        VALUES %s
    """, users)

    execute_values(cur, """
        INSERT INTO accounts (account_id, user_id, account_number, account_type, currency, cached_balance_minor, status)
        VALUES %s
    """, accounts)

    execute_values(cur, """
        INSERT INTO account_limits (account_id, daily_limit_minor, per_txn_limit_minor)
        VALUES %s
    """, limits)

    return [(a[0], a[4]) for a in accounts]  # [(account_id, currency), ...]


def disable_hot_triggers(cur):
    cur.execute("ALTER TABLE ledger_postings DISABLE TRIGGER trg_apply_posting_to_balance;")
    cur.execute("ALTER TABLE ledger_postings DISABLE TRIGGER trg_check_journal_balance;")


def enable_hot_triggers(cur):
    cur.execute("ALTER TABLE ledger_postings ENABLE TRIGGER trg_apply_posting_to_balance;")
    cur.execute("ALTER TABLE ledger_postings ENABLE TRIGGER trg_check_journal_balance;")


def random_timestamp_within(min_days_back, max_days_back):
    """Random timestamp between (now - max_days_back) and (now - min_days_back)."""
    delta = timedelta(
        days=random.randint(min_days_back, max_days_back),
        hours=random.randint(0, 23),
        minutes=random.randint(0, 59),
        seconds=random.randint(0, 59),
    )
    return datetime.now(timezone.utc) - delta


def bulk_copy_postings(cur, rows):
    """rows: list of (posting_id, journal_id, account_id, direction, amount_minor, currency, created_at)"""
    buf = io.StringIO()
    for r in rows:
        buf.write("\t".join(str(x) for x in r) + "\n")
    buf.seek(0)
    cur.copy_expert(
        "COPY ledger_postings (posting_id, journal_id, account_id, direction, amount_minor, currency, created_at) "
        "FROM STDIN WITH (FORMAT text)",
        buf,
    )


def generate_deposits(cur, accounts, ext_accounts, days_back=90):
    """Every account's very first posting: funded from the external clearing account.
    Returns {account_id: running_balance} so the transfer generator can
    stay solvent (never debit more than an account actually has)."""
    print(f"Generating {len(accounts)} initial deposits ...")
    journal_rows = []
    posting_rows = []
    balances = {}
    for account_id, currency in accounts:
        jid = uuid.uuid4()
        # Strictly older than the entire transfer window (0..days_back) below,
        # so a deposit can never be timestamped after one of its own account's
        # transfers -- which would make the passbook's running-balance window
        # function dip negative even though the final balance is correct.
        ts = random_timestamp_within(days_back + 15, days_back + 45)
        amount = random.randint(10_000, 20_000_00)  # 100.00 to 200,000.00 in minor units
        journal_rows.append((str(jid), "DEPOSIT", "Initial account funding", None, "POSTED", ts))
        posting_rows.append((str(uuid.uuid4()), str(jid), str(ext_accounts[currency]), "DEBIT", amount, currency, ts))
        posting_rows.append((str(uuid.uuid4()), str(jid), account_id, "CREDIT", amount, currency, ts))
        balances[account_id] = amount

    execute_values(cur, """
        INSERT INTO journal_entries (journal_id, entry_type, description, initiated_by, status, created_at)
        VALUES %s
    """, journal_rows)

    bulk_copy_postings(cur, posting_rows)
    return balances


MIN_AFFORDABLE_BALANCE = 10_00  # 10.00 in minor units -- below this, account sits out as a sender this round

def generate_transfers(cur, accounts, balances, n_transfers, days_back=90):
    """
    Generates transfers while tracking each account's running balance in
    `balances` (mutated in place), so a sender is never asked to debit
    more than it actually has at that point in the simulated timeline.
    Amount is capped at a fraction of the sender's current balance,
    which also produces a more realistic distribution than pure random
    amounts (most transfers are small relative to someone's balance,
    occasionally someone sends a big chunk).

    Timestamps are pre-generated and sorted ascending, then handed out
    in that order as transfers are generated -- so Python's
    generation-order balance bookkeeping matches chronological order.
    Otherwise a transfer could be assigned an early timestamp while
    being generated (and balance-checked) as if it happened later,
    which would make the passbook's running-balance window function
    show a dip below zero at some point even though the final balance
    is correct.
    """
    print(f"Generating {n_transfers} transfers ...")
    by_currency = {}
    for account_id, currency in accounts:
        by_currency.setdefault(currency, []).append(account_id)

    timestamps = sorted(random_timestamp_within(0, days_back) for _ in range(n_transfers))

    journal_rows = []
    posting_rows = []
    batch_size = 20_000
    inserted = 0
    skipped = 0

    for i in range(n_transfers):
        currency = random.choice(list(by_currency.keys()))
        pool = [a for a in by_currency[currency] if balances.get(a, 0) > MIN_AFFORDABLE_BALANCE]
        if len(pool) < 2:
            skipped += 1
            continue

        sender = random.choice(pool)
        receiver_pool = [a for a in by_currency[currency] if a != sender]
        receiver = random.choice(receiver_pool)

        max_affordable = balances[sender]
        # Send somewhere between 1% and 40% of current balance, capped at 5,000.00 minor units.
        amount = min(int(max_affordable * random.uniform(0.01, 0.40)), 500_000)
        amount = max(amount, 1)  # always at least the smallest unit
        if amount > max_affordable:
            amount = max_affordable

        ts = timestamps[i]
        jid = uuid.uuid4()

        journal_rows.append((str(jid), "TRANSFER", fake.sentence(nb_words=4), None, "POSTED", ts))
        posting_rows.append((str(uuid.uuid4()), str(jid), sender, "DEBIT", amount, currency, ts))
        posting_rows.append((str(uuid.uuid4()), str(jid), receiver, "CREDIT", amount, currency, ts))

        balances[sender] -= amount
        balances[receiver] = balances.get(receiver, 0) + amount

        if len(journal_rows) >= batch_size:
            execute_values(cur, """
                INSERT INTO journal_entries (journal_id, entry_type, description, initiated_by, status, created_at)
                VALUES %s
            """, journal_rows)
            bulk_copy_postings(cur, posting_rows)
            inserted += len(journal_rows)
            print(f"  ... {inserted}/{n_transfers} transfers inserted")
            journal_rows, posting_rows = [], []

    if journal_rows:
        execute_values(cur, """
            INSERT INTO journal_entries (journal_id, entry_type, description, initiated_by, status, created_at)
            VALUES %s
        """, journal_rows)
        bulk_copy_postings(cur, posting_rows)

    if skipped:
        print(f"  (skipped {skipped} rounds where fewer than 2 solvent accounts were available for that currency)")


def recompute_balances(cur):
    """
    Adds each account's net posting delta (DEBIT -> subtract, CREDIT ->
    add) on top of its EXISTING cached_balance_minor, rather than
    overwriting it. This matters for the system accounts (SYS-EXT-*,
    SYS-CLR-*), which carry an administratively-seeded treasury float
    that is not itself backed by a ledger posting -- overwriting with a
    pure ledger-sum would silently discard that float and push the
    account negative. Real customer accounts start at 0 anyway, so
    additive vs. overwrite makes no difference for them.
    """
    print("Recomputing accounts.cached_balance_minor from ledger history ...")
    cur.execute("""
        UPDATE accounts a
        SET cached_balance_minor = a.cached_balance_minor + sub.balance_delta,
            updated_at = now()
        FROM (
            SELECT account_id,
                   COALESCE(SUM(CASE WHEN direction = 'CREDIT' THEN amount_minor ELSE -amount_minor END), 0) AS balance_delta
            FROM ledger_postings
            GROUP BY account_id
        ) sub
        WHERE a.account_id = sub.account_id;
    """)


def ensure_future_partitions(cur, months_back=6, months_forward=3):
    """Historical data goes back in time; also make sure the next couple
    of months forward exist so live demo transfers after seeding work."""
    today = datetime.now(timezone.utc).date().replace(day=1)
    # Step by calendar months precisely (no day-count drift).
    y, m = today.year, today.month
    start_index = -months_back
    end_index = months_forward
    for offset in range(start_index, end_index + 1):
        total = (y * 12 + (m - 1)) + offset
        year = total // 12
        month = total % 12 + 1
        cur.execute("SELECT create_monthly_ledger_partition(%s)", (f"{year:04d}-{month:02d}-01",))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--accounts", type=int, default=3000)
    parser.add_argument("--transfers", type=int, default=100_000)
    parser.add_argument("--days-back", type=int, default=90)
    args = parser.parse_args()

    conn = connect()
    cur = conn.cursor()

    t0 = time.time()
    try:
        ensure_future_partitions(cur)
        ext_accounts = get_external_account_ids(cur)
        accounts = generate_users_and_accounts(cur, args.accounts)
        conn.commit()

        disable_hot_triggers(cur)
        balances = generate_deposits(cur, accounts, ext_accounts, args.days_back)
        generate_transfers(cur, accounts, balances, args.transfers, args.days_back)
        enable_hot_triggers(cur)
        recompute_balances(cur)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()

    elapsed = time.time() - t0
    total_postings = args.accounts * 2 + args.transfers * 2
    print(f"\nDone in {elapsed:.1f}s. ~{total_postings:,} ledger_postings rows, "
          f"{args.accounts:,} accounts, {args.transfers:,} transfers.")


if __name__ == "__main__":
    main()
