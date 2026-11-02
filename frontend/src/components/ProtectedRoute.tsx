import { Navigate, Outlet } from "react-router-dom";
import { useAuth } from "../context/AuthContext";
import type { Role } from "../types";

interface Props {
  allow?: Role[];
}

export function ProtectedRoute({ allow }: Props) {
  const { user } = useAuth();

  if (!user) return <Navigate to="/login" replace />;
  if (allow && !allow.includes(user.role)) return <Navigate to="/" replace />;

  return <Outlet />;
}
