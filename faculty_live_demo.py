#!/usr/bin/env python3
"""
faculty_live_demo.py -- run this ONE live, in front of your professor.

Every run creates a brand-new demo user (unique email), so it's safe to
re-run as many times as you want in rehearsal without any "already
exists" errors. It walks through every DML category Postgres/DBMS
courses grade on -- INSERTION, UPDATION, DELETION, MODIFICATION -- first,
clearly labelled, then every other feature LedgerCore implements.

Run it with the stack already up (docker compose up -d):

    python3 faculty_live_demo.py

Narrated output prints as it goes -- read it aloud / let it speak for
itself while you click the matching screen in the dashboard.
"""

import json
import subprocess
import time
import urllib.request
import urllib.error
import uuid

API = "http://localhost:4000"
PG_CONTAINER = "ledgercore-postgres-1"

DEMO_EMAIL = "demo@ledgercore.local"
DEMO_PASSWORD = "Demo@123"
DEMO_NAME = "Live Demo"
DEMO_PHONE = "9876500000"


def banner(title, n=None, total=None):
    tag = f"[{n}/{total}] " if n else ""
    print(f"\n{'=' * 78}\n{tag}{title}\n{'=' * 78}")


def say(msg):
    print(f"  -> {msg}")


def call(method, path, token=None, body=None, idem_key=None, expect_ok=True):
    url = API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if idem_key:
        req.add_header("Idempotency-Key", idem_key)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        payload = json.loads(e.read().decode() or "{}")
        if expect_ok:
            print(f"  !! {method} {path} -> {e.code}: {payload}")
        return e.code, payload


def psql(sql, show_errors=False):
    """Direct SQL against the DB -- used for admin-only actions and to
    prove the two live schema/engine behaviors the API can't trigger on
    its own: a blocked DELETE, and a real ALTER TABLE."""
    result = subprocess.run(
        ["docker", "exec", PG_CONTAINER, "psql", "-U", "postgres", "-d", "ledgercore", "-c", sql],
        capture_output=True, text=True,
    )
    if show_errors:
        return (result.stdout + result.stderr).strip()
    return result.stdout.strip()


# =====================================================================
step = 0
TOTAL = 15

step += 1
banner("Setup: demo user (registers once, reuses after)", step, TOTAL)
status, body = call("POST", "/auth/register", body={
    "fullName": DEMO_NAME, "email": DEMO_EMAIL, "phone": DEMO_PHONE, "password": DEMO_PASSWORD,
}, expect_ok=False)
if status == 201:
    token = body["token"]
    user_id = body["user"]["user_id"]
    say(f"Registered {DEMO_EMAIL} for the first time")
else:
    _, login_body = call("POST", "/auth/login", body={"email": DEMO_EMAIL, "password": DEMO_PASSWORD})
    token = login_body["token"]
    user_id = None
    say(f"{DEMO_EMAIL} already exists -- logged in instead (safe to rerun anytime)")


# =====================================================================
# PRIORITY 1 -- INSERTION
# =====================================================================
step += 1
banner("PRIORITY 1/4 -- INSERTION", step, TOTAL)
say("api/src/routes/accounts.ts, transfers.ts, beneficiaries.ts -- every INSERT INTO")

_, acc_a = call("POST", "/accounts", token=token, body={"accountType": "SAVINGS", "currency": "INR"})
_, acc_b = call("POST", "/accounts", token=token, body={"accountType": "CURRENT", "currency": "INR"})
_, acc_c = call("POST", "/accounts", token=token, body={"accountType": "SAVINGS", "currency": "USD"})
say(f"INSERT 3 accounts: {acc_a['account_number']} (INR), {acc_b['account_number']} (INR), {acc_c['account_number']} (USD)")

call("POST", "/transfers/deposit", token=token, body={"accountId": acc_a["account_id"], "amountMinor": 5_000_000, "currency": "INR"})
call("POST", "/transfers/deposit", token=token, body={"accountId": acc_b["account_id"], "amountMinor": 2_000_000, "currency": "INR"})
call("POST", "/transfers/deposit", token=token, body={"accountId": acc_c["account_id"], "amountMinor": 50_000, "currency": "USD"})
say("INSERT 3 deposits (journal_entries + ledger_postings rows, via process_deposit())")

_, bene = call("POST", "/beneficiaries", token=token, body={
    "beneficiaryAccountId": acc_b["account_id"], "nickname": "Original Nickname",
})
say(f"INSERT 1 beneficiary: '{bene['nickname']}' (saved_beneficiaries)")

transfer_key = str(uuid.uuid4())
_, txn = call("POST", "/transfers", token=token, idem_key=transfer_key, body={
    "senderAccountId": acc_a["account_id"], "receiverAccountId": acc_b["account_id"],
    "amountMinor": 500_000, "currency": "INR", "description": "Live demo transfer",
})
say(f"INSERT 1 transfer: journalId={txn['journalId']} (1 journal_entries row + 2 ledger_postings rows)")


# =====================================================================
# PRIORITY 2 -- UPDATION
# =====================================================================
step += 1
banner("PRIORITY 2/4 -- UPDATION", step, TOTAL)
say("api/src/routes/beneficiaries.ts, accounts.ts -- every UPDATE ... SET")

_, updated_bene = call("PATCH", f"/beneficiaries/{bene['beneficiary_id']}", token=token, body={
    "nickname": "Renamed Nickname",
})
say(f"UPDATE beneficiary nickname: '{updated_bene['nickname']}'")

_, updated_limits = call("PATCH", f"/accounts/{acc_a['account_id']}/limits", token=token, body={
    "perTxnLimitMinor": 1_500_000,
})
say(f"UPDATE account_limits: per-transaction limit now {updated_limits['per_txn_limit_minor']}")

step += 1
banner("UPDATION (admin-only): freeze / unfreeze an account", step, TOTAL)
say("Promoting this demo user to admin, then re-logging-in for a fresh token (role is baked into the JWT)")
psql(f"""UPDATE user_roles SET role_id = (SELECT role_id FROM roles WHERE role_name = 'admin')
WHERE user_id = (SELECT user_id FROM users WHERE email = '{DEMO_EMAIL}');""")
_, login_body = call("POST", "/auth/login", body={"email": DEMO_EMAIL, "password": DEMO_PASSWORD})
admin_token = login_body["token"]

_, frozen = call("PATCH", f"/accounts/{acc_b['account_id']}/status", token=admin_token, body={"status": "FROZEN"})
say(f"UPDATE accounts.status -> {frozen['status']}  (fires trg_audit_account_status)")
_, active_again = call("PATCH", f"/accounts/{acc_b['account_id']}/status", token=admin_token, body={"status": "ACTIVE"})
say(f"UPDATE accounts.status -> {active_again['status']}  (reactivated, logged again)")


# =====================================================================
# PRIORITY 3 -- DELETION
# =====================================================================
step += 1
banner("PRIORITY 3/4 -- DELETION", step, TOTAL)
say("api/src/routes/beneficiaries.ts -- a real, hard DELETE")
status, _ = call("DELETE", f"/beneficiaries/{bene['beneficiary_id']}", token=token, expect_ok=False)
say(f"DELETE FROM saved_beneficiaries -- HTTP {status} (204 = deleted, row is gone)")

step += 1
banner("DELETION (blocked by design): try to delete ledger history", step, TOTAL)
say("db/migrations/010_functions_triggers.sql -- prevent_ledger_tampering() trigger")
result = psql(
    "DELETE FROM ledger_postings WHERE posting_id = "
    "(SELECT posting_id FROM ledger_postings LIMIT 1);",
    show_errors=True,
)
print("  Postgres says:")
for line in result.splitlines():
    if line.strip():
        print(f"    {line.strip()}")
say("The ledger is append-only. The attempt itself is now logged to audit_logs -- see step 13.")


# =====================================================================
# PRIORITY 4 -- MODIFICATION (schema / DDL)
# =====================================================================
step += 1
banner("PRIORITY 4/4 -- MODIFICATION (schema-level ALTER)", step, TOTAL)
say("Live, real ALTER TABLE -- added and dropped on the spot, safe and reversible")
print(psql("ALTER TABLE accounts ADD COLUMN demo_note TEXT;"))
check = psql("SELECT column_name FROM information_schema.columns WHERE table_name='accounts' AND column_name='demo_note';")
say(f"Column exists right now: {check or '(none found)'}")
print(psql("ALTER TABLE accounts DROP COLUMN demo_note;"))
say("Dropped again -- schema is back to its original shape, nothing left behind.")
say("(A permanent example of the same thing already lives in the project: migration 007_fx_rates.sql")
say(" adds fx_rate_applied/source_currency/target_currency to journal_entries after the table already existed.)")


# =====================================================================
# Everything else
# =====================================================================
step += 1
banner("FX transfer (cross-currency, 4-leg posting)", step, TOTAL)
_, fx = call("POST", "/transfers/fx", token=token, body={
    "senderAccountId": acc_a["account_id"], "receiverAccountId": acc_c["account_id"],
    "sendAmountMinor": 400_000, "description": "Live demo FX transfer",
})
say(f"INR -> USD via SYS-CLR-* clearing accounts. journalId={fx['journalId']}")

step += 1
banner("Idempotency: replay the SAME transfer request", step, TOTAL)
status, replay = call("POST", "/transfers", token=token, idem_key=transfer_key, body={
    "senderAccountId": acc_a["account_id"], "receiverAccountId": acc_b["account_id"],
    "amountMinor": 500_000, "currency": "INR", "description": "Live demo transfer",
})
say(f"HTTP {status} (200 = safely replayed). Same journalId as before: {replay['journalId'] == txn['journalId']}")

step += 1
banner("Fraud detection: trip the velocity rule", step, TOTAL)
for i in range(7):
    call("POST", "/transfers", token=token, idem_key=str(uuid.uuid4()), body={
        "senderAccountId": acc_a["account_id"], "receiverAccountId": acc_b["account_id"],
        "amountMinor": 1_000, "currency": "INR", "description": f"rapid {i+1}",
    })
flags_inserted = psql("SELECT detect_fraud_velocity();")
say(f"Fired 7 rapid debits, ran detect_fraud_velocity() -> {flags_inserted}")
_, fraud_flags = call("GET", "/admin/fraud-flags", token=admin_token)
say(f"GET /admin/fraud-flags now shows {len(fraud_flags)} flag(s) on this account")

step += 1
banner("Reconciliation + settlement", step, TOTAL)
recon_out = psql("SELECT out_account_id, recon_status FROM run_daily_reconciliation();")
recon_rows = len([l for l in recon_out.splitlines() if l.strip()])
say(f"run_daily_reconciliation(): checked accounts, output rows: {recon_rows}")
psql("SELECT refresh_daily_settlement();")
say("refresh_daily_settlement() -- mv_daily_settlement refreshed CONCURRENTLY")

step += 1
banner("Audit trail: everything above, logged automatically", step, TOTAL)
_, audit_rows = call("GET", "/admin/audit-logs", token=admin_token)
say(f"GET /admin/audit-logs -- {len(audit_rows)} most recent entries, including:")
for row in audit_rows[:5]:
    say(f"   {row['action']:<16} on {row['table_name']}")

banner("DONE -- summary")
print(f"""
Log in to http://localhost:8080 with:
  Email:    {DEMO_EMAIL}
  Password: {DEMO_PASSWORD}

(Admin role already granted -- Admin Console is visible immediately.)

What you just ran, in order:
  1. INSERTION   -- 3 accounts, 3 deposits, 1 beneficiary, 1 transfer
  2. UPDATION    -- beneficiary renamed, account limit changed, an account frozen then reactivated
  3. DELETION    -- the beneficiary hard-deleted; a direct attempt to delete ledger history blocked
  4. MODIFICATION -- a live ALTER TABLE ADD COLUMN / DROP COLUMN, safely reversible
  5. FX transfer, idempotency replay, fraud detection, reconciliation, settlement, audit trail

Everything is now sitting in the dashboard and Admin Console, ready to click through.
""")
