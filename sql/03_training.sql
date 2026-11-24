-- =====================================================================
-- 03 TRAINING — courses, sessions, attendance and authorization
--
-- EER constructs in this module
--   * M:N QUALIFIES_FOR between TRAINING_COURSE and EQUIPMENT.
--   * TRAINING_SESSION (1:N from course), led by a trainer PERSON who
--     must be an ACADEMIC or TECHNICIAN.
--   * M:N ATTENDS between PERSON and TRAINING_SESSION with attributes
--     score and outcome.
--   * AUTHORIZATION as a TERNARY relationship among
--     trainee PERSON, assessor PERSON and TRAINING_REQUIRED_EQUIPMENT.
--     It participates with the *subclass*, not with EQUIPMENT: only
--     training-required equipment can be authorized.
--     Ternary is needed because "who certified whom on which instrument"
--     is not recoverable from the three binary projections.
--   * Authorization is no longer typed in by hand: passing a session
--     derives it (training.complete_training).
-- =====================================================================

CREATE TYPE training.attendance_outcome AS ENUM ('passed', 'failed', 'absent');
CREATE TYPE training.authorization_status AS ENUM ('active', 'suspended', 'revoked', 'expired');

CREATE TABLE training.training_course (
    course_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code             varchar(12) NOT NULL UNIQUE,
    title            text NOT NULL,
    validity         interval NOT NULL DEFAULT interval '12 months'
                     CHECK (validity >= interval '1 month'),
    passing_score    numeric(5,2) NOT NULL DEFAULT 70 CHECK (passing_score BETWEEN 0 AND 100),
    -- a safety course certifies for one hazard class; NULL = operation course
    safety_for       inventory.hazard_class
);

CREATE TABLE training.course_qualification (
    course_id     integer NOT NULL REFERENCES training.training_course ON DELETE CASCADE,
    equipment_id  integer NOT NULL REFERENCES inventory.equipment ON DELETE CASCADE,
    PRIMARY KEY (course_id, equipment_id)
);

CREATE TABLE training.training_session (
    session_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id    integer NOT NULL REFERENCES training.training_course ON DELETE RESTRICT,
    trainer_id   integer NOT NULL REFERENCES org.person ON DELETE RESTRICT,
    lab_id       integer NOT NULL REFERENCES org.laboratory ON DELETE RESTRICT,
    starts_at    timestamptz NOT NULL,
    capacity     smallint NOT NULL DEFAULT 8 CHECK (capacity BETWEEN 1 AND 50)
);

CREATE TABLE training.session_attendance (
    session_id  integer NOT NULL REFERENCES training.training_session ON DELETE CASCADE,
    trainee_id  integer NOT NULL REFERENCES org.person ON DELETE RESTRICT,
    score       numeric(5,2) CHECK (score BETWEEN 0 AND 100),
    outcome     training.attendance_outcome NOT NULL,
    PRIMARY KEY (session_id, trainee_id),
    CONSTRAINT absent_has_no_score CHECK (outcome <> 'absent' OR score IS NULL)
);

-- Trainer must be an academic or technician ---------------------------------
CREATE FUNCTION training.is_staff(p_person integer) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM org.academic   WHERE person_id = p_person)
        OR EXISTS (SELECT 1 FROM org.technician WHERE person_id = p_person);
$$;

CREATE FUNCTION training.trg_trainer_is_staff() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT training.is_staff(NEW.trainer_id) THEN
        PERFORM public.rule_violation('LB002',
            format('person %s is neither academic nor technician and cannot lead training', NEW.trainer_id));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trainer_is_staff
    BEFORE INSERT OR UPDATE OF trainer_id ON training.training_session
    FOR EACH ROW EXECUTE FUNCTION training.trg_trainer_is_staff();

-- Attendance: capacity, and a trainer cannot attend their own session -----
CREATE FUNCTION training.trg_attendance_rules() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    s training.training_session%ROWTYPE;
BEGIN
    -- lock the session row so two concurrent enrolments cannot both take
    -- the last seat
    SELECT * INTO s FROM training.training_session
    WHERE session_id = NEW.session_id FOR UPDATE;

    IF NEW.trainee_id = s.trainer_id THEN
        PERFORM public.rule_violation('LB002', 'a trainer cannot attend their own session');
    END IF;
    IF TG_OP = 'INSERT' AND
       (SELECT count(*) FROM training.session_attendance WHERE session_id = NEW.session_id) >= s.capacity THEN
        PERFORM public.rule_violation('LB002', format('session %s is full', NEW.session_id));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER attendance_rules
    BEFORE INSERT OR UPDATE ON training.session_attendance
    FOR EACH ROW EXECUTE FUNCTION training.trg_attendance_rules();

-- Ternary relationship AUTHORIZATION ------------------------------------------
CREATE TABLE training.authorization (
    authorization_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    person_id         integer NOT NULL REFERENCES org.person ON DELETE RESTRICT,           -- trainee
    equipment_id      integer NOT NULL REFERENCES inventory.equipment ON DELETE RESTRICT,  -- instrument
    granted_by        integer NOT NULL REFERENCES org.person ON DELETE RESTRICT,           -- assessor
    session_id        integer REFERENCES training.training_session ON DELETE SET NULL,
    valid_from        date NOT NULL,
    valid_until       date NOT NULL,
    status            training.authorization_status NOT NULL DEFAULT 'active',
    status_reason     text,
    CONSTRAINT authorization_period_valid CHECK (valid_until > valid_from),
    CONSTRAINT authorization_not_self_granted CHECK (granted_by <> person_id),
    -- no two overlapping *active* authorizations for the same pair
    CONSTRAINT authorization_no_overlap EXCLUDE USING gist (
        person_id WITH =, equipment_id WITH =,
        daterange(valid_from, valid_until, '[]') WITH &&)
        WHERE (status = 'active')
);

CREATE FUNCTION training.trg_authorization_rules() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- participation is with the subclass TRAINING_REQUIRED_EQUIPMENT
    IF NOT EXISTS (SELECT 1 FROM inventory.training_required_equipment
                   WHERE equipment_id = NEW.equipment_id) THEN
        PERFORM public.rule_violation('LB008',
            format('equipment %s does not require training; it cannot carry an authorization', NEW.equipment_id));
    END IF;
    IF NOT training.is_staff(NEW.granted_by) THEN
        PERFORM public.rule_violation('LB002',
            format('assessor %s is neither academic nor technician', NEW.granted_by));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER authorization_rules
    BEFORE INSERT OR UPDATE OF equipment_id, granted_by ON training.authorization
    FOR EACH ROW EXECUTE FUNCTION training.trg_authorization_rules();

-- Is the person authorized on the equipment for the whole interval?
CREATE FUNCTION training.is_authorized(p_person integer, p_equipment integer,
                                       p_from date, p_to date)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM training.authorization
        WHERE person_id = p_person AND equipment_id = p_equipment
          AND status = 'active'
          AND valid_from <= p_from AND valid_until >= p_to);
$$;

-- Records a trainee's result and, on a pass, derives authorizations for
-- every instrument the course qualifies for. An existing active
-- authorization that overlaps is extended instead of duplicated.
CREATE PROCEDURE training.complete_training(p_session integer, p_trainee integer,
                                            p_score numeric)
LANGUAGE plpgsql AS $$
DECLARE
    s  training.training_session%ROWTYPE;
    c  training.training_course%ROWTYPE;
    v_outcome training.attendance_outcome;
    v_from date;
    v_until date;
    v_eq integer;
BEGIN
    SELECT * INTO s FROM training.training_session WHERE session_id = p_session;
    IF NOT FOUND THEN
        PERFORM public.rule_violation('LB002', format('session %s does not exist', p_session));
    END IF;
    SELECT * INTO c FROM training.training_course WHERE course_id = s.course_id;

    v_outcome := CASE WHEN p_score IS NULL THEN 'absent'
                      WHEN p_score >= c.passing_score THEN 'passed'
                      ELSE 'failed' END;

    INSERT INTO training.session_attendance (session_id, trainee_id, score, outcome)
    VALUES (p_session, p_trainee, p_score, v_outcome)
    ON CONFLICT (session_id, trainee_id)
    DO UPDATE SET score = EXCLUDED.score, outcome = EXCLUDED.outcome;

    IF v_outcome <> 'passed' THEN
        RETURN;
    END IF;

    v_from  := s.starts_at::date;
    v_until := (s.starts_at + c.validity)::date;

    FOR v_eq IN SELECT equipment_id FROM training.course_qualification WHERE course_id = c.course_id
    LOOP
        UPDATE training.authorization
        SET valid_until = greatest(valid_until, v_until)
        WHERE person_id = p_trainee AND equipment_id = v_eq AND status = 'active'
          AND daterange(valid_from, valid_until, '[]') && daterange(v_from, v_until, '[]');
        IF NOT FOUND THEN
            INSERT INTO training.authorization
                (person_id, equipment_id, granted_by, session_id, valid_from, valid_until)
            VALUES (p_trainee, v_eq, s.trainer_id, p_session, v_from, v_until);
        END IF;
    END LOOP;
END $$;

-- Housekeeping job: mark authorizations whose period has passed.
CREATE FUNCTION training.expire_authorizations(p_today date DEFAULT current_date)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    UPDATE training.authorization
    SET status = 'expired', status_reason = 'validity period ended'
    WHERE status = 'active' AND valid_until < p_today;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;
