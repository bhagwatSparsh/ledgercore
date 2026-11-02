import { Navigate, Route, Routes } from "react-router-dom";
import { Layout } from "./components/Layout";
import { ProtectedRoute } from "./components/ProtectedRoute";
import { AccountDetailPage } from "./pages/AccountDetailPage";
import { AdminDashboardPage } from "./pages/AdminDashboardPage";
import { BeneficiariesPage } from "./pages/BeneficiariesPage";
import { DashboardPage } from "./pages/DashboardPage";
import { LoginPage } from "./pages/LoginPage";
import { RegisterPage } from "./pages/RegisterPage";

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route path="/register" element={<RegisterPage />} />

      <Route element={<ProtectedRoute />}>
        <Route element={<Layout />}>
          <Route path="/" element={<DashboardPage />} />
          <Route path="/accounts/:id" element={<AccountDetailPage />} />
          <Route path="/beneficiaries" element={<BeneficiariesPage />} />

          <Route element={<ProtectedRoute allow={["admin", "auditor"]} />}>
            <Route path="/admin" element={<AdminDashboardPage />} />
          </Route>
        </Route>
      </Route>

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
