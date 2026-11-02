import { Router } from "express";
import { z } from "zod";
import { withSession } from "../db/pool";
import { requireAuth, requireRole, AuthedRequest } from "../middleware/auth";
import { getCachedBalance, setCachedBalance } from "../cache/balanceCache";

const router = Router();
router.use(requireAuth);

function generateAccountNumber(): string {
  return "ACC" + Math.floor(1_000_000_000 + Math.random() * 9_000_000_000).toString();
}

const createAccountSchema = z.object({
  accountType: z.enum(["SAVINGS", "CURRENT", "WALLET"]).default("SAVINGS"),
  currency: z.enum(["INR", "USD", "EUR"]).default("INR"),
});

// POST /accounts -- INSERT, owned by the authenticated user (RLS enforces this regardless).
router.post("/", async (req: AuthedRequest, res, next) => {
  try {
    const body = createAccountSchema.parse(req.body);
    const account = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `INSERT INTO accounts (user_id, account_number, account_type, currency)
         VALUES ($1, $2, $3, $4)
         RETURNING account_id, account_number, account_type, currency, cached_balance_minor, status`,
        [req.session!.userId, generateAccountNumber(), body.accountType, body.currency]
      );
      await client.query(`INSERT INTO account_limits (account_id) VALUES ($1)`, [
        result.rows[0].account_id,
      ]);
      return result.rows[0];
    });
    res.status(201).json(account);
  } catch (err) {
    next(err);
  }
});

// GET /accounts -- SELECT, scoped by RLS to the caller's own accounts (admin/auditor see all).
router.get("/", async (req: AuthedRequest, res, next) => {
  try {
    const accounts = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `SELECT account_id, account_number, account_type, currency, cached_balance_minor, status, created_at
         FROM accounts ORDER BY created_at DESC`
      );
      return result.rows;
    });
    res.json(accounts);
  } catch (err) {
    next(err);
  }
});

// GET /accounts/lookup/:accountNumber -- resolves a typed account
// number to its id/currency for the "send money" flow, via the
// SECURITY DEFINER function so it works regardless of whose account
// it is (see migration 020). Intentionally returns nothing else.
router.get("/lookup/:accountNumber", async (req: AuthedRequest, res, next) => {
  try {
    const row = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `SELECT account_id, account_number, currency FROM get_account_id_by_number($1)`,
        [req.params.accountNumber]
      );
      return result.rows[0];
    });
    if (!row) return res.status(404).json({ error: "No active account with that number." });
    res.json(row);
  } catch (err) {
    next(err);
  }
});

// GET /accounts/:id/balance -- the cache-aside demo endpoint. This is
// the "hot path": a real app calls this constantly (every app open,
// every pull-to-refresh), far more often than it calls /statement or
// /transfers. Checking Redis first instead of Postgres every time is
// what the caching layer is actually for.
router.get("/:id/balance", async (req: AuthedRequest, res, next) => {
  try {
    const cached = await getCachedBalance(req.params.id);
    if (cached !== null) {
      return res.json({ accountId: req.params.id, cachedBalanceMinor: cached, source: "cache" });
    }

    const row = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `SELECT cached_balance_minor FROM accounts WHERE account_id = $1`,
        [req.params.id]
      );
      return result.rows[0];
    });

    if (!row) return res.status(404).json({ error: "Account not found." });

    await setCachedBalance(req.params.id, row.cached_balance_minor);
    res.json({ accountId: req.params.id, cachedBalanceMinor: row.cached_balance_minor, source: "database" });
  } catch (err) {
    next(err);
  }
});

// GET /accounts/:id/statement -- the passbook view (SELECT + window function running balance).
router.get("/:id/statement", async (req: AuthedRequest, res, next) => {
  try {
    const rows = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `SELECT posting_id, journal_id, entry_type, description, direction,
                amount_minor, currency, created_at, running_balance_minor
         FROM v_account_statement
         WHERE account_id = $1
         ORDER BY created_at DESC
         LIMIT 100`,
        [req.params.id]
      );
      return result.rows;
    });
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

const updateLimitsSchema = z.object({
  dailyLimitMinor: z.number().int().positive().optional(),
  perTxnLimitMinor: z.number().int().positive().optional(),
});

// PATCH /accounts/:id/limits -- UPDATE, demonstrates standard CRUD alongside the ledger tables.
router.patch("/:id/limits", async (req: AuthedRequest, res, next) => {
  try {
    const body = updateLimitsSchema.parse(req.body);
    const updated = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `UPDATE account_limits
         SET daily_limit_minor = COALESCE($2, daily_limit_minor),
             per_txn_limit_minor = COALESCE($3, per_txn_limit_minor),
             updated_at = now()
         WHERE account_id = $1
         RETURNING account_id, daily_limit_minor, per_txn_limit_minor`,
        [req.params.id, body.dailyLimitMinor ?? null, body.perTxnLimitMinor ?? null]
      );
      return result.rows[0];
    });
    if (!updated) return res.status(404).json({ error: "Account not found." });
    res.json(updated);
  } catch (err) {
    next(err);
  }
});

const statusSchema = z.object({ status: z.enum(["ACTIVE", "FROZEN", "CLOSED"]) });

// PATCH /accounts/:id/status -- admin-only UPDATE. Fires trg_audit_account_status.
router.patch("/:id/status", requireRole("admin"), async (req: AuthedRequest, res, next) => {
  try {
    const body = statusSchema.parse(req.body);
    const updated = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `UPDATE accounts SET status = $2, updated_at = now() WHERE account_id = $1
         RETURNING account_id, status`,
        [req.params.id, body.status]
      );
      return result.rows[0];
    });
    if (!updated) return res.status(404).json({ error: "Account not found." });
    res.json(updated);
  } catch (err) {
    next(err);
  }
});

export default router;
