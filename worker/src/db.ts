import { Pool, PoolClient } from "pg";
import dotenv from "dotenv";

dotenv.config();

export const pool = new Pool({ connectionString: process.env.DATABASE_URL });

pool.on("error", (err) => {
  // eslint-disable-next-line no-console
  console.error("Unexpected error on idle Postgres client (worker):", err);
});

/**
 * The worker's jobs are inherently cross-account (reconciliation scans
 * every account, the outbox dispatcher touches events for any journal
 * entry, the fraud scan looks across all accounts for velocity). So
 * every worker transaction runs with app.session_role = 'admin', which
 * the RLS policies (db/migrations/011_rls_policies.sql) treat as
 * full-visibility -- same mechanism the API's admin routes use, just
 * applied to every job here since the worker has no single "customer"
 * identity of its own.
 */
export async function withAdminSession<T>(fn: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.session_role', 'admin', true)");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK").catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}
