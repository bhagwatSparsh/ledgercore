import { Pool, PoolClient } from "pg";
import dotenv from "dotenv";

dotenv.config();

export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 20,
  idleTimeoutMillis: 30_000,
});

pool.on("error", (err) => {
  // eslint-disable-next-line no-console
  console.error("Unexpected error on idle Postgres client", err);
});

export interface SessionContext {
  userId: string | null; // null = system/unauthenticated context
  role: "admin" | "customer" | "auditor";
}

/**
 * withSession() is THE pattern every DB-touching request handler uses.
 *
 * Row-Level Security policies (db/migrations/011_rls_policies.sql) read
 * two Postgres session variables -- app.current_user_id and
 * app.session_role -- to decide which rows a query can see or touch.
 *
 * Because the API uses a connection POOL, we cannot just run
 * `SET app.current_user_id = ...` once and forget it: pooled
 * connections are reused across different requests/users, so a plain
 * SET would leak one user's identity onto the next request that
 * happens to grab the same underlying connection.
 *
 * The fix is `SET LOCAL`, which only applies for the duration of the
 * current transaction and is automatically cleared at COMMIT/ROLLBACK.
 * So every DB operation here runs inside an explicit transaction:
 * acquire a client -> BEGIN -> SET LOCAL (the identity) -> run the
 * caller's queries -> COMMIT -> release the client back to the pool
 * clean. If anything throws, we ROLLBACK instead, so a failed request
 * can never partially commit.
 */
export async function withSession<T>(
  ctx: SessionContext,
  fn: (client: PoolClient) => Promise<T>
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    // Postgres's SET/SET LOCAL statements only accept literal values, not
    // query parameters ($1) -- set_config() is the parameterized
    // equivalent. Its third argument (true) scopes it to the current
    // transaction only, exactly like SET LOCAL, which is what keeps this
    // safe to use with a pooled connection (see withSession() doc comment).
    await client.query("SELECT set_config('app.session_role', $1, true)", [ctx.role]);
    if (ctx.userId) {
      await client.query("SELECT set_config('app.current_user_id', $1, true)", [ctx.userId]);
    }
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK").catch(() => {
      /* connection may already be broken; nothing more we can do */
    });
    throw err;
  } finally {
    client.release();
  }
}
