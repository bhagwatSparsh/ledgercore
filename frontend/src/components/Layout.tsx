import { NavLink, Outlet, useNavigate } from "react-router-dom";
import { useAuth } from "../context/AuthContext";

const NAV_ICONS = {
  accounts: (
    <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect x="2.5" y="5" width="15" height="11" rx="1.5" stroke="currentColor" strokeWidth="1.3" />
      <path d="M2.5 8.5H17.5" stroke="currentColor" strokeWidth="1.3" />
      <path d="M5.5 12H9" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
    </svg>
  ),
  beneficiaries: (
    <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="10" cy="7" r="3" stroke="currentColor" strokeWidth="1.3" />
      <path d="M3.5 17C3.5 13.7 6.4 11.5 10 11.5C13.6 11.5 16.5 13.7 16.5 17" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
    </svg>
  ),
  admin: (
    <svg viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path d="M10 2.5L16.5 5.3V9.4C16.5 13.3 13.9 16.6 10 17.8C6.1 16.6 3.5 13.3 3.5 9.4V5.3L10 2.5Z" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round" />
      <path d="M7.3 9.8L9.2 11.7L12.9 8" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  ),
};

export function Layout() {
  const { user, logout } = useAuth();
  const navigate = useNavigate();

  function handleLogout() {
    logout();
    navigate("/login");
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="sidebar-brand">
          <span className="brand-mark">LC</span>
          <span className="brand-word">
            Ledger<em>Core</em>
          </span>
        </div>

        <nav className="sidebar-nav">
          <span className="sidebar-nav-label">Ledger</span>
          <NavLink to="/" end>
            {NAV_ICONS.accounts}
            Accounts
          </NavLink>
          <NavLink to="/beneficiaries">
            {NAV_ICONS.beneficiaries}
            Beneficiaries
          </NavLink>
          {(user?.role === "admin" || user?.role === "auditor") && (
            <>
              <span className="sidebar-nav-label">Oversight</span>
              <NavLink to="/admin">
                {NAV_ICONS.admin}
                Admin console
              </NavLink>
            </>
          )}
        </nav>

        {user && (
          <div className="sidebar-footer">
            <span className={`role-badge role-${user.role}`}>{user.role}</span>
            <button className="btn-ghost" onClick={handleLogout}>
              Log out
            </button>
          </div>
        )}
      </aside>
      <main className="content">
        <Outlet />
      </main>
    </div>
  );
}
