-- ============================================================================
-- Question 2: University Fee Payments (PostgreSQL)
-- ============================================================================

-- (a) Database and seed data [6 marks]
-- Four tables with primary/foreign/unique keys, types, non-negative fee_due
-- and payment amount checks. Seed at least three students with different fee
-- balances (one initially having no payments) and at least six valid payments.

DROP TABLE IF EXISTS daily_collections CASCADE;
DROP TABLE IF EXISTS payment_audit CASCADE;
DROP TABLE IF EXISTS payments CASCADE;
DROP TABLE IF EXISTS students CASCADE;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL,
    fee_due        NUMERIC(12, 2) NOT NULL CHECK (fee_due >= 0.00)
);

CREATE TABLE payments (
    payment_id     SERIAL PRIMARY KEY,
    student_id     INTEGER NOT NULL REFERENCES students(student_id),
    amount         NUMERIC(12, 2) NOT NULL CHECK (amount > 0.00),
    paid_on        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE payment_audit (
    audit_id       SERIAL PRIMARY KEY,
    payment_id     INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id     INTEGER NOT NULL REFERENCES students(student_id),
    amount         NUMERIC(12, 2) NOT NULL CHECK (amount > 0.00),
    logged_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0 CHECK (payment_count >= 0),
    total_amount    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0.00)
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('STU-2026-001', 'Chanda Mulenga',   1500.00),
    ('STU-2026-002', 'Mwamba Banda',     1200.00),
    ('STU-2026-003', 'Thandiwe Phiri',    900.00), -- initially has no payments
    ('STU-2026-004', 'Kabwe Tembo',       800.00);


-- (b) Function [6 marks]
-- fn_fee_balance(p_student_id) returns fee_due minus total payments for a valid
-- student (full fee when no payments exist), and raises an exception for an
-- unknown student_id.

CREATE OR REPLACE FUNCTION fn_fee_balance(
    p_student_id INTEGER
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due        NUMERIC(12, 2);
    v_total_paid     NUMERIC(12, 2);
BEGIN
    SELECT fee_due
      INTO v_fee_due
      FROM students
     WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %.', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00)
      INTO v_total_paid
      FROM payments
     WHERE student_id = p_student_id;

    RETURN ROUND(v_fee_due - v_total_paid, 2);
END;
$$;


-- (c) Procedure [8 marks]
-- pr_receive_payment(p_student_id, p_amount, p_paid_on) rejects NULL, zero,
-- or negative amounts and payments exceeding the current outstanding balance.
-- Inserts a valid payment without modifying fee_due.

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC(12, 2),
    p_paid_on    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due     NUMERIC(12, 2);
    v_total_paid  NUMERIC(12, 2);
    v_balance     NUMERIC(12, 2);
    v_paid_ts     TIMESTAMP;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0.00 THEN
        RAISE EXCEPTION 'Invalid payment amount: %. Amount must be greater than zero.', p_amount;
    END IF;

    SELECT fee_due
      INTO v_fee_due
      FROM students
     WHERE student_id = p_student_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %.', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00)
      INTO v_total_paid
      FROM payments
     WHERE student_id = p_student_id;

    v_balance := v_fee_due - v_total_paid;

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment amount (%) exceeds outstanding balance (%) for student_id %.',
            p_amount, v_balance, p_student_id;
    END IF;

    v_paid_ts := COALESCE(p_paid_on, CURRENT_TIMESTAMP);

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, v_paid_ts);
END;
$$;


-- (d) Trigger [8 marks]
-- AFTER INSERT row trigger on payments that writes payment_id, student_id,
-- amount, and timestamp to payment_audit automatically (not inside the procedure).

CREATE OR REPLACE FUNCTION fn_audit_payment_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_after_insert
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_audit_payment_insert();

-- Seed at least six valid payments (student 3 stays with zero payments initially):
CALL pr_receive_payment(1, 500.00, TIMESTAMP '2026-11-23 08:30:00');
CALL pr_receive_payment(1, 400.00, TIMESTAMP '2026-11-23 10:45:00');
CALL pr_receive_payment(2, 600.00, TIMESTAMP '2026-11-23 13:15:00');
CALL pr_receive_payment(4, 800.00, TIMESTAMP '2026-11-23 15:00:00'); -- fully settles student 4
CALL pr_receive_payment(1, 300.00, TIMESTAMP '2026-11-24 09:20:00');
CALL pr_receive_payment(2, 350.00, TIMESTAMP '2026-11-24 14:10:00');


-- (e) View [5 marks]
-- v_fee_balances shows student_number, full_name, and outstanding_balance
-- for students with a positive balance (> 0), excluding fully settled students.

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    (s.fee_due - COALESCE(SUM(p.amount), 0.00)) AS outstanding_balance
FROM students s
LEFT JOIN payments p
       ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING (s.fee_due - COALESCE(SUM(p.amount), 0.00)) > 0.00
ORDER BY s.student_number ASC;

SELECT * FROM v_fee_balances;


-- (f) Index [5 marks]
-- Composite B-tree index on payments(student_id, paid_on) is ideal because
-- queries filtering by a single student_id and a paid_on date range narrow
-- directly to that student's entries via equality/lookup on student_id and then
-- scan paid_on in sorted order without sorting or scanning unrelated students.

CREATE INDEX idx_payments_student_paid_on
    ON payments (student_id, paid_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    payment_id,
    student_id,
    amount,
    paid_on
FROM payments
WHERE student_id = 1
  AND paid_on >= TIMESTAMP '2026-11-23 00:00:00'
  AND paid_on <  TIMESTAMP '2026-11-24 00:00:00';


-- (g) Scheduled job [6 marks]
-- pr_refresh_collections(p_day) stores payment_count and total_amount for that
-- date in daily_collections, replacing existing summary rows idempotently when
-- rerun, scheduled daily at 01:00 for the previous day.

CREATE OR REPLACE PROCEDURE pr_refresh_collections(
    p_day DATE DEFAULT (CURRENT_DATE - INTERVAL '1 day')::DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day   DATE := COALESCE(p_day, (CURRENT_DATE - INTERVAL '1 day')::DATE);
    v_payment_cnt  INTEGER;
    v_total_amount NUMERIC(12, 2);
BEGIN
    SELECT
        COUNT(*)::INTEGER,
        COALESCE(SUM(amount), 0.00)
      INTO v_payment_cnt, v_total_amount
      FROM payments
     WHERE paid_on >= v_target_day::TIMESTAMP
       AND paid_on <  (v_target_day + 1)::TIMESTAMP;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (v_target_day, v_payment_cnt, v_total_amount)
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount  = EXCLUDED.total_amount;
END;
$$;

-- Example scheduling via pg_cron (daily at 01:00 for the previous day):
-- SELECT cron.schedule(
--     'refresh_previous_day_collections',
--     '0 1 * * *',
--     $$CALL pr_refresh_collections((CURRENT_DATE - INTERVAL '1 day')::DATE);$$
-- );

-- Demonstrate idempotent rerun (replaces existing summary row without duplicating):
CALL pr_refresh_collections(DATE '2026-11-23');
CALL pr_refresh_collections(DATE '2026-11-23');
SELECT * FROM daily_collections WHERE collection_date = DATE '2026-11-23';
