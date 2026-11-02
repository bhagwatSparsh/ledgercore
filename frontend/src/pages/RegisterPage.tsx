import { useState, type FormEvent } from "react";
import { Link, useNavigate } from "react-router-dom";
import { extractErrorMessage, loginUser, registerUser } from "../api/client";
import { useAuth } from "../context/AuthContext";

export function RegisterPage() {
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [phone, setPhone] = useState("");
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
      await registerUser({ fullName, email, phone, password });
      // Registration doesn't return a usable session token shape we
      // rely on elsewhere (role isn't embedded the same way), so we
      // log straight in afterward with the same credentials -- one
      // extra round trip, but it keeps the "what does login return"
      // contract in exactly one place.
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
        <p className="auth-subtitle">Create your account</p>

        {error && <div className="alert alert-error">{error}</div>}

        <label>
          Full name
          <input required value={fullName} onChange={(e) => setFullName(e.target.value)} />
        </label>
        <label>
          Email
          <input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label>
          Phone
          <input required value={phone} onChange={(e) => setPhone(e.target.value)} />
        </label>
        <label>
          Password
          <input
            type="password"
            required
            minLength={8}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </label>

        <button className="btn-primary" type="submit" disabled={busy}>
          {busy ? "Creating…" : "Create account"}
        </button>

        <p className="auth-footer">
          Already have an account? <Link to="/login">Sign in</Link>
        </p>
      </form>
    </div>
  );
}
