-- =====================================================================
-- 003_accounts.sql
-- Balance-bearing accounts
--
-- Design note on money storage: amounts are stored as BIGINT "minor
-- units" (paise/cents), never NUMERIC/FLOAT dollars. 100.50 INR is
-- stored as 10050. This avoids floating-point rounding bugs entirely
-- and matches how Stripe/Razorpay represent money internally.
-- =====================================================================

CREATE TABLE accounts (
    account_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    account_number  VARCHAR(20) UNIQUE NOT NULL,
    account_type    VARCHAR(20) NOT NULL DEFAULT 'SAVINGS'
                    CHECK (account_type IN ('SAVINGS', 'CURRENT', 'WALLET')),
    currency        CHAR(3) NOT NULL DEFAULT 'INR',     -- ISO 4217

    -- Transactionally-maintained fast-read cache. This is NOT the source
    -- of truth -- ledger_postings is. It is updated inside the same
    -- transaction as every posting (see process_transfer() in
    -- 010_functions_triggers.sql) so it's always consistent at commit
    -- time, and it's what the nightly reconciliation job verifies
    -- against the summed ledger history.
    cached_balance_minor BIGINT NOT NULL DEFAULT 0 CHECK (cached_balance_minor >= 0),

    status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE', 'FROZEN', 'CLOSED')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_accounts_user_id ON accounts(user_id);
CREATE INDEX idx_accounts_status ON accounts(status) WHERE status != 'ACTIVE';

-- Per-account transfer limits, split into their own table so changing a
-- limit (frequent, low-risk write) never has to lock the accounts row
-- that the hot transfer path also locks (rare write, high contention).
CREATE TABLE account_limits (
    account_id          UUID PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
    daily_limit_minor   BIGINT NOT NULL DEFAULT 5000000,   -- 50,000.00 default
    per_txn_limit_minor BIGINT NOT NULL DEFAULT 2500000,   -- 25,000.00 default
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE account_limits IS 'Kept separate from accounts to avoid lock contention between limit-management writes and the hot transfer-locking path.';
