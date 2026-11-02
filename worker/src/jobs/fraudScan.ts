import { withAdminSession } from "../db";

/** Runs the window-function velocity check (detect_fraud_velocity()) and reports how many new flags it raised. */
export async function runFraudScan(): Promise<number> {
  return withAdminSession(async (client) => {
    const result = await client.query(`SELECT detect_fraud_velocity(60, 5) AS new_flags`);
    const newFlags = result.rows[0].new_flags as number;
    if (newFlags > 0) {
      // eslint-disable-next-line no-console
      console.warn(`[fraud-scan] ${newFlags} new high-velocity flag(s) raised.`);
    } else {
      // eslint-disable-next-line no-console
      console.log(`[fraud-scan] no new flags.`);
    }
    return newFlags;
  });
}
