-- =====================================================================
-- 021_fraud_scan_excludes_system_accounts.sql
--
-- Real bug found via live testing of the admin dashboard's Fraud tab
-- (not a theoretical edge case): the system's own clearing accounts
-- (SYS-CLR-USD/INR/EUR) and external accounts (SYS-EXT-USD/INR/EUR)
-- participate in EVERY deposit, withdrawal, and FX conversion in the
-- entire system by design (see migrations 009, 014) -- so they will
-- always, permanently exceed any believable transaction-velocity
-- threshold. Left unfixed, HIGH_VELOCITY flags on these accounts would
-- never stop firing and would bury every genuine customer fraud signal
-- in the admin console under system noise.
--
-- Fix: detect_fraud_velocity() now excludes accounts owned by the
-- reserved system user (seeded in migration 009 as
-- '00000000-0000-0000-0000-000000000001') -- those accounts aren't
-- "a customer who might be committing fraud", they're internal
-- plumbing, so velocity-based fraud rules don't apply to them.
-- =====================================================================

CREATE OR REPLACE FUNCTION detect_fraud_velocity(p_window_minutes INT DEFAULT 60, p_threshold INT DEFAULT 5)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_inserted INT;
BEGIN
    WITH velocity AS (
        SELECT lp.account_id, COUNT(*) AS txn_count, MAX(lp.created_at) AS last_txn_at
        FROM ledger_postings lp
        JOIN accounts a ON a.account_id = lp.account_id
        WHERE lp.direction = 'DEBIT'
          AND lp.created_at >= now() - (p_window_minutes || ' minutes')::interval
          AND a.user_id <> '00000000-0000-0000-0000-000000000001'  -- exclude system accounts
        GROUP BY lp.account_id
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
$$;

COMMENT ON FUNCTION detect_fraud_velocity IS 'Flags accounts with unusually high debit velocity in a rolling window. Excludes the reserved system user''s clearing/external accounts, which legitimately touch every deposit/withdrawal/FX leg and would otherwise always trip this rule.';

-- Clean up the false-positive flags already generated against system
-- accounts during earlier testing in this environment, so the admin
-- console reflects the fixed behavior immediately rather than carrying
-- stale noise until those flags age out.
DELETE FROM fraud_flags f
USING accounts a
WHERE f.account_id = a.account_id
  AND a.user_id = '00000000-0000-0000-0000-000000000001'
  AND f.rule_name = 'HIGH_VELOCITY';
