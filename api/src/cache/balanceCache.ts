import { redis, ensureRedisConnection } from "./redis";

const TTL_SECONDS = 10; // balances change often -- a short TTL keeps staleness bounded even without explicit invalidation

function key(accountId: string): string {
  return `balance:${accountId}`;
}

/**
 * Cache-aside read: check Redis first; on a miss, the CALLER queries
 * Postgres and then calls setCachedBalance() to populate it for next
 * time. Returns null on a cache miss OR if Redis is unavailable --
 * either way, the caller's job is the same: go to the database.
 */
export async function getCachedBalance(accountId: string): Promise<string | null> {
  const connected = await ensureRedisConnection();
  if (!connected) return null;
  try {
    return await redis.get(key(accountId));
  } catch {
    return null; // cache failure is never fatal
  }
}

export async function setCachedBalance(accountId: string, balanceMinor: string): Promise<void> {
  const connected = await ensureRedisConnection();
  if (!connected) return;
  try {
    await redis.set(key(accountId), balanceMinor, "EX", TTL_SECONDS);
  } catch {
    /* ignore -- worst case, the next read is a cache miss */
  }
}

/**
 * Called after any successful write that changes an account's balance
 * (transfer, deposit, withdrawal, FX conversion). Invalidating
 * immediately rather than waiting out the TTL means a user who just
 * sent money sees their new balance right away, not up to 10 seconds
 * stale -- the TTL is a safety net for accounts nobody explicitly
 * invalidated (e.g. the receiving side of someone else's transfer,
 * caught by whichever happens first: invalidation or TTL expiry).
 */
export async function invalidateBalance(accountId: string): Promise<void> {
  const connected = await ensureRedisConnection();
  if (!connected) return;
  try {
    await redis.del(key(accountId));
  } catch {
    /* ignore */
  }
}

export async function invalidateBalances(accountIds: string[]): Promise<void> {
  await Promise.all(accountIds.map(invalidateBalance));
}
