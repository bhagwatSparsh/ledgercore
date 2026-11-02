import { createContext, useContext, useMemo, useState, type ReactNode } from "react";
import type { AuthUser, Role } from "../types";

interface AuthContextValue {
  user: AuthUser | null;
  login: (token: string, role: Role) => void;
  logout: () => void;
}

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

// The JWT carries { userId, role }. We only need to read it client-side
// to know who's logged in for display purposes -- verification happens
// server-side on every request, so a naive base64 decode here (no
// signature check) is fine; nothing security-relevant depends on it.
function decodeToken(token: string): AuthUser | null {
  try {
    const payloadB64 = token.split(".")[1];
    const json = atob(payloadB64.replace(/-/g, "+").replace(/_/g, "/"));
    const payload = JSON.parse(json);
    return { userId: payload.userId, role: payload.role };
  } catch {
    return null;
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<AuthUser | null>(() => {
    const token = localStorage.getItem("ledgercore_token");
    return token ? decodeToken(token) : null;
  });

  const value = useMemo<AuthContextValue>(
    () => ({
      user,
      login: (token: string) => {
        localStorage.setItem("ledgercore_token", token);
        const decoded = decodeToken(token);
        setUser(decoded);
      },
      logout: () => {
        localStorage.removeItem("ledgercore_token");
        localStorage.removeItem("ledgercore_role");
        setUser(null);
      },
    }),
    [user]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
