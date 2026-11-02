-- =====================================================================
-- 015_security_definer_fix.sql
--
-- Real bug found via API integration testing: process_transfer(),
-- process_fx_transfer(), process_deposit() and process_withdrawal() ran
-- as SECURITY INVOKER (the Postgres default), meaning they executed
-- under the CALLING role's own Row-Level Security visibility. A
-- customer calling process_transfer() to pay a stranger would have RLS
-- silently hide the receiver's account row from the function's own
-- SELECT/lock, and the system's external clearing account lookup
-- inside process_deposit() failed the exact same way -- which is what
-- the API's deposit endpoint actually hit when tested end-to-end.
--
-- The fix is SECURITY DEFINER, so these functions run with the
-- privileges of their owner instead of the caller, bypassing RLS for
-- this one privileged code path.
--
-- IMPORTANT SECOND BUG this uncovers: RLS had been silently acting as
-- an accidental ownership check. Before this fix, a customer could
-- only successfully transfer FROM an account because RLS let them see
-- it in the first place -- which, incidentally, only happened to be
-- true for their OWN accounts. Once SECURITY DEFINER removes that
-- accidental gate, nothing else in process_transfer()/
-- process_withdrawal() stops a caller from naming someone ELSE's
-- account as the sender. So this migration also adds an EXPLICIT
-- ownership check (p_initiated_by must match the debited account's
-- user_id) to both functions below -- the real authorization boundary
-- now lives in application logic inside the function, not as a side
-- effect of a row being invisible.
--
-- SET search_path is pinned on every SECURITY DEFINER function as
-- standard hardening: without it, a malicious search_path set by the
-- calling session could trick the function into resolving an
-- unqualified name to an attacker-controlled object instead of the
-- real one.
-- =====================================================================

CREATE OR REPLACE FUNCTION process_transfer(
    p_sender_account_id   UUID,
    p_receiver_account_id UUID,
    p_amount_minor        BIGINT,
    p_currency             CHAR(3),
    p_idempotency_key      UUID,
    p_initiated_by          UUID,
    p_description           TEXT DEFAULT NULL
) RETURNS UUID
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_journal_id       UUID;
    v_first_lock_id    UUID;
    v_second_lock_id   UUID;
    v_sender           accounts%ROWTYPE;
    v_receiver         accounts%ROWTYPE;
    v_limits           account_limits%ROWTYPE;
    v_spent_today      BIGINT;
    v_existing_journal UUID;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT journal_id INTO v_existing_journal
        FROM journal_entries WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN
            RETURN v_existing_journal;
        END IF;
    END IF;

    IF p_sender_account_id = p_receiver_account_id THEN
        RAISE EXCEPTION 'Sender and receiver account cannot be the same.';
    END IF;

    IF p_amount_minor <= 0 THEN
        RAISE EXCEPTION 'Transfer amount must be positive.';
    END IF;

    -- Deterministic lock ordering (deadlock-free under concurrency).
    IF p_sender_account_id < p_receiver_account_id THEN
        v_first_lock_id  := p_sender_account_id;
        v_second_lock_id := p_receiver_account_id;
    ELSE
        v_first_lock_id  := p_receiver_account_id;
        v_second_lock_id := p_sender_account_id;
    END IF;

    PERFORM 1 FROM accounts WHERE account_id = v_first_lock_id  FOR UPDATE;
    PERFORM 1 FROM accounts WHERE account_id = v_second_lock_id FOR UPDATE;

    SELECT * INTO v_sender   FROM accounts WHERE account_id = p_sender_account_id;
    SELECT * INTO v_receiver FROM accounts WHERE account_id = p_receiver_account_id;

    IF v_sender.account_id IS NULL OR v_receiver.account_id IS NULL THEN
        RAISE EXCEPTION 'Sender or receiver account does not exist.';
    END IF;

    -- EXPLICIT ownership check -- this is the real authorization
    -- boundary now that SECURITY DEFINER bypasses RLS. p_initiated_by
    -- IS NULL is reserved for trusted system-internal callers only
    -- (e.g. an admin tool or scheduled job calling this directly, never
    -- exposed through the public API, which always passes the
    -- authenticated caller's own user_id).
    IF p_initiated_by IS NOT NULL AND v_sender.user_id <> p_initiated_by THEN
        RAISE EXCEPTION 'Account % does not belong to the initiating user.', v_sender.account_number
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF v_sender.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Sender account % is %, transfers are not permitted.', v_sender.account_number, v_sender.status;
    END IF;

    IF v_receiver.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Receiver account % is %, transfers are not permitted.', v_receiver.account_number, v_receiver.status;
    END IF;

    IF v_sender.currency <> p_currency OR v_receiver.currency <> p_currency THEN
        RAISE EXCEPTION 'Currency mismatch: use process_fx_transfer() for cross-currency transfers.';
    END IF;

    IF v_sender.cached_balance_minor < p_amount_minor THEN
        RAISE EXCEPTION 'Insufficient funds in account %: balance=% requested=%',
            v_sender.account_number, v_sender.cached_balance_minor, p_amount_minor;
    END IF;

    SELECT * INTO v_limits FROM account_limits WHERE account_id = p_sender_account_id;
    IF FOUND THEN
        IF p_amount_minor > v_limits.per_txn_limit_minor THEN
            RAISE EXCEPTION 'Amount % exceeds per-transaction limit % for account %',
                p_amount_minor, v_limits.per_txn_limit_minor, v_sender.account_number;
        END IF;

        SELECT COALESCE(SUM(lp.amount_minor), 0) INTO v_spent_today
        FROM ledger_postings lp
        WHERE lp.account_id = p_sender_account_id
          AND lp.direction = 'DEBIT'
          AND lp.created_at >= date_trunc('day', now());

        IF v_spent_today + p_amount_minor > v_limits.daily_limit_minor THEN
            RAISE EXCEPTION 'Transfer would exceed daily limit % for account % (already spent % today)',
                v_limits.daily_limit_minor, v_sender.account_number, v_spent_today;
        END IF;
    END IF;

    INSERT INTO journal_entries (idempotency_key, entry_type, description, initiated_by)
    VALUES (p_idempotency_key, 'TRANSFER', p_description, p_initiated_by)
    RETURNING journal_id INTO v_journal_id;

    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, p_sender_account_id, 'DEBIT', p_amount_minor, p_currency);

    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, p_receiver_account_id, 'CREDIT', p_amount_minor, p_currency);

    INSERT INTO outbox_events (aggregate_type, aggregate_id, event_type, payload)
    VALUES (
        'journal_entry', v_journal_id, 'TRANSFER_COMPLETED',
        jsonb_build_object(
            'journal_id', v_journal_id, 'sender_account_id', p_sender_account_id,
            'receiver_account_id', p_receiver_account_id, 'amount_minor', p_amount_minor, 'currency', p_currency
        )
    );

    RETURN v_journal_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION process_transfer IS 'Atomic same-currency transfer: deterministic lock ordering (deadlock-free), explicit ownership check, balance + limit validation, append-only double-entry postings, transactional outbox event. SECURITY DEFINER so it can read/lock accounts regardless of caller RLS visibility -- all authorization enforced explicitly inside the function.';

-- ---------------------------------------------------------------------
-- process_withdrawal: same ownership-check fix applied.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_withdrawal(
    p_account_id UUID,
    p_amount_minor BIGINT,
    p_currency CHAR(3),
    p_initiated_by UUID,
    p_description TEXT DEFAULT 'External withdrawal'
) RETURNS UUID
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_journal_id UUID;
    v_external_account UUID;
    v_account accounts%ROWTYPE;
BEGIN
    SELECT account_id INTO v_external_account FROM accounts WHERE account_number = 'SYS-EXT-' || p_currency;

    PERFORM 1 FROM accounts WHERE account_id = p_account_id FOR UPDATE;
    SELECT * INTO v_account FROM accounts WHERE account_id = p_account_id;

    IF v_account.account_id IS NULL THEN
        RAISE EXCEPTION 'Account does not exist.';
    END IF;

    IF p_initiated_by IS NOT NULL AND v_account.user_id <> p_initiated_by THEN
        RAISE EXCEPTION 'Account % does not belong to the initiating user.', v_account.account_number
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF v_account.cached_balance_minor < p_amount_minor THEN
        RAISE EXCEPTION 'Insufficient funds for withdrawal: balance=% requested=%', v_account.cached_balance_minor, p_amount_minor;
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

COMMENT ON FUNCTION process_withdrawal IS 'Cash-out to outside the system. SECURITY DEFINER with an explicit ownership check -- p_initiated_by must own the account being debited.';

-- ---------------------------------------------------------------------
-- process_fx_transfer and process_deposit: SECURITY DEFINER is enough
-- here without an additional ownership check on process_deposit
-- (crediting someone else's account is not a safety issue the way
-- debiting one is), but process_fx_transfer debits the sender, so it
-- gets the same explicit check.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_fx_transfer(
    p_sender_account_id   UUID,
    p_receiver_account_id UUID,
    p_send_amount_minor   BIGINT,
    p_idempotency_key      UUID,
    p_initiated_by          UUID,
    p_description           TEXT DEFAULT NULL
) RETURNS UUID
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_journal_id      UUID;
    v_sender          accounts%ROWTYPE;
    v_receiver        accounts%ROWTYPE;
    v_rate             NUMERIC(18,8);
    v_receive_amount   BIGINT;
    v_sender_clearing  UUID;
    v_receiver_clearing UUID;
    v_lock_ids          UUID[];
    v_id                UUID;
    v_existing_journal   UUID;
BEGIN
    IF p_idempotency_key IS NOT NULL THEN
        SELECT journal_id INTO v_existing_journal FROM journal_entries WHERE idempotency_key = p_idempotency_key;
        IF FOUND THEN RETURN v_existing_journal; END IF;
    END IF;

    SELECT * INTO v_sender   FROM accounts WHERE account_id = p_sender_account_id;
    SELECT * INTO v_receiver FROM accounts WHERE account_id = p_receiver_account_id;

    IF v_sender.account_id IS NULL OR v_receiver.account_id IS NULL THEN
        RAISE EXCEPTION 'Sender or receiver account does not exist.';
    END IF;

    IF p_initiated_by IS NOT NULL AND v_sender.user_id <> p_initiated_by THEN
        RAISE EXCEPTION 'Account % does not belong to the initiating user.', v_sender.account_number
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF v_sender.currency = v_receiver.currency THEN
        RAISE EXCEPTION 'Same-currency transfer: use process_transfer() instead.';
    END IF;

    SELECT account_id INTO v_sender_clearing   FROM accounts WHERE account_number = 'SYS-CLR-' || v_sender.currency;
    SELECT account_id INTO v_receiver_clearing FROM accounts WHERE account_number = 'SYS-CLR-' || v_receiver.currency;

    IF v_sender_clearing IS NULL OR v_receiver_clearing IS NULL THEN
        RAISE EXCEPTION 'No clearing account configured for currency pair % / %', v_sender.currency, v_receiver.currency;
    END IF;

    v_lock_ids := ARRAY[p_sender_account_id, p_receiver_account_id, v_sender_clearing, v_receiver_clearing];
    SELECT array_agg(x ORDER BY x) INTO v_lock_ids FROM unnest(v_lock_ids) AS x;

    FOREACH v_id IN ARRAY v_lock_ids LOOP
        PERFORM 1 FROM accounts WHERE account_id = v_id FOR UPDATE;
    END LOOP;

    SELECT * INTO v_sender   FROM accounts WHERE account_id = p_sender_account_id;
    SELECT * INTO v_receiver FROM accounts WHERE account_id = p_receiver_account_id;

    IF v_sender.status <> 'ACTIVE' OR v_receiver.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Both accounts must be ACTIVE for a transfer.';
    END IF;

    IF v_sender.cached_balance_minor < p_send_amount_minor THEN
        RAISE EXCEPTION 'Insufficient funds in account %', v_sender.account_number;
    END IF;

    SELECT rate INTO v_rate FROM fx_rates
    WHERE base_currency = v_sender.currency AND quote_currency = v_receiver.currency
    ORDER BY as_of DESC LIMIT 1;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'No FX rate available for % -> %', v_sender.currency, v_receiver.currency;
    END IF;

    v_receive_amount := ROUND(p_send_amount_minor * v_rate);

    INSERT INTO journal_entries (idempotency_key, entry_type, description, initiated_by, fx_rate_applied, source_currency, target_currency)
    VALUES (p_idempotency_key, 'FX_CONVERSION', p_description, p_initiated_by, v_rate, v_sender.currency, v_receiver.currency)
    RETURNING journal_id INTO v_journal_id;

    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, p_sender_account_id, 'DEBIT', p_send_amount_minor, v_sender.currency);
    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, v_sender_clearing, 'CREDIT', p_send_amount_minor, v_sender.currency);

    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, v_receiver_clearing, 'DEBIT', v_receive_amount, v_receiver.currency);
    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, p_receiver_account_id, 'CREDIT', v_receive_amount, v_receiver.currency);

    INSERT INTO outbox_events (aggregate_type, aggregate_id, event_type, payload)
    VALUES (
        'journal_entry', v_journal_id, 'FX_TRANSFER_COMPLETED',
        jsonb_build_object(
            'journal_id', v_journal_id, 'sender_account_id', p_sender_account_id,
            'receiver_account_id', p_receiver_account_id, 'send_amount_minor', p_send_amount_minor,
            'receive_amount_minor', v_receive_amount, 'rate', v_rate,
            'source_currency', v_sender.currency, 'target_currency', v_receiver.currency
        )
    );

    RETURN v_journal_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION process_fx_transfer IS 'Cross-currency transfer via system clearing accounts: 4 balanced legs, explicit ownership check, SECURITY DEFINER.';

ALTER FUNCTION process_deposit(UUID, BIGINT, CHAR(3), UUID, TEXT)
    SECURITY DEFINER SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------
-- check_journal_balance() also needs SECURITY DEFINER -- found via the
-- same API integration test. It is a DEFERRED constraint trigger, so
-- it fires at COMMIT time, AFTER process_transfer()/process_deposit()
-- (both SECURITY DEFINER) have already returned and the role has
-- reverted to the original caller. Without this fix, a customer's own
-- RLS visibility would hide the OTHER leg of their own transaction
-- (e.g. the system clearing account in a deposit, or the receiver's
-- account in a transfer to someone else), making a perfectly balanced
-- double-entry transaction look unbalanced from the trigger's point of
-- view and incorrectly reject it.
-- ---------------------------------------------------------------------
ALTER FUNCTION check_journal_balance() SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION check_journal_balance IS 'Deferred zero-sum check, fires at COMMIT. SECURITY DEFINER is essential (not just hardening) here: without it, the caller''s own RLS would hide the other leg of their transaction at the moment this check runs, since role/privileges revert once the SECURITY DEFINER caller (process_transfer etc.) has returned.';
