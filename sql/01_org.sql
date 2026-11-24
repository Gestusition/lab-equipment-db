-- =====================================================================
-- 01 ORG — organisation, people and research projects
--
-- EER constructs in this module
--   * PERSON with an OVERLAPPING, PARTIAL specialization into
--     ACADEMIC, GRAD_STUDENT and TECHNICIAN (a lecturer may also be a
--     PhD student; a visiting researcher may be none of them).
--     Mapping: one relation per subclass sharing the superclass key
--     (Elmasri option 8A), which supports overlap naturally.
--   * Composite attribute: name = (first_name, last_name), with the
--     derived full_name as a generated column.
--   * Multivalued attribute: phone numbers -> person_phone.
--   * Recursive relationship ADVISES (academic -> grad student), both
--     roles played by PERSON.
--   * 1:1 relationship MANAGES (technician manages at most one lab,
--     a lab has at most one manager).
--   * M:N relationship PROJECT_MEMBER with attributes.
-- =====================================================================

CREATE TYPE org.lab_status      AS ENUM ('active', 'renovation', 'closed');
CREATE TYPE org.academic_title  AS ENUM ('Prof.', 'Assoc. Prof.', 'Asst. Prof.', 'Dr.', 'Lecturer');
CREATE TYPE org.degree_program  AS ENUM ('MSc', 'PhD');
CREATE TYPE org.phone_kind      AS ENUM ('office', 'mobile', 'lab');
CREATE TYPE org.project_status  AS ENUM ('draft', 'active', 'suspended', 'completed', 'cancelled');
CREATE TYPE org.member_role     AS ENUM ('PI', 'co_PI', 'researcher', 'student', 'technician');

-- Department -----------------------------------------------------------
CREATE TABLE org.department (
    department_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           varchar(6)  NOT NULL UNIQUE CHECK (code ~ '^[A-Z]{2,6}$'),
    name           text        NOT NULL UNIQUE
);

-- Person (superclass) -----------------------------------------------------
CREATE TABLE org.person (
    person_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name     text NOT NULL CHECK (btrim(first_name) <> ''),
    last_name      text NOT NULL CHECK (btrim(last_name)  <> ''),
    full_name      text GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED,
    email          public.email_address NOT NULL,
    department_id  integer NOT NULL REFERENCES org.department ON DELETE RESTRICT,
    is_active      boolean NOT NULL DEFAULT true,
    registered_on  date    NOT NULL DEFAULT current_date
);
-- e-mail identifies a person regardless of letter case
CREATE UNIQUE INDEX person_email_ci_uq ON org.person (lower(email));

-- Multivalued attribute: a person may have several phone numbers
CREATE TABLE org.person_phone (
    person_id  integer NOT NULL REFERENCES org.person ON DELETE CASCADE,
    phone      varchar(20) NOT NULL CHECK (phone ~ '^\+?[0-9 ]{7,20}$'),
    kind       org.phone_kind NOT NULL DEFAULT 'office',
    PRIMARY KEY (person_id, phone)
);

-- Subclasses (overlapping) ------------------------------------------------
CREATE TABLE org.academic (
    person_id  integer PRIMARY KEY REFERENCES org.person ON DELETE CASCADE,
    title      org.academic_title NOT NULL,
    office     varchar(20)
);

CREATE TABLE org.grad_student (
    person_id    integer PRIMARY KEY REFERENCES org.person ON DELETE CASCADE,
    student_no   varchar(12) NOT NULL UNIQUE,
    program      org.degree_program NOT NULL,
    enrolled_on  date NOT NULL,
    -- recursive relationship ADVISES: both ends are persons
    advisor_id   integer NOT NULL REFERENCES org.academic (person_id) ON DELETE RESTRICT,
    CONSTRAINT grad_student_not_own_advisor CHECK (advisor_id <> person_id)
);

CREATE TABLE org.technician (
    person_id      integer PRIMARY KEY REFERENCES org.person ON DELETE CASCADE,
    specialty      text NOT NULL,
    cert_level     smallint NOT NULL DEFAULT 1 CHECK (cert_level BETWEEN 1 AND 3)
);

-- Laboratory -----------------------------------------------------------------
CREATE TABLE org.laboratory (
    lab_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    department_id    integer NOT NULL REFERENCES org.department ON DELETE RESTRICT,
    name             text    NOT NULL,
    building         varchar(10) NOT NULL,
    room_no          varchar(10) NOT NULL,
    biosafety_level  smallint NOT NULL DEFAULT 1 CHECK (biosafety_level BETWEEN 1 AND 4),
    status           org.lab_status NOT NULL DEFAULT 'active',
    -- 1:1 MANAGES: UNIQUE makes each technician manage at most one lab
    manager_id       integer UNIQUE REFERENCES org.technician (person_id) ON DELETE SET NULL,
    UNIQUE (department_id, name),
    UNIQUE (building, room_no)
);

-- Research project -----------------------------------------------------------
CREATE TABLE org.research_project (
    project_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code           varchar(12) NOT NULL UNIQUE,
    title          text NOT NULL,
    department_id  integer NOT NULL REFERENCES org.department ON DELETE RESTRICT,
    start_date     date NOT NULL,
    end_date       date,
    status         org.project_status NOT NULL DEFAULT 'draft',
    CONSTRAINT project_dates_valid CHECK (end_date IS NULL OR end_date >= start_date)
);

-- M:N PROJECT_MEMBER ---------------------------------------------------------
CREATE TABLE org.project_member (
    project_id   integer NOT NULL REFERENCES org.research_project ON DELETE CASCADE,
    person_id    integer NOT NULL REFERENCES org.person ON DELETE RESTRICT,
    member_role  org.member_role NOT NULL,
    joined_on    date NOT NULL,
    left_on      date,
    PRIMARY KEY (project_id, person_id),
    CONSTRAINT member_dates_valid CHECK (left_on IS NULL OR left_on >= joined_on)
);

-- At most one *current* PI per project (declarative half of the rule).
CREATE UNIQUE INDEX project_one_current_pi
    ON org.project_member (project_id)
    WHERE member_role = 'PI' AND left_on IS NULL;

-- Role/subclass consistency: a PI or co-PI must be an academic, a member
-- with role 'student' must be a grad student, role 'technician' a technician.
CREATE FUNCTION org.trg_member_role_matches_subclass() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.member_role IN ('PI', 'co_PI')
       AND NOT EXISTS (SELECT 1 FROM org.academic WHERE person_id = NEW.person_id) THEN
        PERFORM public.rule_violation('LB001',
            format('person %s is not an academic and cannot be %s', NEW.person_id, NEW.member_role));
    ELSIF NEW.member_role = 'student'
       AND NOT EXISTS (SELECT 1 FROM org.grad_student WHERE person_id = NEW.person_id) THEN
        PERFORM public.rule_violation('LB001',
            format('person %s is not a graduate student', NEW.person_id));
    ELSIF NEW.member_role = 'technician'
       AND NOT EXISTS (SELECT 1 FROM org.technician WHERE person_id = NEW.person_id) THEN
        PERFORM public.rule_violation('LB001',
            format('person %s is not a technician', NEW.person_id));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER member_role_matches_subclass
    BEFORE INSERT OR UPDATE OF member_role, person_id ON org.project_member
    FOR EACH ROW EXECUTE FUNCTION org.trg_member_role_matches_subclass();

-- "Each active project has exactly one current PI" (procedural half).
-- A DEFERRABLE constraint trigger checks the rule at COMMIT, so a PI can
-- be replaced inside one transaction (end old membership, add new one)
-- without the intermediate state being rejected.
CREATE FUNCTION org.assert_active_project_has_pi(p_project_id integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM org.research_project
               WHERE project_id = p_project_id AND status = 'active')
       AND NOT EXISTS (SELECT 1 FROM org.project_member
                       WHERE project_id = p_project_id
                         AND member_role = 'PI' AND left_on IS NULL) THEN
        PERFORM public.rule_violation('LB001',
            format('active project %s has no current principal investigator', p_project_id));
    END IF;
END $$;

CREATE FUNCTION org.trg_project_pi_check() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'research_project' THEN
        PERFORM org.assert_active_project_has_pi(NEW.project_id);
    ELSE
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
            PERFORM org.assert_active_project_has_pi(OLD.project_id);
        END IF;
        IF TG_OP IN ('INSERT', 'UPDATE') THEN
            PERFORM org.assert_active_project_has_pi(NEW.project_id);
        END IF;
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER project_requires_pi
    AFTER INSERT OR UPDATE OF status ON org.research_project
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION org.trg_project_pi_check();

CREATE CONSTRAINT TRIGGER member_change_keeps_pi
    AFTER INSERT OR UPDATE OR DELETE ON org.project_member
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION org.trg_project_pi_check();

-- Application-level identity. A session states who is acting with
--   SET lab.person_id = '<person_id>';
-- When it does, that person may act only for themselves, unless they
-- manage the laboratory concerned (p_lab). Sessions that do not set it
-- (administrative scripts, seed data) are not restricted.
CREATE FUNCTION org.assert_acting_as(p_person integer, p_lab integer DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_me integer := nullif(current_setting('lab.person_id', true), '')::integer;
BEGIN
    IF v_me IS NOT NULL AND v_me <> p_person
       AND NOT EXISTS (SELECT 1 FROM org.laboratory WHERE lab_id = p_lab AND manager_id = v_me) THEN
        PERFORM public.rule_violation('LB004',
            format('person %s cannot act on behalf of person %s', v_me, p_person));
    END IF;
END $$;

-- Membership check used by the booking module: was the person a member of
-- the project for the whole interval [p_from, p_to]?
CREATE FUNCTION org.is_member_during(p_person integer, p_project integer,
                                     p_from date, p_to date)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM org.project_member
        WHERE person_id = p_person AND project_id = p_project
          AND joined_on <= p_from
          AND (left_on IS NULL OR left_on >= p_to));
$$;
