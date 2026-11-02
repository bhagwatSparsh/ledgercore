// Shared types mirroring the API's response shapes. Kept hand-written
// and minimal rather than generated, since the API surface is small and
// stable -- this file is the single source of truth for what the
// dashboard expects to receive.

export type Role = "admin" | "customer" | "auditor";

export interface AuthUser {
  userId: string;
  role: Role;
}

export interface Account {
  account_id: string;
  account_number: string;
  account_type: "SAVINGS" | "CURRENT" | "WALLET";
  currency: "INR" | "USD" | "EUR";
  cached_balance_minor: number;
  status: "ACTIVE" | "FROZEN" | "CLOSED";
  created_at?: string;
}

export interface StatementRow {
  posting_id: string;
  journal_id: string;
  entry_type: string;
  description: string | null;
  direction: "DEBIT" | "CREDIT";
  amount_minor: number;
  currency: string;
  created_at: string;
  running_balance_minor: number;
}

export interface Beneficiary {
  beneficiary_id: string;
  beneficiary_account_id: string;
  nickname: string | null;
  transfer_limit_minor: number;
  added_at: string;
  account_number: string;
  currency: string;
}

export interface FraudFlag {
  flag_id: string;
  account_id: string;
  account_number: string;
  rule_name: string;
  detail: Record<string, unknown>;
  severity: string;
  resolved: boolean;
  created_at: string;
}

export interface ReconciliationRow {
  recon_id: string;
  account_id: string;
  account_number: string;
  currency: string;
  run_date: string;
  expected_balance_minor: number;
  actual_balance_minor: number;
  status: "MATCH" | "DRIFT";
}

export interface SettlementRow {
  settlement_date: string;
  currency: string;
  entry_type: string;
  transaction_count: number;
  total_debited_minor: number;
  total_credited_minor: number;
}

export interface AuditLogRow {
  audit_id: string;
  actor_user_id: string | null;
  action: string;
  table_name: string;
  record_id: string;
  old_value: unknown;
  new_value: unknown;
  created_at: string;
}
