-- =====================================================================
-- 009_system_accounts.sql
-- System-owned FX clearing accounts
--
-- Why these exist: a cross-currency transfer (USD account -> INR
-- account) cannot be a simple 2-leg posting, because "debit 100 USD,
-- credit 8325 INR" would break the per-currency zero-sum invariant
-- (100 USD debited but 0 USD credited anywhere). Real payment systems
-- solve this with an internal clearing/suspense account: the sender's
-- USD passes through a USD clearing account, and the receiver's INR
-- is paid out from an INR clearing account. This keeps every single
-- currency's debits == credits, journal-wide, with zero exceptions --
-- see process_fx_transfer() in 010_functions_triggers.sql.
-- =====================================================================

INSERT INTO users (user_id, full_name, email, phone, password_hash, kyc_status, is_active)
VALUES ('00000000-0000-0000-0000-000000000001', 'System Clearing House', 'system@ledgercore.internal',
        '0000000000', 'SYSTEM_ACCOUNT_NO_LOGIN', 'VERIFIED', TRUE);

-- Seeded with a large treasury float (10,000,000.00 in each currency's
-- minor units) modeling the liquidity reserve a real clearing house
-- holds in every currency it settles. Without this float, the
-- accounts.cached_balance_minor >= 0 CHECK constraint would reject the
-- very first FX transfer in any direction, since the clearing account
-- being debited would dip below zero before the offsetting flow
-- arrives. This is the same reason real banks pre-fund nostro/vostro
-- accounts rather than relying on perfectly matched two-way flow.
INSERT INTO accounts (account_id, user_id, account_number, account_type, currency, cached_balance_minor, status)
VALUES
    ('00000000-0000-0000-0000-00000000a1a1', '00000000-0000-0000-0000-000000000001', 'SYS-CLR-USD', 'CURRENT', 'USD', 1000000000, 'ACTIVE'),
    ('00000000-0000-0000-0000-00000000a2a2', '00000000-0000-0000-0000-000000000001', 'SYS-CLR-INR', 'CURRENT', 'INR', 1000000000, 'ACTIVE'),
    ('00000000-0000-0000-0000-00000000a3a3', '00000000-0000-0000-0000-000000000001', 'SYS-CLR-EUR', 'CURRENT', 'EUR', 1000000000, 'ACTIVE');
