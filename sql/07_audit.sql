-- =====================================================================
-- 07 AUDIT & SECURITY — change log, history protection, roles, RLS
--
--   * audit.change_log is RANGE-PARTITIONED by month of change; old
--     partitions can be detached and archived without touching new ones.
--   * One generic trigger function logs INSERT/UPDATE/DELETE of the key
--     tables as JSONB before/after images.
--   * Historical records (usage, calibration, transfers, completed
--     maintenance, authorizations, invoiced charges, the log itself)
--     cannot be deleted or rewritten (v1: "historical records will be
--     protected from unsafe deletion").
--   * Four group roles with least-privilege grants. Researchers never
--     write tables directly; they call SECURITY DEFINER API functions
--     ("controlled database operations" in v1).
--   * Row-level security: a researcher sees only their own reservations,
--     a lab manager the reservations of the lab they manage.
-- =====================================================================

-- Partitioned change log ------------------------------------------------------------------
CREATE TABLE audit.change_log (
    log_id       bigint GENERATED ALWAYS AS IDENTITY,
    changed_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    table_name   text NOT NULL,
    operation    char(1) NOT NULL CHECK (operation IN ('I', 'U', 'D')),
    db_user      text NOT NULL DEFAULT current_user,
    app_person   integer,
    old_row      jsonb,
    new_row      jsonb,
    PRIMARY KEY (log_id, changed_at)
) PARTITION BY RANGE (changed_at);

-- One partition per month for the project period, plus a default
-- partition so that no change is ever lost.
DO $$
DECLARE
    m date;
BEGIN
    FOR m IN SELECT generate_series(date '2026-09-01', date '2027-08-01', interval '1 month')::date
    LOOP
        EXECUTE format('CREATE TABLE audit.change_log_%s PARTITION OF audit.change_log
                        FOR VALUES FROM (%L) TO (%L)',
                       to_char(m, 'YYYY_MM'), m, (m + interval '1 month')::date);
    END LOOP;
END $$;
CREATE TABLE audit.change_log_default PARTITION OF audit.change_log DEFAULT;

CREATE FUNCTION audit.trg_log_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
    INSERT INTO audit.change_log (table_name, operation, app_person, old_row, new_row)
    VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
            left(TG_OP, 1),
            nullif(current_setting('lab.person_id', true), '')::integer,
            CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
    RETURN NULL;
END $$;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'org.project_member', 'org.research_project', 'inventory.equipment',
        'training.authorization', 'booking.reservation', 'booking.usage_log',
        'service.maintenance', 'service.calibration', 'service.incident', 'finance.charge']
    LOOP
        EXECUTE format('CREATE TRIGGER zz_audit AFTER INSERT OR UPDATE OR DELETE ON %s
                        FOR EACH ROW EXECUTE FUNCTION audit.trg_log_change()', t);
    END LOOP;
END $$;

-- History protection ------------------------------------------------------------------------
CREATE FUNCTION audit.trg_protect_history() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_protected boolean;
BEGIN
    -- TG_ARGV[0] = 'always' : never delete/update
    --            = 'final'  : only rows in a final state are protected
    -- (written as nested CASE because PL/pgSQL does not short-circuit OR,
    --  and tables without a status column would fail on OLD.status)
    v_protected := CASE
        WHEN TG_ARGV[0] = 'always'         THEN true
        WHEN TG_TABLE_NAME = 'authorization' THEN TG_OP = 'DELETE'
        WHEN TG_TABLE_NAME = 'maintenance' THEN to_jsonb(OLD) ->> 'status' = 'completed'
        WHEN TG_TABLE_NAME = 'charge'      THEN to_jsonb(OLD) ->> 'status' = 'invoiced'
        WHEN TG_TABLE_NAME = 'reservation' THEN TG_OP = 'DELETE'
                                           AND to_jsonb(OLD) ->> 'status' IN ('completed', 'no_show')
        ELSE false END;
    IF v_protected THEN
        PERFORM public.rule_violation('LB005',
            format('%s on %s.%s would destroy history', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME));
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER protect_history BEFORE UPDATE OR DELETE ON audit.change_log
    FOR EACH ROW EXECUTE FUNCTION audit.trg_protect_history('always');
CREATE TRIGGER protect_history BEFORE UPDATE OR DELETE ON service.calibration
    FOR EACH ROW EXECUTE FUNCTION audit.trg_protect_history('always');
CREATE TRIGGER protect_history BEFORE UPDATE OR DELETE ON inventory.equipment_transfer
    FOR EACH ROW EXECUTE FUNCTION audit.trg_protect_history('always');
CREATE TRIGGER protect_history BEFORE DELETE ON booking.usage_log
    FOR EACH ROW EXECUTE FUNCTION audit.trg_protect_history('always');
CREATE TRIGGER protect_history BEFORE DELETE ON inventory.stock_movement
    FOR EACH ROW EXECUTE FUNCTION audit.trg_protect_history('always');
CREATE TRIGGER protect_history BEFORE UPDATE OR DELETE ON service.maintenance
    FOR EACH ROW EXECUTE FUNCTION audit.trg_protect_history('final');
CREATE TRIGGER protect_history BEFORE DELETE ON training.authorization
    FOR EACH ROW EXECUTE FUNCTION audit.trg_protect_history('final');
CREATE TRIGGER protect_history BEFORE UPDATE OR DELETE ON finance.charge
    FOR EACH ROW EXECUTE FUNCTION audit.trg_protect_history('final');
CREATE TRIGGER protect_history BEFORE DELETE ON booking.reservation
    FOR EACH ROW EXECUTE FUNCTION audit.trg_protect_history('final');

-- Retiring instead of deleting: equipment with any history is retired.
CREATE PROCEDURE inventory.retire_equipment(p_equipment integer, p_reason text)
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE inventory.equipment SET lifecycle_status = 'retired' WHERE equipment_id = p_equipment;
    IF NOT FOUND THEN
        PERFORM public.rule_violation('LB005', format('equipment %s does not exist', p_equipment));
    END IF;
    RAISE NOTICE 'equipment % retired: %', p_equipment, p_reason;
END $$;

-- Roles -------------------------------------------------------------------------------------
DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['lab_admin', 'lab_manager', 'lab_researcher', 'lab_auditor'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END $$;

-- start from nothing: functions are executable by PUBLIC by default
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA org, inventory, training, booking, service, finance, audit FROM PUBLIC;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA org, inventory, training, booking, service, finance, audit FROM PUBLIC;

-- trigger functions must stay callable by whoever fires the trigger
DO $$
DECLARE
    f regprocedure;
BEGIN
    FOR f IN SELECT p.oid::regprocedure FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname IN ('org','inventory','training','booking','service','finance','audit')
               AND p.prorettype = 'trigger'::regtype
    LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO PUBLIC', f);
    END LOOP;
END $$;

-- lab_admin: everything
GRANT USAGE ON SCHEMA org, inventory, training, booking, service, finance, audit, report TO lab_admin;
GRANT ALL ON ALL TABLES IN SCHEMA org, inventory, training, booking, service, finance TO lab_admin;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA org, inventory, training, booking, service, finance TO lab_admin;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA org, inventory, training, booking, service, finance TO lab_admin;
GRANT SELECT ON audit.change_log TO lab_admin;

-- lab_auditor: read-only everywhere, including the change log
GRANT USAGE ON SCHEMA org, inventory, training, booking, service, finance, audit, report TO lab_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA org, inventory, training, booking, service, finance, audit TO lab_auditor;

-- lab_researcher: read reference data and own bookings; act only via API
GRANT USAGE ON SCHEMA org, inventory, training, booking, report TO lab_researcher;
GRANT SELECT ON org.department, org.laboratory, org.research_project,
                inventory.equipment, inventory.equipment_category,
                inventory.training_required_equipment, inventory.unrestricted_equipment,
                training.training_course, training.training_session,
                booking.reservation, booking.usage_log
             TO lab_researcher;

-- lab_manager: researcher rights + decisions, service and stock
GRANT lab_researcher TO lab_manager;
GRANT USAGE ON SCHEMA service TO lab_manager;
GRANT SELECT ON ALL TABLES IN SCHEMA service, training TO lab_manager;
GRANT INSERT ON inventory.stock_movement TO lab_manager;
GRANT SELECT ON inventory.lab_stock, inventory.consumable TO lab_manager;

-- API functions run with the owner's rights (SECURITY DEFINER) and a
-- fixed search_path, so callers need EXECUTE only, not table privileges.
DO $$
DECLARE
    f regprocedure;
BEGIN
    FOR f IN SELECT unnest(ARRAY[
        'booking.request_reservation(integer,integer,integer,timestamptz,timestamptz,text)',
        'booking.cancel_reservation(integer,text)',
        'booking.decide_reservation(integer,integer,boolean,text)',
        'service.escalate_incident(integer,integer,text)',
        'service.schedule_preventive(integer,date,integer,text,interval)',
        'service.start_maintenance(integer)',
        'service.complete_maintenance(integer,numeric,text)',
        'training.complete_training(integer,integer,numeric)']::regprocedure[])
    LOOP
        EXECUTE format('ALTER ROUTINE %s SECURITY DEFINER SET search_path = pg_catalog, public', f);
    END LOOP;
END $$;

GRANT EXECUTE ON FUNCTION booking.request_reservation(integer,integer,integer,timestamptz,timestamptz,text),
                          training.is_authorized(integer,integer,date,date)
      TO lab_researcher;
GRANT EXECUTE ON PROCEDURE booking.cancel_reservation(integer,text) TO lab_researcher;
GRANT EXECUTE ON PROCEDURE booking.decide_reservation(integer,integer,boolean,text),
                           service.start_maintenance(integer),
                           service.complete_maintenance(integer,numeric,text),
                           training.complete_training(integer,integer,numeric)
      TO lab_manager;
GRANT EXECUTE ON FUNCTION service.escalate_incident(integer,integer,text),
                          service.schedule_preventive(integer,date,integer,text,interval)
      TO lab_manager;

-- Row-level security on reservations ------------------------------------------------------
ALTER TABLE booking.reservation ENABLE ROW LEVEL SECURITY;

CREATE POLICY researcher_own_rows ON booking.reservation
    FOR SELECT TO lab_researcher
    USING (person_id = nullif(current_setting('lab.person_id', true), '')::integer);

CREATE POLICY manager_lab_rows ON booking.reservation
    FOR SELECT TO lab_manager
    USING (EXISTS (
        SELECT 1 FROM inventory.equipment e JOIN org.laboratory l USING (lab_id)
        WHERE e.equipment_id = reservation.equipment_id
          AND l.manager_id = nullif(current_setting('lab.person_id', true), '')::integer));

ALTER TABLE booking.usage_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY usage_follows_reservation ON booking.usage_log
    FOR SELECT TO lab_researcher, lab_manager
    USING (EXISTS (SELECT 1 FROM booking.reservation r
                   WHERE r.reservation_id = usage_log.reservation_id));
