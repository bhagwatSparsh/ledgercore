import { useState, type FormEvent } from "react";
import { Link, useNavigate } from "react-router-dom";
import { extractErrorMessage, loginUser } from "../api/client";
import { useAuth } from "../context/AuthContext";

export function LoginPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const { login } = useAuth();
  const navigate = useNavigate();

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const { token, role } = await loginUser({ email, password });
      login(token, role);
      navigate("/");
    } catch (err) {
      setError(extractErrorMessage(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="auth-screen">
      <form className="auth-card" onSubmit={handleSubmit}>
        <div className="brand brand-lg">
          <span className="brand-mark">LC</span>
          <span>LedgerCore</span>
        </div>
        <p className="auth-subtitle">Concurrency-controlled double-entry ledger — demo console</p>

        {error && <div className="alert alert-error">{error}</div>}

        <label>
          Email
          <input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label>
          Password
          <input
            type="password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </label>

        <button className="btn-primary" type="submit" disabled={busy}>
          {busy ? "Signing in…" : "Sign in"}
        </button>

        <p className="auth-footer">
          New here? <Link to="/register">Create an account</Link>
        </p>
      </form>
    </div>
  );
}
