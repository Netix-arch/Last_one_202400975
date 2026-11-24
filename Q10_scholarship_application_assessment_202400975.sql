-- ============================================================================
-- Question 10: Scholarship Application Assessment (PostgreSQL)
-- ============================================================================

-- (a) Database and seed data [6 marks]
-- Create students, applications, and decision_audit with non-negative income,
-- positive age, marks from 0 to 100, unique student_number, and valid
-- statuses ('PENDING', 'APPROVED', 'REJECTED'). Seed at least three students
-- and six PENDING applications covering qualifying, non-qualifying, and
-- boundary cases.

DROP TABLE IF EXISTS decision_audit CASCADE;
DROP TABLE IF EXISTS applications CASCADE;
DROP TABLE IF EXISTS students CASCADE;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE applications (
    application_id   SERIAL PRIMARY KEY,
    student_id       INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income   NUMERIC(12, 2) NOT NULL CHECK (monthly_income >= 0.00),
    average_mark     NUMERIC(5, 2) NOT NULL CHECK (average_mark >= 0.00 AND average_mark <= 100.00),
    submitted_on     DATE NOT NULL DEFAULT CURRENT_DATE,
    status           VARCHAR(15) NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(15) NOT NULL,
    new_status     VARCHAR(15) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students (student_number, full_name) VALUES
    ('SCH-2026-001', 'Chanda Mulenga'),
    ('SCH-2026-002', 'Mwamba Banda'),
    ('SCH-2026-003', 'Thandiwe Phiri'),
    ('SCH-2026-004', 'Kabwe Tembo');

-- Six PENDING applications covering qualifying, non-qualifying, and boundary cases:
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 18, 3000.00, 70.00, DATE '2026-11-10', 'PENDING'), -- exact lower/upper boundaries -> APPROVED
    (1, 25, 2500.00, 82.50, DATE '2026-11-12', 'PENDING'), -- age 25 upper boundary, qualifying -> APPROVED
    (2, 17, 1500.00, 85.00, DATE '2026-11-14', 'PENDING'), -- age too young (17 < 18) -> REJECTED
    (2, 26, 2000.00, 90.00, DATE '2026-11-16', 'PENDING'), -- age too old (26 > 25) -> REJECTED
    (3, 21, 3000.01, 75.00, DATE '2026-11-18', 'PENDING'), -- income just above K3,000 -> REJECTED
    (4, 20, 1200.00, 69.99, DATE '2026-11-20', 'PENDING'); -- mark just below 70 -> REJECTED


-- (b) Function [6 marks]
-- fn_scholarship_eligible(p_age, p_income, p_mark) returns BOOLEAN for all
-- three eligibility rules: age between 18 and 25 inclusive, monthly_income <=
-- 3000, and average_mark >= 70. Rejects NULL inputs, negative income,
-- non-positive age, or marks outside [0, 100].

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs cannot be NULL: age=%, income=%, mark=%.',
            p_age, p_income, p_mark;
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Invalid age (%): must be positive.', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Invalid monthly_income (%): cannot be negative.', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Invalid average_mark (%): must be between 0 and 100.', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000.00)
       AND (p_mark >= 70.00);
END;
$$;


-- (c) Procedure [8 marks]
-- pr_assess_application(p_application_id) requires an existing PENDING
-- application, calls fn_scholarship_eligible, and updates status to
-- 'APPROVED' or 'REJECTED'. Raises a clear exception for an unknown or
-- already assessed application.

CREATE OR REPLACE PROCEDURE pr_assess_application(
    p_application_id INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age      INTEGER;
    v_income   NUMERIC(12, 2);
    v_mark     NUMERIC(5, 2);
    v_status   VARCHAR(15);
    v_eligible BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
      INTO v_age, v_income, v_mark, v_status
      FROM applications
     WHERE application_id = p_application_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %.', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed with status %.',
            p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
       SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END;
$$;


-- (d) Trigger [8 marks]
-- AFTER UPDATE row trigger on applications that records actual status changes
-- in decision_audit using OLD.status, NEW.status, and CURRENT_TIMESTAMP.
-- Unchanged statuses create no audit row.

CREATE OR REPLACE FUNCTION fn_audit_application_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_status_audit
AFTER UPDATE OF status ON applications
FOR EACH ROW
WHEN (NEW.status IS DISTINCT FROM OLD.status)
EXECUTE FUNCTION fn_audit_application_status_change();


-- (e) View [5 marks]
-- v_approved_applicants shows student_number, full_name, average_mark, and
-- status for APPROVED applications only, omitting household income.

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    a.application_id,
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED'
ORDER BY s.student_number ASC, a.application_id ASC;

SELECT * FROM v_approved_applicants;


-- (f) Index [5 marks]
-- Composite B-tree index on applications(status, submitted_on) supports
-- queries filtering by status (such as 'PENDING' or 'APPROVED') within a
-- submitted_on date range by narrowing to the matching status key and scanning
-- submitted_on in order.

CREATE INDEX idx_applications_status_submitted_on
    ON applications (status, submitted_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    application_id,
    student_id,
    age_at_application,
    average_mark,
    submitted_on,
    status
FROM applications
WHERE status = 'PENDING'
  AND submitted_on >= DATE '2026-11-10'
  AND submitted_on <= DATE '2026-11-20';


-- (g) Scheduled job [6 marks]
-- pr_assess_pending() uses a query FOR loop over PENDING applications and
-- assesses each via pr_assess_application. Scheduled every Monday at 08:00;
-- rerunning does not reassess completed rows or duplicate audit entries.

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    v_app RECORD;
BEGIN
    FOR v_app IN
        SELECT application_id
          FROM applications
         WHERE status = 'PENDING'
         ORDER BY application_id ASC
    LOOP
        CALL pr_assess_application(v_app.application_id);
    END LOOP;
END;
$$;

-- Example scheduling via pg_cron (every Monday at 08:00):
-- SELECT cron.schedule(
--     'weekly_scholarship_assessment',
--     '0 8 * * 1',
--     $$CALL pr_assess_pending();$$
-- );

-- Run once to assess PENDING rows, then rerun to verify idempotency:
CALL pr_assess_pending();
CALL pr_assess_pending();

SELECT * FROM v_approved_applicants;
SELECT * FROM decision_audit ORDER BY application_id, audit_id;
