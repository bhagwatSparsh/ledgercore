import axios from "axios";
import type {
  Account,
  AuditLogRow,
  Beneficiary,
  FraudFlag,
  ReconciliationRow,
  SettlementRow,
  StatementRow,
} from "../types";

const baseURL = import.meta.env.VITE_API_BASE_URL || "http://localhost:4000";

export const api = axios.create({ baseURL });

// Every request picks up whatever token is currently in localStorage --
// simpler than threading it through React context into every call site,
// and fine for a dashboard where the token doesn't rotate mid-session.
api.interceptors.request.use((config) => {
  const token = localStorage.getItem("ledgercore_token");
  if (token) {
    config.headers = config.headers ?? {};
    config.headers.Authorization = `Bearer ${token}`;
  }
  return config;
});

// A 401 means the token is missing/expired/invalid -- bounce to login
// rather than letting every page render its own broken, half-authed
// state. We don't redirect on other routes' own business-logic errors
// (403 "not your account", 422 "insufficient funds", etc.) -- those are
// meaningful and handled by the calling page.
api.interceptors.response.use(
  (res) => res,
  (err) => {
    if (err.response?.status === 401) {
      localStorage.removeItem("ledgercore_token");
      localStorage.removeItem("ledgercore_role");
      if (window.location.pathname !== "/login") {
        window.location.href = "/login";
      }
    }
    return Promise.reject(err);
  }
);

export function extractErrorMessage(err: unknown): string {
  if (axios.isAxiosError(err)) {
    const data = err.response?.data as { error?: string; message?: string } | undefined;
    return data?.error || data?.message || err.message;
  }
  return err instanceof Error ? err.message : "Unexpected error.";
}

// ---- Auth ----

export async function registerUser(payload: {
  fullName: string;
  email: string;
  phone: string;
  password: string;
}) {
  const { data } = await api.post("/auth/register", payload);
  return data as { user: { user_id: string; full_name: string; email: string; kyc_status: string }; token: string };
}

export async function loginUser(payload: { email: string; password: string }) {
  const { data } = await api.post("/auth/login", payload);
  return data as { token: string; role: "admin" | "customer" | "auditor" };
}

// ---- Accounts ----

export async function fetchAccounts(): Promise<Account[]> {
  const { data } = await api.get("/accounts");
  return data;
}

export async function createAccount(payload: { accountType: string; currency: string }): Promise<Account> {
  const { data } = await api.post("/accounts", payload);
  return data;
}

export async function lookupAccountByNumber(
  accountNumber: string
): Promise<{ account_id: string; account_number: string; currency: string }> {
  const { data } = await api.get(`/accounts/lookup/${encodeURIComponent(accountNumber)}`);
  return data;
}

export async function fetchBalance(
  accountId: string
): Promise<{ accountId: string; cachedBalanceMinor: number; source: "cache" | "database" }> {
  const { data } = await api.get(`/accounts/${accountId}/balance`);
  return data;
}

export async function fetchStatement(accountId: string): Promise<StatementRow[]> {
  const { data } = await api.get(`/accounts/${accountId}/statement`);
  return data;
}

export async function updateAccountLimits(
  accountId: string,
  payload: { dailyLimitMinor?: number; perTxnLimitMinor?: number }
) {
  const { data } = await api.patch(`/accounts/${accountId}/limits`, payload);
  return data;
}

export async function updateAccountStatus(accountId: string, status: string) {
  const { data } = await api.patch(`/accounts/${accountId}/status`, { status });
  return data;
}

// ---- Transfers ----

export async function createTransfer(
  payload: {
    senderAccountId: string;
    receiverAccountId: string;
    amountMinor: number;
    currency: string;
    description?: string;
  },
  idempotencyKey: string
) {
  const { data } = await api.post("/transfers", payload, {
    headers: { "Idempotency-Key": idempotencyKey },
  });
  return data;
}

export async function createFxTransfer(payload: {
  senderAccountId: string;
  receiverAccountId: string;
  sendAmountMinor: number;
  description?: string;
}) {
  const { data } = await api.post("/transfers/fx", payload);
  return data;
}

export async function createDeposit(payload: { accountId: string; amountMinor: number; currency: string }) {
  const { data } = await api.post("/transfers/deposit", payload);
  return data;
}

// ---- Beneficiaries ----

export async function fetchBeneficiaries(): Promise<Beneficiary[]> {
  const { data } = await api.get("/beneficiaries");
  return data;
}

export async function addBeneficiary(payload: {
  beneficiaryAccountId: string;
  nickname?: string;
  transferLimitMinor?: number;
}): Promise<Beneficiary> {
  const { data } = await api.post("/beneficiaries", payload);
  return data;
}

export async function deleteBeneficiary(id: string) {
  await api.delete(`/beneficiaries/${id}`);
}

// ---- Admin / Auditor ----

export async function fetchFraudFlags(): Promise<FraudFlag[]> {
  const { data } = await api.get("/admin/fraud-flags");
  return data;
}

export async function fetchReconciliation(): Promise<ReconciliationRow[]> {
  const { data } = await api.get("/admin/reconciliation");
  return data;
}

export async function fetchSettlement(): Promise<SettlementRow[]> {
  const { data } = await api.get("/admin/settlement");
  return data;
}

export async function fetchAuditLogs(): Promise<AuditLogRow[]> {
  const { data } = await api.get("/admin/audit-logs");
  return data;
}
