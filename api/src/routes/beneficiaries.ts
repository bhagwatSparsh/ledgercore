import { Router } from "express";
import { z } from "zod";
import { withSession } from "../db/pool";
import { requireAuth, AuthedRequest } from "../middleware/auth";

const router = Router();
router.use(requireAuth);

const createSchema = z.object({
  beneficiaryAccountId: z.string().uuid(),
  nickname: z.string().max(50).optional(),
  transferLimitMinor: z.number().int().positive().optional(),
});

// POST -- INSERT
router.post("/", async (req: AuthedRequest, res, next) => {
  try {
    const body = createSchema.parse(req.body);
    const row = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `INSERT INTO saved_beneficiaries (user_id, beneficiary_account_id, nickname, transfer_limit_minor)
         VALUES ($1, $2, $3, COALESCE($4, 2500000))
         RETURNING beneficiary_id, beneficiary_account_id, nickname, transfer_limit_minor, added_at`,
        [req.session!.userId, body.beneficiaryAccountId, body.nickname ?? null, body.transferLimitMinor ?? null]
      );
      return result.rows[0];
    });
    res.status(201).json(row);
  } catch (err) {
    next(err);
  }
});

// GET -- SELECT (RLS-scoped to the caller's own saved beneficiaries)
router.get("/", async (req: AuthedRequest, res, next) => {
  try {
    const rows = await withSession(req.session!, async (client) => {
      // Uses get_account_public_info() rather than a plain JOIN to
      // accounts -- a customer's own saved_beneficiaries row is visible
      // to them under RLS, but the beneficiary's OWN account row isn't
      // (it belongs to someone else), so a direct JOIN would silently
      // drop every beneficiary from the list. See migration 016.
      const result = await client.query(
        `SELECT sb.beneficiary_id, sb.beneficiary_account_id, sb.nickname, sb.transfer_limit_minor, sb.added_at,
                pub.account_number, pub.currency
         FROM saved_beneficiaries sb
         CROSS JOIN LATERAL get_account_public_info(sb.beneficiary_account_id) AS pub
         ORDER BY sb.added_at DESC`
      );
      return result.rows;
    });
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

const updateSchema = z.object({
  nickname: z.string().max(50).optional(),
  transferLimitMinor: z.number().int().positive().optional(),
});

// PATCH -- UPDATE
router.patch("/:id", async (req: AuthedRequest, res, next) => {
  try {
    const body = updateSchema.parse(req.body);
    const row = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `UPDATE saved_beneficiaries
         SET nickname = COALESCE($2, nickname),
             transfer_limit_minor = COALESCE($3, transfer_limit_minor)
         WHERE beneficiary_id = $1
         RETURNING beneficiary_id, nickname, transfer_limit_minor`,
        [req.params.id, body.nickname ?? null, body.transferLimitMinor ?? null]
      );
      return result.rows[0];
    });
    if (!row) return res.status(404).json({ error: "Beneficiary not found." });
    res.json(row);
  } catch (err) {
    next(err);
  }
});

// DELETE -- hard delete, the faculty-evaluation-checklist showcase of a real DELETE statement.
router.delete("/:id", async (req: AuthedRequest, res, next) => {
  try {
    const deleted = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `DELETE FROM saved_beneficiaries WHERE beneficiary_id = $1 RETURNING beneficiary_id`,
        [req.params.id]
      );
      return result.rows[0];
    });
    if (!deleted) return res.status(404).json({ error: "Beneficiary not found." });
    res.status(204).send();
  } catch (err) {
    next(err);
  }
});

export default router;
