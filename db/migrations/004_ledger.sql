-- =====================================================================
-- 004_ledger.sql
-- The core double-entry ledger: journal_entries + ledger_postings
--
-- journal_entries  = one row per transaction EVENT (the "receipt header")
-- ledger_postings   = the individual debit/credit LEGS of that event
--                      (the "receipt line items") -- APPEND-ONLY, enforced
--                      by a trigger in 010_functions_triggers.sql
--
-- A transfer of 500 from Account A to Account B creates:
--   1 journal_entries row
--   2 ledger_postings rows: (A, DEBIT, 500) and (B, CREDIT, 500)
-- The invariant SUM(debits) = SUM(credits) per journal_id is enforced by
-- a deferred constraint trigger, not just application code.
-- =====================================================================

CREATE TABLE journal_entries (
    journal_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key  UUID UNIQUE,                 -- NULL allowed for system-generated entries
    entry_type       VARCHAR(20) NOT NULL
                     CHECK (entry_type IN ('TRANSFER', 'DEPOSIT', 'WITHDRAWAL', 'FX_CONVERSION', 'FEE', 'REVERSAL')),
    description      TEXT,
    initiated_by     UUID REFERENCES users(user_id),  -- who triggered it (NULL = system job)
    status           VARCHAR(20) NOT NULL DEFAULT 'POSTED'
                     CHECK (status IN ('POSTED', 'REVERSED')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_journal_entries_initiated_by ON journal_entries(initiated_by);

-- ---------------------------------------------------------------------
-- ledger_postings: partitioned by month on created_at.
--
-- Why partition: this table grows forever (every money movement, ever).
-- Range partitioning means a query scoped to "this month's postings for
-- account X" only touches one small partition instead of scanning the
-- entire history, and old partitions can be detached/archived in O(1)
-- instead of running a slow DELETE over millions of rows.
-- ---------------------------------------------------------------------
CREATE TABLE ledger_postings (
    posting_id    UUID NOT NULL DEFAULT gen_random_uuid(),
    journal_id    UUID NOT NULL REFERENCES journal_entries(journal_id),
    account_id    UUID NOT NULL REFERENCES accounts(account_id),
    direction     VARCHAR(6) NOT NULL CHECK (direction IN ('DEBIT', 'CREDIT')),
    amount_minor  BIGINT NOT NULL CHECK (amount_minor > 0),
    currency      CHAR(3) NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (posting_id, created_at)      -- partition key must be part of the PK
) PARTITION BY RANGE (created_at);

-- Composite index used by the passbook view and account-history lookups.
-- Created on the parent so every partition inherits it automatically.
CREATE INDEX idx_ledger_postings_account_created ON ledger_postings (account_id, created_at);
CREATE INDEX idx_ledger_postings_journal ON ledger_postings (journal_id);

-- Initial partitions: current month and next 2 months, so the project
-- works out of the box. db/scripts/create_partition.sql / the worker's
-- scheduled job creates future partitions before they're needed.
CREATE TABLE ledger_postings_2026_10 PARTITION OF ledger_postings
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE ledger_postings_2026_11 PARTITION OF ledger_postings
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE ledger_postings_2026_12 PARTITION OF ledger_postings
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- Helper so new partitions can be created ahead of time (called monthly
-- by the worker's cron job -- see worker/src/jobs/partitionMaintenance.ts).
CREATE OR REPLACE FUNCTION create_monthly_ledger_partition(target_month DATE)
RETURNS VOID AS $$
DECLARE
    partition_name TEXT := 'ledger_postings_' || to_char(target_month, 'YYYY_MM');
    start_date DATE := date_trunc('month', target_month);
    end_date   DATE := start_date + INTERVAL '1 month';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = partition_name) THEN
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF ledger_postings FOR VALUES FROM (%L) TO (%L)',
            partition_name, start_date, end_date
        );
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- balance_snapshots: daily materialized cache per account.
-- Used by the reconciliation job: it recomputes the true balance from
-- ledger_postings and compares it against both this snapshot and
-- accounts.cached_balance_minor to detect drift.
-- ---------------------------------------------------------------------
CREATE TABLE balance_snapshots (
    account_id       UUID NOT NULL REFERENCES accounts(account_id),
    snapshot_date    DATE NOT NULL,
    closing_balance_minor BIGINT NOT NULL,
    last_posting_id  UUID,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, snapshot_date)
);

CREATE INDEX idx_balance_snapshots_date ON balance_snapshots(snapshot_date);
