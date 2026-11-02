import { withAdminSession } from "../db";

/**
 * The "nightly audit" from the project brief: recomputes every
 * account's true balance from ledger history and compares it against
 * the cached balance, via run_daily_reconciliation() (db/migrations/
 * 013_fraud_and_reconciliation.sql). Logs a summary and flags drift
 * loudly -- in production this would page someone, not just log.
 */
export async function runNightlyReconciliation(): Promise<{ matched: number; drifted: number }> {
  return withAdminSession(async (client) => {
    const result = await client.query(`SELECT recon_status FROM run_daily_reconciliation()`);
    const matched = result.rows.filter((r) => r.recon_status === "MATCH").length;
    const drifted = result.rows.filter((r) => r.recon_status === "DRIFT").length;

    // eslint-disable-next-line no-console
    console.log(`[reconciliation] ${matched} accounts matched, ${drifted} accounts drifted.`);
    if (drifted > 0) {
      // eslint-disable-next-line no-console
      console.error(
        `[reconciliation] ALERT: ${drifted} account(s) show balance drift -- see reconciliation_logs for details.`
      );
    }

    return { matched, drifted };
  });
}
