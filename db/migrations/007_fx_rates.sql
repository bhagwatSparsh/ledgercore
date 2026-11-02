-- =====================================================================
-- 007_fx_rates.sql
-- Multi-currency support
-- =====================================================================

CREATE TABLE fx_rates (
    base_currency  CHAR(3) NOT NULL,
    quote_currency CHAR(3) NOT NULL,
    rate           NUMERIC(18, 8) NOT NULL CHECK (rate > 0),
    as_of          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (base_currency, quote_currency, as_of)
);

CREATE INDEX idx_fx_rates_lookup ON fx_rates (base_currency, quote_currency, as_of DESC);

-- Seed a few static rates so the demo works offline without a live FX API.
INSERT INTO fx_rates (base_currency, quote_currency, rate) VALUES
    ('USD', 'INR', 83.25000000),
    ('INR', 'USD', 0.01201201),
    ('EUR', 'INR', 90.10000000),
    ('INR', 'EUR', 0.01109878),
    ('USD', 'EUR', 0.92300000),
    ('EUR', 'USD', 1.08342362);

COMMENT ON TABLE fx_rates IS 'Cross-currency transfers look up the latest rate (MAX(as_of)) at execution time and store the applied rate on the journal_entries row for auditability.';

-- Track which FX rate was actually applied to a given journal entry, so
-- the transaction remains auditable even after the rate changes later.
ALTER TABLE journal_entries
    ADD COLUMN fx_rate_applied NUMERIC(18, 8),
    ADD COLUMN source_currency CHAR(3),
    ADD COLUMN target_currency CHAR(3);

