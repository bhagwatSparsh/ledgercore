import cron from "node-cron";
import { dispatchOutboxEvents } from "./jobs/outboxDispatcher";
import { runNightlyReconciliation } from "./jobs/reconciliation";
import { runFraudScan } from "./jobs/fraudScan";
import { refreshDailySettlement } from "./jobs/settlementRefresh";
import { ensureNextPartitionExists } from "./jobs/partitionMaintenance";

function log(msg: string) {
  // eslint-disable-next-line no-console
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

async function safeRun(name: string, fn: () => Promise<unknown>) {
  try {
    await fn();
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error(`[${name}] job failed:`, err);
  }
}

// Outbox dispatch: frequent. Notifications should go out within
// seconds of a transfer completing, not minutes.
cron.schedule("*/10 * * * * *", () => safeRun("outbox", dispatchOutboxEvents));

// Fraud scan: every 5 minutes. Frequent enough to catch an in-progress
// burst, cheap enough to run constantly (it's a single indexed query).
cron.schedule("*/5 * * * *", () => safeRun("fraud-scan", runFraudScan));

// Settlement rollup: hourly. The dashboard chart doesn't need
// second-by-second freshness.
cron.schedule("0 * * * *", () => safeRun("settlement-refresh", refreshDailySettlement));

// Reconciliation + partition maintenance: once a day, at 02:00 -- the
// classic "nightly batch job" slot, chosen to run during low-traffic
// hours since reconciliation scans the entire ledger history.
cron.schedule("0 2 * * *", () => safeRun("reconciliation", runNightlyReconciliation));
cron.schedule("0 2 * * *", () => safeRun("partition-maintenance", ensureNextPartitionExists));

log("LedgerCore worker started. Schedules: outbox/10s, fraud-scan/5m, settlement/1h, reconciliation+partitions/daily@02:00.");

// Run once immediately on boot too, so a freshly started worker (or a
// one-off manual run) doesn't sit idle waiting for the first cron tick
// -- useful for demos and for CI health checks.
void safeRun("outbox", dispatchOutboxEvents);
void safeRun("fraud-scan", runFraudScan);
void safeRun("settlement-refresh", refreshDailySettlement);
void safeRun("partition-maintenance", ensureNextPartitionExists);
