-- Quick end-to-end sanity check of the core engine.
\set ON_ERROR_STOP off

-- Two test users + accounts
INSERT INTO users (user_id, full_name, email, phone, password_hash, kyc_status)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'Alice Sharma', 'alice@test.com', '9000000001', 'hash', 'VERIFIED'),
  ('22222222-2222-2222-2222-222222222222', 'Bob Mehta', 'bob@test.com', '9000000002', 'hash', 'VERIFIED');

INSERT INTO accounts (account_id, user_id, account_number, currency, cached_balance_minor)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'ACC-ALICE-01', 'INR', 0),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-2222-2222-222222222222', 'ACC-BOB-01',   'INR', 0);

INSERT INTO account_limits (account_id) VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

\echo '--- TEST 0: Fund both accounts via process_deposit (not direct column writes) ---'
SELECT process_deposit('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 1000000, 'INR', '11111111-1111-1111-1111-111111111111', 'Initial funding');
SELECT process_deposit('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 500000, 'INR', '22222222-2222-2222-2222-222222222222', 'Initial funding');

\echo '--- TEST 1: Normal transfer Alice -> Bob, 2000.00 INR ---'
SELECT process_transfer(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  200000, 'INR', gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Rent payment'
) AS journal_id \gset

SELECT account_number, cached_balance_minor FROM accounts WHERE account_id IN
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

\echo '--- TEST 2: Idempotency replay (same key, should return SAME journal_id) ---'
-- reuse the key from test 1 by re-querying journal_entries
SELECT idempotency_key FROM journal_entries WHERE journal_id = :'journal_id' \gset
SELECT process_transfer(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  200000, 'INR', :'idempotency_key', '11111111-1111-1111-1111-111111111111', 'Rent payment (retry)'
) = :'journal_id' AS idempotency_held;

\echo '--- TEST 3: Insufficient funds should raise an exception ---'
SELECT process_transfer(
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  99999999, 'INR', gen_random_uuid(), '22222222-2222-2222-2222-222222222222', 'Should fail'
);

\echo '--- TEST 4: Attempting to UPDATE an immutable ledger_postings row should fail ---'
UPDATE ledger_postings SET amount_minor = 1 WHERE journal_id = :'journal_id';

\echo '--- TEST 5: Attempting to DELETE a ledger_postings row should fail ---'
DELETE FROM ledger_postings WHERE journal_id = :'journal_id';

\echo '--- TEST 6: Cross-currency FX transfer, Alice (INR) -> a new USD account ---'
INSERT INTO accounts (account_id, user_id, account_number, currency, cached_balance_minor)
VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc', '22222222-2222-2222-2222-222222222222', 'ACC-BOB-USD', 'USD', 0);
INSERT INTO account_limits (account_id) VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc');

SELECT process_fx_transfer(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'cccccccc-cccc-cccc-cccc-cccccccccccc',
  83250, gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'INR to USD test'
) AS fx_journal_id \gset

SELECT account_number, currency, cached_balance_minor FROM accounts
WHERE account_id IN ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','cccccccc-cccc-cccc-cccc-cccccccccccc')
   OR account_number LIKE 'SYS-CLR%';

\echo '--- TEST 7: Verify per-currency zero-sum on the FX journal ---'
SELECT currency, direction, SUM(amount_minor) FROM ledger_postings
WHERE journal_id = :'fx_journal_id' GROUP BY currency, direction ORDER BY currency, direction;

\echo '--- ALL TESTS EXECUTED ---'
