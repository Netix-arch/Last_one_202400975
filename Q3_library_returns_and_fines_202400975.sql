-- ============================================================================
-- Question 3: Library Returns and Overdue Fines (PostgreSQL)
-- ============================================================================

-- (a) Database and seed data [6 marks]
-- Create the four tables with primary/foreign keys and constraints.
-- Require due_on >= borrowed_on. Seed three books and six loans including
-- an open overdue loan, an on-time loan, and a returned loan.

DROP TABLE IF EXISTS overdue_summary CASCADE;
DROP TABLE IF EXISTS loan_audit CASCADE;
DROP TABLE IF EXISTS loans CASCADE;
DROP TABLE IF EXISTS books CASCADE;

CREATE TABLE books (
    book_id       SERIAL PRIMARY KEY,
    title         VARCHAR(200) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(120) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL CHECK (due_on >= borrowed_on),
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0.00)
);

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0 CHECK (overdue_count >= 0),
    total_fine    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_fine >= 0.00)
);

INSERT INTO books (title) VALUES
    ('Database Systems: Design and Implementation'),
    ('Clean Code'),
    ('Introduction to Algorithms');

-- Seed six loans (open overdue, on-time, and returned):
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Chanda Mulenga', DATE '2026-11-01', DATE '2026-11-10', NULL,              0.00), -- open overdue
    (2, 'Mwamba Banda',   DATE '2026-11-05', DATE '2026-11-15', NULL,              0.00), -- open overdue
    (3, 'Thandiwe Phiri', DATE '2026-11-18', DATE '2026-11-28', NULL,              0.00), -- open on-time
    (1, 'Kabwe Tembo',    DATE '2026-11-20', DATE '2026-11-30', NULL,              0.00), -- open on-time
    (2, 'Mutale Lungu',   DATE '2026-11-01', DATE '2026-11-10', DATE '2026-11-10', 0.00), -- returned on time
    (3, 'Bwalya Zulu',    DATE '2026-11-02', DATE '2026-11-12', DATE '2026-11-16', 8.00); -- returned 4 days late (4 * K2)


-- (b) Function [6 marks]
-- fn_loan_fine(p_loan_id, p_as_of) returns K2 * overdue days (minimum 0.00).
-- Uses the earlier of p_as_of and returned_on when returned_on is not NULL.
-- Rejects an unknown loan_id.

CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INTEGER,
    p_as_of   DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on      DATE;
    v_returned_on DATE;
    v_eval_date   DATE;
    v_days_late   INTEGER;
BEGIN
    SELECT due_on, returned_on
      INTO v_due_on, v_returned_on
      FROM loans
     WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %.', p_loan_id;
    END IF;

    v_eval_date := COALESCE(p_as_of, CURRENT_DATE);
    IF v_returned_on IS NOT NULL THEN
        v_eval_date := LEAST(v_eval_date, v_returned_on);
    END IF;

    v_days_late := GREATEST(0, v_eval_date - v_due_on);
    RETURN (v_days_late * 2.00)::NUMERIC(10, 2);
END;
$$;


-- (c) Procedure [8 marks]
-- pr_return_loan(p_loan_id, p_returned_on) rejects unknown or already returned
-- loans, and rejects a return date before borrowed_on. Stores returned_on and
-- the calculated final fine together.

CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id     INTEGER,
    p_returned_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_returned_on DATE;
    v_return_dt   DATE := COALESCE(p_returned_on, CURRENT_DATE);
    v_final_fine  NUMERIC(10, 2);
BEGIN
    SELECT borrowed_on, returned_on
      INTO v_borrowed_on, v_returned_on
      FROM loans
     WHERE loan_id = p_loan_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %.', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % has already been returned on %.', p_loan_id, v_returned_on;
    END IF;

    IF v_return_dt < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date (%) cannot be before borrowed_on (%).',
            v_return_dt, v_borrowed_on;
    END IF;

    UPDATE loans
       SET returned_on = v_return_dt
     WHERE loan_id = p_loan_id;

    v_final_fine := fn_loan_fine(p_loan_id, v_return_dt);

    UPDATE loans
       SET fine_amount = v_final_fine
     WHERE loan_id = p_loan_id;
END;
$$;


-- (d) Trigger [8 marks]
-- AFTER UPDATE row trigger on loans that logs changes to returned_on in
-- loan_audit using OLD and NEW. Does not create an audit row when unchanged.

CREATE OR REPLACE FUNCTION fn_audit_loan_return()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_returned_on_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (NEW.returned_on IS DISTINCT FROM OLD.returned_on)
EXECUTE FUNCTION fn_audit_loan_return();


-- (e) View [5 marks]
-- v_overdue_loans for loans currently unreturned and due before CURRENT_DATE,
-- showing book title, borrower, due date, and fine as of today.

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    l.loan_id,
    b.title        AS book_title,
    l.borrower_name,
    l.due_on       AS due_date,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE
ORDER BY l.due_on ASC, l.loan_id ASC;

SELECT * FROM v_overdue_loans;


-- (f) Index [5 marks]
-- Partial index on loans(book_id) WHERE returned_on IS NULL directly supports
-- searching for a given book's unreturned loans while keeping the index small.

CREATE INDEX idx_loans_unreturned_by_book
    ON loans (book_id)
    WHERE returned_on IS NULL;

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    loan_id,
    book_id,
    borrower_name,
    borrowed_on,
    due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;


-- (g) Scheduled job [6 marks]
-- pr_refresh_overdue(p_as_of) counts loans still unreturned as of p_as_of and
-- sums their fines, replacing the same snapshot_date on a rerun.
-- Scheduled daily at 00:10 for CURRENT_DATE.

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(
    p_as_of DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_date   DATE := COALESCE(p_as_of, CURRENT_DATE);
    v_overdue_count INTEGER;
    v_total_fine    NUMERIC(12, 2);
BEGIN
    SELECT
        COUNT(*)::INTEGER,
        COALESCE(SUM(fn_loan_fine(loan_id, v_target_date)), 0.00)
      INTO v_overdue_count, v_total_fine
      FROM loans
     WHERE (returned_on IS NULL OR returned_on > v_target_date)
       AND due_on < v_target_date;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (v_target_date, v_overdue_count, v_total_fine)
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

-- Example scheduling via pg_cron (daily at 00:10 for CURRENT_DATE):
-- SELECT cron.schedule(
--     'refresh_daily_overdue_summary',
--     '10 0 * * *',
--     $$CALL pr_refresh_overdue(CURRENT_DATE);$$
-- );

-- Demonstrate idempotent rerun:
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary WHERE snapshot_date = CURRENT_DATE;
