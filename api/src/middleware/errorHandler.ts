import { Request, Response, NextFunction } from "express";

/**
 * Centralized error translator. Database exceptions raised from our own
 * PL/pgSQL (RAISE EXCEPTION ...) carry a human-readable message that is
 * SAFE to show the client -- we wrote those messages ourselves
 * specifically for this purpose ("Insufficient funds in account...",
 * "Transfer would exceed daily limit..."). Anything else (a genuine
 * unexpected DB/connection error) is logged in full server-side but
 * returned to the client as a generic message, so internal details
 * never leak.
 */
const KNOWN_SAFE_PG_PREFIXES = [
  "Insufficient funds",
  "Transfer would exceed",
  "Amount",
  "Sender account",
  "Receiver account",
  "Sender and receiver",
  "Currency mismatch",
  "Same-currency transfer",
  "No clearing account",
  "No FX rate",
  "Both accounts must be ACTIVE",
  "CRITICAL: ledger_postings",
  "Zero-sum invariant",
  "Sender or receiver account does not exist",
];

export function errorHandler(err: any, req: Request, res: Response, _next: NextFunction) {
  // eslint-disable-next-line no-console
  console.error(`[${new Date().toISOString()}] ${req.method} ${req.path} ->`, err);

  const message: string | undefined = err?.message;
  if (message && KNOWN_SAFE_PG_PREFIXES.some((p) => message.startsWith(p))) {
    return res.status(422).json({ error: message });
  }

  if (err?.code === "23505") {
    // Postgres unique_violation
    return res.status(409).json({ error: "A record with that unique value already exists." });
  }

  if (err?.code === "42501") {
    // Postgres insufficient_privilege -- what process_transfer()/process_withdrawal()
    // raise when the caller names an account they don't own as the one being debited.
    return res.status(403).json({ error: message ?? "You do not have permission to perform this action." });
  }

  if (err?.status) {
    return res.status(err.status).json({ error: err.message ?? "Request failed." });
  }

  return res.status(500).json({ error: "Internal server error." });
}
