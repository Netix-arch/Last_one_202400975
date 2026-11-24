-- ============================================================================
-- Question 6: Monthly Payroll Processing (PostgreSQL)
-- ============================================================================

-- (a) Database and seed data [6 marks]
-- Create employees, payroll, and salary_audit with non-negative money inputs,
-- BOOLEAN active, pay_month stored as the first date of a month, and unique
-- constraint on (employee_id, pay_month). Seed active and inactive employees
-- and data for at least two payroll months.

DROP TABLE IF EXISTS salary_audit CASCADE;
DROP TABLE IF EXISTS payroll CASCADE;
DROP TABLE IF EXISTS employees CASCADE;

CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(120) NOT NULL,
    basic_salary NUMERIC(12, 2) NOT NULL CHECK (basic_salary >= 0.00),
    allowance    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (allowance >= 0.00),
    deduction    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (deduction >= 0.00),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
    gross_pay   NUMERIC(12, 2) NOT NULL CHECK (gross_pay >= 0.00),
    net_pay     NUMERIC(12, 2) NOT NULL CHECK (net_pay >= 0.00),
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12, 2) NOT NULL CHECK (old_salary >= 0.00),
    new_salary  NUMERIC(12, 2) NOT NULL CHECK (new_salary >= 0.00),
    changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Chanda Mulenga', 8000.00, 1500.00, 1200.00, TRUE),
    ('Mwamba Banda',   6500.00, 1000.00,  800.00, TRUE),
    ('Thandiwe Phiri', 5000.00,  500.00,  600.00, FALSE), -- inactive employee
    ('Kabwe Tembo',    7200.00,  800.00,  900.00, TRUE);


-- (b) Function [6 marks]
-- fn_net_pay(p_employee_id) computes gross_pay = basic_salary + allowance and
-- net_pay = gross_pay - deduction from the employee's current figures.
-- Rejects an unknown employee or a negative computed net pay.

CREATE OR REPLACE FUNCTION fn_net_pay(
    p_employee_id INTEGER
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic_salary NUMERIC(12, 2);
    v_allowance    NUMERIC(12, 2);
    v_deduction    NUMERIC(12, 2);
    v_gross_pay    NUMERIC(12, 2);
    v_net_pay      NUMERIC(12, 2);
BEGIN
    SELECT basic_salary, allowance, deduction
      INTO v_basic_salary, v_allowance, v_deduction
      FROM employees
     WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %.', p_employee_id;
    END IF;

    v_gross_pay := v_basic_salary + v_allowance;
    v_net_pay   := v_gross_pay - v_deduction;

    IF v_net_pay < 0.00 THEN
        RAISE EXCEPTION 'Computed net pay (%) is negative for employee_id %.',
            v_net_pay, p_employee_id;
    END IF;

    RETURN ROUND(v_net_pay, 2);
END;
$$;


-- (c) Procedure [8 marks]
-- pr_process_payroll(p_month) uses a query FOR loop over active employees,
-- requires p_month to be the first day of a month, inserts missing
-- (employee_id, pay_month) rows while leaving existing rows unchanged, and
-- lets any invalid employee calculation fail the whole call.

CREATE OR REPLACE PROCEDURE pr_process_payroll(
    p_month DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec       RECORD;
    v_gross_pay NUMERIC(12, 2);
    v_net_pay   NUMERIC(12, 2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Invalid pay_month (%): must be the first day of a month.', p_month;
    END IF;

    FOR v_rec IN
        SELECT employee_id, basic_salary, allowance, deduction
          FROM employees
         WHERE active = TRUE
         ORDER BY employee_id
    LOOP
        v_gross_pay := ROUND(v_rec.basic_salary + v_rec.allowance, 2);
        v_net_pay   := fn_net_pay(v_rec.employee_id);

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (v_rec.employee_id, p_month, v_gross_pay, v_net_pay)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;


-- (d) Trigger [8 marks]
-- AFTER UPDATE row trigger on employees that logs actual basic_salary changes
-- using OLD.basic_salary and NEW.basic_salary into salary_audit. Unchanged
-- salaries do not create audit entries.

CREATE OR REPLACE FUNCTION fn_audit_basic_salary_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_basic_salary_audit
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
WHEN (NEW.basic_salary IS DISTINCT FROM OLD.basic_salary)
EXECUTE FUNCTION fn_audit_basic_salary_change();

-- Seed historical payroll across two months (including a row for inactive employee 3):
INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
VALUES (3, DATE '2026-09-01', 5500.00, 4900.00);

CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');


-- (e) View [5 marks]
-- v_payroll_report joins employee names to pay_month, gross_pay, and net_pay,
-- including historical payroll rows for employees who later become inactive.

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    p.payroll_id,
    e.employee_id,
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id
ORDER BY p.pay_month DESC, e.full_name ASC;

SELECT * FROM v_payroll_report;


-- (f) Index [5 marks]
-- Non-unique B-tree index on payroll(pay_month) supports reports filtering or
-- grouping by pay_month across all employees without duplicating the existing
-- composite unique constraint/index on (employee_id, pay_month), which leads
-- with employee_id and cannot efficiently serve pay_month-only range/equality
-- scans for all employees.

CREATE INDEX idx_payroll_pay_month
    ON payroll (pay_month);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    payroll_id,
    employee_id,
    pay_month,
    gross_pay,
    net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';


-- (g) Scheduled job [6 marks]
-- Schedule pr_process_payroll at 02:00 on the first day of each month, passing
-- the first date of the previous month ((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE),
-- and inspect the scheduled job and its run history.

-- Schedule via pg_cron (02:00 on day 1 of every month for previous month):
-- SELECT cron.schedule(
--     'monthly_payroll_processing',
--     '0 2 1 * *',
--     $$CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);$$
-- );

-- Inspect scheduled job definition in pg_cron:
-- SELECT jobid, jobname, schedule, command, active
--   FROM cron.job
--  WHERE jobname = 'monthly_payroll_processing';

-- Inspect job run history in pg_cron:
-- SELECT runid, jobid, status, return_message, start_time, end_time
--   FROM cron.job_run_details
--  WHERE jobid = (
--      SELECT jobid FROM cron.job WHERE jobname = 'monthly_payroll_processing'
--  )
--  ORDER BY start_time DESC;
