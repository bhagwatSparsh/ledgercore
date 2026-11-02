-- =====================================================================
-- 018_reconciliation_security_definer.sql
--
-- Real bug found running the worker's reconciliation job for the first
-- time through the actual ledgercore_app role (every prior test of
-- run_daily_reconciliation() was run as the postgres superuser, which
-- bypasses RLS entirely and so never exercised this path): the
-- reconciliation_logs table was given a SELECT policy for staff
-- (011_rls_policies.sql) but no INSERT policy at all -- so the
-- function's own INSERT into its own audit table was rejected by RLS
-- with zero permissive policies to allow it.
--
-- Fix: SECURITY DEFINER, the same pattern used throughout this project
-- for "system-level" functions that legitimately need to write data a
-- normal caller shouldn't be able to write directly.
-- =====================================================================

ALTER FUNCTION run_daily_reconciliation(DATE) SECURITY DEFINER SET search_path = public, pg_temp;

COMMENT ON FUNCTION run_daily_reconciliation IS 'Nightly job: recomputes true balances from ledger history, flags drift in reconciliation_logs, refreshes balance_snapshots. SECURITY DEFINER: reconciliation_logs intentionally has no direct INSERT policy for any role (only this trusted function writes to it).';
