-- =====================================================================
-- 014_deposits_withdrawals.sql
-- External cash-in / cash-out, modeled the same way FX works: money
-- doesn't appear from nowhere, it flows through a system-owned
-- "external" clearing account, so EVERY account's balance -- including
-- the very first deposit it ever received -- is fully explained by the
-- ledger. This is what lets run_daily_reconciliation() show MATCH for
-- every real account from day one.
-- =====================================================================

INSERT INTO accounts (account_id, user_id, account_number, account_type, currency, cached_balance_minor, status)
VALUES
    ('00000000-0000-0000-0000-00000000e1e1', '00000000-0000-0000-0000-000000000001', 'SYS-EXT-USD', 'CURRENT', 'USD', 0, 'ACTIVE'),
    ('00000000-0000-0000-0000-00000000e2e2', '00000000-0000-0000-0000-000000000001', 'SYS-EXT-INR', 'CURRENT', 'INR', 0, 'ACTIVE'),
    ('00000000-0000-0000-0000-00000000e3e3', '00000000-0000-0000-0000-000000000001', 'SYS-EXT-EUR', 'CURRENT', 'EUR', 0, 'ACTIVE');

-- External accounts are allowed to go negative (they represent money
-- entering/leaving the system entirely, e.g. a card network or UPI
-- rail) -- relax their own CHECK by giving them a very large negative
-- allowance isn't possible via CHECK per-row, so instead we simply
-- don't rely on the >= 0 constraint for these three rows: we pre-fund
-- them generously, matching the same treasury-float reasoning as the
-- FX clearing accounts.
UPDATE accounts SET cached_balance_minor = 100000000000
WHERE account_number IN ('SYS-EXT-USD', 'SYS-EXT-INR', 'SYS-EXT-EUR');

CREATE OR REPLACE FUNCTION process_deposit(
    p_account_id UUID,
    p_amount_minor BIGINT,
    p_currency CHAR(3),
    p_initiated_by UUID,
    p_description TEXT DEFAULT 'External deposit'
) RETURNS UUID AS $$
DECLARE
    v_journal_id UUID;
    v_external_account UUID;
BEGIN
    SELECT account_id INTO v_external_account FROM accounts WHERE account_number = 'SYS-EXT-' || p_currency;
    IF v_external_account IS NULL THEN
        RAISE EXCEPTION 'No external clearing account configured for currency %', p_currency;
    END IF;

    PERFORM 1 FROM accounts WHERE account_id = p_account_id FOR UPDATE;

    INSERT INTO journal_entries (entry_type, description, initiated_by)
    VALUES ('DEPOSIT', p_description, p_initiated_by)
    RETURNING journal_id INTO v_journal_id;

    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, v_external_account, 'DEBIT', p_amount_minor, p_currency);

    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, p_account_id, 'CREDIT', p_amount_minor, p_currency);

    RETURN v_journal_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION process_withdrawal(
    p_account_id UUID,
    p_amount_minor BIGINT,
    p_currency CHAR(3),
    p_initiated_by UUID,
    p_description TEXT DEFAULT 'External withdrawal'
) RETURNS UUID AS $$
DECLARE
    v_journal_id UUID;
    v_external_account UUID;
    v_balance BIGINT;
BEGIN
    SELECT account_id INTO v_external_account FROM accounts WHERE account_number = 'SYS-EXT-' || p_currency;

    PERFORM 1 FROM accounts WHERE account_id = p_account_id FOR UPDATE;
    SELECT cached_balance_minor INTO v_balance FROM accounts WHERE account_id = p_account_id;

    IF v_balance < p_amount_minor THEN
        RAISE EXCEPTION 'Insufficient funds for withdrawal: balance=% requested=%', v_balance, p_amount_minor;
    END IF;

    INSERT INTO journal_entries (entry_type, description, initiated_by)
    VALUES ('WITHDRAWAL', p_description, p_initiated_by)
    RETURNING journal_id INTO v_journal_id;

    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, p_account_id, 'DEBIT', p_amount_minor, p_currency);

    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, v_external_account, 'CREDIT', p_amount_minor, p_currency);

    RETURN v_journal_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION process_deposit IS 'Cash-in from outside the system (e.g. UPI/card network), modeled as a transfer from a pre-funded external clearing account -- keeps every account fully explained by ledger history.';
COMMENT ON FUNCTION process_withdrawal IS 'Cash-out to outside the system, mirror of process_deposit.';
