-- ============================================================================
-- Question 1: Pharmacy Stock and Daily Sales (PostgreSQL)
-- ============================================================================

-- (a) Database and seed data [6 marks]
-- Four tables with primary/foreign keys, types, positive unit_price,
-- and non-negative stock_qty. Seed at least three medicines and six valid
-- sales loaded via pr_record_sale (created in part c).

DROP TABLE IF EXISTS daily_sales CASCADE;
DROP TABLE IF EXISTS stock_audit CASCADE;
DROP TABLE IF EXISTS sales CASCADE;
DROP TABLE IF EXISTS medicines CASCADE;

CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL UNIQUE,
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id       SERIAL PRIMARY KEY,
    medicine_id   INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity      INTEGER NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE stock_audit (
    audit_id      SERIAL PRIMARY KEY,
    medicine_id   INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty       INTEGER NOT NULL CHECK (old_qty >= 0),
    new_qty       INTEGER NOT NULL CHECK (new_qty >= 0),
    changed_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date    DATE PRIMARY KEY,
    total_qty     INTEGER NOT NULL DEFAULT 0 CHECK (total_qty >= 0),
    total_amount  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0.00)
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Amoxicillin 500mg', 4.50, 50),
    ('Ibuprofen 400mg',   2.25, 25),
    ('Cetirizine 10mg',   1.80, 12),
    ('Omeprazole 20mg',   3.10, 30);


-- (b) Function [6 marks]
-- fn_sale_value(p_medicine_id, p_quantity) returns current unit_price * quantity
-- for a valid medicine and positive quantity; rejects unknown medicine or <= 0 qty.

CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity    INTEGER
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unit_price NUMERIC(10, 2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %. Quantity must be greater than zero.', p_quantity;
    END IF;

    SELECT unit_price
      INTO v_unit_price
      FROM medicines
     WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %.', p_medicine_id;
    END IF;

    RETURN ROUND(v_unit_price * p_quantity, 2);
END;
$$;


-- (c) Procedure [8 marks]
-- pr_record_sale(p_medicine_id, p_quantity, p_sold_on) checks available stock,
-- stores current unit_price in sales, deducts stock_qty once, and leaves both
-- tables unchanged if validation/stock check fails.

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unit_price NUMERIC(10, 2);
    v_stock_qty  INTEGER;
    v_sold_ts    TIMESTAMP;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %. Quantity must be positive.', p_quantity;
    END IF;

    SELECT unit_price, stock_qty
      INTO v_unit_price, v_stock_qty
      FROM medicines
     WHERE medicine_id = p_medicine_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %.', p_medicine_id;
    END IF;

    IF v_stock_qty < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine_id %: available %, requested %.',
            p_medicine_id, v_stock_qty, p_quantity;
    END IF;

    v_sold_ts := COALESCE(p_sold_on, CURRENT_TIMESTAMP);

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_unit_price, v_sold_ts);

    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;
END;
$$;


-- (d) Trigger [8 marks]
-- AFTER UPDATE row trigger on medicines recording OLD.stock_qty and NEW.stock_qty
-- in stock_audit ONLY when stock_qty actually changes.

CREATE OR REPLACE FUNCTION fn_audit_medicine_stock_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (NEW.stock_qty IS DISTINCT FROM OLD.stock_qty)
EXECUTE FUNCTION fn_audit_medicine_stock_change();

-- Seed at least three medicines and six valid sales via pr_record_sale:
CALL pr_record_sale(1, 10, TIMESTAMP '2026-11-23 09:15:00');
CALL pr_record_sale(2, 8,  TIMESTAMP '2026-11-23 11:30:00');
CALL pr_record_sale(3, 5,  TIMESTAMP '2026-11-23 14:45:00');
CALL pr_record_sale(1, 32, TIMESTAMP '2026-11-23 16:10:00'); -- brings Amoxicillin stock to 8 (< 10)
CALL pr_record_sale(2, 10, TIMESTAMP '2026-11-24 10:05:00'); -- brings Ibuprofen stock to 7 (< 10)
CALL pr_record_sale(4, 6,  TIMESTAMP '2026-11-24 15:20:00');


-- (e) View [5 marks]
-- v_low_stock shows medicines with stock_qty < 10 (name, price, remaining stock),
-- followed by querying the view after a sale.

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10
ORDER BY stock_qty ASC, medicine_name ASC;

-- Query v_low_stock after sales:
SELECT * FROM v_low_stock;


-- (f) Index [5 marks]
-- Composite B-tree index on sales(medicine_id, sold_on) for filtering a single
-- medicine's sales over a sold_on date range (equality/lookup on medicine_id
-- followed by range scan on sold_on), plus EXPLAIN for a matching query.

CREATE INDEX idx_sales_medicine_sold_on
    ON sales (medicine_id, sold_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    sale_id,
    medicine_id,
    quantity,
    unit_price,
    sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on >= TIMESTAMP '2026-11-23 00:00:00'
  AND sold_on <  TIMESTAMP '2026-11-24 00:00:00';


-- (g) Scheduled job [6 marks]
-- pr_refresh_sales(p_day) idempotently replaces that day's total_qty and
-- total_amount in daily_sales, scheduled daily at 00:15 for the previous day.

CREATE OR REPLACE PROCEDURE pr_refresh_sales(
    p_day DATE DEFAULT (CURRENT_DATE - INTERVAL '1 day')::DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day   DATE := COALESCE(p_day, (CURRENT_DATE - INTERVAL '1 day')::DATE);
    v_total_qty    INTEGER;
    v_total_amount NUMERIC(12, 2);
BEGIN
    SELECT
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0.00)
      INTO v_total_qty, v_total_amount
      FROM sales
     WHERE sold_on >= v_target_day::TIMESTAMP
       AND sold_on <  (v_target_day + 1)::TIMESTAMP;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (v_target_day, v_total_qty, v_total_amount)
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Example scheduling via pg_cron (daily at 00:15 for the previous day):
-- SELECT cron.schedule(
--     'refresh_previous_day_sales',
--     '15 0 * * *',
--     $$CALL pr_refresh_sales((CURRENT_DATE - INTERVAL '1 day')::DATE);$$
-- );

-- Demonstrate idempotent execution (rerunning does not duplicate or double-count):
CALL pr_refresh_sales(DATE '2026-11-23');
CALL pr_refresh_sales(DATE '2026-11-23');
SELECT * FROM daily_sales WHERE sales_date = DATE '2026-11-23';
