-- ============================================================================
-- Question 8: Transport Fleet Maintenance (PostgreSQL)
-- ============================================================================

-- (a) Database and seed data [6 marks]
-- Create vehicles, trips, and service_alerts with non-negative odometers and
-- last_service_odometer <= current_ometer. Seed three vehicles with different
-- service positions and six trips added via pr_record_trip after the trigger
-- is installed.

DROP TABLE IF EXISTS service_alerts CASCADE;
DROP TABLE IF EXISTS trips CASCADE;
DROP TABLE IF EXISTS vehicles CASCADE;

CREATE TABLE vehicles (
    vehicle_id           SERIAL PRIMARY KEY,
    registration         VARCHAR(30) NOT NULL UNIQUE,
    current_odometer     NUMERIC(12, 2) NOT NULL CHECK (current_odometer >= 0.00),
    last_service_odometer NUMERIC(12, 2) NOT NULL CHECK (last_service_odometer >= 0.00),
    CONSTRAINT chk_vehicle_odometers CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer NUMERIC(12, 2) NOT NULL CHECK (start_odometer >= 0.00),
    end_odometer   NUMERIC(12, 2) NOT NULL CHECK (end_odometer >= start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id      INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12, 2) NOT NULL CHECK (km_since_service >= 0.00),
    flagged_on      DATE NOT NULL DEFAULT CURRENT_DATE
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABZ 101', 14200.00, 14000.00), -- 200 km since service (not due)
    ('ABZ 202', 24500.00, 20000.00), -- 4,500 km since service (will cross 5,000 km after trips)
    ('ABZ 303', 36000.00, 30000.00); -- already 6,000 km since service (due)


-- (b) Function [6 marks]
-- fn_service_due(p_vehicle_id) returns BOOLEAN indicating whether
-- (current_odometer - last_service_odometer) >= 5000.00. Rejects unknown
-- vehicle_id.

CREATE OR REPLACE FUNCTION fn_service_due(
    p_vehicle_id INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr_odo NUMERIC(12, 2);
    v_last_svc NUMERIC(12, 2);
BEGIN
    SELECT current_odometer, last_service_odometer
      INTO v_curr_odo, v_last_svc
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %.', p_vehicle_id;
    END IF;

    RETURN (v_curr_odo - v_last_svc) >= 5000.00;
END;
$$;


-- (c) Procedure [8 marks]
-- pr_record_trip(p_vehicle_id, p_trip_on, p_start, p_end) validates the
-- vehicle and requires end_odometer > start_odometer. Inserts the trip and
-- leaves updating current_odometer to the BEFORE INSERT trigger on trips.

CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      NUMERIC(12, 2),
    p_end        NUMERIC(12, 2)
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1
       FROM vehicles
      WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %.', p_vehicle_id;
    END IF;

    IF p_start IS NULL OR p_end IS NULL OR p_start < 0.00 OR p_end <= p_start THEN
        RAISE EXCEPTION 'Invalid trip odometer readings: start=%, end=%. end_odometer must be greater than start_odometer.',
            p_start, p_end;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, COALESCE(p_trip_on, CURRENT_DATE), p_start, p_end);
END;
$$;


-- (d) Trigger [8 marks]
-- BEFORE INSERT row trigger on trips that verifies start_odometer equals the
-- vehicle's current_odometer, rejects invalid mileage, and updates
-- current_odometer to NEW.end_odometer once.

CREATE OR REPLACE FUNCTION fn_process_trip_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr_odo NUMERIC(12, 2);
BEGIN
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL
       OR NEW.start_odometer < 0.00 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid trip odometer readings: start=%, end=%.',
            NEW.start_odometer, NEW.end_odometer;
    END IF;

    SELECT current_odometer
      INTO v_curr_odo
      FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %.', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_curr_odo THEN
        RAISE EXCEPTION 'start_odometer (%) does not match vehicle % current_odometer (%).',
            NEW.start_odometer, NEW.vehicle_id, v_curr_odo;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION fn_process_trip_insert();

-- Seed six valid trips via pr_record_trip after trigger installation:
CALL pr_record_trip(1, DATE '2026-11-18', 14200.00, 14500.00);
CALL pr_record_trip(1, DATE '2026-11-20', 14500.00, 14850.00);
CALL pr_record_trip(2, DATE '2026-11-19', 24500.00, 25100.00); -- +600 km -> 5,100 km since service (now due)
CALL pr_record_trip(2, DATE '2026-11-22', 25100.00, 25400.00);
CALL pr_record_trip(3, DATE '2026-11-21', 36000.00, 36400.00);
CALL pr_record_trip(3, DATE '2026-11-23', 36400.00, 36900.00);


-- (e) View [5 marks]
-- v_service_due shows registration and kilometres since service for vehicles
-- that currently meet the 5,000 km service threshold.

CREATE OR REPLACE VIEW v_service_due AS
SELECT
    v.vehicle_id,
    v.registration,
    (v.current_odometer - v.last_service_odometer) AS km_since_service
FROM vehicles v
WHERE (v.current_odometer - v.last_service_odometer) >= 5000.00
ORDER BY km_since_service DESC, v.registration ASC;

SELECT * FROM v_service_due;


-- (f) Index [5 marks]
-- Composite B-tree index on trips(vehicle_id, trip_on) is optimal for
-- retrieving one vehicle's trips over a trip_on date range: equality/lookup
-- on vehicle_id narrows directly to that vehicle's trips, followed by an
-- ordered range scan on trip_on.

CREATE INDEX idx_trips_vehicle_trip_on
    ON trips (vehicle_id, trip_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT
    trip_id,
    vehicle_id,
    trip_on,
    start_odometer,
    end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on >= DATE '2026-11-19'
  AND trip_on <= DATE '2026-11-23';


-- (g) Scheduled job [6 marks]
-- pr_refresh_service_alerts() inserts or updates one alert per due vehicle
-- and deletes alerts for vehicles that are no longer due after servicing.
-- Scheduled every Monday at 06:00.

CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM service_alerts sa
     WHERE NOT EXISTS (
         SELECT 1
           FROM vehicles v
          WHERE v.vehicle_id = sa.vehicle_id
            AND (v.current_odometer - v.last_service_odometer) >= 5000.00
     );

    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        v.vehicle_id,
        (v.current_odometer - v.last_service_odometer) AS km_since_service,
        CURRENT_DATE
    FROM vehicles v
    WHERE (v.current_odometer - v.last_service_odometer) >= 5000.00
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service,
            flagged_on       = EXCLUDED.flagged_on;
END;
$$;

-- Example scheduling via pg_cron (every Monday at 06:00):
-- SELECT cron.schedule(
--     'weekly_fleet_service_alerts',
--     '0 6 * * 1',
--     $$CALL pr_refresh_service_alerts();$$
-- );

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;
