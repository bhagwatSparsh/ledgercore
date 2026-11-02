import { withAdminSession } from "../db";

const BATCH_SIZE = Number(process.env.OUTBOX_BATCH_SIZE ?? 100);
const WEBHOOK_URL = process.env.NOTIFICATION_WEBHOOK_URL;

/**
 * The other half of the transactional outbox pattern (the write half
 * lives in process_transfer()/process_deposit() in the database, which
 * insert an outbox_events row in the SAME transaction as the ledger
 * posting). This job polls for unpublished events, "delivers" them
 * (an HTTP POST to a configured webhook, or just a structured log line
 * if none is configured -- so the project runs end to end without
 * requiring an external service), and marks them published.
 *
 * Because the write and the event are atomic at the database level, a
 * crash here before marking an event published just means it gets
 * picked up again on the next poll -- at-least-once delivery, which is
 * the standard, defensible guarantee for this pattern (the alternative,
 * exactly-once, is a much harder distributed-systems problem this
 * project doesn't need to solve to make the point).
 */
export async function dispatchOutboxEvents(): Promise<number> {
  return withAdminSession(async (client) => {
    const pending = await client.query(
      `SELECT event_id, aggregate_type, aggregate_id, event_type, payload
       FROM outbox_events
       WHERE published = FALSE
       ORDER BY created_at
       LIMIT $1
       FOR UPDATE SKIP LOCKED`, // SKIP LOCKED: if multiple worker instances ever run, they never block on the same row
      [BATCH_SIZE]
    );

    if (pending.rows.length === 0) return 0;

    for (const event of pending.rows) {
      await deliver(event);
      await client.query(`UPDATE outbox_events SET published = TRUE, published_at = now() WHERE event_id = $1`, [
        event.event_id,
      ]);
    }

    return pending.rows.length;
  });
}

async function deliver(event: { event_id: string; event_type: string; payload: unknown }): Promise<void> {
  if (WEBHOOK_URL) {
    try {
      await fetch(WEBHOOK_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(event),
      });
      return;
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error(`[outbox] webhook delivery failed for ${event.event_id}, will retry next cycle:`, err);
      throw err; // don't mark published -- let it be retried
    }
  }

  // eslint-disable-next-line no-console
  console.log(`[outbox] ${event.event_type} ->`, JSON.stringify(event.payload));
}
