-- ============================================================================
-- Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL)
-- ============================================================================

-- (a) Database and seed data [6 marks]
-- Create farmers, deliveries, and daily_purchases with NUMERIC weight and
-- money fields, unique farmer_number, grade CHECK ('A', 'B', 'C'), and
-- BOOLEAN is_paid. Seed three farmers and six deliveries covering all grades
-- and both payment states (loaded after the trigger in part d is installed).

DROP TABLE IF EXISTS daily_purchases CASCADE;
DROP TABLE IF EXISTS deliveries CASCADE;
DROP TABLE IF EXISTS farmers CASCADE;

CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(30) NOT NULL UNIQUE,
    full_name     VARCHAR(120) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(12, 2) NOT NULL CHECK (weight_kg > 0.00),
    unit_rate    NUMERIC(10, 2) NOT NULL CHECK (unit_rate > 0.00),
    total_value  NUMERIC(12, 2) NOT NULL CHECK (total_value > 0.00),
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_weight >= 0.00),
    total_value   NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_value >= 0.00)
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('FRM-2026-001', 'Chanda Mulenga'),
    ('FRM-2026-002', 'Mwamba Banda'),
    ('FRM-2026-003', 'Thandiwe Phiri');


-- (b) Function [6 marks]
-- fn_maize_rate(p_grade) returns K5.00 for 'A', K4.00 for 'B', and K3.00
-- for 'C'. Rejects NULL or any unsupported grade.

CREATE OR REPLACE FUNCTION fn_maize_rate(
    p_grade TEXT
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_grade TEXT := UPPER(TRIM(p_grade));
BEGIN
    IF v_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL. Allowed grades: A, B, C.';
    ELSIF v_grade = 'A' THEN
        RETURN 5.00;
    ELSIF v_grade = 'B' THEN
        RETURN 4.00;
    ELSIF v_grade = 'C' THEN
        RETURN 3.00;
    ELSE
        RAISE EXCEPTION 'Unsupported maize grade: %. Allowed grades: A, B, C.', p_grade;
    END IF;
END;
$$;


-- (c) Procedure [8 marks]
-- pr_receive_delivery(p_farmer_id, p_grade, p_weight, p_date) rejects unknown
-- farmers and invalid inputs, and inserts the delivery with is_paid = FALSE,
-- letting the BEFORE INSERT/UPDATE trigger supply unit_rate and total_value.

CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     TEXT,
    p_weight    NUMERIC(12, 2),
    p_date      DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_grade     TEXT := UPPER(TRIM(p_grade));
    v_unit_rate NUMERIC(10, 2);
BEGIN
    PERFORM 1
       FROM farmers
      WHERE farmer_id = p_farmer_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %.', p_farmer_id;
    END IF;

    IF p_weight IS NULL OR p_weight <= 0.00 THEN
        RAISE EXCEPTION 'Invalid weight_kg: %. Weight must be greater than zero.', p_weight;
    END IF;

    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date (p_date) cannot be NULL.';
    END IF;

    v_unit_rate := fn_maize_rate(v_grade);

    INSERT INTO deliveries (
        farmer_id,
        grade,
        weight_kg,
        unit_rate,
        total_value,
        delivered_on,
        is_paid
    )
    VALUES (
        p_farmer_id,
        v_grade::CHAR(1),
        p_weight,
        v_unit_rate,
        ROUND(p_weight * v_unit_rate, 2),
        p_date,
        FALSE
    );
END;
$$;


-- (d) Trigger [8 marks]
-- BEFORE INSERT OR UPDATE row trigger on deliveries that rejects non-positive
-- weight_kg, calls fn_maize_rate(NEW.grade), and consistently sets
-- NEW.unit_rate and NEW.total_value (including direct SQL INSERT/UPDATE).

CREATE OR REPLACE FUNCTION fn_calculate_delivery_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_grade TEXT := UPPER(TRIM(NEW.grade));
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0.00 THEN
        RAISE EXCEPTION 'Invalid weight_kg (%): must be greater than zero.', NEW.weight_kg;
    END IF;

    NEW.grade       := v_grade::CHAR(1);
    NEW.unit_rate   := fn_maize_rate(v_grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_calculate_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_calculate_delivery_pricing();

-- Seed six deliveries covering grades A, B, and C and both payment states
-- after the trigger is installed:
CALL pr_receive_delivery(1, 'A', 120.00, DATE '2026-11-22'); -- K5 * 120 = K600.00
CALL pr_receive_delivery(1, 'B',  80.00, DATE '2026-11-23'); -- K4 *  80 = K320.00
CALL pr_receive_delivery(2, 'C', 150.00, DATE '2026-11-23'); -- K3 * 150 = K450.00
CALL pr_receive_delivery(2, 'A', 100.00, DATE '2026-11-24'); -- K5 * 100 = K500.00
CALL pr_receive_delivery(3, 'B',  60.00, DATE '2026-11-24'); -- K4 *  60 = K240.00
CALL pr_receive_delivery(3, 'C',  90.00, DATE '2026-11-24'); -- K3 *  90 = K270.00

UPDATE deliveries
   SET is_paid = TRUE
 WHERE delivery_id IN (1, 3, 5);


-- (e) View [5 marks]
-- v_farmer_amount_due shows each farmer's number, name, and total unpaid
-- delivery value, including farmers with zero unpaid deliveries as 0.00.

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_id,
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0.00)::NUMERIC(12, 2) AS unpaid_amount_due
FROM farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name
ORDER BY f.farmer_number ASC;

SELECT * FROM v_farmer_amount_due;


-- (f) Index [5 marks]
-- Composite B-tree index on deliveries(farmer_id, delivered_on) supports
-- querying a farmer's deliveries between two dates by filtering directly to
-- farmer_id via equality/lookup and scanning delivered_on in index order.

CREATE INDEX idx_deliveries_farmer_delivered_on
    ON deliveries (farmer_id, delivered_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    delivery_id,
    farmer_id,
    grade,
    weight_kg,
    unit_rate,
    total_value,
    delivered_on,
    is_paid
FROM deliveries
WHERE farmer_id = 2
  AND delivered_on >= DATE '2026-11-23'
  AND delivered_on <= DATE '2026-11-24';


-- (g) Scheduled job [6 marks]
-- pr_refresh_purchases(p_day) stores that date's total_weight and total_value
-- in daily_purchases, replacing existing totals idempotently on rerun.
-- Scheduled daily at 01:30 for the previous day.

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(
    p_day DATE DEFAULT (CURRENT_DATE - INTERVAL '1 day')::DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day   DATE := COALESCE(p_day, (CURRENT_DATE - INTERVAL '1 day')::DATE);
    v_total_weight NUMERIC(12, 2);
    v_total_value  NUMERIC(12, 2);
BEGIN
    SELECT
        COALESCE(SUM(weight_kg), 0.00),
        COALESCE(SUM(total_value), 0.00)
      INTO v_total_weight, v_total_value
      FROM deliveries
     WHERE delivered_on = v_target_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (v_target_day, v_total_weight, v_total_value)
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;
END;
$$;

-- Example scheduling via pg_cron (daily at 01:30 for the previous day):
-- SELECT cron.schedule(
--     'refresh_previous_day_maize_purchases',
--     '30 1 * * *',
--     $$CALL pr_refresh_purchases((CURRENT_DATE - INTERVAL '1 day')::DATE);$$
-- );

-- Demonstrate idempotent rerun (replaces totals rather than adding again):
CALL pr_refresh_purchases(DATE '2026-11-23');
CALL pr_refresh_purchases(DATE '2026-11-23');
SELECT * FROM daily_purchases WHERE purchase_date = DATE '2026-11-23';
