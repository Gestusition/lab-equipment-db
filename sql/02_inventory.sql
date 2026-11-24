-- =====================================================================
-- 02 INVENTORY — categories, equipment, components, transfers, consumables
--
-- EER constructs in this module
--   * Recursive 1:N on EQUIPMENT_CATEGORY (category tree).
--   * Recursive 1:N on EQUIPMENT (an instrument system and its attached
--     modules, e.g. a confocal microscope and its laser unit).
--   * Specialization 1 (from v1): TOTAL, DISJOINT, predicate-defined on
--     training_required -> TRAINING_REQUIRED / UNRESTRICTED equipment.
--     Mapping: single relation + discriminator (option 8C) + two views.
--   * Specialization 2 (new): PARTIAL, OVERLAPPING, user-defined ->
--     HAZARDOUS_EQUIPMENT and CALIBRATABLE_EQUIPMENT, each with its own
--     attributes. Mapping: one relation per subclass (option 8A).
--     An item may be in both (a radioactive-source analyser), either or
--     neither.
--   * Weak entity EQUIPMENT_COMPONENT, identified by
--     (owner equipment_id, component_no) through relationship HAS_PART.
--   * Temporal history EQUIPMENT_TRANSFER (v1 "future work").
--   * CONSUMABLE, LAB_STOCK (M:N lab x consumable with quantity) and
--     STOCK_MOVEMENT ledger.
-- =====================================================================

CREATE TYPE inventory.lifecycle_status AS ENUM
    ('in_service', 'under_maintenance', 'out_of_service', 'retired');
CREATE TYPE inventory.hazard_class AS ENUM
    ('chemical', 'biological', 'radiation', 'laser', 'high_voltage', 'cryogenic');
CREATE TYPE inventory.movement_type AS ENUM
    ('receive', 'consume', 'adjust', 'dispose');

-- Category tree --------------------------------------------------------------
CREATE TABLE inventory.equipment_category (
    category_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                text NOT NULL UNIQUE,
    description         text,
    parent_category_id  integer REFERENCES inventory.equipment_category ON DELETE RESTRICT,
    CONSTRAINT category_not_own_parent CHECK (parent_category_id <> category_id)
);

-- Equipment (superclass of both specializations) ----------------------------
CREATE TABLE inventory.equipment (
    equipment_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    asset_tag            varchar(16) NOT NULL UNIQUE CHECK (asset_tag ~ '^EQ-[0-9]{4,}$'),
    name                 text NOT NULL,
    manufacturer         text NOT NULL,
    model                text NOT NULL,
    serial_no            text,
    purchase_date        date NOT NULL,
    purchase_price       public.money_amount,
    lab_id               integer NOT NULL REFERENCES org.laboratory ON DELETE RESTRICT,
    category_id          integer NOT NULL REFERENCES inventory.equipment_category ON DELETE RESTRICT,
    lifecycle_status     inventory.lifecycle_status NOT NULL DEFAULT 'in_service',
    -- discriminator of the total, disjoint specialization (NOT NULL = total)
    training_required    boolean NOT NULL,
    parent_equipment_id  integer REFERENCES inventory.equipment ON DELETE RESTRICT,
    UNIQUE (manufacturer, serial_no),
    CONSTRAINT equipment_not_own_parent CHECK (parent_equipment_id <> equipment_id)
);

-- Cycle prevention for both recursive relationships. A plain CHECK only
-- stops self-loops; longer cycles (A->B->A) need a recursive query.
CREATE FUNCTION inventory.trg_no_category_cycle() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.parent_category_id IS NOT NULL AND EXISTS (
        WITH RECURSIVE up(id) AS (
            SELECT NEW.parent_category_id
            UNION
            SELECT c.parent_category_id
            FROM inventory.equipment_category c JOIN up ON c.category_id = up.id
            WHERE c.parent_category_id IS NOT NULL)
        SELECT 1 FROM up WHERE id = NEW.category_id)
    THEN
        PERFORM public.rule_violation('LB006',
            format('category %s would become its own ancestor', NEW.category_id));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER no_category_cycle
    BEFORE INSERT OR UPDATE OF parent_category_id ON inventory.equipment_category
    FOR EACH ROW EXECUTE FUNCTION inventory.trg_no_category_cycle();

CREATE FUNCTION inventory.trg_no_equipment_cycle() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.parent_equipment_id IS NOT NULL AND EXISTS (
        WITH RECURSIVE up(id) AS (
            SELECT NEW.parent_equipment_id
            UNION
            SELECT e.parent_equipment_id
            FROM inventory.equipment e JOIN up ON e.equipment_id = up.id
            WHERE e.parent_equipment_id IS NOT NULL)
        SELECT 1 FROM up WHERE id = NEW.equipment_id)
    THEN
        PERFORM public.rule_violation('LB006',
            format('equipment %s would become part of itself', NEW.equipment_id));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER no_equipment_cycle
    BEFORE INSERT OR UPDATE OF parent_equipment_id ON inventory.equipment
    FOR EACH ROW EXECUTE FUNCTION inventory.trg_no_equipment_cycle();

-- An attached module must sit in the same laboratory as its system.
-- Checked at COMMIT (deferred) so a whole subtree can be moved by one
-- UPDATE regardless of the order in which rows are processed.
CREATE FUNCTION inventory.trg_same_lab_as_parent() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM inventory.equipment c
        JOIN inventory.equipment p ON p.equipment_id = c.parent_equipment_id
        WHERE (c.equipment_id = NEW.equipment_id OR p.equipment_id = NEW.equipment_id)
          AND c.lab_id <> p.lab_id)
    THEN
        PERFORM public.rule_violation('LB006',
            format('equipment %s and its parent/child system are in different laboratories',
                   NEW.equipment_id));
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER same_lab_as_parent
    AFTER INSERT OR UPDATE OF parent_equipment_id, lab_id ON inventory.equipment
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION inventory.trg_same_lab_as_parent();

-- Specialization 1: subtype views (option 8C) --------------------------------
CREATE VIEW inventory.training_required_equipment AS
    SELECT * FROM inventory.equipment WHERE training_required;

CREATE VIEW inventory.unrestricted_equipment AS
    SELECT * FROM inventory.equipment WHERE NOT training_required;

-- Specialization 2: overlapping subclasses (option 8A) -----------------------
CREATE TABLE inventory.hazardous_equipment (
    equipment_id   integer PRIMARY KEY REFERENCES inventory.equipment ON DELETE CASCADE,
    hazard_class   inventory.hazard_class NOT NULL,
    min_biosafety  smallint NOT NULL DEFAULT 1 CHECK (min_biosafety BETWEEN 1 AND 4),
    requires_ppe   boolean NOT NULL DEFAULT true,
    safety_notes   text
);

CREATE TABLE inventory.calibratable_equipment (
    equipment_id           integer PRIMARY KEY REFERENCES inventory.equipment ON DELETE CASCADE,
    calibration_interval   interval NOT NULL CHECK (calibration_interval >= interval '1 day'),
    tolerance              text NOT NULL
);

-- Hazardous equipment may only be housed in a lab with an adequate
-- biosafety level (checked on both sides of the relationship).
CREATE FUNCTION inventory.trg_hazard_lab_level() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_lab_level smallint;
BEGIN
    SELECT l.biosafety_level INTO v_lab_level
    FROM inventory.equipment e JOIN org.laboratory l USING (lab_id)
    WHERE e.equipment_id = NEW.equipment_id;
    IF v_lab_level < NEW.min_biosafety THEN
        PERFORM public.rule_violation('LB003',
            format('equipment %s needs biosafety level %s but its lab has %s',
                   NEW.equipment_id, NEW.min_biosafety, v_lab_level));
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER hazard_lab_level
    BEFORE INSERT OR UPDATE ON inventory.hazardous_equipment
    FOR EACH ROW EXECUTE FUNCTION inventory.trg_hazard_lab_level();

-- Weak entity: component identified by its owner and a partial key ---------
CREATE TABLE inventory.equipment_component (
    equipment_id   integer NOT NULL REFERENCES inventory.equipment ON DELETE CASCADE,
    component_no   smallint NOT NULL CHECK (component_no > 0),
    name           text NOT NULL,
    part_number    text,
    installed_on   date NOT NULL,
    removed_on     date,
    PRIMARY KEY (equipment_id, component_no),
    CONSTRAINT component_dates_valid CHECK (removed_on IS NULL OR removed_on >= installed_on)
);

-- Transfer history ----------------------------------------------------------
CREATE TABLE inventory.equipment_transfer (
    transfer_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    equipment_id    integer NOT NULL REFERENCES inventory.equipment ON DELETE RESTRICT,
    from_lab_id     integer NOT NULL REFERENCES org.laboratory,
    to_lab_id       integer NOT NULL REFERENCES org.laboratory,
    transferred_at  timestamptz NOT NULL DEFAULT now(),
    reason          text,
    approved_by     integer REFERENCES org.person,
    CONSTRAINT transfer_changes_lab CHECK (from_lab_id <> to_lab_id)
);

-- Any change of equipment.lab_id is recorded automatically, so the
-- history cannot be skipped by a direct UPDATE. The transfer procedure
-- passes reason/approver through transaction-local settings.
CREATE FUNCTION inventory.trg_record_transfer() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO inventory.equipment_transfer
        (equipment_id, from_lab_id, to_lab_id, reason, approved_by)
    VALUES (NEW.equipment_id, OLD.lab_id, NEW.lab_id,
            nullif(current_setting('lab.transfer_reason', true), ''),
            nullif(current_setting('lab.person_id', true), '')::integer);
    RETURN NULL;
END $$;

CREATE TRIGGER record_transfer
    AFTER UPDATE OF lab_id ON inventory.equipment
    FOR EACH ROW WHEN (OLD.lab_id IS DISTINCT FROM NEW.lab_id)
    EXECUTE FUNCTION inventory.trg_record_transfer();

-- Moves a system together with its attached modules in one transaction.
CREATE PROCEDURE inventory.transfer_equipment(p_equipment integer, p_to_lab integer,
                                              p_approved_by integer, p_reason text)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM org.laboratory WHERE lab_id = p_to_lab AND status = 'active') THEN
        PERFORM public.rule_violation('LB003', format('laboratory %s is not active', p_to_lab));
    END IF;
    IF EXISTS (SELECT 1 FROM inventory.hazardous_equipment h, org.laboratory l
               WHERE h.equipment_id = p_equipment AND l.lab_id = p_to_lab
                 AND l.biosafety_level < h.min_biosafety) THEN
        PERFORM public.rule_violation('LB003',
            format('laboratory %s does not meet the biosafety level of equipment %s', p_to_lab, p_equipment));
    END IF;
    PERFORM set_config('lab.transfer_reason', p_reason, true);
    PERFORM set_config('lab.person_id', p_approved_by::text, true);

    -- move the system and every attached module together; the deferred
    -- same-lab constraint verifies the result at commit
    WITH RECURSIVE subtree(id) AS (
        SELECT p_equipment
        UNION
        SELECT e.equipment_id FROM inventory.equipment e JOIN subtree s
          ON e.parent_equipment_id = s.id)
    UPDATE inventory.equipment SET lab_id = p_to_lab
    WHERE equipment_id IN (SELECT id FROM subtree);
END $$;

-- Consumables ------------------------------------------------------------------
CREATE TABLE inventory.consumable (
    consumable_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku            varchar(20) NOT NULL UNIQUE,
    name           text NOT NULL,
    unit           varchar(10) NOT NULL,
    hazard_class   inventory.hazard_class,
    reorder_level  numeric(10,2) NOT NULL DEFAULT 0 CHECK (reorder_level >= 0)
);

CREATE TABLE inventory.lab_stock (
    lab_id         integer NOT NULL REFERENCES org.laboratory ON DELETE RESTRICT,
    consumable_id  integer NOT NULL REFERENCES inventory.consumable ON DELETE RESTRICT,
    quantity       numeric(10,2) NOT NULL DEFAULT 0
                   CONSTRAINT stock_not_negative CHECK (quantity >= 0),
    PRIMARY KEY (lab_id, consumable_id)
);

CREATE TABLE inventory.stock_movement (
    movement_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lab_id         integer NOT NULL,
    consumable_id  integer NOT NULL,
    movement_type  inventory.movement_type NOT NULL,
    quantity       numeric(10,2) NOT NULL CHECK (quantity <> 0),
    moved_at       timestamptz NOT NULL DEFAULT now(),
    person_id      integer NOT NULL REFERENCES org.person,
    note           text,
    FOREIGN KEY (lab_id, consumable_id) REFERENCES inventory.lab_stock ON DELETE RESTRICT,
    -- sign must agree with the movement type
    CONSTRAINT movement_sign CHECK (
        (movement_type = 'receive' AND quantity > 0) OR
        (movement_type IN ('consume', 'dispose') AND quantity < 0) OR
        movement_type = 'adjust')
);

-- The ledger drives the balance; the CHECK on lab_stock rejects a movement
-- that would make stock negative, rolling back the movement as well.
CREATE FUNCTION inventory.trg_apply_movement() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE inventory.lab_stock
    SET quantity = quantity + NEW.quantity
    WHERE lab_id = NEW.lab_id AND consumable_id = NEW.consumable_id;
    RETURN NULL;
END $$;

CREATE TRIGGER apply_movement
    AFTER INSERT ON inventory.stock_movement
    FOR EACH ROW EXECUTE FUNCTION inventory.trg_apply_movement();
