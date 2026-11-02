import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import {
  createFxTransfer,
  createTransfer,
  extractErrorMessage,
  fetchBalance,
  fetchBeneficiaries,
  fetchStatement,
  lookupAccountByNumber,
} from "../api/client";
import { Modal } from "../components/Modal";
import type { Beneficiary, StatementRow } from "../types";
import { formatMoney, toMinorUnits } from "../utils/money";

const POLL_MS = 5000;

export function AccountDetailPage() {
  const { id } = useParams<{ id: string }>();
  const accountId = id!;

  const [balance, setBalance] = useState<{ cachedBalanceMinor: number; source: string } | null>(null);
  const [currency, setCurrency] = useState("INR");
  const [statement, setStatement] = useState<StatementRow[]>([]);
  const [newRowIds, setNewRowIds] = useState<Set<string>>(new Set());
  const [error, setError] = useState<string | null>(null);
  const [showTransfer, setShowTransfer] = useState(false);
  const [showFx, setShowFx] = useState(false);
  const knownIds = useRef<Set<string>>(new Set());
  const [live, setLive] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const [bal, stmt] = await Promise.all([fetchBalance(accountId), fetchStatement(accountId)]);
      setBalance(bal);
      if (stmt.length > 0) setCurrency(stmt[0].currency);

      const fresh = stmt.filter((r) => !knownIds.current.has(r.posting_id)).map((r) => r.posting_id);
      if (fresh.length > 0 && knownIds.current.size > 0) {
        setNewRowIds(new Set(fresh));
        setTimeout(() => setNewRowIds(new Set()), 3000);
      }
      stmt.forEach((r) => knownIds.current.add(r.posting_id));

      setStatement(stmt);
      setError(null);
    } catch (err) {
      setError(extractErrorMessage(err));
    }
  }, [accountId]);

  useEffect(() => {
    refresh();
    if (!live) return;
    const interval = setInterval(refresh, POLL_MS);
    return () => clearInterval(interval);
  }, [refresh, live]);

  return (
    <div>
      <div className="page-header">
        <div>
          <Link to="/" className="back-link">
            ← All accounts
          </Link>
          <h1>Account statement</h1>
        </div>
        <div className="row-actions">
          <button className="btn-secondary" onClick={() => setShowFx(true)}>
            FX transfer
          </button>
          <button className="btn-primary" onClick={() => setShowTransfer(true)}>
            Send money
          </button>
        </div>
      </div>

      {error && <div className="alert alert-error">{error}</div>}

      <div className="balance-panel">
        <div>
          <div className="muted small">Current balance</div>
          <div className="big-balance">{balance ? formatMoney(balance.cachedBalanceMinor, currency) : "…"}</div>
        </div>
        {balance && (
          <span className={`source-badge source-${balance.source}`}>
            served from {balance.source === "cache" ? "Redis cache" : "PostgreSQL"}
          </span>
        )}
        <label className="live-toggle">
          <input type="checkbox" checked={live} onChange={(e) => setLive(e.target.checked)} />
          <span className={`live-dot ${live ? "live-on" : ""}`} /> Live feed ({POLL_MS / 1000}s)
        </label>
      </div>

      <table className="statement-table">
        <thead>
          <tr>
            <th>Date</th>
            <th>Type</th>
            <th>Description</th>
            <th className="num">Amount</th>
            <th className="num">Running balance</th>
          </tr>
        </thead>
        <tbody>
          {statement.length === 0 ? (
            <tr>
              <td colSpan={5} className="muted">
                No postings yet.
              </td>
            </tr>
          ) : (
            statement.map((row) => (
              <tr key={row.posting_id} className={newRowIds.has(row.posting_id) ? "row-flash" : ""}>
                <td>{new Date(row.created_at).toLocaleString()}</td>
                <td>{row.entry_type}</td>
                <td>{row.description ?? "—"}</td>
                <td className={`num ${row.direction === "CREDIT" ? "amount-credit" : "amount-debit"}`}>
                  {row.direction === "CREDIT" ? "+" : "−"}
                  {formatMoney(row.amount_minor, row.currency)}
                </td>
                <td className="num">{formatMoney(row.running_balance_minor, row.currency)}</td>
              </tr>
            ))
          )}
        </tbody>
      </table>

      {showTransfer && (
        <TransferModal
          senderAccountId={accountId}
          senderCurrency={currency}
          onClose={() => setShowTransfer(false)}
          onDone={() => {
            setShowTransfer(false);
            refresh();
          }}
        />
      )}
      {showFx && (
        <FxTransferModal
          senderAccountId={accountId}
          onClose={() => setShowFx(false)}
          onDone={() => {
            setShowFx(false);
            refresh();
          }}
        />
      )}
    </div>
  );
}

function TransferModal({
  senderAccountId,
  senderCurrency,
  onClose,
  onDone,
}: {
  senderAccountId: string;
  senderCurrency: string;
  onClose: () => void;
  onDone: () => void;
}) {
  const [beneficiaries, setBeneficiaries] = useState<Beneficiary[]>([]);
  const [mode, setMode] = useState<"beneficiary" | "accountNumber">("beneficiary");
  const [beneficiaryId, setBeneficiaryId] = useState("");
  const [accountNumber, setAccountNumber] = useState("");
  const [amount, setAmount] = useState("");
  const [description, setDescription] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  const idemKeyRef = useRef<string>(crypto.randomUUID());

  useEffect(() => {
    fetchBeneficiaries().then(setBeneficiaries).catch(() => undefined);
  }, []);

  async function resolveReceiver(): Promise<{ id: string; currency: string }> {
    if (mode === "beneficiary") {
      const b = beneficiaries.find((x) => x.beneficiary_id === beneficiaryId);
      if (!b) throw new Error("Pick a beneficiary.");
      return { id: b.beneficiary_account_id, currency: b.currency };
    }
    const found = await lookupAccountByNumber(accountNumber);
    return { id: found.account_id, currency: found.currency };
  }

  async function submit() {
    setBusy(true);
    setError(null);
    try {
      const receiver = await resolveReceiver();
      if (receiver.currency !== senderCurrency) {
        throw new Error(
          `Receiver account is in ${receiver.currency}, but this account is ${senderCurrency}. Use "FX transfer" for cross-currency sends.`
        );
      }
      const res = await createTransfer(
        {
          senderAccountId,
          receiverAccountId: receiver.id,
          amountMinor: toMinorUnits(Number(amount)),
          currency: senderCurrency,
          description: description || undefined,
        },
        idemKeyRef.current
      );
      setResult(`Success — journal ${res.journalId ?? res.journalId} (status: ${res.status}).`);
      setSent(true);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  async function replaySameRequest() {
    // Demonstrates the idempotency guarantee live: re-sends the exact
    // same Idempotency-Key + body. The API should return the cached
    // COMPLETED response (HTTP 200, not 201) instead of transferring
    // the money a second time.
    setBusy(true);
    setError(null);
    try {
      const receiver = await resolveReceiver();
      const res = await createTransfer(
        {
          senderAccountId,
          receiverAccountId: receiver.id,
          amountMinor: toMinorUnits(Number(amount)),
          currency: senderCurrency,
          description: description || undefined,
        },
        idemKeyRef.current
      );
      setResult(`Replayed safely — same journal ${res.journalId}, no money moved twice.`);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal title="Send money" onClose={onClose}>
      {error && <div className="alert alert-error">{error}</div>}
      {result && <div className="alert alert-success">{result}</div>}

      <div className="segmented">
        <button className={mode === "beneficiary" ? "active" : ""} onClick={() => setMode("beneficiary")}>
          Saved beneficiary
        </button>
        <button className={mode === "accountNumber" ? "active" : ""} onClick={() => setMode("accountNumber")}>
          Account number
        </button>
      </div>

      {mode === "beneficiary" ? (
        <label>
          Beneficiary
          <select value={beneficiaryId} disabled={sent} onChange={(e) => setBeneficiaryId(e.target.value)}>
            <option value="">Select…</option>
            {beneficiaries.map((b) => (
              <option key={b.beneficiary_id} value={b.beneficiary_id}>
                {b.nickname || b.account_number} ({b.account_number}, {b.currency})
              </option>
            ))}
          </select>
        </label>
      ) : (
        <label>
          Recipient account number
          <input value={accountNumber} disabled={sent} onChange={(e) => setAccountNumber(e.target.value)} />
        </label>
      )}

      <label>
        Amount ({senderCurrency})
        <input
          type="number"
          min="0.01"
          step="0.01"
          value={amount}
          disabled={sent}
          onChange={(e) => setAmount(e.target.value)}
        />
      </label>
      <label>
        Note (optional)
        <input value={description} disabled={sent} onChange={(e) => setDescription(e.target.value)} />
      </label>

      <div className="row-actions">
        {!sent ? (
          <button className="btn-primary" onClick={submit} disabled={busy || !amount}>
            {busy ? "Sending…" : "Send"}
          </button>
        ) : (
          <div className="stacked-actions">
            <button className="btn-ghost" onClick={replaySameRequest} disabled={busy}>
              {busy ? "Replaying…" : "Replay same request (idempotency demo)"}
            </button>
            <button className="btn-primary" onClick={onDone}>
              Done
            </button>
          </div>
        )}
      </div>
      <p className="muted small">
        Idempotency-Key: <code>{idemKeyRef.current.slice(0, 8)}…</code> — retrying this exact request will not
        double-charge.
      </p>
    </Modal>
  );
}

function FxTransferModal({
  senderAccountId,
  onClose,
  onDone,
}: {
  senderAccountId: string;
  onClose: () => void;
  onDone: () => void;
}) {
  const [accountNumber, setAccountNumber] = useState("");
  const [amount, setAmount] = useState("");
  const [description, setDescription] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit() {
    setBusy(true);
    setError(null);
    try {
      const receiver = await lookupAccountByNumber(accountNumber);
      await createFxTransfer({
        senderAccountId,
        receiverAccountId: receiver.account_id,
        sendAmountMinor: toMinorUnits(Number(amount)),
        description: description || undefined,
      });
      onDone();
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal title="Cross-currency (FX) transfer" onClose={onClose}>
      {error && <div className="alert alert-error">{error}</div>}
      <p className="muted small">
        Routes through the system's currency clearing accounts, converting at the latest stored rate, so
        each currency leg still balances independently.
      </p>
      <label>
        Recipient account number
        <input value={accountNumber} onChange={(e) => setAccountNumber(e.target.value)} />
      </label>
      <label>
        Amount to send (your currency)
        <input type="number" min="0.01" step="0.01" value={amount} onChange={(e) => setAmount(e.target.value)} />
      </label>
      <label>
        Note (optional)
        <input value={description} onChange={(e) => setDescription(e.target.value)} />
      </label>
      <button className="btn-primary" onClick={submit} disabled={busy || !amount || !accountNumber}>
        {busy ? "Converting & sending…" : "Send"}
      </button>
    </Modal>
  );
}
