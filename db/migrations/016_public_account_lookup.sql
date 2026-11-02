-- =====================================================================
-- 016_public_account_lookup.sql
--
-- Real bug found via API integration testing: the beneficiaries list
-- endpoint JOINs saved_beneficiaries to accounts to show the payee's
-- account number and currency. Under RLS, a customer can only see
-- their OWN account rows -- so joining to someone else's account (the
-- whole point of a beneficiary list) silently drops the row entirely,
-- making a customer's own saved payees disappear from their own list.
--
-- Fix: a narrow SECURITY DEFINER function exposing only the two
-- non-sensitive columns (account_number, currency) that are safe for
-- any authenticated user to resolve for a beneficiary account id --
-- never balance, status, or anything else. This is intentionally NOT a
-- blanket RLS bypass: it's a single-purpose "public directory lookup",
-- the same category of thing as a bank letting you confirm an IFSC/
-- account-number pair exists before you save it as a payee.
-- =====================================================================

CREATE OR REPLACE FUNCTION get_account_public_info(p_account_id UUID)
RETURNS TABLE(account_number VARCHAR, currency CHAR(3))
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT account_number, currency FROM accounts WHERE account_id = p_account_id;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION get_account_public_info IS 'Narrow RLS-bypassing lookup of ONLY account_number/currency -- never balance or status. Lets a customer resolve basic info about an account they do not own (e.g. a beneficiary they are saving), without exposing anything sensitive about it.';
