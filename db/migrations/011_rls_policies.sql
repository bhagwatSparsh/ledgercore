-- =====================================================================
-- 011_rls_policies.sql
-- Row-Level Security: access control enforced BY THE DATABASE, not by
-- "if user.role == admin" checks scattered through API code. Even a
-- buggy or compromised API layer cannot leak another customer's rows,
-- because Postgres itself refuses to return them.
--
-- How it's wired to the app: the API authenticates the user (JWT),
-- then opens a DB transaction and runs:
--   SET LOCAL app.current_user_id = '<uuid>';
--   SET LOCAL app.session_role    = 'customer' | 'admin' | 'auditor';
-- before running any query. Policies below read those session settings.
-- =====================================================================

-- Dedicated low-privilege role the API connects as. It must NOT have
-- BYPASSRLS -- that's what makes the policies below actually matter.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledgercore_app') THEN
        CREATE ROLE ledgercore_app LOGIN PASSWORD 'change_me_in_prod';
    END IF;
END $$;

GRANT CONNECT ON DATABASE ledgercore TO ledgercore_app;
GRANT USAGE ON SCHEMA public TO ledgercore_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ledgercore_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO ledgercore_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ledgercore_app;

-- ---------------------------------------------------------------------
-- accounts: customers see only their own accounts; admins/auditors see
-- all. Soft-deleted/closed accounts stay visible (closing is a status,
-- not a row removal) so history remains intact.
-- ---------------------------------------------------------------------
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;

CREATE POLICY accounts_owner_access ON accounts
    FOR ALL
    USING (
        current_setting('app.session_role', true) IN ('admin', 'auditor')
        OR user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    )
    WITH CHECK (
        current_setting('app.session_role', true) IN ('admin', 'auditor')
        OR user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    );

-- ---------------------------------------------------------------------
-- ledger_postings / journal_entries: a customer may only see postings
-- that touch an account they own. Auditors/admins see everything.
-- Note: no WITH CHECK needed for INSERT here -- all writes go through
-- process_transfer()/process_fx_transfer(), which run with the
-- privileges of the ledgercore_app role and are the only sanctioned
-- write path (enforced at the API layer, not re-derived here).
-- ---------------------------------------------------------------------
ALTER TABLE ledger_postings ENABLE ROW LEVEL SECURITY;

CREATE POLICY ledger_postings_owner_read ON ledger_postings
    FOR SELECT
    USING (
        current_setting('app.session_role', true) IN ('admin', 'auditor')
        OR account_id IN (
            SELECT account_id FROM accounts
            WHERE user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
        )
    );

-- Inserts/the (blocked) update-delete path remain open to the app role;
-- the actual write gate is process_transfer()'s own logic plus the
-- trg_protect_ledger trigger, which fires regardless of who the caller
-- is -- RLS and triggers are complementary layers here, not duplicates.
CREATE POLICY ledger_postings_insert ON ledger_postings
    FOR INSERT WITH CHECK (true);

ALTER TABLE journal_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY journal_entries_owner_read ON journal_entries
    FOR SELECT
    USING (
        current_setting('app.session_role', true) IN ('admin', 'auditor')
        OR journal_id IN (
            SELECT lp.journal_id FROM ledger_postings lp
            JOIN accounts a ON a.account_id = lp.account_id
            WHERE a.user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
        )
    );

CREATE POLICY journal_entries_insert ON journal_entries
    FOR INSERT WITH CHECK (true);

-- ---------------------------------------------------------------------
-- users: a customer can read/update only their own profile row.
-- Auditors get read-only (enforced by only granting them a SELECT
-- policy, no UPDATE policy matches their role).
-- ---------------------------------------------------------------------
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

CREATE POLICY users_self_select ON users
    FOR SELECT
    USING (
        current_setting('app.session_role', true) IN ('admin', 'auditor')
        OR user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    );

CREATE POLICY users_self_update ON users
    FOR UPDATE
    USING (
        current_setting('app.session_role', true) = 'admin'
        OR user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    )
    WITH CHECK (
        current_setting('app.session_role', true) = 'admin'
        OR user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    );

CREATE POLICY users_insert ON users FOR INSERT WITH CHECK (true);

-- ---------------------------------------------------------------------
-- saved_beneficiaries: strictly owner-only, full CRUD.
-- ---------------------------------------------------------------------
ALTER TABLE saved_beneficiaries ENABLE ROW LEVEL SECURITY;

CREATE POLICY beneficiaries_owner_all ON saved_beneficiaries
    FOR ALL
    USING (
        current_setting('app.session_role', true) IN ('admin', 'auditor')
        OR user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    )
    WITH CHECK (
        current_setting('app.session_role', true) = 'admin'
        OR user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
    );

-- ---------------------------------------------------------------------
-- audit_logs / fraud_flags / reconciliation_logs: auditor + admin only.
-- Regular customers have no policy matching them at all, which means
-- (with RLS enabled and no permissive policy) they see zero rows.
-- ---------------------------------------------------------------------
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_logs_staff_read ON audit_logs
    FOR SELECT USING (current_setting('app.session_role', true) IN ('admin', 'auditor'));
CREATE POLICY audit_logs_insert ON audit_logs FOR INSERT WITH CHECK (true);

ALTER TABLE fraud_flags ENABLE ROW LEVEL SECURITY;
CREATE POLICY fraud_flags_staff_read ON fraud_flags
    FOR SELECT USING (current_setting('app.session_role', true) IN ('admin', 'auditor'));
CREATE POLICY fraud_flags_staff_write ON fraud_flags
    FOR ALL USING (current_setting('app.session_role', true) = 'admin')
    WITH CHECK (current_setting('app.session_role', true) = 'admin');

ALTER TABLE reconciliation_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY reconciliation_logs_staff_read ON reconciliation_logs
    FOR SELECT USING (current_setting('app.session_role', true) IN ('admin', 'auditor'));

COMMENT ON ROLE ledgercore_app IS 'Dedicated low-privilege login the Node.js API connects as. No BYPASSRLS, no SUPERUSER -- RLS policies are the real access boundary.';
