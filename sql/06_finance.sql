-- =====================================================================
-- 06 FINANCE — equipment ownership, grants, rate cards, usage charges
-- (v1 listed "charging" as future work; it is now in scope.)
--
-- EER constructs in this module
--   * CATEGORY (UNION TYPE) EQUIPMENT_OWNER, a subset of
--     DEPARTMENT ∪ LABORATORY ∪ FUNDING_GRANT. Unlike a specialization,
--     its members come from *different* superclasses. The category is
--     PARTIAL: a department that owns nothing is not an owner.
--     Mapping (Elmasri 9.2): a surrogate key owner_id in a relation of
--     its own, added as a foreign key to each superclass relation; the
--     discriminator owner_kind travels inside the FK so one owner row can
--     never be claimed by two superclasses.
--   * OWNS: EQUIPMENT_OWNER 1:N EQUIPMENT.
--   * FUNDING_AGENCY 1:N FUNDING_GRANT N:1 RESEARCH_PROJECT.
--   * RATE_CARD: temporal rate per category; no overlapping validity.
--   * CHARGE: 1:1 with USAGE_LOG, N:1 with FUNDING_GRANT; amount is a
--     derived (generated) attribute.
-- =====================================================================

CREATE TYPE finance.owner_kind    AS ENUM ('department', 'laboratory', 'grant');
CREATE TYPE finance.charge_status AS ENUM ('pending', 'invoiced', 'waived');

CREATE TABLE finance.owner (
    owner_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_kind  finance.owner_kind NOT NULL,
    UNIQUE (owner_id, owner_kind)
);

-- Superclasses of the category receive the surrogate key ----------------------------
ALTER TABLE org.department
    ADD COLUMN owner_id   integer UNIQUE,
    ADD COLUMN owner_kind finance.owner_kind NOT NULL DEFAULT 'department'
        CHECK (owner_kind = 'department'),
    ADD FOREIGN KEY (owner_id, owner_kind) REFERENCES finance.owner (owner_id, owner_kind);

ALTER TABLE org.laboratory
    ADD COLUMN owner_id   integer UNIQUE,
    ADD COLUMN owner_kind finance.owner_kind NOT NULL DEFAULT 'laboratory'
        CHECK (owner_kind = 'laboratory'),
    ADD FOREIGN KEY (owner_id, owner_kind) REFERENCES finance.owner (owner_id, owner_kind);

CREATE TABLE finance.funding_agency (
    agency_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       text NOT NULL UNIQUE,
    country    char(2) NOT NULL CHECK (country ~ '^[A-Z]{2}$')
);

CREATE TABLE finance.funding_grant (
    grant_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    grant_no    varchar(24) NOT NULL UNIQUE,
    agency_id   integer NOT NULL REFERENCES finance.funding_agency ON DELETE RESTRICT,
    project_id  integer NOT NULL REFERENCES org.research_project ON DELETE RESTRICT,
    budget      public.money_amount NOT NULL,
    start_date  date NOT NULL,
    end_date    date NOT NULL,
    owner_id    integer UNIQUE,
    owner_kind  finance.owner_kind NOT NULL DEFAULT 'grant' CHECK (owner_kind = 'grant'),
    FOREIGN KEY (owner_id, owner_kind) REFERENCES finance.owner (owner_id, owner_kind),
    CONSTRAINT grant_dates_valid CHECK (end_date > start_date)
);

-- OWNS --------------------------------------------------------------------------------
ALTER TABLE inventory.equipment
    ADD COLUMN owner_id integer REFERENCES finance.owner ON DELETE RESTRICT;

-- Returns (creating on first use) the owner id of a department, lab or grant.
CREATE FUNCTION finance.ensure_owner(p_kind finance.owner_kind, p_id integer)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_owner integer;
BEGIN
    EXECUTE format('SELECT owner_id FROM %s WHERE %I = $1 FOR UPDATE',
                   CASE p_kind WHEN 'department' THEN 'org.department'
                               WHEN 'laboratory' THEN 'org.laboratory'
                               ELSE 'finance.funding_grant' END,
                   CASE p_kind WHEN 'department' THEN 'department_id'
                               WHEN 'laboratory' THEN 'lab_id'
                               ELSE 'grant_id' END)
    INTO v_owner USING p_id;
    IF v_owner IS NOT NULL THEN
        RETURN v_owner;
    END IF;

    INSERT INTO finance.owner (owner_kind) VALUES (p_kind) RETURNING owner_id INTO v_owner;
    EXECUTE format('UPDATE %s SET owner_id = $1 WHERE %I = $2',
                   CASE p_kind WHEN 'department' THEN 'org.department'
                               WHEN 'laboratory' THEN 'org.laboratory'
                               ELSE 'finance.funding_grant' END,
                   CASE p_kind WHEN 'department' THEN 'department_id'
                               WHEN 'laboratory' THEN 'lab_id'
                               ELSE 'grant_id' END)
    USING v_owner, p_id;
    IF NOT FOUND THEN
        PERFORM public.rule_violation('LB008', format('%s %s does not exist', p_kind, p_id));
    END IF;
    RETURN v_owner;
END $$;

-- Every owner row must belong to exactly one superclass entity (checked
-- at commit, since the owner row is created before it is attached).
CREATE FUNCTION finance.trg_owner_attached() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM finance.owner WHERE owner_id = NEW.owner_id)
       AND NOT EXISTS (SELECT 1 FROM org.department      WHERE owner_id = NEW.owner_id)
       AND NOT EXISTS (SELECT 1 FROM org.laboratory      WHERE owner_id = NEW.owner_id)
       AND NOT EXISTS (SELECT 1 FROM finance.funding_grant WHERE owner_id = NEW.owner_id) THEN
        PERFORM public.rule_violation('LB008',
            format('owner %s is not attached to any department, laboratory or grant', NEW.owner_id));
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER owner_attached
    AFTER INSERT ON finance.owner
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION finance.trg_owner_attached();

-- Rate card ---------------------------------------------------------------------------------
CREATE TABLE finance.rate_card (
    rate_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id  integer NOT NULL REFERENCES inventory.equipment_category ON DELETE RESTRICT,
    valid        daterange NOT NULL CHECK (NOT isempty(valid) AND NOT lower_inf(valid)),
    hourly_rate  public.money_amount NOT NULL,
    CONSTRAINT rate_no_overlap EXCLUDE USING gist (category_id WITH =, valid WITH &&)
);

-- Hourly rate of an item on a date: the rate of its own category, or of
-- the nearest ancestor category that has one (walks the category tree).
CREATE FUNCTION finance.rate_for(p_equipment integer, p_on date)
RETURNS numeric LANGUAGE sql STABLE AS $$
    WITH RECURSIVE up(category_id, depth) AS (
        SELECT category_id, 0 FROM inventory.equipment WHERE equipment_id = p_equipment
        UNION ALL
        SELECT c.parent_category_id, up.depth + 1
        FROM inventory.equipment_category c JOIN up ON c.category_id = up.category_id
        WHERE c.parent_category_id IS NOT NULL)
    SELECT r.hourly_rate
    FROM up JOIN finance.rate_card r ON r.category_id = up.category_id AND r.valid @> p_on
    ORDER BY up.depth
    LIMIT 1;
$$;

-- Charges ---------------------------------------------------------------------------------
CREATE TABLE finance.charge (
    charge_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usage_id     integer NOT NULL UNIQUE REFERENCES booking.usage_log ON DELETE RESTRICT,
    grant_id     integer NOT NULL REFERENCES finance.funding_grant ON DELETE RESTRICT,
    hours        numeric(8,2)  NOT NULL CHECK (hours > 0),
    hourly_rate  numeric(10,2) NOT NULL CHECK (hourly_rate >= 0),
    amount       numeric(12,2) GENERATED ALWAYS AS (round(hours * hourly_rate, 2)) STORED,
    status       finance.charge_status NOT NULL DEFAULT 'pending',
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- Remaining budget of a grant (derived attribute)
CREATE FUNCTION finance.grant_remaining(p_grant integer) RETURNS numeric
LANGUAGE sql STABLE AS $$
    SELECT g.budget - coalesce((SELECT sum(amount) FROM finance.charge
                                WHERE grant_id = g.grant_id AND status <> 'waived'), 0)
    FROM finance.funding_grant g WHERE g.grant_id = p_grant;
$$;

-- A charge must: go to a grant of the same project as the booking, fall
-- inside the grant period, and fit in the remaining budget. The grant row
-- is locked so two concurrent charges cannot both spend the last money.
CREATE FUNCTION finance.trg_charge_rules() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    g finance.funding_grant%ROWTYPE;
    v_project integer;
    v_used date;
    v_own numeric;
BEGIN
    SELECT * INTO g FROM finance.funding_grant WHERE grant_id = NEW.grant_id FOR UPDATE;
    SELECT r.project_id, u.actual_start::date INTO v_project, v_used
    FROM booking.usage_log u JOIN booking.reservation r USING (reservation_id)
    WHERE u.usage_id = NEW.usage_id;

    IF g.project_id <> v_project THEN
        PERFORM public.rule_violation('LB007',
            format('grant %s does not fund project %s', g.grant_no, v_project));
    END IF;
    IF v_used NOT BETWEEN g.start_date AND g.end_date THEN
        PERFORM public.rule_violation('LB007',
            format('usage on %s is outside grant %s period', v_used, g.grant_no));
    END IF;
    -- on UPDATE the row's own previous amount is already counted as spent
    v_own := 0;
    IF TG_OP = 'UPDATE' AND OLD.status <> 'waived' THEN
        v_own := OLD.amount;
    END IF;
    IF NEW.status <> 'waived'
       AND finance.grant_remaining(g.grant_id) + v_own < round(NEW.hours * NEW.hourly_rate, 2) THEN
        PERFORM public.rule_violation('LB007',
            format('grant %s has insufficient budget', g.grant_no));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER charge_rules
    BEFORE INSERT OR UPDATE ON finance.charge
    FOR EACH ROW EXECUTE FUNCTION finance.trg_charge_rules();

-- Billing run: charges every uncharged usage up to p_until to the
-- project's grant that ends first and still has budget. Usage that no
-- grant can cover is left uncharged and reported by the budget view.
CREATE FUNCTION finance.generate_charges(p_until timestamptz DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    u record;
    v_grant integer;
    v_rate numeric;
    n integer := 0;
BEGIN
    FOR u IN
        SELECT ul.usage_id, ul.hours_used, ul.actual_start, r.project_id, r.equipment_id
        FROM booking.usage_log ul
        JOIN booking.reservation r USING (reservation_id)
        WHERE ul.actual_end <= coalesce(p_until, public.app_now())
          AND NOT EXISTS (SELECT 1 FROM finance.charge c WHERE c.usage_id = ul.usage_id)
        ORDER BY ul.actual_start
    LOOP
        v_rate := finance.rate_for(u.equipment_id, u.actual_start::date);
        CONTINUE WHEN v_rate IS NULL OR v_rate = 0;

        SELECT g.grant_id INTO v_grant
        FROM finance.funding_grant g
        WHERE g.project_id = u.project_id
          AND u.actual_start::date BETWEEN g.start_date AND g.end_date
          AND finance.grant_remaining(g.grant_id) >= round(u.hours_used * v_rate, 2)
        ORDER BY g.end_date, g.grant_id
        LIMIT 1;
        CONTINUE WHEN v_grant IS NULL;

        INSERT INTO finance.charge (usage_id, grant_id, hours, hourly_rate)
        VALUES (u.usage_id, v_grant, u.hours_used, v_rate);
        n := n + 1;
    END LOOP;
    RETURN n;
END $$;
