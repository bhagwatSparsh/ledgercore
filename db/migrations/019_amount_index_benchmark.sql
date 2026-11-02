-- =====================================================================
-- 019_amount_index_benchmark.sql
--
-- Phase 8 benchmark: large-transaction / AML-style compliance reports
-- ("show me every posting over threshold X") filter on amount_minor,
-- which until now had no index -- every such query degenerated into a
-- Parallel Seq Scan across EVERY monthly partition of ledger_postings.
-- See db/benchmarks/explain_before_index.txt / explain_after_index.txt
-- for the captured EXPLAIN ANALYZE proof.
--
-- Because ledger_postings is RANGE-partitioned, creating the index
-- directly on the parent (not on an individual partition) makes
-- Postgres create it on every existing partition AND automatically
-- attach it to every future partition created by
-- create_monthly_ledger_partition() -- no extra maintenance needed.
-- =====================================================================

CREATE INDEX IF NOT EXISTS idx_ledger_postings_amount ON ledger_postings (amount_minor);

COMMENT ON INDEX idx_ledger_postings_amount IS 'Speeds up large-transaction / compliance-style range queries on amount_minor. Added after benchmarking showed these degenerated into a full parallel sequential scan across every monthly partition.';
