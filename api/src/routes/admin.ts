import { Router } from "express";
import { withSession } from "../db/pool";
import { requireAuth, requireRole, AuthedRequest } from "../middleware/auth";

const router = Router();
router.use(requireAuth, requireRole("admin", "auditor"));

// GET /admin/fraud-flags -- backs the admin dashboard's fraud panel.
router.get("/fraud-flags", async (req: AuthedRequest, res, next) => {
  try {
    const rows = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `SELECT f.flag_id, f.account_id, a.account_number, f.rule_name, f.detail, f.severity, f.resolved, f.created_at
         FROM fraud_flags f JOIN accounts a ON a.account_id = f.account_id
         ORDER BY f.created_at DESC LIMIT 100`
      );
      return result.rows;
    });
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

// GET /admin/reconciliation -- latest drift report.
router.get("/reconciliation", async (req: AuthedRequest, res, next) => {
  try {
    const rows = await withSession(req.session!, async (client) => {
      // DISTINCT ON (account_id), ordered by created_at DESC, picks each
      // account's single MOST RECENT reconciliation row -- not just
      // "every row from the latest date". The nightly job normally runs
      // once a day, but a manually re-triggered run (ops investigating a
      // flagged account) or a job restart can insert a second row for
      // the same account on the same run_date; without this, the admin
      // report would show that account twice.
      const result = await client.query(
        `SELECT recon_id, account_id, account_number, currency, run_date, expected_balance_minor,
                actual_balance_minor, status
         FROM (
           SELECT DISTINCT ON (r.account_id)
                  r.recon_id, r.account_id, a.account_number, a.currency, r.run_date,
                  r.expected_balance_minor, r.actual_balance_minor, r.status, r.created_at
           FROM reconciliation_logs r
           JOIN accounts a ON a.account_id = r.account_id
           ORDER BY r.account_id, r.created_at DESC
         ) latest
         ORDER BY status DESC, account_number`
      );
      return result.rows;
    });
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

// GET /admin/settlement -- daily volume rollup (mv_daily_settlement) for the dashboard chart.
router.get("/settlement", async (req: AuthedRequest, res, next) => {
  try {
    const rows = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `SELECT settlement_date, currency, entry_type, transaction_count, total_debited_minor, total_credited_minor
         FROM mv_daily_settlement ORDER BY settlement_date DESC LIMIT 60`
      );
      return result.rows;
    });
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

// GET /admin/audit-logs -- recent sensitive-change audit trail.
router.get("/audit-logs", async (req: AuthedRequest, res, next) => {
  try {
    const rows = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `SELECT audit_id, actor_user_id, action, table_name, record_id, old_value, new_value, created_at
         FROM audit_logs ORDER BY created_at DESC LIMIT 100`
      );
      return result.rows;
    });
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

export default router;
