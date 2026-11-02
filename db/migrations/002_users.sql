-- =====================================================================
-- 002_users.sql
-- Identity & KYC
-- =====================================================================

CREATE TABLE users (
    user_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name     VARCHAR(150) NOT NULL,
    email         VARCHAR(150) UNIQUE NOT NULL,
    phone         VARCHAR(20)  NOT NULL,
    password_hash TEXT NOT NULL,                       -- bcrypt/argon2 hash, never plaintext
    kyc_status    VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                  CHECK (kyc_status IN ('PENDING', 'VERIFIED', 'REJECTED')),
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,        -- soft-delete flag
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE user_roles (
    user_id   UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    role_id   SMALLINT NOT NULL REFERENCES roles(role_id),
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, role_id)
);

CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_user_roles_role ON user_roles(role_id);

COMMENT ON COLUMN users.is_active IS 'Soft delete: closing a profile sets this FALSE rather than removing the row, preserving ledger/audit history integrity (accounts hold FK references to users).';
