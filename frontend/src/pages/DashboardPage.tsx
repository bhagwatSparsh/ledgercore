import { useEffect, useState, type CSSProperties } from "react";
import { Link } from "react-router-dom";
import { createAccount, createDeposit, extractErrorMessage, fetchAccounts } from "../api/client";
import { Modal } from "../components/Modal";
import type { Account } from "../types";
import { formatMoney, toMinorUnits } from "../utils/money";

export function DashboardPage() {
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const [showDeposit, setShowDeposit] = useState<Account | null>(null);

  async function load() {
    setLoading(true);
    try {
      setAccounts(await fetchAccounts());
      setError(null);
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
  }, []);

  return (
    <div>
      <div className="page-header">
        <div>
          <h1>Your Accounts</h1>
          <p className="muted">Every balance shown here is backed by an immutable, double-entry ledger.</p>
        </div>
        <button className="btn-primary" onClick={() => setShowCreate(true)}>
          + New account
        </button>
      </div>

      {error && <div className="alert alert-error">{error}</div>}

      {loading ? (
        <p className="muted">Loading…</p>
      ) : accounts.length === 0 ? (
        <div className="empty-state">
          <p>No accounts yet. Create one to get started.</p>
        </div>
      ) : (
        <div className="account-grid">
          {accounts.map((acc, idx) => (
            <div
              className="account-card"
              key={acc.account_id}
              style={{ "--i": idx } as CSSProperties}
            >
              <div className="account-card-top">
                <span className={`status-dot status-${acc.status.toLowerCase()}`} title={acc.status} />
                <span className="account-type">{acc.account_type}</span>
                <span className="account-currency">{acc.currency}</span>
              </div>
              <div className="account-balance">{formatMoney(acc.cached_balance_minor, acc.currency)}</div>
              <div className="account-number">{acc.account_number}</div>
              <div className="account-card-actions">
                <Link className="btn-secondary" to={`/accounts/${acc.account_id}`}>
                  Open
                </Link>
                <button className="btn-ghost" onClick={() => setShowDeposit(acc)}>
                  Add money
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {showCreate && (
        <CreateAccountModal
          onClose={() => setShowCreate(false)}
          onCreated={() => {
            setShowCreate(false);
            load();
          }}
        />
      )}

      {showDeposit && (
        <DepositModal
          account={showDeposit}
          onClose={() => setShowDeposit(null)}
          onDone={() => {
            setShowDeposit(null);
            load();
          }}
        />
      )}
    </div>
  );
}

function CreateAccountModal({ onClose, onCreated }: { onClose: () => void; onCreated: () => void }) {
  const [accountType, setAccountType] = useState("SAVINGS");
  const [currency, setCurrency] = useState("INR");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit() {
    setBusy(true);
    setError(null);
    try {
      await createAccount({ accountType, currency });
      onCreated();
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal title="Create a new account" onClose={onClose}>
      {error && <div className="alert alert-error">{error}</div>}
      <label>
        Account type
        <select value={accountType} onChange={(e) => setAccountType(e.target.value)}>
          <option value="SAVINGS">Savings</option>
          <option value="CURRENT">Current</option>
          <option value="WALLET">Wallet</option>
        </select>
      </label>
      <label>
        Currency
        <select value={currency} onChange={(e) => setCurrency(e.target.value)}>
          <option value="INR">INR</option>
          <option value="USD">USD</option>
          <option value="EUR">EUR</option>
        </select>
      </label>
      <button className="btn-primary" onClick={submit} disabled={busy}>
        {busy ? "Creating…" : "Create account"}
      </button>
    </Modal>
  );
}

function DepositModal({
  account,
  onClose,
  onDone,
}: {
  account: Account;
  onClose: () => void;
  onDone: () => void;
}) {
  const [amount, setAmount] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit() {
    setBusy(true);
    setError(null);
    try {
      await createDeposit({
        accountId: account.account_id,
        amountMinor: toMinorUnits(Number(amount)),
        currency: account.currency,
      });
      onDone();
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal title={`Add money to ${account.account_number}`} onClose={onClose}>
      {error && <div className="alert alert-error">{error}</div>}
      <label>
        Amount ({account.currency})
        <input
          type="number"
          min="0.01"
          step="0.01"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
        />
      </label>
      <p className="muted small">
        This simulates an external cash-in (ATM deposit, bank transfer in) via{" "}
        <code>process_deposit()</code> — the money originates from the system's external clearing
        account, fully ledgered like any other movement.
      </p>
      <button className="btn-primary" onClick={submit} disabled={busy || !amount}>
        {busy ? "Depositing…" : "Deposit"}
      </button>
    </Modal>
  );
}
