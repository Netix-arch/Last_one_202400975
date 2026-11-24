-- ============================================================================
-- Question 5: Hostel Room Allocation (PostgreSQL)
-- ============================================================================

-- (a) Database and seed data [6 marks]
-- Create the four tables with positive room capacity, ACTIVE/ENDED status,
-- ACTIVE requiring released_on IS NULL, and ENDED requiring released_on IS NOT NULL.
-- Seed rooms, students, and allocations showing full, partly occupied, and
-- empty rooms.

DROP TABLE IF EXISTS occupancy_snapshot CASCADE;
DROP TABLE IF EXISTS allocations CASCADE;
DROP TABLE IF EXISTS rooms CASCADE;
DROP TABLE IF EXISTS students CASCADE;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(30) NOT NULL UNIQUE,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_allocation_dates CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR
        (status = 'ENDED' AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds     INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO rooms (room_number, capacity) VALUES
    ('H1-101', 2), -- will be full (2 active)
    ('H1-102', 3), -- will be partly occupied (1 active, plus 1 ended)
    ('H1-103', 2), -- will be empty (only ended history)
    ('H1-104', 2); -- completely empty (no allocations)

INSERT INTO students (student_number, full_name) VALUES
    ('STU-2026-101', 'Chanda Mulenga'),
    ('STU-2026-102', 'Mwamba Banda'),
    ('STU-2026-103', 'Thandiwe Phiri'),
    ('STU-2026-104', 'Kabwe Tembo'),
    ('STU-2026-105', 'Mutale Lungu');

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (1, 1, DATE '2026-09-01', NULL,              'ACTIVE'), -- H1-101 (1/2)
    (2, 1, DATE '2026-09-02', NULL,              'ACTIVE'), -- H1-101 (2/2 -> full)
    (3, 2, DATE '2026-09-05', NULL,              'ACTIVE'), -- H1-102 (1/3 -> partly occupied)
    (4, 2, DATE '2026-08-01', DATE '2026-08-31', 'ENDED'),  -- H1-102 historical ended
    (5, 3, DATE '2026-08-10', DATE '2026-08-25', 'ENDED');  -- H1-103 empty (ended only)


-- (b) Function [6 marks]
-- fn_free_beds(p_room_id) returns room capacity minus its ACTIVE allocation
-- count (ENDED allocations do not reduce availability). Rejects unknown room_id.

CREATE OR REPLACE FUNCTION fn_free_beds(
    p_room_id INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity
      INTO v_capacity
      FROM rooms
     WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %.', p_room_id;
    END IF;

    SELECT COUNT(*)::INTEGER
      INTO v_active
      FROM allocations
     WHERE room_id = p_room_id
       AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;


-- (c) Procedure [8 marks]
-- pr_allocate_room(p_student_id, p_room_id, p_allocated_on) validates IDs,
-- ensures the student has no existing ACTIVE allocation, checks room bed
-- availability, and creates one ACTIVE allocation with released_on IS NULL.

CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_alloc_date DATE := COALESCE(p_allocated_on, CURRENT_DATE);
    v_has_active BOOLEAN;
    v_free_beds  INTEGER;
BEGIN
    PERFORM 1
       FROM students
      WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %.', p_student_id;
    END IF;

    SELECT capacity
      FROM rooms
     WHERE room_id = p_room_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %.', p_room_id;
    END IF;

    SELECT EXISTS (
        SELECT 1
          FROM allocations
         WHERE student_id = p_student_id
           AND status = 'ACTIVE'
    )
    INTO v_has_active;

    IF v_has_active THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE room allocation.', p_student_id;
    END IF;

    v_free_beds := fn_free_beds(p_room_id);

    IF v_free_beds <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds available.', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, v_alloc_date, NULL, 'ACTIVE');
END;
$$;


-- (d) Trigger [8 marks]
-- BEFORE INSERT OR UPDATE row trigger on allocations that enforces room capacity
-- and at most one ACTIVE allocation per student for direct SQL changes,
-- excluding the row being updated when checking other allocations.

CREATE OR REPLACE FUNCTION fn_enforce_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity     INTEGER;
    v_active_room  INTEGER;
    v_other_active BOOLEAN;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity
          INTO v_capacity
          FROM rooms
         WHERE room_id = NEW.room_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %.', NEW.room_id;
        END IF;

        SELECT EXISTS (
            SELECT 1
              FROM allocations a
             WHERE a.student_id = NEW.student_id
               AND a.status = 'ACTIVE'
               AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)
        )
        INTO v_other_active;

        IF v_other_active THEN
            RAISE EXCEPTION 'Student % already has another ACTIVE allocation.', NEW.student_id;
        END IF;

        SELECT COUNT(*)::INTEGER
          INTO v_active_room
          FROM allocations a
         WHERE a.room_id = NEW.room_id
           AND a.status = 'ACTIVE'
           AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);

        IF (v_active_room + 1) > v_capacity THEN
            RAISE EXCEPTION 'Room % capacity (%) exceeded by ACTIVE allocations.',
                NEW.room_id, v_capacity;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_enforce_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_enforce_allocation_rules();


-- (e) View [5 marks]
-- v_room_occupancy shows every room, its capacity, occupied beds, and free
-- beds, including rooms with no allocations.

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')::INTEGER AS occupied_beds,
    (r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE'))::INTEGER AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity
ORDER BY r.room_id ASC;

SELECT * FROM v_room_occupancy;


-- (f) Index [5 marks]
-- Partial index on allocations(room_id) WHERE status = 'ACTIVE' targets queries
-- filtering ACTIVE allocations by room_id while excluding ENDED rows to keep
-- index size small and lookups fast.

CREATE INDEX idx_allocations_active_by_room
    ON allocations (room_id)
    WHERE status = 'ACTIVE';

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    allocation_id,
    student_id,
    room_id,
    allocated_on
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';


-- (g) Scheduled job [6 marks]
-- pr_refresh_occupancy() records CURRENT_DATE occupancy for every room (one row
-- per date and room) and replaces existing values when rerun. Scheduled
-- daily at 23:55.

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
DECLARE
    v_today DATE := CURRENT_DATE;
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT
        v_today,
        r.room_id,
        COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')::INTEGER AS occupied_beds,
        (r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE'))::INTEGER AS free_beds
    FROM rooms r
    LEFT JOIN allocations a
           ON a.room_id = r.room_id
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;

-- Example scheduling via pg_cron (daily at 23:55):
-- SELECT cron.schedule(
--     'refresh_daily_hostel_occupancy',
--     '55 23 * * *',
--     $$CALL pr_refresh_occupancy();$$
-- );

-- Demonstrate idempotent rerun (one row per date and room, replacing values):
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot WHERE snapshot_date = CURRENT_DATE ORDER BY room_id;
