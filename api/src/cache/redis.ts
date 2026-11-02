import Redis from "ioredis";
import dotenv from "dotenv";

dotenv.config();

/**
 * The cache is a CONVENIENCE layer, never a source of truth. If Redis
 * is slow, unreachable, or simply not configured, every function in
 * balanceCache.ts falls through to Postgres instead of throwing -- a
 * missing cache should degrade performance, not break the app. That's
 * why every cache read/write below is wrapped in try/catch.
 */
export const redis = new Redis(process.env.REDIS_URL ?? "redis://localhost:6379", {
  maxRetriesPerRequest: 1,
  retryStrategy: () => null, // don't keep retrying forever if Redis is down; just fail fast and fall through
  lazyConnect: true,
});

let connectionAttempted = false;

export async function ensureRedisConnection(): Promise<boolean> {
  const currentStatus: string = redis.status;
  if (currentStatus === "ready") return true;
  if (connectionAttempted && currentStatus !== "end") return false;
  connectionAttempted = true;
  try {
    await redis.connect();
    return true;
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn("Redis unavailable, continuing without cache:", (err as Error).message);
    return false;
  }
}
