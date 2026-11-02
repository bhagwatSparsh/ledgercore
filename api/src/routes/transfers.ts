import { Router } from "express";
import { z } from "zod";
import crypto from "crypto";
import { v4 as uuidv4 } from "uuid";
import { withSession } from "../db/pool";
import { requireAuth, AuthedRequest } from "../middleware/auth";
import { invalidateBalances } from "../cache/balanceCache";

const router = Router();
router.use(requireAuth);

const transferSchema = z.object({
  senderAccountId: z.string().uuid(),
  receiverAccountId: z.string().uuid(),
  amountMinor: z.number().int().positive(),
  currency: z.enum(["INR", "USD", "EUR"]),
  description: z.string().max(500).optional(),
});

function hashBody(body: unknown): string {
  return crypto.createHash("sha256").update(JSON.stringify(body)).digest("hex");
}

/**
 * POST /transfers
 *
 * Demonstrates the full idempotency flow described in the project
 * brief: the client sends an `Idempotency-Key` header. If we've already
 * fully processed that key, we replay the cached response instead of
 * calling process_transfer() again -- so a network retry after a
 * timeout can never double-charge. If a request with that key is
 * CURRENTLY in flight (the original call hasn't finished), we reject
 * the duplicate outright rather than racing it.
 */
router.post("/", async (req: AuthedRequest, res, next) => {
  const idempotencyKeyHeader = req.header("Idempotency-Key");
  if (!idempotencyKeyHeader) {
    return res.status(400).json({ error: "Idempotency-Key header is required for transfers." });
  }

  try {
    const body = transferSchema.parse(req.body);
    const requestHash = hashBody(body);

    const result = await withSession(req.session!, async (client) => {
      const existing = await client.query(
        `SELECT status, response_body, request_hash FROM idempotency_keys WHERE idempotency_key = $1`,
        [idempotencyKeyHeader]
      );

      if (existing.rows.length > 0) {
        const row = existing.rows[0];
        if (row.request_hash !== requestHash) {
          const err: any = new Error("Idempotency-Key reused with a different request body.");
          err.status = 409;
          throw err;
        }
        if (row.status === "COMPLETED") {
          return { replay: true, body: row.response_body };
        }
        if (row.status === "PROCESSING") {
          const err: any = new Error("A request with this Idempotency-Key is already being processed.");
          err.status = 409;
          throw err;
        }
        // status === 'FAILED' -> fall through and retry below
      } else {
        await client.query(
          `INSERT INTO idempotency_keys (idempotency_key, user_id, request_hash, status)
           VALUES ($1, $2, $3, 'PROCESSING')`,
          [idempotencyKeyHeader, req.session!.userId, requestHash]
        );
      }

      // A SAVEPOINT here matters: if process_transfer() raises (bad
      // ownership, insufficient funds, frozen account, etc.), Postgres
      // marks the WHOLE enclosing transaction as aborted, not just that
      // one statement -- so the "mark this idempotency key as FAILED"
      // UPDATE below would itself fail with "current transaction is
      // aborted", masking the real, correct rejection behind a generic
      // 500. Rolling back to the savepoint undoes only the failed
      // process_transfer() call, leaving the rest of the transaction
      // (including the PROCESSING row inserted above) usable.
      await client.query("SAVEPOINT before_transfer");
      try {
        const txn = await client.query(
          `SELECT process_transfer($1, $2, $3, $4, $5, $6, $7) AS journal_id`,
          [
            body.senderAccountId,
            body.receiverAccountId,
            body.amountMinor,
            body.currency,
            idempotencyKeyHeader,
            req.session!.userId,
            body.description ?? null,
          ]
        );

        const responseBody = {
          journalId: txn.rows[0].journal_id,
          status: "COMPLETED",
          senderAccountId: body.senderAccountId,
          receiverAccountId: body.receiverAccountId,
          amountMinor: body.amountMinor,
          currency: body.currency,
        };

        await client.query(
          `UPDATE idempotency_keys SET status = 'COMPLETED', response_body = $2 WHERE idempotency_key = $1`,
          [idempotencyKeyHeader, JSON.stringify(responseBody)]
        );

        return { replay: false, body: responseBody };
      } catch (procErr) {
        await client.query("ROLLBACK TO SAVEPOINT before_transfer");
        await client.query(
          `UPDATE idempotency_keys SET status = 'FAILED' WHERE idempotency_key = $1`,
          [idempotencyKeyHeader]
        );
        throw procErr;
      }
    });

    // Only invalidate on an actual new transfer, not an idempotency
    // replay -- a replay means nothing in the database changed, so the
    // cached balance (if any) is still accurate.
    if (!result.replay) {
      await invalidateBalances([body.senderAccountId, body.receiverAccountId]);
    }

    res.status(result.replay ? 200 : 201).json(result.body);
  } catch (err) {
    next(err);
  }
});

const fxTransferSchema = z.object({
  senderAccountId: z.string().uuid(),
  receiverAccountId: z.string().uuid(),
  sendAmountMinor: z.number().int().positive(),
  description: z.string().max(500).optional(),
});

// POST /transfers/fx -- cross-currency transfer via process_fx_transfer().
router.post("/fx", async (req: AuthedRequest, res, next) => {
  const idempotencyKey = req.header("Idempotency-Key") ?? uuidv4();
  try {
    const body = fxTransferSchema.parse(req.body);
    const journalId = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `SELECT process_fx_transfer($1, $2, $3, $4, $5, $6) AS journal_id`,
        [
          body.senderAccountId,
          body.receiverAccountId,
          body.sendAmountMinor,
          idempotencyKey,
          req.session!.userId,
          body.description ?? null,
        ]
      );
      return result.rows[0].journal_id;
    });
    await invalidateBalances([body.senderAccountId, body.receiverAccountId]);
    res.status(201).json({ journalId, status: "COMPLETED" });
  } catch (err) {
    next(err);
  }
});

const depositSchema = z.object({
  accountId: z.string().uuid(),
  amountMinor: z.number().int().positive(),
  currency: z.enum(["INR", "USD", "EUR"]),
});

// POST /transfers/deposit -- external cash-in (process_deposit()), e.g. "add money" in the demo UI.
router.post("/deposit", async (req: AuthedRequest, res, next) => {
  try {
    const body = depositSchema.parse(req.body);
    const journalId = await withSession(req.session!, async (client) => {
      const result = await client.query(`SELECT process_deposit($1, $2, $3, $4) AS journal_id`, [
        body.accountId,
        body.amountMinor,
        body.currency,
        req.session!.userId,
      ]);
      return result.rows[0].journal_id;
    });
    await invalidateBalances([body.accountId]);
    res.status(201).json({ journalId, status: "COMPLETED" });
  } catch (err) {
    next(err);
  }
});

// GET /transfers/:journalId -- SELECT, RLS-scoped (journal_entries_owner_read policy).
router.get("/:journalId", async (req: AuthedRequest, res, next) => {
  try {
    const row = await withSession(req.session!, async (client) => {
      const result = await client.query(
        `SELECT je.journal_id, je.entry_type, je.description, je.status, je.created_at,
                json_agg(json_build_object(
                  'accountId', lp.account_id, 'direction', lp.direction,
                  'amountMinor', lp.amount_minor, 'currency', lp.currency
                )) AS postings
         FROM journal_entries je
         JOIN ledger_postings lp ON lp.journal_id = je.journal_id
         WHERE je.journal_id = $1
         GROUP BY je.journal_id`,
        [req.params.journalId]
      );
      return result.rows[0];
    });
    if (!row) return res.status(404).json({ error: "Transaction not found." });
    res.json(row);
  } catch (err) {
    next(err);
  }
});

export default router;
