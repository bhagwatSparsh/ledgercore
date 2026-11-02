-- =====================================================================
-- 013_fraud_and_reconciliation.sql
-- Scheduled analytical jobs, exposed as callable functions so the
-- worker process (or pg_cron, or a plain cron+psql call) can invoke
-- them on a schedule. Logic lives in the database; the scheduler is
-- just a trigger for "run this now".
-- =====================================================================

-- ---------------------------------------------------------------------
-- detect_fraud_velocity(): flags accounts with more debit transactions
-- than p_threshold within the trailing p_window_minutes. Avoids
-- re-flagging an account that already has an unresolved flag from the
-- same window, so repeated runs don't spam fraud_flags with duplicates.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION detect_fraud_velocity(
    p_window_minutes INT DEFAULT 60,
    p_threshold      INT DEFAULT 5
) RETURNS INT AS $$
DECLARE
    v_inserted INT;
BEGIN
    WITH velocity AS (
        SELECT account_id, COUNT(*) AS txn_count, MAX(created_at) AS last_txn_at
        FROM ledger_postings
        WHERE direction = 'DEBIT'
          AND created_at >= now() - (p_window_minutes || ' minutes')::interval
        GROUP BY account_id
        HAVING COUNT(*) > p_threshold
    ),
    to_flag AS (
        SELECT v.* FROM velocity v
        WHERE NOT EXISTS (
            SELECT 1 FROM fraud_flags f
            WHERE f.account_id = v.account_id
              AND f.rule_name = 'HIGH_VELOCITY'
              AND f.resolved = FALSE
              AND f.created_at >= now() - (p_window_minutes || ' minutes')::interval
        )
    )
    INSERT INTO fraud_flags (account_id, rule_name, detail, severity)
    SELECT
        account_id,
        'HIGH_VELOCITY',
        jsonb_build_object('transaction_count', txn_count, 'window_minutes', p_window_minutes, 'last_txn_at', last_txn_at),
        CASE WHEN txn_count > p_threshold * 2 THEN 'HIGH' ELSE 'MEDIUM' END
    FROM to_flag;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    RETURN v_inserted;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION detect_fraud_velocity IS 'Run periodically by the worker. Pure analytical SQL (window-adjacent GROUP BY/HAVING) -- no app-side loop over rows.';

-- ---------------------------------------------------------------------
-- run_daily_reconciliation(): recomputes each account's TRUE balance
-- from the append-only ledger_postings history, compares it against
-- the transactionally-maintained accounts.cached_balance_minor cache,
-- logs the result, and refreshes that day's balance_snapshots row.
-- This is the "nightly audit" described in the project brief: if these
-- two numbers ever disagree, something is wrong (a bug, manual DB
-- surgery, a missed trigger) and this function is what catches it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION run_daily_reconciliation(p_run_date DATE DEFAULT CURRENT_DATE)
RETURNS TABLE(out_account_id UUID, recon_status TEXT) AS $$
BEGIN
    RETURN QUERY
    WITH computed AS (
        SELECT
            a.account_id,
            COALESCE(SUM(
                CASE WHEN lp.direction = 'CREDIT' THEN lp.amount_minor ELSE -lp.amount_minor END
            ), 0) AS ledger_balance
        FROM accounts a
        LEFT JOIN ledger_postings lp ON lp.account_id = a.account_id
        GROUP BY a.account_id
    ),
    logged AS (
        INSERT INTO reconciliation_logs (account_id, run_date, expected_balance_minor, actual_balance_minor, status)
        SELECT
            c.account_id, p_run_date, c.ledger_balance, a.cached_balance_minor,
            CASE WHEN c.ledger_balance = a.cached_balance_minor THEN 'MATCH' ELSE 'DRIFT' END
        FROM computed c
        JOIN accounts a ON a.account_id = c.account_id
        RETURNING reconciliation_logs.account_id AS acc_id, reconciliation_logs.status::TEXT AS stat
    ),
    snapshot_upsert AS (
        INSERT INTO balance_snapshots (account_id, snapshot_date, closing_balance_minor)
        SELECT c.account_id, p_run_date, c.ledger_balance FROM computed c
        ON CONFLICT (account_id, snapshot_date)
        DO UPDATE SET closing_balance_minor = EXCLUDED.closing_balance_minor
    )
    SELECT logged.acc_id, logged.stat FROM logged;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION run_daily_reconciliation IS 'Nightly job: recomputes true balances from ledger history, flags drift in reconciliation_logs, refreshes balance_snapshots. Scheduled by worker/src/jobs/reconciliation.ts.';
