-- =====================================================================
-- 05 SERVICE — incidents, maintenance (preventive / corrective), calibration
--
-- EER constructs in this module
--   * MAINTENANCE with a TOTAL, DISJOINT, attribute-defined
--     specialization on maintenance_type into PREVENTIVE_MAINTENANCE and
--     CORRECTIVE_MAINTENANCE, each with its own attributes.
--     Mapping: one relation per class (option 8A). Disjointness is
--     declarative: each subclass row carries the discriminator, pinned by
--     a CHECK, inside a composite foreign key. Totality (every maintenance
--     row has its subclass row) is checked at COMMIT by a deferred
--     constraint trigger.
--   * INCIDENT reported by a PERSON, optionally during a USAGE_LOG.
--   * 1:1 RESOLVES between CORRECTIVE_MAINTENANCE and INCIDENT.
--   * ASSIGNED_TO: maintenance -> TECHNICIAN.
--   * CALIBRATION is related to the CALIBRATABLE_EQUIPMENT subclass only.
--
-- The equipment's lifecycle status follows its open work orders, and
-- availability for booking requires a valid calibration.
-- =====================================================================

CREATE TYPE service.maintenance_type   AS ENUM ('preventive', 'corrective');
-- 'scheduled' orders are planned for later and do not hold the item yet
CREATE TYPE service.maintenance_status AS ENUM ('scheduled', 'open', 'in_progress', 'completed', 'cancelled');
CREATE TYPE service.severity           AS ENUM ('low', 'medium', 'high', 'critical');
CREATE TYPE service.incident_status    AS ENUM ('open', 'escalated', 'resolved', 'dismissed');
CREATE TYPE service.calibration_result AS ENUM ('pass', 'adjusted', 'fail');

-- Incident -------------------------------------------------------------------------
CREATE TABLE service.incident (
    incident_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    equipment_id  integer NOT NULL REFERENCES inventory.equipment ON DELETE RESTRICT,
    reported_by   integer NOT NULL REFERENCES org.person ON DELETE RESTRICT,
    usage_id      integer REFERENCES booking.usage_log ON DELETE RESTRICT,
    reported_at   timestamptz NOT NULL DEFAULT now(),
    severity      service.severity NOT NULL,
    description   text NOT NULL,
    status        service.incident_status NOT NULL DEFAULT 'open'
);

-- an incident raised from a usage log must concern the booked item
CREATE FUNCTION service.trg_incident_matches_usage() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.usage_id IS NOT NULL AND NEW.equipment_id IS DISTINCT FROM (
        SELECT r.equipment_id FROM booking.usage_log u
        JOIN booking.reservation r USING (reservation_id)
        WHERE u.usage_id = NEW.usage_id) THEN
        PERFORM public.rule_violation('LB005',
            format('usage %s was not on equipment %s', NEW.usage_id, NEW.equipment_id));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER incident_matches_usage
    BEFORE INSERT OR UPDATE OF usage_id, equipment_id ON service.incident
    FOR EACH ROW EXECUTE FUNCTION service.trg_incident_matches_usage();

-- A critical incident locks the item out immediately (safety stop).
-- Setting out_of_service in turn cancels its future bookings through the
-- booking module's revalidation trigger.
CREATE FUNCTION service.trg_critical_lockout() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE inventory.equipment SET lifecycle_status = 'out_of_service'
    WHERE equipment_id = NEW.equipment_id AND lifecycle_status <> 'retired';
    RETURN NULL;
END $$;

CREATE TRIGGER critical_lockout
    AFTER INSERT ON service.incident
    FOR EACH ROW WHEN (NEW.severity = 'critical')
    EXECUTE FUNCTION service.trg_critical_lockout();

-- A usage log that ends with condition 'fault' opens an incident.
CREATE FUNCTION service.trg_fault_opens_incident() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO service.incident (equipment_id, reported_by, usage_id, reported_at, severity, description)
    SELECT r.equipment_id, r.person_id, NEW.usage_id, NEW.actual_end, 'medium',
           coalesce(NEW.notes, 'fault reported at end of use')
    FROM booking.reservation r WHERE r.reservation_id = NEW.reservation_id;
    RETURN NULL;
END $$;

CREATE TRIGGER fault_opens_incident
    AFTER INSERT ON booking.usage_log
    FOR EACH ROW WHEN (NEW.condition_after = 'fault')
    EXECUTE FUNCTION service.trg_fault_opens_incident();

-- Maintenance (superclass) ------------------------------------------------------------
CREATE TABLE service.maintenance (
    maintenance_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    maintenance_type  service.maintenance_type NOT NULL,     -- discriminator (total)
    equipment_id      integer NOT NULL REFERENCES inventory.equipment ON DELETE RESTRICT,
    technician_id     integer REFERENCES org.technician (person_id) ON DELETE SET NULL,
    vendor            text,
    opened_at         timestamptz NOT NULL DEFAULT now(),
    completed_at      timestamptz,
    cost              public.money_amount NOT NULL DEFAULT 0,
    status            service.maintenance_status NOT NULL DEFAULT 'open',
    description       text NOT NULL,
    UNIQUE (maintenance_id, maintenance_type),               -- target of subclass FKs
    CONSTRAINT maintenance_has_worker CHECK (technician_id IS NOT NULL OR vendor IS NOT NULL),
    CONSTRAINT maintenance_completion CHECK (
        (status = 'completed') = (completed_at IS NOT NULL)
        AND (completed_at IS NULL OR completed_at >= opened_at))
);

-- Subclasses (disjoint: the discriminator is part of the FK and pinned) ----------------
CREATE TABLE service.preventive_maintenance (
    maintenance_id    integer PRIMARY KEY,
    maintenance_type  service.maintenance_type NOT NULL DEFAULT 'preventive'
                      CHECK (maintenance_type = 'preventive'),
    planned_for       date NOT NULL,
    repeat_every      interval CHECK (repeat_every >= interval '7 days'),
    checklist         text NOT NULL,
    FOREIGN KEY (maintenance_id, maintenance_type)
        REFERENCES service.maintenance (maintenance_id, maintenance_type) ON DELETE CASCADE
);

CREATE TABLE service.corrective_maintenance (
    maintenance_id    integer PRIMARY KEY,
    maintenance_type  service.maintenance_type NOT NULL DEFAULT 'corrective'
                      CHECK (maintenance_type = 'corrective'),
    incident_id       integer NOT NULL UNIQUE REFERENCES service.incident ON DELETE RESTRICT,
    root_cause        text,
    parts_replaced    text,
    FOREIGN KEY (maintenance_id, maintenance_type)
        REFERENCES service.maintenance (maintenance_id, maintenance_type) ON DELETE CASCADE
);

-- Totality: checked at COMMIT so parent and child can be inserted in
-- either order inside one transaction.
CREATE FUNCTION service.trg_maintenance_total() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM service.maintenance WHERE maintenance_id = NEW.maintenance_id) THEN
        RETURN NULL;  -- row was deleted later in the same transaction
    END IF;
    IF NOT EXISTS (SELECT 1 FROM service.preventive_maintenance WHERE maintenance_id = NEW.maintenance_id)
       AND NOT EXISTS (SELECT 1 FROM service.corrective_maintenance WHERE maintenance_id = NEW.maintenance_id) THEN
        PERFORM public.rule_violation('LB008',
            format('maintenance %s has no %s subclass row', NEW.maintenance_id, NEW.maintenance_type));
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER maintenance_total
    AFTER INSERT ON service.maintenance
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION service.trg_maintenance_total();

-- the corrective work order must be for the item the incident concerns
CREATE FUNCTION service.trg_corrective_same_equipment() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT equipment_id FROM service.maintenance WHERE maintenance_id = NEW.maintenance_id)
       IS DISTINCT FROM (SELECT equipment_id FROM service.incident WHERE incident_id = NEW.incident_id) THEN
        PERFORM public.rule_violation('LB005',
            format('maintenance %s and incident %s concern different equipment', NEW.maintenance_id, NEW.incident_id));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER corrective_same_equipment
    BEFORE INSERT OR UPDATE ON service.corrective_maintenance
    FOR EACH ROW EXECUTE FUNCTION service.trg_corrective_same_equipment();

-- Lifecycle status follows open work orders ------------------------------------------
CREATE FUNCTION service.trg_sync_lifecycle() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('open', 'in_progress') THEN
        UPDATE inventory.equipment SET lifecycle_status = 'under_maintenance'
        WHERE equipment_id = NEW.equipment_id AND lifecycle_status = 'in_service';
    ELSIF NEW.status IN ('completed', 'cancelled')
      AND NOT EXISTS (SELECT 1 FROM service.maintenance
                      WHERE equipment_id = NEW.equipment_id
                        AND status IN ('open', 'in_progress')) THEN
        -- last open order closed: back in service unless retired
        UPDATE inventory.equipment SET lifecycle_status = 'in_service'
        WHERE equipment_id = NEW.equipment_id
          AND lifecycle_status IN ('under_maintenance', 'out_of_service');
        -- a finished repair resolves its incident
        IF NEW.status = 'completed' THEN
            UPDATE service.incident i SET status = 'resolved'
            FROM service.corrective_maintenance c
            WHERE c.maintenance_id = NEW.maintenance_id AND i.incident_id = c.incident_id;
        END IF;
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER sync_lifecycle
    AFTER INSERT OR UPDATE OF status ON service.maintenance
    FOR EACH ROW EXECUTE FUNCTION service.trg_sync_lifecycle();

-- Work-order API --------------------------------------------------------------------
CREATE FUNCTION service.escalate_incident(p_incident integer, p_technician integer,
                                          p_vendor text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    i service.incident%ROWTYPE;
    v_id integer;
BEGIN
    SELECT * INTO i FROM service.incident WHERE incident_id = p_incident FOR UPDATE;
    IF i.status <> 'open' THEN
        PERFORM public.rule_violation('LB004', format('incident %s is %s, not open', p_incident, i.status));
    END IF;
    INSERT INTO service.maintenance (maintenance_type, equipment_id, technician_id, vendor,
                                     opened_at, description)
    VALUES ('corrective', i.equipment_id, p_technician, p_vendor, public.app_now(),
            'Repair: ' || i.description)
    RETURNING maintenance_id INTO v_id;
    INSERT INTO service.corrective_maintenance (maintenance_id, incident_id)
    VALUES (v_id, p_incident);
    UPDATE service.incident SET status = 'escalated' WHERE incident_id = p_incident;
    RETURN v_id;
END $$;

CREATE FUNCTION service.schedule_preventive(p_equipment integer, p_planned date,
                                            p_technician integer, p_checklist text,
                                            p_repeat interval DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_id integer;
BEGIN
    INSERT INTO service.maintenance (maintenance_type, equipment_id, technician_id,
                                     opened_at, status, description)
    VALUES ('preventive', p_equipment, p_technician, p_planned::timestamptz, 'scheduled',
            'Preventive maintenance')
    RETURNING maintenance_id INTO v_id;
    INSERT INTO service.preventive_maintenance (maintenance_id, planned_for, repeat_every, checklist)
    VALUES (v_id, p_planned, p_repeat, p_checklist);
    RETURN v_id;
END $$;

-- A scheduled job starts: the item is taken out of use.
CREATE PROCEDURE service.start_maintenance(p_maintenance integer)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE service.maintenance SET status = 'in_progress'
    WHERE maintenance_id = p_maintenance AND status IN ('scheduled', 'open');
    IF NOT FOUND THEN
        PERFORM public.rule_violation('LB004', format('maintenance %s cannot be started', p_maintenance));
    END IF;
END $$;

CREATE PROCEDURE service.complete_maintenance(p_maintenance integer, p_cost numeric,
                                              p_note text DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    m service.maintenance%ROWTYPE;
    p service.preventive_maintenance%ROWTYPE;
BEGIN
    UPDATE service.maintenance
    SET status = 'completed', completed_at = greatest(public.app_now(), opened_at), cost = p_cost
    WHERE maintenance_id = p_maintenance AND status IN ('open', 'in_progress')
    RETURNING * INTO m;
    IF NOT FOUND THEN
        PERFORM public.rule_violation('LB004', format('maintenance %s is not open', p_maintenance));
    END IF;
    UPDATE service.corrective_maintenance SET root_cause = coalesce(p_note, root_cause)
    WHERE maintenance_id = p_maintenance;

    -- a recurring preventive job schedules its next occurrence
    SELECT * INTO p FROM service.preventive_maintenance WHERE maintenance_id = p_maintenance;
    IF FOUND AND p.repeat_every IS NOT NULL THEN
        PERFORM service.schedule_preventive(m.equipment_id, (p.planned_for + p.repeat_every)::date,
                                            m.technician_id, p.checklist, p.repeat_every);
    END IF;
END $$;

-- Calibration (related to the CALIBRATABLE subclass only) -------------------------------
CREATE TABLE service.calibration (
    calibration_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    equipment_id    integer NOT NULL REFERENCES inventory.calibratable_equipment ON DELETE RESTRICT,
    performed_on    date NOT NULL,
    next_due        date NOT NULL,
    result          service.calibration_result NOT NULL,
    certificate_no  varchar(24) NOT NULL UNIQUE,
    performed_by    integer REFERENCES org.technician (person_id) ON DELETE SET NULL,
    vendor          text,
    CONSTRAINT calibration_has_worker CHECK (performed_by IS NOT NULL OR vendor IS NOT NULL),
    CONSTRAINT calibration_due_after CHECK (next_due > performed_on),
    UNIQUE (equipment_id, performed_on)
);

-- next_due defaults to performed_on + the item's calibration interval
CREATE FUNCTION service.trg_calibration_due() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.next_due IS NULL THEN
        SELECT (NEW.performed_on + c.calibration_interval)::date INTO NEW.next_due
        FROM inventory.calibratable_equipment c WHERE c.equipment_id = NEW.equipment_id;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER calibration_due
    BEFORE INSERT ON service.calibration
    FOR EACH ROW EXECUTE FUNCTION service.trg_calibration_due();

-- Is the item usable up to p_until as far as calibration is concerned?
-- Items that are not calibratable are always fine.
CREATE FUNCTION service.calibration_valid(p_equipment integer, p_until date)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (SELECT 1 FROM inventory.calibratable_equipment WHERE equipment_id = p_equipment)
        OR coalesce((
            SELECT c.result <> 'fail' AND c.next_due >= p_until
            FROM service.calibration c
            WHERE c.equipment_id = p_equipment
            ORDER BY c.performed_on DESC
            LIMIT 1), false);
$$;

-- Plug the calibration rule into booking: the service module extends the
-- booking module's checks without the booking module knowing about it.
CREATE FUNCTION service.trg_reservation_calibrated() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('requested', 'approved')
       AND NOT service.calibration_valid(NEW.equipment_id, upper(NEW.period)::date) THEN
        PERFORM public.rule_violation('LB003',
            format('equipment %s has no valid calibration for the booked period', NEW.equipment_id));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER reservation_calibrated
    BEFORE INSERT OR UPDATE OF equipment_id, period ON booking.reservation
    FOR EACH ROW EXECUTE FUNCTION service.trg_reservation_calibrated();
