-- =====================================================================
-- 04 BOOKING — reservations, approval workflow, waitlist, usage logs
--
-- EER constructs in this module
--   * RESERVATION is the associative entity of the ternary relationship
--     BOOKS(PERSON, EQUIPMENT, RESEARCH_PROJECT); it has its own key
--     because USAGE_LOG and WAITLIST refer to it.
--   * DECIDES: optional relationship to the approving PERSON.
--   * WAITLIST_ENTRY: a request that could not be booked yet.
--   * USAGE_LOG: 1:1 with RESERVATION (partial on reservation side,
--     total on log side), enforced by UNIQUE NOT NULL.
--
-- Rules enforced
--   * no two blocking reservations of one item overlap (exclusion)
--   * project active, booker a member for the whole period
--   * equipment in service and housed in an active lab
--   * training-required equipment: valid authorization for the period
--   * hazardous equipment: passed safety course, and manager approval
--   * legal status transitions only
--   * changes elsewhere (membership ends, authorization revoked,
--     training requirement introduced, equipment retired) re-validate
--     and cancel affected future bookings
-- =====================================================================

CREATE TYPE booking.reservation_status AS ENUM
    ('requested', 'approved', 'rejected', 'cancelled', 'completed', 'no_show');
CREATE TYPE booking.waitlist_status AS ENUM ('waiting', 'promoted', 'withdrawn', 'expired');
CREATE TYPE booking.usage_condition AS ENUM ('ok', 'minor_issue', 'fault');

CREATE TABLE booking.reservation (
    reservation_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id       integer NOT NULL REFERENCES org.person ON DELETE RESTRICT,
    equipment_id    integer NOT NULL REFERENCES inventory.equipment ON DELETE RESTRICT,
    project_id      integer NOT NULL REFERENCES org.research_project ON DELETE RESTRICT,
    period          tstzrange NOT NULL,
    purpose         text NOT NULL,
    status          booking.reservation_status NOT NULL DEFAULT 'requested',
    requested_at    timestamptz NOT NULL DEFAULT now(),
    decided_by      integer REFERENCES org.person ON DELETE RESTRICT,
    decided_at      timestamptz,
    status_note     text,
    CONSTRAINT period_bounded CHECK (
        NOT isempty(period) AND NOT lower_inf(period) AND NOT upper_inf(period)),
    CONSTRAINT period_length CHECK (
        upper(period) - lower(period) BETWEEN interval '15 minutes' AND interval '72 hours'),
    CONSTRAINT decision_recorded CHECK (
        status NOT IN ('approved', 'rejected')
        OR (decided_by IS NOT NULL AND decided_at IS NOT NULL)),
    -- the v1 core rule: blocking reservations of one item never overlap
    CONSTRAINT reservation_no_overlap EXCLUDE USING gist (
        equipment_id WITH =, period WITH &&)
        WHERE (status IN ('requested', 'approved', 'completed'))
);

-- Eligibility check -------------------------------------------------------------
-- Raises the first rule that a (person, equipment, project, period)
-- combination violates. Used by the trigger and by revalidation.
CREATE FUNCTION booking.assert_eligible(p_person integer, p_equipment integer,
                                        p_project integer, p_period tstzrange)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_from date := lower(p_period)::date;
    v_to   date := upper(p_period)::date;
    e      inventory.equipment%ROWTYPE;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM org.research_project
                   WHERE project_id = p_project AND status = 'active') THEN
        PERFORM public.rule_violation('LB001', format('project %s is not active', p_project));
    END IF;
    IF NOT org.is_member_during(p_person, p_project, v_from, v_to) THEN
        PERFORM public.rule_violation('LB001',
            format('person %s is not a member of project %s for the whole booking', p_person, p_project));
    END IF;

    SELECT * INTO e FROM inventory.equipment WHERE equipment_id = p_equipment;
    IF e.lifecycle_status <> 'in_service' THEN
        PERFORM public.rule_violation('LB003',
            format('equipment %s is %s', p_equipment, e.lifecycle_status));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM org.laboratory WHERE lab_id = e.lab_id AND status = 'active') THEN
        PERFORM public.rule_violation('LB003', format('the laboratory of equipment %s is not active', p_equipment));
    END IF;

    IF e.training_required AND NOT training.is_authorized(p_person, p_equipment, v_from, v_to) THEN
        PERFORM public.rule_violation('LB002',
            format('person %s has no valid authorization for equipment %s', p_person, p_equipment));
    END IF;

    IF EXISTS (SELECT 1 FROM inventory.hazardous_equipment WHERE equipment_id = p_equipment)
       AND NOT EXISTS (
            SELECT 1 FROM training.session_attendance a
            JOIN training.training_session s USING (session_id)
            JOIN training.training_course c USING (course_id)
            WHERE a.trainee_id = p_person AND a.outcome = 'passed' AND c.is_safety_course
              AND s.starts_at <= lower(p_period)
              AND s.starts_at + c.validity >= upper(p_period)) THEN
        PERFORM public.rule_violation('LB002',
            format('person %s has no valid safety training for hazardous equipment %s', p_person, p_equipment));
    END IF;
END $$;

CREATE FUNCTION booking.trg_reservation_eligible() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IN ('requested', 'approved') THEN
        PERFORM booking.assert_eligible(NEW.person_id, NEW.equipment_id, NEW.project_id, NEW.period);
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER reservation_eligible
    BEFORE INSERT OR UPDATE OF person_id, equipment_id, project_id, period
    ON booking.reservation
    FOR EACH ROW EXECUTE FUNCTION booking.trg_reservation_eligible();

-- Status workflow (state machine) -----------------------------------------------
--   requested -> approved | rejected | cancelled
--   approved  -> completed | no_show | cancelled
--   rejected, cancelled, completed, no_show are final
CREATE FUNCTION booking.trg_status_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;
    IF NOT ((OLD.status = 'requested' AND NEW.status IN ('approved', 'rejected', 'cancelled'))
         OR (OLD.status = 'approved'  AND NEW.status IN ('completed', 'no_show', 'cancelled'))) THEN
        PERFORM public.rule_violation('LB004',
            format('reservation %s cannot go from %s to %s', OLD.reservation_id, OLD.status, NEW.status));
    END IF;
    IF NEW.status = 'no_show' AND upper(OLD.period) > public.app_now() THEN
        PERFORM public.rule_violation('LB004', 'a reservation can be marked no-show only after it ends');
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER status_transition
    BEFORE UPDATE OF status ON booking.reservation
    FOR EACH ROW EXECUTE FUNCTION booking.trg_status_transition();

-- Booking API --------------------------------------------------------------------
-- Hazardous equipment needs the lab manager's approval; anything else is
-- approved immediately. Returns the new reservation id.
CREATE FUNCTION booking.request_reservation(p_person integer, p_equipment integer,
                                            p_project integer, p_from timestamptz,
                                            p_to timestamptz, p_purpose text)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_needs_approval boolean;
    v_id integer;
BEGIN
    PERFORM org.assert_acting_as(p_person,
        (SELECT lab_id FROM inventory.equipment WHERE equipment_id = p_equipment));
    IF p_from < public.app_now() THEN
        PERFORM public.rule_violation('LB004', 'cannot book a period that has already started');
    END IF;
    v_needs_approval := EXISTS (SELECT 1 FROM inventory.hazardous_equipment
                                WHERE equipment_id = p_equipment);
    INSERT INTO booking.reservation (person_id, equipment_id, project_id, period, purpose, status,
                                     decided_by, decided_at, status_note)
    VALUES (p_person, p_equipment, p_project, tstzrange(p_from, p_to, '[)'), p_purpose,
            CASE WHEN v_needs_approval THEN 'requested' ELSE 'approved' END::booking.reservation_status,
            CASE WHEN v_needs_approval THEN NULL ELSE p_person END,
            CASE WHEN v_needs_approval THEN NULL ELSE public.app_now() END,
            CASE WHEN v_needs_approval THEN NULL ELSE 'auto-approved' END)
    RETURNING reservation_id INTO v_id;
    RETURN v_id;
END $$;

-- Only the manager of the laboratory that houses the equipment decides.
CREATE PROCEDURE booking.decide_reservation(p_reservation integer, p_approver integer,
                                            p_approve boolean, p_note text DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_manager integer;
BEGIN
    SELECT l.manager_id INTO v_manager
    FROM booking.reservation r
    JOIN inventory.equipment e USING (equipment_id)
    JOIN org.laboratory l ON l.lab_id = e.lab_id
    WHERE r.reservation_id = p_reservation;

    PERFORM org.assert_acting_as(p_approver);
    IF v_manager IS DISTINCT FROM p_approver THEN
        PERFORM public.rule_violation('LB004',
            format('person %s is not the manager of the laboratory for reservation %s', p_approver, p_reservation));
    END IF;
    UPDATE booking.reservation
    SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END::booking.reservation_status,
        decided_by = p_approver, decided_at = public.app_now(), status_note = p_note
    WHERE reservation_id = p_reservation;
END $$;

CREATE PROCEDURE booking.cancel_reservation(p_reservation integer, p_reason text)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM org.assert_acting_as(r.person_id, e.lab_id)
    FROM booking.reservation r JOIN inventory.equipment e USING (equipment_id)
    WHERE r.reservation_id = p_reservation;
    UPDATE booking.reservation
    SET status = 'cancelled', status_note = p_reason
    WHERE reservation_id = p_reservation;
    IF NOT FOUND THEN
        PERFORM public.rule_violation('LB004', format('reservation %s does not exist', p_reservation));
    END IF;
END $$;

-- Waitlist -------------------------------------------------------------------------
CREATE TABLE booking.waitlist_entry (
    entry_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id        integer NOT NULL REFERENCES org.person ON DELETE CASCADE,
    equipment_id     integer NOT NULL REFERENCES inventory.equipment ON DELETE CASCADE,
    project_id       integer NOT NULL REFERENCES org.research_project ON DELETE CASCADE,
    desired_period   tstzrange NOT NULL CHECK (NOT isempty(desired_period)),
    purpose          text NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),
    status           booking.waitlist_status NOT NULL DEFAULT 'waiting',
    reservation_id   integer UNIQUE REFERENCES booking.reservation ON DELETE SET NULL,
    CONSTRAINT promoted_has_reservation CHECK ((status = 'promoted') = (reservation_id IS NOT NULL))
);

-- When a blocking reservation is released, promote waiting requests for
-- the same item in FIFO order. Each attempt runs in its own
-- subtransaction (BEGIN ... EXCEPTION), so a request that is no longer
-- eligible is simply skipped.
CREATE FUNCTION booking.promote_waitlist(p_equipment integer) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    w booking.waitlist_entry%ROWTYPE;
    v_res integer;
    n integer := 0;
BEGIN
    FOR w IN SELECT * FROM booking.waitlist_entry
             WHERE equipment_id = p_equipment AND status = 'waiting'
               AND lower(desired_period) > public.app_now()
             ORDER BY created_at, entry_id
             FOR UPDATE SKIP LOCKED
    LOOP
        BEGIN
            v_res := booking.request_reservation(w.person_id, w.equipment_id, w.project_id,
                                                 lower(w.desired_period), upper(w.desired_period),
                                                 w.purpose);
            UPDATE booking.waitlist_entry
            SET status = 'promoted', reservation_id = v_res
            WHERE entry_id = w.entry_id;
            n := n + 1;
        EXCEPTION
            WHEN exclusion_violation OR SQLSTATE 'LB001' OR SQLSTATE 'LB002'
                 OR SQLSTATE 'LB003' OR SQLSTATE 'LB004' THEN
                NULL;  -- still not bookable; leave it waiting
        END;
    END LOOP;
    RETURN n;
END $$;

CREATE FUNCTION booking.trg_release_slot() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM booking.promote_waitlist(NEW.equipment_id);
    RETURN NULL;
END $$;

CREATE TRIGGER release_slot
    AFTER UPDATE OF status ON booking.reservation
    FOR EACH ROW
    WHEN (OLD.status IN ('requested', 'approved') AND NEW.status IN ('cancelled', 'rejected'))
    EXECUTE FUNCTION booking.trg_release_slot();

-- Usage log ------------------------------------------------------------------------
CREATE TABLE booking.usage_log (
    usage_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reservation_id   integer NOT NULL UNIQUE REFERENCES booking.reservation ON DELETE RESTRICT,
    actual_start     timestamptz NOT NULL,
    actual_end       timestamptz NOT NULL,
    condition_after  booking.usage_condition NOT NULL DEFAULT 'ok',
    notes            text,
    -- derived attribute, stored because billing and reports read it often
    hours_used       numeric(8,2) GENERATED ALWAYS AS
                     (round(extract(epoch FROM actual_end - actual_start) / 3600.0, 2)) STORED,
    CONSTRAINT usage_times_valid CHECK (actual_end > actual_start)
);

-- A log may only be written for an approved reservation, inside its slot
-- (15 minutes early start / 30 minutes overrun tolerated). Writing the
-- log completes the reservation.
CREATE FUNCTION booking.trg_usage_rules() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    r booking.reservation%ROWTYPE;
BEGIN
    SELECT * INTO r FROM booking.reservation WHERE reservation_id = NEW.reservation_id FOR UPDATE;
    IF r.status <> 'approved' THEN
        PERFORM public.rule_violation('LB004',
            format('reservation %s is %s; usage can be logged only for approved bookings',
                   r.reservation_id, r.status));
    END IF;
    IF NEW.actual_start < lower(r.period) - interval '15 minutes'
       OR NEW.actual_end > upper(r.period) + interval '30 minutes' THEN
        PERFORM public.rule_violation('LB004',
            format('actual use %s - %s lies outside reservation %s', NEW.actual_start, NEW.actual_end, r.period));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER usage_rules
    BEFORE INSERT ON booking.usage_log
    FOR EACH ROW EXECUTE FUNCTION booking.trg_usage_rules();

CREATE FUNCTION booking.trg_usage_completes_reservation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE booking.reservation SET status = 'completed'
    WHERE reservation_id = NEW.reservation_id;
    RETURN NULL;
END $$;

CREATE TRIGGER usage_completes_reservation
    AFTER INSERT ON booking.usage_log
    FOR EACH ROW EXECUTE FUNCTION booking.trg_usage_completes_reservation();

-- Revalidation of future bookings ---------------------------------------------------
-- Re-runs the eligibility check for every future active reservation that
-- matches the filter; the ones that fail are cancelled with the reason.
CREATE FUNCTION booking.revalidate_future(p_equipment integer DEFAULT NULL,
                                          p_person integer DEFAULT NULL,
                                          p_project integer DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    r booking.reservation%ROWTYPE;
    n integer := 0;
BEGIN
    FOR r IN SELECT * FROM booking.reservation
             WHERE status IN ('requested', 'approved')
               AND lower(period) > public.app_now()
               AND (p_equipment IS NULL OR equipment_id = p_equipment)
               AND (p_person    IS NULL OR person_id    = p_person)
               AND (p_project   IS NULL OR project_id   = p_project)
             ORDER BY lower(period)
    LOOP
        BEGIN
            PERFORM booking.assert_eligible(r.person_id, r.equipment_id, r.project_id, r.period);
        EXCEPTION WHEN SQLSTATE 'LB001' OR SQLSTATE 'LB002' OR SQLSTATE 'LB003' THEN
            UPDATE booking.reservation
            SET status = 'cancelled', status_note = 'auto-cancelled: ' || SQLERRM
            WHERE reservation_id = r.reservation_id;
            n := n + 1;
        END;
    END LOOP;
    RETURN n;
END $$;

-- Hooks into the other modules ----------------------------------------------------------
CREATE FUNCTION booking.trg_revalidate_equipment() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM booking.revalidate_future(p_equipment => NEW.equipment_id);
    RETURN NULL;
END $$;

-- v1 remark: "changes to training requirements must revalidate affected
-- bookings"; the same applies when an item leaves service permanently.
CREATE TRIGGER revalidate_on_equipment_change
    AFTER UPDATE OF training_required, lifecycle_status ON inventory.equipment
    FOR EACH ROW
    WHEN ((NOT OLD.training_required AND NEW.training_required)
          OR NEW.lifecycle_status IN ('out_of_service', 'retired'))
    EXECUTE FUNCTION booking.trg_revalidate_equipment();

CREATE FUNCTION booking.trg_revalidate_member() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM booking.revalidate_future(p_person => NEW.person_id, p_project => NEW.project_id);
    RETURN NULL;
END $$;

CREATE TRIGGER revalidate_on_membership_end
    AFTER UPDATE OF left_on ON org.project_member
    FOR EACH ROW WHEN (NEW.left_on IS NOT NULL)
    EXECUTE FUNCTION booking.trg_revalidate_member();

CREATE FUNCTION booking.trg_revalidate_authorization() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM booking.revalidate_future(p_equipment => NEW.equipment_id, p_person => NEW.person_id);
    RETURN NULL;
END $$;

CREATE TRIGGER revalidate_on_authorization_change
    AFTER UPDATE OF status, valid_until ON training.authorization
    FOR EACH ROW EXECUTE FUNCTION booking.trg_revalidate_authorization();

CREATE FUNCTION booking.trg_revalidate_project() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM booking.revalidate_future(p_project => NEW.project_id);
    RETURN NULL;
END $$;

CREATE TRIGGER revalidate_on_project_status
    AFTER UPDATE OF status ON org.research_project
    FOR EACH ROW WHEN (NEW.status <> 'active')
    EXECUTE FUNCTION booking.trg_revalidate_project();
