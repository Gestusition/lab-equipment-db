-- =====================================================================
-- 95 TESTS — positive, negative and concurrency tests
--
-- Every test runs its SQL inside a subtransaction that is always rolled
-- back, so tests are independent of each other and leave the seed data
-- untouched. The observed outcome is either 'accept' or the SQLSTATE of
-- the error raised, and is stored next to the expected outcome in
-- test.result.
--
--   23505 unique_violation       23503 foreign_key_violation
--   23514 check_violation        23P01 exclusion_violation
--   23001 restrict_violation     23502 not_null_violation
--   22000 data_exception (invalid range bounds)
--   42501 insufficient_privilege
--   LB001 membership  LB002 authorization/training  LB003 availability
--   LB004 workflow    LB005 history   LB006 hierarchy  LB007 budget
--   LB008 specialization / category
--
-- Deferred constraint triggers fire at COMMIT; tests that exercise them
-- end with SET CONSTRAINTS ALL IMMEDIATE so the check runs inside the
-- subtransaction.
-- =====================================================================

SET TIME ZONE 'Europe/Istanbul';
SET lab.now = '2026-12-01 09:00:00+03';

DROP SCHEMA IF EXISTS test CASCADE;
CREATE SCHEMA test;

CREATE TABLE test.result (
    test_no   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    module    text NOT NULL,
    name      text NOT NULL,
    expected  text NOT NULL,
    observed  text NOT NULL,
    passed    boolean NOT NULL,
    message   text
);

CREATE PROCEDURE test.expect(p_module text, p_name text, p_expected text, p_sql text)
LANGUAGE plpgsql AS $$
DECLARE
    v_observed text;
    v_message  text;
BEGIN
    BEGIN
        EXECUTE p_sql;
        -- success: undo the test's effects with a private error code
        RAISE EXCEPTION USING ERRCODE = 'TROLL', MESSAGE = 'rollback after success';
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = 'TROLL' THEN
            v_observed := 'accept';
        ELSE
            v_observed := SQLSTATE;
            v_message  := SQLERRM;
        END IF;
    END;
    INSERT INTO test.result (module, name, expected, observed, passed, message)
    VALUES (p_module, p_name, p_expected, v_observed, v_observed = p_expected, v_message);
END $$;

-- =====================================================================
-- ORG
-- =====================================================================
CALL test.expect('org', 'duplicate e-mail differing only in case', '23505', $$
    INSERT INTO org.person (first_name, last_name, email, department_id)
    VALUES ('Ayse', 'Demir', 'AYSE.DEMIR@uni.edu.tr', 2) $$);

CALL test.expect('org', 'person in a non-existent department', '23503', $$
    INSERT INTO org.person (first_name, last_name, email, department_id)
    VALUES ('No', 'Parent', 'no.parent@uni.edu.tr', 99) $$);

CALL test.expect('org', 'malformed e-mail address (domain)', '23514', $$
    INSERT INTO org.person (first_name, last_name, email, department_id)
    VALUES ('Bad', 'Mail', 'bad.mail.at.uni', 1) $$);

CALL test.expect('org', 'graduate student advising themself', '23514', $$
    UPDATE org.grad_student SET advisor_id = 5 WHERE person_id = 5 $$);

CALL test.expect('org', 'advisor who is not an academic', '23503', $$
    UPDATE org.grad_student SET advisor_id = 14 WHERE person_id = 7 $$);

CALL test.expect('org', 'technician managing a second laboratory (1:1)', '23505', $$
    UPDATE org.laboratory SET manager_id = 10 WHERE lab_id = 5 $$);

CALL test.expect('org', 'overlapping subclasses: academic who is also technician', 'accept', $$
    INSERT INTO org.technician (person_id, specialty) VALUES (3, 'FPGA prototyping') $$);

CALL test.expect('org', 'non-academic as principal investigator', 'LB001', $$
    INSERT INTO org.project_member VALUES (3, 8, 'PI', '2026-12-01', NULL) $$);

CALL test.expect('org', 'student role for someone who is not a student', 'LB001', $$
    INSERT INTO org.project_member VALUES (3, 14, 'student', '2026-12-01', NULL) $$);

CALL test.expect('org', 'activating a draft project without a PI', 'LB001', $$
    UPDATE org.research_project SET status = 'active' WHERE project_id = 5;
    SET CONSTRAINTS ALL IMMEDIATE $$);

CALL test.expect('org', 'activating a draft project with its PI in one transaction', 'accept', $$
    INSERT INTO org.project_member VALUES (5, 1, 'PI', '2027-01-01', NULL);
    UPDATE org.research_project SET status = 'active' WHERE project_id = 5;
    SET CONSTRAINTS ALL IMMEDIATE $$);

CALL test.expect('org', 'replacing the PI inside one transaction (deferred check)', 'accept', $$
    UPDATE org.project_member SET left_on = '2026-12-01' WHERE project_id = 3 AND person_id = 3;
    INSERT INTO org.project_member VALUES (3, 4, 'PI', '2026-12-01', NULL);
    SET CONSTRAINTS ALL IMMEDIATE $$);

CALL test.expect('org', 'removing the only PI of an active project', 'LB001', $$
    DELETE FROM org.project_member WHERE project_id = 4 AND person_id = 4;
    SET CONSTRAINTS ALL IMMEDIATE $$);

CALL test.expect('org', 'second current PI on one project', '23505', $$
    INSERT INTO org.project_member VALUES (3, 4, 'PI', '2026-12-01', NULL) $$);

CALL test.expect('org', 'membership ending before it starts', '23514', $$
    UPDATE org.project_member SET left_on = '2025-01-01' WHERE project_id = 1 AND person_id = 8 $$);

-- =====================================================================
-- INVENTORY
-- =====================================================================
CALL test.expect('inventory', 'duplicate asset tag', '23505', $$
    INSERT INTO inventory.equipment (asset_tag, name, manufacturer, model, purchase_date, lab_id, category_id, training_required)
    VALUES ('EQ-1001', 'Copy', 'X', 'Y', '2026-01-01', 1, 1, false) $$);

CALL test.expect('inventory', 'malformed asset tag', '23514', $$
    INSERT INTO inventory.equipment (asset_tag, name, manufacturer, model, purchase_date, lab_id, category_id, training_required)
    VALUES ('TAG-1', 'Bad tag', 'X', 'Y', '2026-01-01', 1, 1, false) $$);

CALL test.expect('inventory', 'missing specialization discriminator (total)', '23502', $$
    INSERT INTO inventory.equipment (asset_tag, name, manufacturer, model, purchase_date, lab_id, category_id, training_required)
    VALUES ('EQ-2001', 'Undecided', 'X', 'Y', '2026-01-01', 1, 1, NULL) $$);

CALL test.expect('inventory', 'category tree cycle', 'LB006', $$
    UPDATE inventory.equipment_category SET parent_category_id = 5 WHERE category_id = 1 $$);

CALL test.expect('inventory', 'instrument becomes part of its own module', 'LB006', $$
    UPDATE inventory.equipment SET parent_equipment_id = 4 WHERE equipment_id = 3 $$);

CALL test.expect('inventory', 'module moved away from its system (deferred)', 'LB006', $$
    UPDATE inventory.equipment SET lab_id = 1 WHERE equipment_id = 4;
    SET CONSTRAINTS ALL IMMEDIATE $$);

CALL test.expect('inventory', 'transfer moves system with modules and records history', 'accept', $$
    CALL inventory.transfer_equipment(3, 1, 10, 'test move');
    SET CONSTRAINTS ALL IMMEDIATE;
    DO $v$ BEGIN
        IF (SELECT lab_id FROM inventory.equipment WHERE equipment_id = 4) <> 1
           OR (SELECT count(*) FROM inventory.equipment_transfer
               WHERE equipment_id IN (3, 4) AND reason = 'test move') <> 2 THEN
            RAISE EXCEPTION 'subtree not moved or history missing';
        END IF;
    END $v$ $$);

CALL test.expect('inventory', 'transfer to an inactive laboratory', 'LB003', $$
    CALL inventory.transfer_equipment(7, 6, 11, 'into renovation room') $$);

CALL test.expect('inventory', 'radiation source into a BSL-1 laboratory', 'LB003', $$
    CALL inventory.transfer_equipment(11, 1, 10, 'space') $$);

CALL test.expect('inventory', 'hazard class above the lab biosafety level', 'LB003', $$
    INSERT INTO inventory.hazardous_equipment (equipment_id, hazard_class, min_biosafety)
    VALUES (7, 'biological', 3) $$);

CALL test.expect('inventory', 'overlapping subclasses: hazardous and calibratable', 'accept', $$
    INSERT INTO inventory.hazardous_equipment (equipment_id, hazard_class, min_biosafety) VALUES (5, 'high_voltage', 1);
    DO $v$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM inventory.calibratable_equipment WHERE equipment_id = 5) THEN
            RAISE EXCEPTION 'expected item 5 in both subclasses';
        END IF;
    END $v$ $$);

CALL test.expect('inventory', 'weak entity: duplicate partial key', '23505', $$
    INSERT INTO inventory.equipment_component (equipment_id, component_no, name, installed_on)
    VALUES (1, 1, 'Second ion source', '2026-12-01') $$);

CALL test.expect('inventory', 'weak entity: same partial key under another owner', 'accept', $$
    INSERT INTO inventory.equipment_component (equipment_id, component_no, name, installed_on)
    VALUES (8, 1, 'Probe set', '2026-12-01') $$);

CALL test.expect('inventory', 'deleting equipment that has bookings', '23001', $$
    DELETE FROM inventory.equipment WHERE equipment_id = 7 $$);

CALL test.expect('inventory', 'consuming more than the stock', '23514', $$
    INSERT INTO inventory.stock_movement (lab_id, consumable_id, movement_type, quantity, person_id)
    VALUES (1, 1, 'consume', -10, 5) $$);

CALL test.expect('inventory', 'receipt with a negative quantity', '23514', $$
    INSERT INTO inventory.stock_movement (lab_id, consumable_id, movement_type, quantity, person_id)
    VALUES (1, 1, 'receive', -1, 10) $$);

CALL test.expect('inventory', 'stock ledger updates the balance', 'accept', $$
    INSERT INTO inventory.stock_movement (lab_id, consumable_id, movement_type, quantity, person_id)
    VALUES (1, 1, 'consume', -3, 5);
    DO $v$ BEGIN
        IF (SELECT quantity FROM inventory.lab_stock WHERE lab_id = 1 AND consumable_id = 1) <> 0 THEN
            RAISE EXCEPTION 'balance not updated';
        END IF;
    END $v$ $$);

-- =====================================================================
-- TRAINING
-- =====================================================================
CALL test.expect('training', 'trainer who is neither academic nor technician', 'LB002', $$
    INSERT INTO training.training_session (course_id, trainer_id, lab_id, starts_at)
    VALUES (1, 8, 1, '2026-12-20 10:00+03') $$);

CALL test.expect('training', 'trainer attending own session', 'LB002', $$
    INSERT INTO training.session_attendance VALUES (1, 10, 90, 'passed') $$);

CALL test.expect('training', 'session over capacity', 'LB002', $$
    INSERT INTO training.session_attendance VALUES
        (7, 5, NULL, 'absent'), (7, 8, NULL, 'absent'), (7, 9, NULL, 'absent') $$);

CALL test.expect('training', 'authorization on unrestricted equipment (subclass participation)', 'LB008', $$
    INSERT INTO training.authorization (person_id, equipment_id, granted_by, valid_from, valid_until)
    VALUES (7, 2, 10, '2026-12-01', '2027-12-01') $$);

CALL test.expect('training', 'self-granted authorization', '23514', $$
    INSERT INTO training.authorization (person_id, equipment_id, granted_by, valid_from, valid_until)
    VALUES (10, 1, 10, '2026-12-01', '2027-12-01') $$);

CALL test.expect('training', 'assessor who is not staff', 'LB002', $$
    INSERT INTO training.authorization (person_id, equipment_id, granted_by, valid_from, valid_until)
    VALUES (7, 1, 8, '2026-12-01', '2027-12-01') $$);

CALL test.expect('training', 'overlapping active authorizations for one pair', '23P01', $$
    INSERT INTO training.authorization (person_id, equipment_id, granted_by, valid_from, valid_until)
    VALUES (5, 1, 10, '2026-12-01', '2027-03-01') $$);

CALL test.expect('training', 'authorization ending before it starts', '23514', $$
    INSERT INTO training.authorization (person_id, equipment_id, granted_by, valid_from, valid_until)
    VALUES (7, 1, 10, '2027-01-01', '2026-01-01') $$);

CALL test.expect('training', 'passing a course derives authorizations', 'accept', $$
    CALL training.complete_training(2, 7, 80);
    DO $v$ BEGIN
        IF (SELECT count(*) FROM training.authorization
            WHERE person_id = 7 AND equipment_id IN (3, 4) AND status = 'active') <> 2 THEN
            RAISE EXCEPTION 'authorizations not derived';
        END IF;
    END $v$ $$);

CALL test.expect('training', 'failing a course derives nothing', 'accept', $$
    CALL training.complete_training(1, 7, 50);
    DO $v$ BEGIN
        IF EXISTS (SELECT 1 FROM training.authorization WHERE person_id = 7 AND equipment_id = 1) THEN
            RAISE EXCEPTION 'authorization granted for a failed course';
        END IF;
    END $v$ $$);

-- =====================================================================
-- BOOKING
-- =====================================================================
CALL test.expect('booking', 'overlapping booking of the same item', '23P01', $$
    SELECT booking.request_reservation(8, 1, 1, '2026-12-03 10:00+03', '2026-12-03 11:00+03', 'clash') $$);

CALL test.expect('booking', 'back-to-back booking (half-open ranges)', 'accept', $$
    SELECT booking.request_reservation(8, 1, 1, '2026-12-03 12:00+03', '2026-12-03 13:00+03', 'adjacent') $$);

CALL test.expect('booking', 'same period on a different item', 'accept', $$
    SELECT booking.request_reservation(8, 2, 1, '2026-12-03 09:00+03', '2026-12-03 12:00+03', 'other item') $$);

CALL test.expect('booking', 'booker not a member of the project', 'LB001', $$
    SELECT booking.request_reservation(7, 2, 1, '2026-12-05 09:00+03', '2026-12-05 10:00+03', 'not member') $$);

CALL test.expect('booking', 'booking for a draft project', 'LB001', $$
    SELECT booking.request_reservation(1, 2, 5, '2026-12-05 09:00+03', '2026-12-05 10:00+03', 'draft') $$);

CALL test.expect('booking', 'booking beyond the end of membership', 'LB001', $$
    SELECT booking.request_reservation(9, 2, 1, '2027-02-10 09:00+03', '2027-02-10 10:00+03', 'after leaving') $$);

CALL test.expect('booking', 'training-required item without authorization', 'LB002', $$
    SELECT booking.request_reservation(9, 1, 1, '2026-12-05 09:00+03', '2026-12-05 10:00+03', 'untrained') $$);

CALL test.expect('booking', 'expired authorization', 'LB002', $$
    SELECT booking.request_reservation(1, 1, 1, '2026-12-05 09:00+03', '2026-12-05 11:00+03', 'expired auth') $$);

CALL test.expect('booking', 'hazardous item without safety course', 'LB002', $$
    SELECT booking.request_reservation(14, 4, 2, '2026-12-09 09:00+03', '2026-12-09 10:00+03', 'no laser safety') $$);

CALL test.expect('booking', 'retired equipment', 'LB003', $$
    SELECT booking.request_reservation(6, 12, 2, '2026-12-05 09:00+03', '2026-12-05 10:00+03', 'retired') $$);

CALL test.expect('booking', 'calibration already overdue', 'LB003', $$
    SELECT booking.request_reservation(5, 13, 1, '2026-12-05 09:00+03', '2026-12-05 10:00+03', 'overdue') $$);

CALL test.expect('booking', 'calibration expires before the booking ends', 'LB003', $$
    SELECT booking.request_reservation(5, 11, 1, '2027-01-05 09:00+03', '2027-01-05 10:00+03', 'gamma') $$);

CALL test.expect('booking', 'booking a period in the past', 'LB004', $$
    SELECT booking.request_reservation(5, 2, 1, '2026-11-30 09:00+03', '2026-11-30 10:00+03', 'past') $$);

CALL test.expect('booking', 'booking longer than 72 hours', '23514', $$
    SELECT booking.request_reservation(5, 2, 1, '2026-12-10 09:00+03', '2026-12-14 09:00+03', 'too long') $$);

CALL test.expect('booking', 'booking ending before it starts', '22000', $$
    SELECT booking.request_reservation(5, 2, 1, '2026-12-10 10:00+03', '2026-12-10 09:00+03', 'reversed') $$);

CALL test.expect('booking', 'hazardous item waits for manager approval', 'accept', $$
    DO $v$ DECLARE r integer; BEGIN
        r := booking.request_reservation(11, 6, 2, '2026-12-14 09:00+03', '2026-12-14 11:00+03', 'cabinet');
        IF (SELECT status FROM booking.reservation WHERE reservation_id = r) <> 'requested' THEN
            RAISE EXCEPTION 'hazardous booking was auto-approved';
        END IF;
    END $v$ $$);

CALL test.expect('booking', 'approval by someone other than the lab manager', 'LB004', $$
    CALL booking.decide_reservation(18, 10, true) $$);

CALL test.expect('booking', 'approval by the lab manager', 'accept', $$
    CALL booking.decide_reservation(18, 11, true, 'ok') $$);

CALL test.expect('booking', 'illegal status transition completed -> approved', 'LB004', $$
    UPDATE booking.reservation SET status = 'approved' WHERE reservation_id = 1 $$);

CALL test.expect('booking', 'no-show recorded before the slot ends', 'LB004', $$
    UPDATE booking.reservation SET status = 'no_show' WHERE reservation_id = 14 $$);

CALL test.expect('booking', 'usage log for a reservation still awaiting approval', 'LB004', $$
    INSERT INTO booking.usage_log (reservation_id, actual_start, actual_end)
    VALUES (18, '2026-12-07 09:00+03', '2026-12-07 10:00+03') $$);

CALL test.expect('booking', 'second usage log for one reservation', 'LB004', $$
    INSERT INTO booking.usage_log (reservation_id, actual_start, actual_end)
    VALUES (1, '2026-10-05 09:00+03', '2026-10-05 10:00+03') $$);

CALL test.expect('booking', 'usage outside the reserved slot', 'LB004', $$
    INSERT INTO booking.usage_log (reservation_id, actual_start, actual_end)
    VALUES (14, '2026-12-03 13:00+03', '2026-12-03 14:00+03') $$);

CALL test.expect('booking', 'usage ending before it starts', '23514', $$
    INSERT INTO booking.usage_log (reservation_id, actual_start, actual_end)
    VALUES (14, '2026-12-03 10:00+03', '2026-12-03 09:30+03') $$);

CALL test.expect('booking', 'usage log completes the reservation', 'accept', $$
    INSERT INTO booking.usage_log (reservation_id, actual_start, actual_end)
    VALUES (14, '2026-12-03 09:00+03', '2026-12-03 11:30+03');
    DO $v$ BEGIN
        IF (SELECT status FROM booking.reservation WHERE reservation_id = 14) <> 'completed' THEN
            RAISE EXCEPTION 'reservation not completed';
        END IF;
    END $v$ $$);

CALL test.expect('booking', 'cancellation promotes the waitlist', 'accept', $$
    CALL booking.cancel_reservation(14, 'plans changed');
    DO $v$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM booking.waitlist_entry w
                       JOIN booking.reservation r USING (reservation_id)
                       WHERE w.status = 'promoted' AND r.person_id = 8 AND r.status = 'approved') THEN
            RAISE EXCEPTION 'waitlist entry not promoted';
        END IF;
    END $v$ $$);

CALL test.expect('booking', 'membership ending cancels later bookings only', 'accept', $$
    UPDATE org.project_member SET left_on = '2027-01-10' WHERE project_id = 1 AND person_id = 9;
    DO $v$ BEGIN
        IF (SELECT status FROM booking.reservation WHERE reservation_id = 22) <> 'cancelled'
           OR (SELECT status FROM booking.reservation WHERE reservation_id = 21) <> 'approved' THEN
            RAISE EXCEPTION 'wrong bookings cancelled';
        END IF;
    END $v$ $$);

CALL test.expect('booking', 'revoking an authorization cancels future bookings', 'accept', $$
    UPDATE training.authorization SET status = 'revoked', status_reason = 'safety breach'
    WHERE person_id = 5 AND equipment_id = 1 AND status = 'active';
    DO $v$ BEGIN
        IF (SELECT status FROM booking.reservation WHERE reservation_id = 14) <> 'cancelled' THEN
            RAISE EXCEPTION 'booking survived revocation';
        END IF;
    END $v$ $$);

CALL test.expect('booking', 'introducing a training requirement revalidates bookings', 'accept', $$
    UPDATE inventory.equipment SET training_required = true WHERE equipment_id = 2;
    DO $v$ BEGIN
        IF (SELECT status FROM booking.reservation WHERE reservation_id = 21) <> 'cancelled' THEN
            RAISE EXCEPTION 'untrained booking survived';
        END IF;
    END $v$ $$);

CALL test.expect('booking', 'critical incident locks the item and cancels bookings', 'accept', $$
    INSERT INTO service.incident (equipment_id, reported_by, severity, description)
    VALUES (8, 7, 'critical', 'Smoke from the power supply');
    DO $v$ BEGIN
        IF (SELECT lifecycle_status FROM inventory.equipment WHERE equipment_id = 8) <> 'out_of_service'
           OR (SELECT status FROM booking.reservation WHERE reservation_id = 19) <> 'cancelled' THEN
            RAISE EXCEPTION 'lockout incomplete';
        END IF;
    END $v$ $$);

CALL test.expect('booking', 'session identity: booking for someone else', 'LB004', $$
    SET LOCAL lab.person_id = '7';
    SELECT booking.request_reservation(8, 2, 1, '2026-12-05 09:00+03', '2026-12-05 10:00+03', 'impersonation') $$);

CALL test.expect('booking', 'session identity: lab manager cancels in own lab', 'accept', $$
    SET LOCAL lab.person_id = '10';
    CALL booking.cancel_reservation(15, 'instrument needed for service') $$);

CALL test.expect('booking', 'session identity: manager of another lab cancels', 'LB004', $$
    SET LOCAL lab.person_id = '12';
    CALL booking.cancel_reservation(15, 'not my lab') $$);

-- =====================================================================
-- SERVICE
-- =====================================================================
CALL test.expect('service', 'maintenance without its subclass row (total, deferred)', 'LB008', $$
    INSERT INTO service.maintenance (maintenance_type, equipment_id, technician_id, description)
    VALUES ('preventive', 7, 11, 'orphan');
    SET CONSTRAINTS ALL IMMEDIATE $$);

CALL test.expect('service', 'preventive row for a corrective order (disjoint)', '23503', $$
    INSERT INTO service.preventive_maintenance (maintenance_id, planned_for, checklist)
    VALUES (1, '2026-12-20', 'wrong subclass') $$);

CALL test.expect('service', 'work order with neither technician nor vendor', '23514', $$
    INSERT INTO service.maintenance (maintenance_type, equipment_id, description)
    VALUES ('corrective', 7, 'nobody') $$);

CALL test.expect('service', 'completed maintenance is immutable', 'LB005', $$
    UPDATE service.maintenance SET cost = 0 WHERE maintenance_id = 1 $$);

CALL test.expect('service', 'repair order for an incident on other equipment', 'LB005', $$
    DO $v$ DECLARE m integer; BEGIN
        INSERT INTO service.maintenance (maintenance_type, equipment_id, technician_id, description)
        VALUES ('corrective', 7, 11, 'mismatch') RETURNING maintenance_id INTO m;
        INSERT INTO service.corrective_maintenance (maintenance_id, incident_id)
        VALUES (m, (SELECT incident_id FROM service.incident WHERE equipment_id = 13));
    END $v$ $$);

CALL test.expect('service', 'escalation puts the item under maintenance', 'accept', $$
    SELECT service.escalate_incident((SELECT incident_id FROM service.incident WHERE equipment_id = 13), 10);
    SET CONSTRAINTS ALL IMMEDIATE;
    DO $v$ BEGIN
        IF (SELECT lifecycle_status FROM inventory.equipment WHERE equipment_id = 13) <> 'under_maintenance' THEN
            RAISE EXCEPTION 'lifecycle not synchronised';
        END IF;
    END $v$ $$);

CALL test.expect('service', 'booking an item under maintenance', 'LB003', $$
    INSERT INTO service.incident (equipment_id, reported_by, severity, description)
    VALUES (7, 6, 'medium', 'Lid latch broken');
    SELECT service.escalate_incident(currval(pg_get_serial_sequence('service.incident', 'incident_id'))::integer, 11);
    SELECT booking.request_reservation(6, 7, 2, '2026-12-05 09:00+03', '2026-12-05 10:00+03', 'spin') $$);

CALL test.expect('service', 'completing the repair returns the item to service', 'accept', $$
    INSERT INTO service.incident (equipment_id, reported_by, severity, description)
    VALUES (7, 6, 'medium', 'Lid latch broken');
    DO $v$ DECLARE m integer; BEGIN
        m := service.escalate_incident(currval(pg_get_serial_sequence('service.incident', 'incident_id'))::integer, 11);
        CALL service.complete_maintenance(m, 35);
        IF (SELECT lifecycle_status FROM inventory.equipment WHERE equipment_id = 7) <> 'in_service' THEN
            RAISE EXCEPTION 'not back in service';
        END IF;
    END $v$;
    SET CONSTRAINTS ALL IMMEDIATE $$);

CALL test.expect('service', 'escalating an incident that is already resolved', 'LB004', $$
    SELECT service.escalate_incident(1, 11) $$);

CALL test.expect('service', 'calibration of non-calibratable equipment (subclass FK)', '23503', $$
    INSERT INTO service.calibration (equipment_id, performed_on, next_due, result, certificate_no, vendor)
    VALUES (7, '2026-12-01', '2027-12-01', 'pass', 'CAL-X-1', 'Lab') $$);

CALL test.expect('service', 'calibration due date derived from the interval', 'accept', $$
    INSERT INTO service.calibration (equipment_id, performed_on, next_due, result, certificate_no, vendor)
    VALUES (2, '2026-12-01', NULL, 'pass', 'CAL-X-2', 'Shimadzu Service TR');
    DO $v$ BEGIN
        IF (SELECT next_due FROM service.calibration WHERE certificate_no = 'CAL-X-2') <> date '2027-12-01' THEN
            RAISE EXCEPTION 'next_due not derived';
        END IF;
    END $v$ $$);

CALL test.expect('service', 'calibration certificates are immutable', 'LB005', $$
    UPDATE service.calibration SET result = 'fail' WHERE certificate_no = 'CAL-2026-0811' $$);

CALL test.expect('service', 'recalibration makes an overdue item bookable', 'accept', $$
    INSERT INTO service.calibration (equipment_id, performed_on, result, certificate_no, vendor)
    VALUES (13, '2026-12-01', 'pass', 'CAL-X-3', 'Bruker Service');
    SELECT booking.request_reservation(5, 13, 1, '2026-12-05 09:00+03', '2026-12-05 10:00+03', 'FTIR') $$);

-- =====================================================================
-- FINANCE
-- =====================================================================
CALL test.expect('finance', 'union type: department claiming a laboratory owner row', '23503', $$
    UPDATE org.department SET owner_id = (SELECT owner_id FROM org.laboratory WHERE lab_id = 2)
    WHERE department_id = 3 $$);

CALL test.expect('finance', 'union type: owner row attached to nothing (deferred)', 'LB008', $$
    INSERT INTO finance.owner (owner_kind) VALUES ('grant');
    SET CONSTRAINTS ALL IMMEDIATE $$);

CALL test.expect('finance', 'union type: grant becomes an owner', 'accept', $$
    UPDATE inventory.equipment SET owner_id = finance.ensure_owner('grant', 2) WHERE equipment_id = 7;
    SET CONSTRAINTS ALL IMMEDIATE $$);

CALL test.expect('finance', 'overlapping rate periods for one category', '23P01', $$
    INSERT INTO finance.rate_card (category_id, valid, hourly_rate) VALUES (1, '[2026-06-01,2026-12-31)', 25) $$);

CALL test.expect('finance', 'rate lookup walks up the category tree', 'accept', $$
    DO $v$ BEGIN
        IF finance.rate_for(8, '2026-12-01') <> 20      -- oscilloscope: root rate
           OR finance.rate_for(1, '2026-12-01') <> 120  -- LC-MS: own category
           OR finance.rate_for(1, '2027-02-01') <> 22   -- 2027: falls back to root
        THEN RAISE EXCEPTION 'wrong rate'; END IF;
    END $v$ $$);

CALL test.expect('finance', 'charging a grant of another project', 'LB007', $$
    INSERT INTO finance.charge (usage_id, grant_id, hours, hourly_rate)
    VALUES ((SELECT usage_id FROM booking.usage_log WHERE reservation_id = 1), 2, 1, 1) $$);

CALL test.expect('finance', 'charge larger than the remaining budget', 'LB007', $$
    INSERT INTO finance.charge (usage_id, grant_id, hours, hourly_rate)
    VALUES ((SELECT usage_id FROM booking.usage_log WHERE reservation_id = 12), 4, 100, 100) $$);

CALL test.expect('finance', 'invoiced charges are immutable', 'LB005', $$
    UPDATE finance.charge SET status = 'waived' WHERE status = 'invoiced' $$);

CALL test.expect('finance', 'grant ending before it starts', '23514', $$
    INSERT INTO finance.funding_grant (grant_no, agency_id, project_id, budget, start_date, end_date)
    VALUES ('BAD-1', 1, 1, 10, '2027-01-01', '2026-01-01') $$);

CALL test.expect('finance', 'billing run is idempotent', 'accept', $$
    DO $v$ BEGIN
        IF finance.generate_charges('2026-12-01 09:00+03') <> 0 THEN
            RAISE EXCEPTION 'usage charged twice';
        END IF;
    END $v$ $$);

-- =====================================================================
-- AUDIT & SECURITY
-- =====================================================================
CALL test.expect('audit', 'every reservation change is logged', 'accept', $$
    DO $v$ DECLARE n bigint; BEGIN
        SELECT count(*) INTO n FROM audit.change_log WHERE table_name = 'booking.reservation';
        UPDATE booking.reservation SET purpose = purpose || ' (edited)' WHERE reservation_id = 19;
        IF (SELECT count(*) FROM audit.change_log WHERE table_name = 'booking.reservation') <> n + 1 THEN
            RAISE EXCEPTION 'no audit row';
        END IF;
    END $v$ $$);

CALL test.expect('audit', 'audit log is append-only', 'LB005', $$
    DELETE FROM audit.change_log $$);

CALL test.expect('audit', 'deleting a completed reservation', 'LB005', $$
    DELETE FROM booking.reservation WHERE reservation_id = 1 $$);

CALL test.expect('audit', 'deleting a usage log', 'LB005', $$
    DELETE FROM booking.usage_log WHERE reservation_id = 1 $$);

CALL test.expect('audit', 'deleting a transfer record', 'LB005', $$
    DELETE FROM inventory.equipment_transfer $$);

CALL test.expect('security', 'researcher cannot write reservations directly', '42501', $$
    SET LOCAL ROLE lab_researcher;
    INSERT INTO booking.reservation (person_id, equipment_id, project_id, period, purpose)
    VALUES (7, 9, 3, '[2026-12-15 09:00+03,2026-12-15 10:00+03)', 'direct') $$);

CALL test.expect('security', 'researcher books through the API', 'accept', $$
    SET LOCAL ROLE lab_researcher;
    SET LOCAL lab.person_id = '7';
    SELECT booking.request_reservation(7, 9, 3, '2026-12-15 09:00+03', '2026-12-15 10:00+03', 'via API') $$);

CALL test.expect('security', 'researcher cannot read the audit log', '42501', $$
    SET LOCAL ROLE lab_researcher;
    SELECT count(*) FROM audit.change_log $$);

CALL test.expect('security', 'row-level security: researcher sees only own bookings', 'accept', $$
    SET LOCAL ROLE lab_researcher;
    SET LOCAL lab.person_id = '6';
    DO $v$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM booking.reservation)
           OR EXISTS (SELECT 1 FROM booking.reservation WHERE person_id <> 6) THEN
            RAISE EXCEPTION 'row-level security leak';
        END IF;
    END $v$ $$);

CALL test.expect('security', 'row-level security: manager sees own lab only', 'accept', $$
    SET LOCAL ROLE lab_manager;
    SET LOCAL lab.person_id = '11';
    DO $v$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM booking.reservation)
           OR EXISTS (SELECT 1 FROM booking.reservation r JOIN inventory.equipment e USING (equipment_id)
                      WHERE e.lab_id <> 2) THEN
            RAISE EXCEPTION 'row-level security leak';
        END IF;
    END $v$ $$);

CALL test.expect('security', 'auditor cannot modify data', '42501', $$
    SET LOCAL ROLE lab_auditor;
    UPDATE booking.reservation SET purpose = 'x' WHERE reservation_id = 19 $$);

-- =====================================================================
-- CONCURRENCY (two real sessions through dblink)
-- =====================================================================
-- Session A books a slot and keeps its transaction open; session B tries
-- the same slot, must WAIT on A's uncommitted row, and must fail once A
-- commits. The same pattern then races two trainees for the last seat
-- of a training session.
CREATE PROCEDURE test.concurrent(p_name text, p_setup text, p_a text, p_b text,
                                 p_expected text, p_cleanup text)
LANGUAGE plpgsql AS $$
DECLARE
    v_conn text := format('dbname=%s port=%s user=%s', current_database(),
                          current_setting('port'), current_user);
    v_waited boolean := false;
    v_err text;
    v_state text;
    v_pid_b integer;
BEGIN
    BEGIN
        PERFORM dblink_connect('ca', v_conn);
        PERFORM dblink_connect('cb', v_conn);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO test.result (module, name, expected, observed, passed, message)
        VALUES ('concurrency', p_name, p_expected, 'skipped', false, 'dblink could not connect: ' || SQLERRM);
        RETURN;
    END;

    IF p_setup IS NOT NULL THEN
        PERFORM dblink_exec('ca', p_setup);
    END IF;
    PERFORM dblink_exec('ca', 'BEGIN');
    PERFORM dblink_exec('cb', 'BEGIN');
    PERFORM dblink_exec('ca', 'SET LOCAL lab.now = ''2026-12-01 09:00+03''');
    PERFORM dblink_exec('cb', 'SET LOCAL lab.now = ''2026-12-01 09:00+03''');
    SELECT pid INTO v_pid_b FROM dblink('cb', 'SELECT pg_backend_pid()') AS t(pid integer);

    PERFORM * FROM dblink('ca', p_a) AS t(x text);           -- A holds its change
    PERFORM dblink_send_query('cb', p_b);                    -- B starts, should block

    FOR i IN 1..50 LOOP                                      -- up to 5 s
        IF EXISTS (SELECT 1 FROM pg_stat_activity
                   WHERE pid = v_pid_b AND wait_event_type = 'Lock') THEN
            v_waited := true;
            EXIT;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;

    PERFORM dblink_exec('ca', 'COMMIT');                     -- release B
    -- fail => false: a remote error is reported, not re-raised here
    PERFORM * FROM dblink_get_result('cb', false) AS t(x text);
    v_err := nullif(dblink_error_message('cb'), 'OK');
    PERFORM * FROM dblink_get_result('cb', false) AS t(x text);   -- end-of-results marker
    PERFORM dblink_exec('cb', 'ROLLBACK');

    v_state := CASE WHEN v_err IS NULL THEN 'accept'
                    WHEN v_err LIKE '%reservation_no_overlap%' THEN '23P01'
                    WHEN v_err LIKE '%is full%' THEN 'LB002'
                    ELSE 'error' END;

    INSERT INTO test.result (module, name, expected, observed, passed, message)
    VALUES ('concurrency', p_name, p_expected, v_state,
            v_state = p_expected AND v_waited,
            CASE WHEN v_waited THEN 'B waited for A''s lock; ' ELSE 'B did NOT wait; ' END
            || coalesce(v_err, ''));

    PERFORM dblink_exec('ca', p_cleanup);
    PERFORM dblink_disconnect('ca');
    PERFORM dblink_disconnect('cb');
END $$;

CALL test.concurrent(
    'two sessions booking the same slot at once',
    NULL,
    $q$SELECT booking.request_reservation(6, 7, 2, '2026-12-20 10:00+03', '2026-12-20 12:00+03', 'session A')::text$q$,
    $q$SELECT booking.request_reservation(11, 7, 2, '2026-12-20 11:00+03', '2026-12-20 13:00+03', 'session B')::text$q$,
    '23P01',
    $q$DELETE FROM booking.reservation WHERE equipment_id = 7 AND lower(period) >= '2026-12-20'$q$);

CALL test.concurrent(
    'two trainees taking the last seat of a session at once',
    $q$INSERT INTO training.session_attendance VALUES (7, 5, NULL, 'absent')$q$,
    $q$INSERT INTO training.session_attendance VALUES (7, 8, NULL, 'absent') RETURNING 'A'$q$,
    $q$INSERT INTO training.session_attendance VALUES (7, 9, NULL, 'absent') RETURNING 'B'$q$,
    'LB002',
    $q$DELETE FROM training.session_attendance WHERE session_id = 7$q$);

-- =====================================================================
-- SUMMARY
-- =====================================================================
\echo
\echo ===== Test results =====
SELECT test_no AS "#", module, name, expected, observed,
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
FROM test.result ORDER BY test_no;

SELECT module, count(*) AS tests, count(*) FILTER (WHERE passed) AS passed,
       count(*) FILTER (WHERE NOT passed) AS failed
FROM test.result GROUP BY ROLLUP (module)
ORDER BY module NULLS LAST;

RESET lab.now;
