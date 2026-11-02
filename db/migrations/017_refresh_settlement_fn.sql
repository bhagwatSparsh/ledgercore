-- =====================================================================
-- 017_refresh_settlement_fn.sql
--
-- Real bug found running the worker: REFRESH MATERIALIZED VIEW requires
-- the calling ROLE to literally own the object (or be superuser) -- this
-- is a Postgres role-level privilege check, completely separate from
-- the app.session_role='admin' RLS context the rest of this project
-- uses. Setting that session variable has no effect on it. ledgercore_app
-- isn't the owner (postgres is), so the worker's refresh job failed.
--
-- Fix: the same narrow-SECURITY-DEFINER pattern used elsewhere, rather
-- than handing ledgercore_app ownership of the view outright.
-- =====================================================================

CREATE OR REPLACE FUNCTION refresh_daily_settlement()
RETURNS VOID
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_settlement;
$$ LANGUAGE sql;

COMMENT ON FUNCTION refresh_daily_settlement IS 'SECURITY DEFINER wrapper for REFRESH MATERIALIZED VIEW, which requires object ownership that ledgercore_app intentionally does not have.';
