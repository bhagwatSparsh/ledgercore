-- =====================================================================
-- 001_extensions_and_roles.sql
-- Extensions + RBAC role catalog
-- =====================================================================

-- UUID generation, used as surrogate keys everywhere instead of
-- auto-increment ints. UUIDs avoid leaking row counts (e.g. "account #4"
-- tells a competitor how many accounts you have) and make the schema
-- safe to shard/replicate later without PK collisions.
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Role catalog for Row-Level Security policies (see 012_rls_policies.sql).
-- Kept as a real table (not an enum) so new roles can be added without a
-- schema migration.
CREATE TABLE roles (
    role_id     SMALLINT PRIMARY KEY,
    role_name   VARCHAR(30) UNIQUE NOT NULL
);

INSERT INTO roles (role_id, role_name) VALUES
    (1, 'admin'),      -- full access, bypasses RLS via BYPASSRLS grant
    (2, 'customer'),   -- can only see/modify rows tied to their own user_id
    (3, 'auditor');    -- read-only access to everything, no writes

COMMENT ON TABLE roles IS 'RBAC role catalog, referenced by user_roles and enforced via Postgres Row-Level Security policies.';
