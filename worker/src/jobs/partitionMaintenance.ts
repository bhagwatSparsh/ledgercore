import { withAdminSession } from "../db";

/**
 * Ensures ledger_postings has a partition ready for next month before
 * it's needed -- an INSERT into a partitioned table with no matching
 * partition fails outright (see db/migrations/004_ledger.sql), so this
 * must run ahead of the month boundary, not react to it.
 */
export async function ensureNextPartitionExists(): Promise<void> {
  await withAdminSession(async (client) => {
    const nextMonth = new Date();
    nextMonth.setMonth(nextMonth.getMonth() + 1);
    nextMonth.setDate(1);
    const iso = nextMonth.toISOString().slice(0, 10);

    await client.query(`SELECT create_monthly_ledger_partition($1)`, [iso]);
  });
  // eslint-disable-next-line no-console
  console.log(`[partition-maintenance] next month's ledger_postings partition confirmed.`);
}
