import { useEffect, useState } from "react";
import {
  addBeneficiary,
  deleteBeneficiary,
  extractErrorMessage,
  fetchBeneficiaries,
  lookupAccountByNumber,
} from "../api/client";
import type { Beneficiary } from "../types";
import { formatMoney, toMinorUnits } from "../utils/money";

export function BeneficiariesPage() {
  const [beneficiaries, setBeneficiaries] = useState<Beneficiary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [accountNumber, setAccountNumber] = useState("");
  const [nickname, setNickname] = useState("");
  const [transferLimit, setTransferLimit] = useState("");
  const [busy, setBusy] = useState(false);

  async function load() {
    setLoading(true);
    try {
      setBeneficiaries(await fetchBeneficiaries());
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

  async function handleAdd() {
    setBusy(true);
    setError(null);
    try {
      const found = await lookupAccountByNumber(accountNumber);
      await addBeneficiary({
        beneficiaryAccountId: found.account_id,
        nickname: nickname || undefined,
        transferLimitMinor: transferLimit ? toMinorUnits(Number(transferLimit)) : undefined,
      });
      setAccountNumber("");
      setNickname("");
      setTransferLimit("");
      load();
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  async function handleDelete(id: string) {
    try {
      await deleteBeneficiary(id);
      load();
    } catch (err) {
      setError(extractErrorMessage(err));
    }
  }

  return (
    <div>
      <div className="page-header">
        <div>
          <h1>Beneficiaries</h1>
          <p className="muted">Saved recipients for faster, safer transfers.</p>
        </div>
      </div>

      {error && <div className="alert alert-error">{error}</div>}

      <div className="panel">
        <h3>Add a beneficiary</h3>
        <div className="inline-form">
          <input
            placeholder="Account number"
            value={accountNumber}
            onChange={(e) => setAccountNumber(e.target.value)}
          />
          <input placeholder="Nickname (optional)" value={nickname} onChange={(e) => setNickname(e.target.value)} />
          <input
            placeholder="Transfer limit (optional)"
            type="number"
            value={transferLimit}
            onChange={(e) => setTransferLimit(e.target.value)}
          />
          <button className="btn-primary" onClick={handleAdd} disabled={busy || !accountNumber}>
            {busy ? "Adding…" : "Add"}
          </button>
        </div>
      </div>

      {loading ? (
        <p className="muted">Loading…</p>
      ) : beneficiaries.length === 0 ? (
        <div className="empty-state">
          <p>No saved beneficiaries yet.</p>
        </div>
      ) : (
        <table className="statement-table">
          <thead>
            <tr>
              <th>Nickname</th>
              <th>Account number</th>
              <th>Currency</th>
              <th className="num">Transfer limit</th>
              <th>Added</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {beneficiaries.map((b) => (
              <tr key={b.beneficiary_id}>
                <td>{b.nickname || "—"}</td>
                <td>{b.account_number}</td>
                <td>{b.currency}</td>
                <td className="num">{formatMoney(b.transfer_limit_minor, b.currency)}</td>
                <td>{new Date(b.added_at).toLocaleDateString()}</td>
                <td>
                  <button className="btn-ghost danger" onClick={() => handleDelete(b.beneficiary_id)}>
                    Remove
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
