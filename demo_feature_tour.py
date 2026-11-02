#!/usr/bin/env python3
"""
demo_feature_tour.py -- exercises every feature of LedgerCore end to end,
through the real HTTP API (the same endpoints the dashboard itself calls),
and prints a narrated transcript as it goes.

Run it once, then open http://localhost:8080 and log in with the demo
account printed at the top -- every account, transfer, FX conversion,
idempotency replay, fraud flag, and admin data point will already be
sitting there, ready to click through for a demo.

Usage:
    python3 demo_feature_tour.py
"""

import json
import subprocess
import urllib.request
import urllib.error
import uuid

API = "http://localhost:4000"
DEMO_EMAIL = "faculty.demo@ledgercore.local"
DEMO_PASSWORD = "Demo@12345"
DEMO_NAME = "Faculty Demo"
DEMO_PHONE = "9999999999"

PG_CONTAINER = "ledgercore-postgres-1"


def step(title):
    print(f"\n{'=' * 70}\n{title}\n{'=' * 70}")


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
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        payload = json.loads(e.read().decode() or "{}")
        if expect_ok:
            print(f"  !! {method} {path} -> {e.code}: {payload}")
        return e.code, payload


def psql(sql):
    """Run one SQL statement directly against the DB (for admin-only
    actions -- promoting a role, or triggering a worker job immediately
    instead of waiting for its schedule)."""
    result = subprocess.run(
        ["docker", "exec", PG_CONTAINER, "psql", "-U", "postgres", "-d", "ledgercore", "-t", "-c", sql],
        capture_output=True, text=True,
    )
    return result.stdout.strip()


# ---------------------------------------------------------------------
step("1. Register (or log in, if this script already ran before)")
status, body = call("POST", "/auth/register", body={
    "fullName": DEMO_NAME, "email": DEMO_EMAIL, "phone": DEMO_PHONE, "password": DEMO_PASSWORD,
}, expect_ok=False)

if status == 201:
    token = body["token"]
    print(f"  Registered new demo user: {DEMO_EMAIL}")
else:
    status, body = call("POST", "/auth/login", body={"email": DEMO_EMAIL, "password": DEMO_PASSWORD})
    token = body["token"]
    print(f"  Demo user already existed -- logged in instead: {DEMO_EMAIL}")

# ---------------------------------------------------------------------
step("2. Create three accounts (two currencies, to set up an FX demo)")
_, acc_a = call("POST", "/accounts", token=token, body={"accountType": "SAVINGS", "currency": "INR"})
_, acc_b = call("POST", "/accounts", token=token, body={"accountType": "CURRENT", "currency": "INR"})
_, acc_c = call("POST", "/accounts", token=token, body={"accountType": "SAVINGS", "currency": "USD"})
print(f"  Account A (INR SAVINGS): {acc_a['account_number']}")
print(f"  Account B (INR CURRENT): {acc_b['account_number']}")
print(f"  Account C (USD SAVINGS): {acc_c['account_number']}")

# ---------------------------------------------------------------------
step("3. Deposit starting money into each account")
call("POST", "/transfers/deposit", token=token, body={"accountId": acc_a["account_id"], "amountMinor": 5_000_000, "currency": "INR"})
call("POST", "/transfers/deposit", token=token, body={"accountId": acc_b["account_id"], "amountMinor": 2_000_000, "currency": "INR"})
call("POST", "/transfers/deposit", token=token, body={"accountId": acc_c["account_id"], "amountMinor": 50_000, "currency": "USD"})
print("  Deposited Rs.50,000 -> A, Rs.20,000 -> B, $500 -> C")

# ---------------------------------------------------------------------
step("4. Normal transfer: A -> B (demonstrates atomicity)")
transfer_key = str(uuid.uuid4())
status, txn = call("POST", "/transfers", token=token, idem_key=transfer_key, body={
    "senderAccountId": acc_a["account_id"], "receiverAccountId": acc_b["account_id"],
    "amountMinor": 500_000, "currency": "INR", "description": "Demo transfer A to B",
})
print(f"  Transferred Rs.5,000, journalId={txn.get('journalId')}, status={txn.get('status')}")

# ---------------------------------------------------------------------
step("5. Replay the SAME request with the SAME Idempotency-Key (the idempotency proof)")
status, replay = call("POST", "/transfers", token=token, idem_key=transfer_key, body={
    "senderAccountId": acc_a["account_id"], "receiverAccountId": acc_b["account_id"],
    "amountMinor": 500_000, "currency": "INR", "description": "Demo transfer A to B",
})
print(f"  HTTP {status} (200 = safely replayed, NOT a new transfer). Same journalId: {replay.get('journalId') == txn.get('journalId')}")

# ---------------------------------------------------------------------
step("6. FX transfer: A (INR) -> C (USD)")
status, fx = call("POST", "/transfers/fx", token=token, body={
    "senderAccountId": acc_a["account_id"], "receiverAccountId": acc_c["account_id"],
    "sendAmountMinor": 400_000, "description": "Demo FX transfer INR to USD",
})
print(f"  Sent Rs.4,000 worth from A -> converted into C's USD balance. journalId={fx.get('journalId')}")

# ---------------------------------------------------------------------
step("7. Save a beneficiary")
_, bene = call("POST", "/beneficiaries", token=token, body={
    "beneficiaryAccountId": acc_b["account_id"], "nickname": "My Current Account",
})
print(f"  Saved beneficiary: {bene.get('nickname')}")

# ---------------------------------------------------------------------
step("8. Fire rapid small transfers to trip fraud detection (>5 debits/hour on one account)")
for i in range(7):
    call("POST", "/transfers", token=token, idem_key=str(uuid.uuid4()), body={
        "senderAccountId": acc_a["account_id"], "receiverAccountId": acc_b["account_id"],
        "amountMinor": 1_000, "currency": "INR", "description": f"Rapid txn {i+1}",
    })
print("  Fired 7 rapid-fire debits from Account A")

# ---------------------------------------------------------------------
step("9. Trigger the worker's scheduled jobs NOW (instead of waiting for their normal schedule)")
print("  Fraud scan new flags:", psql("SELECT detect_fraud_velocity();"))
recon_output = psql("SELECT out_account_id, recon_status FROM run_daily_reconciliation();")
recon_rows = len([l for l in recon_output.splitlines() if l.strip()])
print(f"  Reconciliation:       {recon_rows} account(s) checked")
psql("SELECT refresh_daily_settlement();")
print("  Settlement view refreshed")

# ---------------------------------------------------------------------
step("10. Promote this demo account to admin (so the Admin Console is visible)")
promote_sql = f"""
UPDATE user_roles SET role_id = (SELECT role_id FROM roles WHERE role_name = 'admin')
WHERE user_id = (SELECT user_id FROM users WHERE email = '{DEMO_EMAIL}');
"""
print(" ", psql(promote_sql))

# ---------------------------------------------------------------------
step("DONE")
print(f"""
Log in to http://localhost:8080 with:
  Email:    {DEMO_EMAIL}
  Password: {DEMO_PASSWORD}

(You must log IN fresh with these credentials -- don't just refresh an
existing session -- so your browser picks up the new admin role.)

Everything is already there to show:
  - 3 accounts (2 currencies) under "Accounts"
  - A completed transfer + an idempotency replay in Account A's statement
  - A completed FX transfer
  - A saved beneficiary
  - A HIGH_VELOCITY fraud flag under Admin Console -> Fraud
  - A reconciliation result under Admin Console -> Reconciliation
  - A settlement bar under Admin Console -> Overview chart
""")
