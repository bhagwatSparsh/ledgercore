import { withAdminSession } from "../db";

/**
 * Refreshes mv_daily_settlement (the materialized view behind the
 * admin dashboard's volume chart). CONCURRENTLY means readers never see
 * a locked/empty view mid-refresh -- the unique index created in
 * 012_views.sql is what makes CONCURRENTLY possible at all.
 */
export async function refreshDailySettlement(): Promise<void> {
  await withAdminSession(async (client) => {
    // Calls a SECURITY DEFINER wrapper (017_refresh_settlement_fn.sql)
    // rather than REFRESH directly -- that statement requires actual
    // Postgres object OWNERSHIP, which ledgercore_app deliberately
    // doesn't have, separate from the app-level admin RLS context.
    await client.query(`SELECT refresh_daily_settlement()`);
  });
  // eslint-disable-next-line no-console
  console.log(`[settlement-refresh] mv_daily_settlement refreshed.`);
}
