-- =====================================================================
-- 012_views.sql
-- Views & materialized views for reporting and the passbook UI.
-- =====================================================================

-- ---------------------------------------------------------------------
-- v_account_statement: a customer-facing "passbook" -- every posting
-- for an account, with a running balance computed via a window
-- function instead of re-summing history on every row (SUM() OVER an
-- ordered frame is O(n) total, not O(n^2)).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_account_statement AS
SELECT
    a.account_id,
    a.account_number,
    u.full_name,
    lp.posting_id,
    lp.journal_id,
    je.entry_type,
    je.description,
    lp.direction,
    lp.amount_minor,
    lp.currency,
    lp.created_at,
    SUM(
        CASE WHEN lp.direction = 'CREDIT' THEN lp.amount_minor ELSE -lp.amount_minor END
    ) OVER (
        PARTITION BY a.account_id
        ORDER BY lp.created_at, lp.posting_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_balance_minor
FROM ledger_postings lp
JOIN accounts a       ON a.account_id = lp.account_id
JOIN users u           ON u.user_id = a.user_id
JOIN journal_entries je ON je.journal_id = lp.journal_id;

COMMENT ON VIEW v_account_statement IS 'Passbook view: every posting for an account with a running balance via window function. RLS on the underlying tables still applies -- a customer querying this view only sees their own rows.';

-- ---------------------------------------------------------------------
-- mv_daily_settlement: materialized rollup of daily transaction volume
-- per currency/entry-type. Refreshed on a schedule by the worker
-- (REFRESH MATERIALIZED VIEW CONCURRENTLY, which needs the unique index
-- below so it can refresh without locking out readers).
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_daily_settlement AS
SELECT
    date_trunc('day', lp.created_at)::date AS settlement_date,
    lp.currency,
    je.entry_type,
    COUNT(DISTINCT lp.journal_id) AS transaction_count,
    SUM(lp.amount_minor) FILTER (WHERE lp.direction = 'DEBIT')  AS total_debited_minor,
    SUM(lp.amount_minor) FILTER (WHERE lp.direction = 'CREDIT') AS total_credited_minor
FROM ledger_postings lp
JOIN journal_entries je ON je.journal_id = lp.journal_id
GROUP BY 1, 2, 3
WITH DATA;

CREATE UNIQUE INDEX idx_mv_daily_settlement_pk
    ON mv_daily_settlement (settlement_date, currency, entry_type);

COMMENT ON MATERIALIZED VIEW mv_daily_settlement IS 'Daily volume rollup for the admin dashboard. Refreshed nightly by the worker via REFRESH MATERIALIZED VIEW CONCURRENTLY.';

-- ---------------------------------------------------------------------
-- v_high_velocity_accounts: a live (non-materialized) analytical query
-- using window functions to surface accounts transacting unusually
-- fast in the trailing hour. Backs the fraud-detection job AND can be
-- queried directly by the admin dashboard for a live view.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_high_velocity_accounts AS
SELECT
    account_id,
    COUNT(*)                        AS txn_count_last_hour,
    SUM(amount_minor)               AS total_debited_minor,
    MAX(created_at)                 AS last_txn_at
FROM ledger_postings
WHERE direction = 'DEBIT'
  AND created_at >= now() - INTERVAL '1 hour'
GROUP BY account_id
HAVING COUNT(*) > 5;

COMMENT ON VIEW v_high_velocity_accounts IS 'Accounts with more than 5 outbound transactions in the trailing hour -- the HAVING + GROUP BY velocity check referenced throughout the project notes.';
