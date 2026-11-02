-- =====================================================================
-- Migration 022: fix audit_row_change() -- CASE expression bug
--
-- Bug: the original function (010_functions_triggers.sql) picked the
-- audited record's ID with a single CASE expression:
--
--   v_record_id := CASE TG_TABLE_NAME
--       WHEN 'accounts'       THEN NEW.account_id
--       WHEN 'users'          THEN NEW.user_id
--       WHEN 'account_limits' THEN NEW.account_id
--   END;
--
-- PL/pgSQL type-checks every branch of a CASE expression against NEW's
-- actual row type -- even branches that won't be taken at runtime. When
-- this fires on account_limits (which has no user_id column), Postgres
-- raises "record 'new' has no field 'user_id'" even though that branch
-- was never selected. Caught live while testing PATCH /accounts/:id/limits.
--
-- Fix: use separate IF/ELSIF statements instead of one CASE expression.
-- Each branch is a distinct PL/pgSQL statement, so only the one that
-- actually matches TG_TABLE_NAME gets compiled/evaluated -- the others
-- are never type-checked against NEW at all.
-- =====================================================================

CREATE OR REPLACE FUNCTION audit_row_change()
RETURNS TRIGGER AS $$
DECLARE
    v_record_id UUID;
BEGIN
    IF TG_TABLE_NAME = 'accounts' THEN
        v_record_id := NEW.account_id;
    ELSIF TG_TABLE_NAME = 'users' THEN
        v_record_id := NEW.user_id;
    ELSIF TG_TABLE_NAME = 'account_limits' THEN
        v_record_id := NEW.account_id;
    END IF;

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
