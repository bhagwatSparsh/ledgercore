import { useEffect, useState } from "react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import {
  extractErrorMessage,
  fetchAuditLogs,
  fetchFraudFlags,
  fetchReconciliation,
  fetchSettlement,
} from "../api/client";
import type { AuditLogRow, FraudFlag, ReconciliationRow, SettlementRow } from "../types";
import { formatMoney } from "../utils/money";

type Tab = "overview" | "fraud" | "reconciliation" | "audit";

export function AdminDashboardPage() {
  const [tab, setTab] = useState<Tab>("overview");
  const [fraud, setFraud] = useState<FraudFlag[]>([]);
  const [recon, setRecon] = useState<ReconciliationRow[]>([]);
  const [settlement, setSettlement] = useState<SettlementRow[]>([]);
  const [audit, setAudit] = useState<AuditLogRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  async function loadAll() {
    setLoading(true);
    try {
      const [f, r, s, a] = await Promise.all([
        fetchFraudFlags(),
        fetchReconciliation(),
        fetchSettlement(),
        fetchAuditLogs(),
      ]);
      setFraud(f);
      setRecon(r);
      setSettlement(s);
      setAudit(a);
      setError(null);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    loadAll();
  }, []);

  const drifted = recon.filter((r) => r.status === "DRIFT");
  const unresolvedFraud = fraud.filter((f) => !f.resolved);

  const chartData = aggregateSettlementByDate(settlement);

  return (
    <div>
      <div className="page-header">
        <div>
          <h1>Admin Console</h1>
          <p className="muted">Fraud monitoring, reconciliation, settlement volume, and audit trail.</p>
        </div>
        <button className="btn-secondary" onClick={loadAll}>
          Refresh
        </button>
      </div>

      {error && <div className="alert alert-error">{error}</div>}

      <div className="kpi-row">
        <div className="kpi-card">
          <div className="kpi-value">{unresolvedFraud.length}</div>
          <div className="kpi-label">Unresolved fraud flags</div>
        </div>
        <div className="kpi-card">
          <div className="kpi-value">{drifted.length}</div>
          <div className="kpi-label">Accounts with reconciliation drift</div>
        </div>
        <div className="kpi-card">
          <div className="kpi-value">{recon.length - drifted.length}</div>
          <div className="kpi-label">Accounts matched (latest run)</div>
        </div>
      </div>

      <div className="tab-bar">
        {(["overview", "fraud", "reconciliation", "audit"] as Tab[]).map((t) => (
          <button key={t} className={tab === t ? "active" : ""} onClick={() => setTab(t)}>
            {t[0].toUpperCase() + t.slice(1)}
          </button>
        ))}
      </div>

      {loading ? (
        <p className="muted">Loading…</p>
      ) : tab === "overview" ? (
        <div className="panel">
          <h3>Daily settlement volume</h3>
          <ResponsiveContainer width="100%" height={320}>
            <BarChart data={chartData}>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
              <XAxis dataKey="date" stroke="var(--text-muted)" fontSize={12} />
              <YAxis stroke="var(--text-muted)" fontSize={12} />
              <Tooltip contentStyle={{ background: "var(--surface)", border: "1px solid var(--border)" }} />
              <Legend />
              <Bar dataKey="debited" name="Total debited (minor units)" fill="#6366f1" radius={[4, 4, 0, 0]} />
              <Bar dataKey="credited" name="Total credited (minor units)" fill="#22c55e" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
          <p className="muted small">
            Backed by <code>mv_daily_settlement</code>, a materialized view refreshed hourly by the
            background worker via <code>REFRESH MATERIALIZED VIEW CONCURRENTLY</code>.
          </p>
        </div>
      ) : tab === "fraud" ? (
        <table className="statement-table">
          <thead>
            <tr>
              <th>Account</th>
              <th>Rule</th>
              <th>Detail</th>
              <th>Severity</th>
              <th>Resolved</th>
              <th>Flagged</th>
            </tr>
          </thead>
          <tbody>
            {fraud.length === 0 ? (
              <tr>
                <td colSpan={6} className="muted">
                  No fraud flags.
                </td>
              </tr>
            ) : (
              fraud.map((f) => (
                <tr key={f.flag_id} className={!f.resolved ? "row-warning" : ""}>
                  <td>{f.account_number}</td>
                  <td>{f.rule_name}</td>
                  <td className="mono-small">{formatFraudDetail(f.detail)}</td>
                  <td>
                    <span className={`severity-badge severity-${f.severity.toLowerCase()}`}>{f.severity}</span>
                  </td>
                  <td>{f.resolved ? "Yes" : "No"}</td>
                  <td>{new Date(f.created_at).toLocaleString()}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      ) : tab === "reconciliation" ? (
        <table className="statement-table">
          <thead>
            <tr>
              <th>Account</th>
              <th>Run date</th>
              <th className="num">Expected</th>
              <th className="num">Actual</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {recon.map((r) => (
              <tr key={r.recon_id} className={r.status === "DRIFT" ? "row-warning" : ""}>
                <td>{r.account_number}</td>
                <td>{new Date(r.run_date).toLocaleDateString()}</td>
                <td className="num">{formatMoney(r.expected_balance_minor, r.currency)}</td>
                <td className="num">{formatMoney(r.actual_balance_minor, r.currency)}</td>
                <td>
                  <span className={`severity-badge ${r.status === "DRIFT" ? "severity-high" : "severity-low"}`}>
                    {r.status}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : (
        <table className="statement-table">
          <thead>
            <tr>
              <th>When</th>
              <th>Action</th>
              <th>Table</th>
              <th>Record</th>
            </tr>
          </thead>
          <tbody>
            {audit.map((a) => (
              <tr key={a.audit_id}>
                <td>{new Date(a.created_at).toLocaleString()}</td>
                <td>{a.action}</td>
                <td>{a.table_name}</td>
                <td className="mono-small">{a.record_id}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

function formatFraudDetail(detail: Record<string, unknown>): string {
  return Object.entries(detail)
    .map(([k, v]) => `${k}: ${v}`)
    .join(", ");
}

function aggregateSettlementByDate(rows: SettlementRow[]) {
  const byDate = new Map<string, { date: string; debited: number; credited: number }>();
  for (const row of rows) {
    const key = new Date(row.settlement_date).toLocaleDateString();
    const entry = byDate.get(key) ?? { date: key, debited: 0, credited: 0 };
    entry.debited += Number(row.total_debited_minor);
    entry.credited += Number(row.total_credited_minor);
    byDate.set(key, entry);
  }
  return Array.from(byDate.values()).reverse();
}
