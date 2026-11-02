-- =====================================================================
-- 008_fraud_outbox_audit_recon.sql
-- Fraud detection, transactional outbox, audit trail, reconciliation
-- =====================================================================

-- ---------------------------------------------------------------------
-- fraud_flags: populated by a scheduled analytical query (see
-- db/queries/fraud_velocity_check.sql) using window functions to spot
-- accounts with abnormal transaction velocity.
-- ---------------------------------------------------------------------
CREATE TABLE fraud_flags (
    flag_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id  UUID NOT NULL REFERENCES accounts(account_id),
    rule_name   VARCHAR(50) NOT NULL,       -- e.g. 'HIGH_VELOCITY', 'UNUSUAL_AMOUNT'
    detail      JSONB NOT NULL,
    severity    VARCHAR(10) NOT NULL DEFAULT 'MEDIUM'
                CHECK (severity IN ('LOW', 'MEDIUM', 'HIGH')),
    resolved    BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_fraud_flags_account_created ON fraud_flags(account_id, created_at);
CREATE INDEX idx_fraud_flags_unresolved ON fraud_flags(resolved) WHERE resolved = FALSE;

-- ---------------------------------------------------------------------
-- outbox_events: transactional outbox pattern. A row is inserted into
-- this table in the SAME transaction as a ledger posting (by the
-- process_transfer trigger), guaranteeing "committed to DB" and
-- "event will eventually be published" are atomic. A worker process
-- polls WHERE published = FALSE and dispatches webhooks/notifications,
-- then marks the row published. This avoids the classic bug where a
-- transfer commits but the notification service call fails/is lost.
-- ---------------------------------------------------------------------
CREATE TABLE outbox_events (
    event_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type VARCHAR(30) NOT NULL,     -- e.g. 'journal_entry'
    aggregate_id   UUID NOT NULL,
    event_type     VARCHAR(50) NOT NULL,     -- e.g. 'TRANSFER_COMPLETED'
    payload        JSONB NOT NULL,
    published      BOOLEAN NOT NULL DEFAULT FALSE,
    published_at   TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_outbox_unpublished ON outbox_events(created_at) WHERE published = FALSE;

-- ---------------------------------------------------------------------
-- audit_logs: generic change-tracking table, written by triggers on
-- sensitive tables (accounts status/limit changes, user KYC changes).
-- ---------------------------------------------------------------------
CREATE TABLE audit_logs (
    audit_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_user_id UUID REFERENCES users(user_id),   -- NULL = system
    action       VARCHAR(20) NOT NULL,              -- INSERT / UPDATE / DELETE / BLOCKED_ATTEMPT
    table_name   VARCHAR(50) NOT NULL,
    record_id    UUID,
    old_value    JSONB,
    new_value    JSONB,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_logs_table_record ON audit_logs(table_name, record_id);
CREATE INDEX idx_audit_logs_created ON audit_logs(created_at);

-- ---------------------------------------------------------------------
-- reconciliation_logs: output of the nightly job that recomputes each
-- account's true balance from ledger_postings and compares it against
-- accounts.cached_balance_minor and balance_snapshots.
-- ---------------------------------------------------------------------
CREATE TABLE reconciliation_logs (
    recon_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id        UUID NOT NULL REFERENCES accounts(account_id),
    run_date          DATE NOT NULL DEFAULT CURRENT_DATE,
    expected_balance_minor BIGINT NOT NULL,   -- sum of ledger_postings
    actual_balance_minor   BIGINT NOT NULL,   -- accounts.cached_balance_minor at run time
    status            VARCHAR(10) NOT NULL CHECK (status IN ('MATCH', 'DRIFT')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_reconciliation_logs_drift ON reconciliation_logs(run_date) WHERE status = 'DRIFT';
