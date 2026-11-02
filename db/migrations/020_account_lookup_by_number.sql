-- =====================================================================
-- 020_account_lookup_by_number.sql
--
-- Phase 9 (frontend) need: a customer sending money types the
-- recipient's account NUMBER, never their internal UUID -- so the
-- dashboard needs a way to resolve "account number typed by a stranger"
-- into the account_id process_transfer() actually requires, without
-- RLS silently hiding the row (the typed account almost certainly
-- belongs to someone else, same situation already solved for
-- get_account_public_info() in migration 016).
--
-- Deliberately returns nothing but the id/number/currency -- never
-- balance, status, or owner -- so this can't be used to probe a
-- stranger's account for anything beyond "does this account number
-- exist, and what currency is it in" (needed client-side to warn
-- before a same-currency-only transfer, FX being a separate flow).
-- =====================================================================

CREATE OR REPLACE FUNCTION get_account_id_by_number(p_account_number VARCHAR)
RETURNS TABLE(account_id UUID, account_number VARCHAR, currency CHAR(3))
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT account_id, account_number, currency
    FROM accounts
    WHERE account_number = p_account_number
      AND status = 'ACTIVE';
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION get_account_id_by_number IS 'SECURITY DEFINER lookup used by the "send money" flow to resolve a typed account number to its id across RLS, without exposing balance/owner/status.';
