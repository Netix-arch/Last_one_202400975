-- ============================================================================
-- Question 4: Clinic Appointment Scheduling (PostgreSQL)
-- ============================================================================

-- (a) Database and seed data [6 marks]
-- Create the four tables; use TIME for slot_time and BOOKED, ATTENDED, or
-- CANCELLED for status. Seed three patients, three doctors, and six
-- appointments without violating the slot rule (at most one non-cancelled
-- appointment per doctor, appointment_day, and slot_time among 09:00, 10:00,
-- 11:00, and 12:00).

DROP TABLE IF EXISTS clinic_summary CASCADE;
DROP TABLE IF EXISTS appointments CASCADE;
DROP TABLE IF EXISTS doctors CASCADE;
DROP TABLE IF EXISTS patients CASCADE;

CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(120) NOT NULL
);

CREATE TABLE doctors (
    doctor_id  SERIAL PRIMARY KEY,
    full_name  VARCHAR(120) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL CHECK (slot_time IN (TIME '09:00:00', TIME '10:00:00', TIME '11:00:00', TIME '12:00:00')),
    status          VARCHAR(15) NOT NULL DEFAULT 'BOOKED'
                    CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0 CHECK (booked_count >= 0),
    attended_count  INTEGER NOT NULL DEFAULT 0 CHECK (attended_count >= 0),
    cancelled_count INTEGER NOT NULL DEFAULT 0 CHECK (cancelled_count >= 0)
);

INSERT INTO patients (full_name) VALUES
    ('Chanda Mulenga'),
    ('Mwamba Banda'),
    ('Thandiwe Phiri');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Kabwe Tembo'),
    ('Dr. Mutale Lungu'),
    ('Dr. Bwalya Zulu');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,               TIME '09:00:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,               TIME '10:00:00', 'ATTENDED'),
    (3, 2, CURRENT_DATE,               TIME '09:00:00', 'BOOKED'),
    (1, 3, CURRENT_DATE + 1,           TIME '11:00:00', 'BOOKED'),
    (2, 2, CURRENT_DATE + 1,           TIME '10:00:00', 'CANCELLED'),
    (3, 1, DATE '2026-11-23',          TIME '12:00:00', 'ATTENDED');


-- (b) Function [6 marks]
-- fn_daily_load(p_doctor_id, p_day) returns the number of that doctor's
-- non-cancelled appointments on p_day (0 when none exist), and raises an
-- exception for an unknown doctor_id.

CREATE OR REPLACE FUNCTION fn_daily_load(
    p_doctor_id INTEGER,
    p_day       DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    PERFORM 1
       FROM doctors
      WHERE doctor_id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %.', p_doctor_id;
    END IF;

    SELECT COUNT(*)::INTEGER
      INTO v_count
      FROM appointments
     WHERE doctor_id = p_doctor_id
       AND appointment_day = p_day
       AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;


-- (c) Procedure [8 marks]
-- pr_book_appointment(p_patient_id, p_doctor_id, p_day, p_slot) validates
-- patient_id and doctor_id, rejects a past date or unsupported slot, and
-- inserts a BOOKED appointment.

CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book an appointment on a past date: %.', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN (
        TIME '09:00:00',
        TIME '10:00:00',
        TIME '11:00:00',
        TIME '12:00:00'
    ) THEN
        RAISE EXCEPTION 'Unsupported appointment slot: %. Allowed slots are 09:00, 10:00, 11:00, 12:00.', p_slot;
    END IF;

    PERFORM 1
       FROM patients
      WHERE patient_id = p_patient_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %.', p_patient_id;
    END IF;

    PERFORM 1
       FROM doctors
      WHERE doctor_id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %.', p_doctor_id;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;


-- (d) Trigger [8 marks]
-- BEFORE INSERT OR UPDATE row trigger on appointments that rejects a clash
-- with another non-cancelled appointment for the same doctor, day, and slot.
-- On UPDATE, excludes the appointment row being updated from the clash check.

CREATE OR REPLACE FUNCTION fn_prevent_appointment_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_clash_exists BOOLEAN;
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        SELECT EXISTS (
            SELECT 1
              FROM appointments a
             WHERE a.doctor_id = NEW.doctor_id
               AND a.appointment_day = NEW.appointment_day
               AND a.slot_time = NEW.slot_time
               AND a.status <> 'CANCELLED'
               AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
        )
        INTO v_clash_exists;

        IF v_clash_exists THEN
            RAISE EXCEPTION 'Slot clash for doctor_id % on % at %.',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_prevent_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION fn_prevent_appointment_clash();


-- (e) View [5 marks]
-- v_today_appointments shows today's BOOKED appointments with patient name,
-- doctor name, and slot without exposing unrelated patient data.

CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    a.appointment_id,
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED'
ORDER BY a.slot_time ASC, a.appointment_id ASC;

SELECT * FROM v_today_appointments;


-- (f) Index [5 marks]
-- Non-unique composite B-tree index on appointments(appointment_day, doctor_id)
-- supports filtering/grouping by appointment_day and doctor_id efficiently,
-- followed by the query and its EXPLAIN plan.

CREATE INDEX idx_appointments_day_doctor
    ON appointments (appointment_day, doctor_id);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    appointment_id,
    patient_id,
    doctor_id,
    appointment_day,
    slot_time,
    status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;


-- (g) Scheduled job [6 marks]
-- pr_refresh_clinic_summary(p_day) counts BOOKED, ATTENDED, and CANCELLED
-- appointments for p_day, replacing any existing summary row for that date
-- on rerun. Scheduled daily at 01:00 for the previous day.

CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(
    p_day DATE DEFAULT (CURRENT_DATE - INTERVAL '1 day')::DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_day    DATE := COALESCE(p_day, (CURRENT_DATE - INTERVAL '1 day')::DATE);
    v_booked_cnt    INTEGER;
    v_attended_cnt  INTEGER;
    v_cancelled_cnt INTEGER;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE status = 'BOOKED')::INTEGER,
        COUNT(*) FILTER (WHERE status = 'ATTENDED')::INTEGER,
        COUNT(*) FILTER (WHERE status = 'CANCELLED')::INTEGER
      INTO v_booked_cnt, v_attended_cnt, v_cancelled_cnt
      FROM appointments
     WHERE appointment_day = v_target_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (v_target_day, v_booked_cnt, v_attended_cnt, v_cancelled_cnt)
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

-- Example scheduling via pg_cron (daily at 01:00 for the previous day):
-- SELECT cron.schedule(
--     'refresh_previous_day_clinic_summary',
--     '0 1 * * *',
--     $$CALL pr_refresh_clinic_summary((CURRENT_DATE - INTERVAL '1 day')::DATE);$$
-- );

-- Demonstrate idempotent rerun:
CALL pr_refresh_clinic_summary(DATE '2026-11-23');
CALL pr_refresh_clinic_summary(DATE '2026-11-23');
SELECT * FROM clinic_summary WHERE summary_date = DATE '2026-11-23';
