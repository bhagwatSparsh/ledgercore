-- =====================================================================
-- 010_functions_triggers.sql
-- The database logic layer: triggers + stored procedures.
-- This is the part of the project that actually demonstrates database
-- engineering, as opposed to table design.
-- =====================================================================

-- =====================================================================
-- SECTION A: Immutability -- ledger_postings can never be changed once
-- written. This is THE defining feature of a double-entry ledger: the
-- audit trail must be tamper-proof.
-- =====================================================================

CREATE OR REPLACE FUNCTION prevent_ledger_tampering()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
    VALUES (
        NULLIF(current_setting('app.current_user_id', true), '')::uuid,
        'BLOCKED_' || TG_OP,
        'ledger_postings',
        OLD.posting_id,
        to_jsonb(OLD),
        NULL
    );
    RAISE EXCEPTION 'CRITICAL: ledger_postings is append-only. % is not permitted on posting %.', TG_OP, OLD.posting_id
        USING ERRCODE = 'integrity_constraint_violation';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_protect_ledger
    BEFORE UPDATE OR DELETE ON ledger_postings
    FOR EACH ROW EXECUTE FUNCTION prevent_ledger_tampering();

-- =====================================================================
-- SECTION B: The zero-sum invariant.
-- For every journal_id, and independently for every currency within
-- that journal (to support multi-leg FX transfers), SUM(debits) must
-- equal SUM(credits). This is checked as a DEFERRED constraint trigger
-- so that a journal entry's multiple INSERT statements can all run
-- first, with the invariant verified once, right before COMMIT -- not
-- after every individual row, which would reject the debit leg for
-- having no matching credit leg yet.
-- =====================================================================

CREATE OR REPLACE FUNCTION check_journal_balance()
RETURNS TRIGGER AS $$
DECLARE
    v_debits  BIGINT;
    v_credits BIGINT;
BEGIN
    SELECT
        COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'DEBIT'), 0),
        COALESCE(SUM(amount_minor) FILTER (WHERE direction = 'CREDIT'), 0)
    INTO v_debits, v_credits
    FROM ledger_postings
    WHERE journal_id = NEW.journal_id
      AND currency = NEW.currency;

    IF v_debits <> v_credits THEN
        RAISE EXCEPTION 'Zero-sum invariant violated for journal % (currency %): debits=% credits=%',
            NEW.journal_id, NEW.currency, v_debits, v_credits
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trg_check_journal_balance
    AFTER INSERT ON ledger_postings
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_journal_balance();

-- =====================================================================
-- SECTION C: Maintain the fast-read balance cache transactionally.
-- Fires in the SAME transaction as the posting insert, under the same
-- row lock process_transfer() already holds, so it can never diverge
-- mid-transaction. The nightly reconciliation job is what catches any
-- divergence that somehow still occurs (bugs, manual DB surgery, etc).
-- =====================================================================

CREATE OR REPLACE FUNCTION apply_posting_to_balance()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.direction = 'DEBIT' THEN
        UPDATE accounts
           SET cached_balance_minor = cached_balance_minor - NEW.amount_minor,
               updated_at = now()
         WHERE account_id = NEW.account_id;
    ELSE
        UPDATE accounts
           SET cached_balance_minor = cached_balance_minor + NEW.amount_minor,
               updated_at = now()
         WHERE account_id = NEW.account_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_posting_to_balance
    AFTER INSERT ON ledger_postings
    FOR EACH ROW EXECUTE FUNCTION apply_posting_to_balance();

-- =====================================================================
-- SECTION D: Audit trail for sensitive state changes (not every column
-- -- balance changes are already captured by the ledger itself, so
-- logging them again here would just be noise. We log the things an
-- auditor actually cares about: status/KYC/limit changes.)
-- =====================================================================

CREATE OR REPLACE FUNCTION audit_row_change()
RETURNS TRIGGER AS $$
DECLARE
    v_record_id UUID;
BEGIN
    v_record_id := CASE TG_TABLE_NAME
        WHEN 'accounts'       THEN NEW.account_id
        WHEN 'users'          THEN NEW.user_id
        WHEN 'account_limits' THEN NEW.account_id
    END;

    INSERT INTO audit_logs (actor_user_id, action, table_name, record_id, old_value, new_value)
    VALUES (
        NULLIF(current_setting('app.current_user_id', true), '')::uuid,
        TG_OP,
        TG_TABLE_NAME,
        v_record_id,
        to_jsonb(OLD),
        to_jsonb(NEW)
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_account_status
    AFTER UPDATE OF status ON accounts
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION audit_row_change();

CREATE TRIGGER trg_audit_user_kyc
    AFTER UPDATE OF kyc_status ON users
    FOR EACH ROW
    WHEN (OLD.kyc_status IS DISTINCT FROM NEW.kyc_status)
    EXECUTE FUNCTION audit_row_change();

CREATE TRIGGER trg_audit_account_limits
    AFTER UPDATE ON account_limits
    FOR EACH ROW
    WHEN (OLD.daily_limit_minor IS DISTINCT FROM NEW.daily_limit_minor
       OR OLD.per_txn_limit_minor IS DISTINCT FROM NEW.per_txn_limit_minor)
    EXECUTE FUNCTION audit_row_change();

-- =====================================================================
-- SECTION E: process_transfer() -- the atomic, deadlock-free,
-- idempotent same-currency transfer procedure. This is the function
-- the API layer calls for every transfer; all correctness guarantees
-- live here, in the database, not scattered across application code.
-- =====================================================================

CREATE OR REPLACE FUNCTION process_transfer(
    p_sender_account_id   UUID,
    p_receiver_account_id UUID,
    p_amount_minor        BIGINT,
    p_currency             CHAR(3),
    p_idempotency_key      UUID,
    p_initiated_by          UUID,
    p_description           TEXT DEFAULT NULL
) RETURNS UUID AS $$
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
    -- 0. Idempotency short-circuit: if this exact key already produced a
    --    journal entry, return it instead of doing the transfer again.
    --    (The API layer also checks idempotency_keys before calling this
    --    procedure at all -- this is defense-in-depth at the DB level.)
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

    -- 1. Deterministic lock ordering: always lock the LOWER account_id
    --    first, regardless of which side is sender/receiver. This is
    --    what makes two simultaneous, opposite-direction transfers
    --    (A->B and B->A at the same millisecond) resolve without
    --    deadlocking -- both transactions request locks in the same
    --    global order, so one always waits cleanly behind the other
    --    instead of each holding what the other wants.
    IF p_sender_account_id < p_receiver_account_id THEN
        v_first_lock_id  := p_sender_account_id;
        v_second_lock_id := p_receiver_account_id;
    ELSE
        v_first_lock_id  := p_receiver_account_id;
        v_second_lock_id := p_sender_account_id;
    END IF;

    PERFORM 1 FROM accounts WHERE account_id = v_first_lock_id  FOR UPDATE;
    PERFORM 1 FROM accounts WHERE account_id = v_second_lock_id FOR UPDATE;

    -- 2. Now that both rows are locked, read their authoritative state.
    SELECT * INTO v_sender   FROM accounts WHERE account_id = p_sender_account_id;
    SELECT * INTO v_receiver FROM accounts WHERE account_id = p_receiver_account_id;

    IF v_sender.account_id IS NULL OR v_receiver.account_id IS NULL THEN
        RAISE EXCEPTION 'Sender or receiver account does not exist.';
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

    -- 3. Balance sufficiency, read from the just-locked row -- safe from
    --    races because no other transaction can touch this row until we
    --    commit or roll back.
    IF v_sender.cached_balance_minor < p_amount_minor THEN
        RAISE EXCEPTION 'Insufficient funds in account %: balance=% requested=%',
            v_sender.account_number, v_sender.cached_balance_minor, p_amount_minor;
    END IF;

    -- 4. Limit checks.
    SELECT * INTO v_limits FROM account_limits WHERE account_id = p_sender_account_id;
    IF FOUND THEN
        IF p_amount_minor > v_limits.per_txn_limit_minor THEN
            RAISE EXCEPTION 'Amount % exceeds per-transaction limit % for account %',
                p_amount_minor, v_limits.per_txn_limit_minor, v_sender.account_number;
        END IF;

        SELECT COALESCE(SUM(lp.amount_minor), 0) INTO v_spent_today
        FROM ledger_postings lp
        JOIN journal_entries je ON je.journal_id = lp.journal_id
        WHERE lp.account_id = p_sender_account_id
          AND lp.direction = 'DEBIT'
          AND lp.created_at >= date_trunc('day', now());

        IF v_spent_today + p_amount_minor > v_limits.daily_limit_minor THEN
            RAISE EXCEPTION 'Transfer would exceed daily limit % for account % (already spent % today)',
                v_limits.daily_limit_minor, v_sender.account_number, v_spent_today;
        END IF;
    END IF;

    -- 5. Write the journal entry + two balanced ledger legs, all inside
    --    this same transaction. The deferred trg_check_journal_balance
    --    constraint trigger re-verifies the zero-sum invariant right
    --    before commit as a final safety net.
    INSERT INTO journal_entries (idempotency_key, entry_type, description, initiated_by)
    VALUES (p_idempotency_key, 'TRANSFER', p_description, p_initiated_by)
    RETURNING journal_id INTO v_journal_id;

    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, p_sender_account_id, 'DEBIT', p_amount_minor, p_currency);

    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, p_receiver_account_id, 'CREDIT', p_amount_minor, p_currency);

    -- 6. Transactional outbox: this row commits atomically with the
    --    ledger postings above. A worker polling outbox_events will
    --    eventually see it and fire notifications -- guaranteed exactly
    --    once at the DB level, regardless of whether the notification
    --    service happens to be down right now.
    INSERT INTO outbox_events (aggregate_type, aggregate_id, event_type, payload)
    VALUES (
        'journal_entry', v_journal_id, 'TRANSFER_COMPLETED',
        jsonb_build_object(
            'journal_id', v_journal_id,
            'sender_account_id', p_sender_account_id,
            'receiver_account_id', p_receiver_account_id,
            'amount_minor', p_amount_minor,
            'currency', p_currency
        )
    );

    RETURN v_journal_id;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION process_transfer IS 'Atomic same-currency transfer: deterministic lock ordering (deadlock-free), balance + limit validation, append-only double-entry postings, transactional outbox event.';

-- =====================================================================
-- SECTION F: process_fx_transfer() -- cross-currency transfer via the
-- system clearing accounts seeded in 009_system_accounts.sql. Four
-- balanced legs instead of two, keeping the per-currency zero-sum
-- invariant intact for both currencies independently.
-- =====================================================================

CREATE OR REPLACE FUNCTION process_fx_transfer(
    p_sender_account_id   UUID,
    p_receiver_account_id UUID,
    p_send_amount_minor   BIGINT,       -- amount in sender's currency
    p_idempotency_key      UUID,
    p_initiated_by          UUID,
    p_description           TEXT DEFAULT NULL
) RETURNS UUID AS $$
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

    IF v_sender.currency = v_receiver.currency THEN
        RAISE EXCEPTION 'Same-currency transfer: use process_transfer() instead.';
    END IF;

    SELECT account_id INTO v_sender_clearing   FROM accounts WHERE account_number = 'SYS-CLR-' || v_sender.currency;
    SELECT account_id INTO v_receiver_clearing FROM accounts WHERE account_number = 'SYS-CLR-' || v_receiver.currency;

    IF v_sender_clearing IS NULL OR v_receiver_clearing IS NULL THEN
        RAISE EXCEPTION 'No clearing account configured for currency pair % / %', v_sender.currency, v_receiver.currency;
    END IF;

    -- Lock all 4 accounts (sender, receiver, both clearing accounts) in
    -- a single deterministic sorted order to stay deadlock-free even
    -- when FX transfers run concurrently in both directions.
    v_lock_ids := ARRAY[p_sender_account_id, p_receiver_account_id, v_sender_clearing, v_receiver_clearing];
    SELECT array_agg(x ORDER BY x) INTO v_lock_ids FROM unnest(v_lock_ids) AS x;

    FOREACH v_id IN ARRAY v_lock_ids LOOP
        PERFORM 1 FROM accounts WHERE account_id = v_id FOR UPDATE;
    END LOOP;

    -- Re-read authoritative post-lock state.
    SELECT * INTO v_sender   FROM accounts WHERE account_id = p_sender_account_id;
    SELECT * INTO v_receiver FROM accounts WHERE account_id = p_receiver_account_id;

    IF v_sender.status <> 'ACTIVE' OR v_receiver.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Both accounts must be ACTIVE for a transfer.';
    END IF;

    IF v_sender.cached_balance_minor < p_send_amount_minor THEN
        RAISE EXCEPTION 'Insufficient funds in account %', v_sender.account_number;
    END IF;

    -- Latest published rate for this currency pair.
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

    -- Leg 1/2: sender's currency is balanced between sender and that
    -- currency's clearing account.
    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, p_sender_account_id, 'DEBIT', p_send_amount_minor, v_sender.currency);
    INSERT INTO ledger_postings (journal_id, account_id, direction, amount_minor, currency)
    VALUES (v_journal_id, v_sender_clearing, 'CREDIT', p_send_amount_minor, v_sender.currency);

    -- Leg 3/4: receiver's currency is balanced between that currency's
    -- clearing account and the receiver.
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

COMMENT ON FUNCTION process_fx_transfer IS 'Cross-currency transfer via system clearing accounts: 4 balanced legs keep the zero-sum invariant intact per-currency.';
