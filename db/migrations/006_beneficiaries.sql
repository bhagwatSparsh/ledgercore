-- =====================================================================
-- 006_beneficiaries.sql
-- Standard full-CRUD table (demonstrates vanilla INSERT/UPDATE/DELETE
-- for faculty evaluation, alongside the append-only ledger tables)
-- =====================================================================

CREATE TABLE saved_beneficiaries (
    beneficiary_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    beneficiary_account_id UUID NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    nickname                VARCHAR(50),
    transfer_limit_minor    BIGINT NOT NULL DEFAULT 2500000,
    added_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, beneficiary_account_id)
);

CREATE INDEX idx_saved_beneficiaries_user ON saved_beneficiaries(user_id);
