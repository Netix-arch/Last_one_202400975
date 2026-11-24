-- ============================================================================
-- Question 7: Water Meter Readings and Billing (PostgreSQL)
-- ============================================================================

-- (a) Database and seed data [6 marks]
-- Create customers, readings, bills, and receivable_snapshot with non-negative
-- numeric meter values, month-start reading_month, unique (customer_id,
-- reading_month), unique reading_id in bills, and amount_paid between 0 and
-- charge. Seed three customers and six readings covering zero, exactly 10,
-- and above 10 units.

DROP TABLE IF EXISTS receivable_snapshot CASCADE;
DROP TABLE IF EXISTS bills CASCADE;
DROP TABLE IF EXISTS readings CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(12, 2) NOT NULL CHECK (previous_reading >= 0.00),
    current_reading  NUMERIC(12, 2) NOT NULL CHECK (current_reading >= 0.00),
    CONSTRAINT uq_readings_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12, 2) NOT NULL CHECK (charge >= 0.00),
    amount_paid NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0.00 AND amount_paid <= charge),
    due_on      DATE NOT NULL
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_due >= 0.00)
);

INSERT INTO customers (full_name) VALUES
    ('Chanda Mulenga'),
    ('Mwamba Banda'),
    ('Thandiwe Phiri');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100.00, 100.00), -- 0 units
    (2, DATE '2026-09-01', 200.00, 210.00), -- 10 units
    (3, DATE '2026-09-01', 300.00, 325.00), -- 25 units (above 10)
    (1, DATE '2026-10-01', 100.00, 110.00), -- 10 units
    (2, DATE '2026-10-01', 210.00, 210.00), -- 0 units
    (3, DATE '2026-10-01', 325.00, 340.00); -- 15 units (above 10)


-- (b) Function [6 marks]
-- fn_water_charge(p_units) applies the two tariff bands:
-- first 10 units at K5 each, units above 10 at K8 each, and 0 units = K0.00.
-- Rejects NULL or negative consumption and returns an exact two-decimal charge.

CREATE OR REPLACE FUNCTION fn_water_charge(
    p_units NUMERIC
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC(12, 2);
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: %. Units must be non-negative.', p_units;
    END IF;

    IF p_units = 0 THEN
        v_charge := 0.00;
    ELSIF p_units <= 10 THEN
        v_charge := p_units * 5.00;
    ELSE
        v_charge := (10 * 5.00) + ((p_units - 10) * 8.00);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$;


-- (c) Procedure [8 marks]
-- pr_generate_bill(p_reading_id, p_due_on) derives consumption, calls
-- fn_water_charge, and inserts a bill with amount_paid = 0.00.
-- Rejects an unknown reading_id or a reading that already has a bill.

CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INTEGER,
    p_due_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(12, 2);
    v_curr   NUMERIC(12, 2);
    v_units  NUMERIC(12, 2);
    v_charge NUMERIC(12, 2);
    v_exists BOOLEAN;
BEGIN
    SELECT previous_reading, current_reading
      INTO v_prev, v_curr
      FROM readings
     WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %.', p_reading_id;
    END IF;

    SELECT EXISTS (
        SELECT 1
          FROM bills
         WHERE reading_id = p_reading_id
    )
    INTO v_exists;

    IF v_exists THEN
        RAISE EXCEPTION 'Reading % already has a bill.', p_reading_id;
    END IF;

    v_units  := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0.00, p_due_on);
END;
$$;


-- (d) Trigger [8 marks]
-- BEFORE INSERT OR UPDATE row trigger on readings that rejects
-- current_reading < previous_reading (including direct SQL imports).
-- A rejected reading is not stored.

CREATE OR REPLACE FUNCTION fn_validate_meter_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%).',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_validate_meter
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_validate_meter_reading();

-- Generate bills for seeded readings (some overdue, some partially paid):
CALL pr_generate_bill(1, DATE '2026-10-15');
CALL pr_generate_bill(2, DATE '2026-10-15');
CALL pr_generate_bill(3, DATE '2026-10-15');
CALL pr_generate_bill(4, DATE '2026-11-15');
CALL pr_generate_bill(5, DATE '2026-11-15');
CALL pr_generate_bill(6, DATE '2026-12-15');

UPDATE bills SET amount_paid = 50.00 WHERE reading_id = 2; -- fully paid
UPDATE bills SET amount_paid = 40.00 WHERE reading_id = 3; -- partially paid


-- (e) View [5 marks]
-- v_overdue_bills shows customer name, due date, and outstanding amount
-- where due_on < CURRENT_DATE and the bill is not fully paid.

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    b.bill_id,
    c.full_name              AS customer_name,
    b.due_on                 AS due_date,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings  r ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge
ORDER BY b.due_on ASC, b.bill_id ASC;

SELECT * FROM v_overdue_bills;


-- (f) Index [5 marks]
-- Partial B-tree index on bills(due_on) WHERE amount_paid < charge supports
-- date-based searches for overdue/unpaid bills while excluding settled bills
-- to keep the index compact and fast.

CREATE INDEX idx_bills_unpaid_due_on
    ON bills (due_on)
    WHERE amount_paid < charge;

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    bill_id,
    reading_id,
    charge,
    amount_paid,
    due_on
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;


-- (g) Scheduled job [6 marks]
-- pr_refresh_receivables() stores today's total unpaid bill balances in
-- receivable_snapshot, replacing the same date's total on a rerun.
-- Scheduled daily at 00:30.

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_today     DATE := CURRENT_DATE;
    v_total_due NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0.00)
      INTO v_total_due
      FROM bills
     WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (v_today, v_total_due)
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;
END;
$$;

-- Example scheduling via pg_cron (daily at 00:30):
-- SELECT cron.schedule(
--     'refresh_daily_receivables',
--     '30 0 * * *',
--     $$CALL pr_refresh_receivables();$$
-- );

-- Demonstrate idempotent rerun:
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot WHERE snapshot_date = CURRENT_DATE;
