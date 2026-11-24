-- =====================================================================
-- 90 SEED — reproducible sample data
--
-- The clock is pinned with lab.now so every time-dependent rule gives
-- the same result whenever the script runs. History (October-November
-- 2026) is written by moving the pinned clock forward step by step;
-- "today" for the tests is 1 December 2026, 09:00 Istanbul time.
-- Fixed ids (OVERRIDING SYSTEM VALUE) keep the tests readable; identity
-- sequences are advanced at the end.
-- =====================================================================

SET TIME ZONE 'Europe/Istanbul';
SET lab.now = '2026-12-01 09:00:00+03';

-- moves every identity sequence past the highest id already used
CREATE FUNCTION pg_temp.sync_identities() RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    c record;
BEGIN
    FOR c IN SELECT table_schema, table_name, column_name
             FROM information_schema.columns
             WHERE is_identity = 'YES'
               AND table_schema IN ('org','inventory','training','booking','service','finance')
    LOOP
        EXECUTE format('SELECT setval(pg_get_serial_sequence(%L, %L), coalesce(max(%I), 0) + 1, false) FROM %I.%I',
                       c.table_schema || '.' || c.table_name, c.column_name, c.column_name,
                       c.table_schema, c.table_name);
    END LOOP;
END $$;

BEGIN;

-- ORG --------------------------------------------------------------------------
INSERT INTO org.department (department_id, code, name) OVERRIDING SYSTEM VALUE VALUES
  (1, 'CENG', 'Computer Engineering'),
  (2, 'CHEM', 'Chemistry'),
  (3, 'BIO',  'Molecular Biology and Genetics'),
  (4, 'EEE',  'Electrical and Electronics Engineering');

INSERT INTO org.person (person_id, first_name, last_name, email, department_id, registered_on)
OVERRIDING SYSTEM VALUE VALUES
  ( 1, 'Ayşe',   'Demir',   'ayse.demir@uni.edu.tr',    2, '2020-09-01'),
  ( 2, 'Mehmet', 'Yılmaz',  'mehmet.yilmaz@uni.edu.tr', 3, '2019-09-01'),
  ( 3, 'Elif',   'Kaya',    'elif.kaya@uni.edu.tr',     1, '2022-02-01'),
  ( 4, 'Can',    'Öztürk',  'can.ozturk@uni.edu.tr',    4, '2021-09-01'),
  ( 5, 'Zeynep', 'Arslan',  'zeynep.arslan@uni.edu.tr', 2, '2023-09-01'),
  ( 6, 'Burak',  'Şahin',   'burak.sahin@uni.edu.tr',   3, '2024-09-01'),
  ( 7, 'Deniz',  'Koç',     'deniz.koc@uni.edu.tr',     1, '2025-09-01'),
  ( 8, 'Selin',  'Aydın',   'selin.aydin@uni.edu.tr',   2, '2025-09-01'),
  ( 9, 'Emre',   'Çelik',   'emre.celik@uni.edu.tr',    2, '2025-09-01'),
  (10, 'Hakan',  'Polat',   'hakan.polat@uni.edu.tr',   2, '2018-03-01'),
  (11, 'Gizem',  'Erdem',   'gizem.erdem@uni.edu.tr',   3, '2021-03-01'),
  (12, 'Murat',  'Kılıç',   'murat.kilic@uni.edu.tr',   4, '2017-06-01'),
  (13, 'Oğuz',   'Tan',     'oguz.tan@uni.edu.tr',      1, '2022-06-01'),
  (14, 'Laura',  'Fischer', 'laura.fischer@uni-bonn.de',3, '2026-09-01'),
  (15, 'Ali',    'Vural',   'ali.vural@uni.edu.tr',     4, '2024-09-01');

INSERT INTO org.person_phone (person_id, phone, kind) VALUES
  (1, '+90 212 555 0101', 'office'), (1, '+90 532 555 0101', 'mobile'),
  (10, '+90 212 555 0110', 'lab'),   (11, '+90 212 555 0211', 'lab'),
  (12, '+90 212 555 0412', 'lab'),   (14, '+49 228 555 0114', 'mobile');

-- overlapping specialization: 5 is academic AND grad student,
-- 11 is technician AND grad student, 14 is in no subclass
INSERT INTO org.academic (person_id, title, office) VALUES
  (1, 'Prof.', 'A-301'), (2, 'Assoc. Prof.', 'B-402'), (3, 'Asst. Prof.', 'C-210'),
  (4, 'Dr.', 'D-105'),   (5, 'Lecturer', 'A-118');

INSERT INTO org.grad_student (person_id, student_no, program, enrolled_on, advisor_id) VALUES
  ( 5, 'S2023001', 'PhD', '2023-09-01', 1),
  ( 6, 'S2024017', 'PhD', '2024-09-01', 2),
  ( 7, 'S2025042', 'MSc', '2025-09-01', 3),
  ( 8, 'S2025043', 'MSc', '2025-09-01', 1),
  ( 9, 'S2025044', 'MSc', '2025-09-01', 5),   -- advised by a PhD student who lectures
  (11, 'S2021090', 'PhD', '2021-09-01', 2),
  (15, 'S2024088', 'PhD', '2024-09-01', 4);

INSERT INTO org.technician (person_id, specialty, cert_level) VALUES
  (10, 'Mass spectrometry', 3), (11, 'Imaging and cell culture', 2),
  (12, 'High-voltage testing', 3), (13, 'Embedded electronics', 2);

INSERT INTO org.laboratory (lab_id, department_id, name, building, room_no, biosafety_level, status, manager_id)
OVERRIDING SYSTEM VALUE VALUES
  (1, 2, 'Analytical Chemistry Lab', 'A', '101', 1, 'active', 10),
  (2, 3, 'Cell Biology Lab',         'B', '210', 2, 'active', 11),
  (3, 1, 'Embedded Systems Lab',     'C', '305', 1, 'active', 13),
  (4, 4, 'High Voltage Lab',         'D', '010', 1, 'active', 12),
  (5, 2, 'Radiochemistry Lab',       'A', '120', 3, 'active', NULL),
  (6, 3, 'Old Microscopy Room',      'B', '015', 1, 'renovation', NULL);

INSERT INTO org.research_project (project_id, code, title, department_id, start_date, end_date, status)
OVERRIDING SYSTEM VALUE VALUES
  (1, 'PRJ-CHEM-01', 'Trace Pesticide Analysis in Drinking Water', 2, '2026-01-01', '2027-12-31', 'active'),
  (2, 'PRJ-BIO-01',  'Live-Cell Imaging of Neuronal Growth Cones', 3, '2026-01-01', '2027-06-30', 'active'),
  (3, 'PRJ-CENG-01', 'Low-Power Wireless Sensor Node Design',      1, '2026-02-01', '2027-08-31', 'active'),
  (4, 'PRJ-EEE-01',  'Polymer Insulator Breakdown Characterisation', 4, '2026-03-01', '2027-03-01', 'active'),
  (5, 'PRJ-CHEM-02', 'Radiolabelled Tracer Uptake Study',          2, '2027-01-01', NULL,         'draft'),
  (6, 'PRJ-BIO-00',  'Recombinant Protein Expression Screening',   3, '2025-01-01', '2026-06-30', 'completed');

INSERT INTO org.project_member (project_id, person_id, member_role, joined_on, left_on) VALUES
  (1,  1, 'PI',         '2026-01-01', NULL),
  (1,  5, 'researcher', '2026-01-15', NULL),
  (1,  8, 'student',    '2026-01-15', NULL),
  (1,  9, 'student',    '2026-01-15', '2027-01-31'),
  (1, 10, 'technician', '2026-01-01', NULL),
  (2,  2, 'PI',         '2026-01-01', NULL),
  (2,  6, 'student',    '2026-01-10', NULL),
  (2, 11, 'technician', '2026-01-10', NULL),
  (2, 14, 'researcher', '2026-09-01', '2027-02-28'),
  (3,  3, 'PI',         '2026-02-01', NULL),
  (3,  7, 'student',    '2026-02-01', NULL),
  (3, 13, 'technician', '2026-02-01', NULL),
  (4,  4, 'PI',         '2026-03-01', NULL),
  (4, 15, 'student',    '2026-03-01', NULL),
  (4, 12, 'technician', '2026-03-01', NULL),
  (6,  2, 'PI',         '2025-01-01', '2026-06-30'),
  (6,  6, 'student',    '2025-01-01', '2026-06-30');
-- project 5 is a draft with no members (allowed by the v1 rules)

-- INVENTORY ----------------------------------------------------------------------
INSERT INTO inventory.equipment_category (category_id, name, description, parent_category_id)
OVERRIDING SYSTEM VALUE VALUES
  ( 1, 'Instruments',         'All shared instruments', NULL),
  ( 2, 'Spectroscopy',        'Optical and radiation spectroscopy', 1),
  ( 3, 'Mass Spectrometry',   'MS and hyphenated MS systems', 2),
  ( 4, 'Microscopy',          'Light and electron microscopy', 1),
  ( 5, 'Confocal Microscopy', 'Laser scanning confocal systems', 4),
  ( 6, 'Sample Preparation',  'Preparation and containment', 1),
  ( 7, 'Centrifuges',         'Bench and ultra centrifuges', 6),
  ( 8, 'Electronics Test',    'Electrical test and measurement', 1),
  ( 9, 'Oscilloscopes',       'Digital storage oscilloscopes', 8),
  (10, 'Safety Cabinets',     'Biosafety and fume cabinets', 6);

INSERT INTO inventory.equipment (equipment_id, asset_tag, name, manufacturer, model, serial_no,
                                 purchase_date, purchase_price, lab_id, category_id,
                                 lifecycle_status, training_required, parent_equipment_id)
OVERRIDING SYSTEM VALUE VALUES
  ( 1, 'EQ-1001', 'LC-MS/MS System',            'Agilent',      '6470B',        'SG2104A001', '2021-04-12', 412000, 1, 3, 'in_service', true,  NULL),
  ( 2, 'EQ-1002', 'UV-Vis Spectrophotometer',   'Shimadzu',     'UV-1900i',     'A1192300',   '2022-01-20',  18500, 1, 2, 'in_service', false, NULL),
  ( 3, 'EQ-1003', 'Confocal Microscope',        'Zeiss',        'LSM 980',      '2618000412', '2023-06-05', 690000, 2, 5, 'in_service', true,  NULL),
  ( 4, 'EQ-1004', '488 nm Laser Module',        'Zeiss',        'LM-488',       'LM488-7781', '2023-06-05',  42000, 2, 5, 'in_service', true,  3),
  ( 5, 'EQ-1005', 'Ultracentrifuge',            'Beckman',      'Optima XPN-100','CX19D221',  '2020-11-30',  98000, 2, 7, 'in_service', true,  NULL),
  ( 6, 'EQ-1006', 'Class II Biosafety Cabinet', 'Thermo',       '1300 Series A2','300437712', '2019-08-14',  21000, 2,10, 'in_service', true,  NULL),
  ( 7, 'EQ-1007', 'Benchtop Microcentrifuge',   'Eppendorf',    '5425',         '5405KF0912', '2024-02-02',   3900, 2, 7, 'in_service', false, NULL),
  ( 8, 'EQ-1008', 'Digital Oscilloscope',       'Keysight',     'DSOX3054G',    'MY59100231', '2022-09-09',  16800, 3, 9, 'in_service', false, NULL),
  ( 9, 'EQ-1009', 'Logic Analyzer',             'Saleae',       'Logic Pro 16', 'SAL-77120',  '2023-03-15',   1500, 3, 8, 'in_service', false, NULL),
  (10, 'EQ-1010', 'Impulse Voltage Generator',  'HighVolt',     'IP 150/1500',  'HV-2019-044','2019-05-27', 245000, 4, 8, 'in_service', true,  NULL),
  (11, 'EQ-1011', 'Automatic Gamma Counter',    'PerkinElmer',  'Wizard2 2480', 'GC2480-1120','2024-10-01', 156000, 5, 2, 'in_service', true,  NULL),
  (12, 'EQ-1012', 'Fluorescence Microscope',    'Olympus',      'BX41',         'BX41-55120', '2009-03-10',  31000, 2, 4, 'retired',    false, NULL),
  (13, 'EQ-1013', 'FTIR Spectrometer',          'Bruker',       'Alpha II',     'BA2-201876', '2021-07-07',  39500, 1, 2, 'in_service', false, NULL),
  (14, 'EQ-1014', 'Triple-Quad Detector Module','Agilent',      'G6470-DET',    'SG2104D009', '2021-04-12',  65000, 1, 3, 'in_service', true,  1);

-- second (overlapping) specialization: 10 and 11 are in both subclasses
INSERT INTO inventory.hazardous_equipment (equipment_id, hazard_class, min_biosafety, requires_ppe, safety_notes) VALUES
  ( 4, 'laser',        1, true, 'Class 3B laser; interlock must stay closed'),
  ( 6, 'biological',   2, true, 'Work with BSL-2 agents only'),
  (10, 'high_voltage', 1, true, 'Two-person rule; earth stick before entry'),
  (11, 'radiation',    3, true, 'Sealed sources; dosimeter required');

INSERT INTO inventory.calibratable_equipment (equipment_id, calibration_interval, tolerance) VALUES
  ( 1, '180 days', 'mass accuracy < 2 ppm'),
  ( 2, '365 days', 'photometric ±0.002 Abs'),
  ( 5, '365 days', 'speed ±0.5 %'),
  ( 8, '365 days', 'DC gain ±1.5 %'),
  (10, '180 days', 'peak voltage ±3 %'),
  (11, '90 days',  'efficiency drift < 2 %'),
  (13, '365 days', 'wavenumber ±0.5 cm-1');

-- weak entity: components numbered within their instrument
INSERT INTO inventory.equipment_component (equipment_id, component_no, name, part_number, installed_on, removed_on) VALUES
  (1, 1, 'Jet Stream ion source',   'G1958-65138', '2021-04-12', NULL),
  (1, 2, 'Turbo-molecular pump',    'G7077-80001', '2021-04-12', '2025-11-02'),
  (1, 3, 'Turbo-molecular pump',    'G7077-80001', '2025-11-02', NULL),
  (3, 1, 'Plan-Apochromat 63x/1.40','420782-9900', '2023-06-05', NULL),
  (3, 2, 'GaAsP detector',          '000000-2101', '2023-06-05', NULL),
  (5, 1, 'Ti-70 fixed-angle rotor', '337922',      '2020-11-30', NULL);

INSERT INTO inventory.consumable (consumable_id, sku, name, unit, hazard_class, reorder_level)
OVERRIDING SYSTEM VALUE VALUES
  (1, 'CH-ACN-HPLC',  'Acetonitrile, HPLC grade', 'L',      'chemical',  4),
  (2, 'BIO-DMEM',     'DMEM culture medium',      'bottle', NULL,       10),
  (3, 'GEN-NITRILE-M','Nitrile gloves, size M',   'box',    NULL,        5),
  (4, 'CH-N2-LIQ',    'Liquid nitrogen',          'L',      'cryogenic',50);

INSERT INTO inventory.lab_stock (lab_id, consumable_id) VALUES
  (1, 1), (1, 3), (1, 4), (2, 2), (2, 3), (3, 3);

INSERT INTO inventory.stock_movement (lab_id, consumable_id, movement_type, quantity, moved_at, person_id, note) VALUES
  (1, 1, 'receive',  20, '2026-10-01 10:00+03', 10, 'PO 2026-311'),
  (1, 1, 'consume',  -9, '2026-10-20 15:00+03',  5, 'mobile phase'),
  (1, 1, 'consume',  -8, '2026-11-16 09:30+03',  8, 'mobile phase'),
  (1, 3, 'receive',  10, '2026-10-01 10:00+03', 10, NULL),
  (1, 4, 'receive', 200, '2026-11-02 08:00+03', 10, 'dewar fill'),
  (1, 4, 'consume', -40, '2026-11-20 08:00+03', 10, NULL),
  (2, 2, 'receive',  24, '2026-09-25 11:00+03', 11, NULL),
  (2, 2, 'consume', -16, '2026-11-15 11:00+03',  6, NULL),
  (2, 3, 'receive',  12, '2026-09-25 11:00+03', 11, NULL),
  (3, 3, 'receive',   4, '2026-09-25 11:00+03', 13, NULL);

-- FINANCE: owners (union type) ------------------------------------------------------
INSERT INTO finance.funding_agency (agency_id, name, country) OVERRIDING SYSTEM VALUE VALUES
  (1, 'TÜBİTAK', 'TR'), (2, 'Horizon Europe', 'BE');

INSERT INTO finance.funding_grant (grant_id, grant_no, agency_id, project_id, budget, start_date, end_date)
OVERRIDING SYSTEM VALUE VALUES
  (1, 'TUBITAK-1001-124Z301', 1, 1, 50000, '2026-01-01', '2027-12-31'),
  (2, 'HE-MSCA-2026-101088',  2, 2,  3000, '2026-03-01', '2027-02-28'),
  (3, 'TUBITAK-3501-125E044', 1, 3, 10000, '2026-02-01', '2027-08-31'),
  (4, 'TUBITAK-1002-126M210', 1, 4,   400, '2026-03-01', '2027-03-01');

UPDATE inventory.equipment SET owner_id = finance.ensure_owner('department', 2) WHERE equipment_id IN (1, 2, 13, 14);
UPDATE inventory.equipment SET owner_id = finance.ensure_owner('laboratory', 2) WHERE equipment_id IN (3, 4, 5, 6, 7, 12);
UPDATE inventory.equipment SET owner_id = finance.ensure_owner('department', 1) WHERE equipment_id IN (8, 9);
UPDATE inventory.equipment SET owner_id = finance.ensure_owner('laboratory', 4) WHERE equipment_id = 10;
UPDATE inventory.equipment SET owner_id = finance.ensure_owner('grant', 1)      WHERE equipment_id = 11;

INSERT INTO finance.rate_card (category_id, valid, hourly_rate) VALUES
  (1, '[2026-01-01,2027-01-01)', 20.00),   -- default for every instrument
  (1, '[2027-01-01,2028-01-01)', 22.00),
  (3, '[2026-01-01,2027-01-01)', 120.00),  -- mass spectrometry
  (5, '[2026-01-01,2027-01-01)', 80.00),   -- confocal
  (7, '[2026-01-01,2027-01-01)', 15.00);   -- centrifuges

COMMIT;

-- TRAINING (history) -------------------------------------------------------------------
BEGIN;
INSERT INTO training.training_course (course_id, code, title, validity, passing_score, is_safety_course)
OVERRIDING SYSTEM VALUE VALUES
  (1, 'TRN-LCMS',    'LC-MS/MS Operation',            '12 months', 70, false),
  (2, 'TRN-CONF',    'Confocal Microscopy Operation', '12 months', 70, false),
  (3, 'TRN-BSL2',    'Biosafety Level 2 Practice',    '12 months', 75, true),
  (4, 'TRN-HV',      'High-Voltage Safety',           '6 months',  80, true),
  (5, 'TRN-UCF',     'Ultracentrifuge Operation',     '24 months', 70, false),
  (6, 'TRN-LASER',   'Laser Safety',                  '12 months', 70, true),
  (7, 'TRN-RAD',     'Radiation Protection',          '12 months', 80, true);

INSERT INTO training.course_qualification (course_id, equipment_id) VALUES
  (1, 1), (1, 14), (2, 3), (2, 4), (3, 6), (4, 10), (5, 5), (7, 11);

INSERT INTO training.training_session (session_id, course_id, trainer_id, lab_id, starts_at, capacity)
OVERRIDING SYSTEM VALUE VALUES
  (1, 1, 10, 1, '2026-09-10 10:00+03', 6),
  (2, 2, 11, 2, '2026-09-15 10:00+03', 4),
  (3, 3,  2, 2, '2026-09-20 10:00+03', 8),
  (4, 4, 12, 4, '2026-10-01 10:00+03', 4),
  (5, 5, 11, 2, '2026-10-05 14:00+03', 3),
  (6, 6, 11, 2, '2026-09-16 10:00+03', 6),
  (7, 7, 10, 5, '2026-12-10 10:00+03', 2);   -- upcoming

CALL training.complete_training(1,  5, 85);
CALL training.complete_training(1,  8, 90);
CALL training.complete_training(1,  9, 60);   -- failed: no authorization
CALL training.complete_training(2,  6, 88);
CALL training.complete_training(2, 14, 75);
CALL training.complete_training(6,  6, 92);
CALL training.complete_training(6, 14, 55);   -- failed laser safety
CALL training.complete_training(3,  6, 80);
CALL training.complete_training(3, 11, 95);
CALL training.complete_training(3, 14, 78);
CALL training.complete_training(4, 15, 82);
CALL training.complete_training(4,  4, 90);
CALL training.complete_training(5,  6, 70);   -- exactly the pass mark

-- an older, manually granted authorization that has run out
INSERT INTO training.authorization (person_id, equipment_id, granted_by, valid_from, valid_until)
VALUES (1, 1, 10, '2025-12-01', '2026-11-30');
SELECT training.expire_authorizations('2026-12-01');
COMMIT;

-- SERVICE: calibration history --------------------------------------------------------
INSERT INTO service.calibration (equipment_id, performed_on, next_due, result, certificate_no, performed_by, vendor) VALUES
  ( 1, '2026-08-01', NULL,         'pass',     'CAL-2026-0811', 10,   NULL),
  ( 2, '2026-03-01', NULL,         'pass',     'CAL-2026-0230', NULL, 'Shimadzu Service TR'),
  ( 5, '2026-02-01', NULL,         'pass',     'CAL-2026-0102', NULL, 'Beckman Coulter TR'),
  ( 8, '2026-05-10', NULL,         'pass',     'CAL-2026-0455', NULL, 'Keysight Cal Lab'),
  (10, '2026-09-15', NULL,         'adjusted', 'CAL-2026-0907', 12,   'HighVolt Service'),
  (11, '2026-10-01', NULL,         'pass',     'CAL-2026-1001', NULL, 'TAEK Metrology'),
  (13, '2025-10-01', '2026-10-01', 'pass',     'CAL-2025-0918', NULL, 'Bruker Service');   -- now overdue

-- BOOKING + SERVICE history, replayed with a moving clock ------------------------------
-- Historical reservations are inserted directly as approved bookings
-- (request_reservation refuses past periods); all eligibility rules
-- still run on every row.
BEGIN;
SET LOCAL lab.now = '2026-09-30 09:00+03';
INSERT INTO booking.reservation (reservation_id, person_id, equipment_id, project_id, period, purpose,
                                 status, requested_at, decided_by, decided_at, status_note)
OVERRIDING SYSTEM VALUE VALUES
  ( 1,  5,  1, 1, '[2026-10-05 09:00+03,2026-10-05 13:00+03)', 'Method validation, 12 pesticides', 'approved', '2026-09-28 10:00+03',  5, '2026-09-28 10:00+03', 'auto-approved'),
  ( 2,  8,  1, 1, '[2026-10-12 14:00+03,2026-10-12 18:00+03)', 'Calibration curves, batch 1',      'approved', '2026-09-29 11:00+03',  8, '2026-09-29 11:00+03', 'auto-approved'),
  ( 3,  6,  3, 2, '[2026-10-08 10:00+03,2026-10-08 14:00+03)', 'Time-lapse imaging, DIV7',         'approved', '2026-09-29 12:00+03',  6, '2026-09-29 12:00+03', 'auto-approved'),
  ( 4,  6,  4, 2, '[2026-10-08 10:00+03,2026-10-08 14:00+03)', '488 nm excitation for GFP',        'approved', '2026-09-29 12:00+03', 11, '2026-09-29 15:00+03', 'approved by lab manager'),
  ( 5, 14,  3, 2, '[2026-10-20 09:00+03,2026-10-20 12:00+03)', 'Growth cone morphology',           'approved', '2026-09-30 08:00+03', 14, '2026-09-30 08:00+03', 'auto-approved'),
  ( 6,  7,  8, 3, '[2026-10-21 13:00+03,2026-10-21 17:00+03)', 'Sleep-current measurements',       'approved', '2026-09-30 08:30+03',  7, '2026-09-30 08:30+03', 'auto-approved'),
  ( 7, 15, 10, 4, '[2026-10-15 10:00+03,2026-10-15 12:00+03)', 'Lightning impulse, sample set A',  'approved', '2026-09-30 08:40+03', 12, '2026-09-30 09:00+03', 'approved by lab manager');

INSERT INTO booking.usage_log (reservation_id, actual_start, actual_end, condition_after, notes) VALUES
  (1, '2026-10-05 09:05+03', '2026-10-05 12:50+03', 'ok', NULL),
  (2, '2026-10-12 14:00+03', '2026-10-12 17:30+03', 'ok', NULL),
  (3, '2026-10-08 10:10+03', '2026-10-08 13:55+03', 'ok', NULL),
  (4, '2026-10-08 10:10+03', '2026-10-08 13:55+03', 'ok', NULL),
  (5, '2026-10-20 09:10+03', '2026-10-20 11:55+03', 'fault', 'Stage drifts in Z during long acquisitions'),
  (6, '2026-10-21 13:00+03', '2026-10-21 16:40+03', 'ok', NULL),
  (7, '2026-10-15 10:00+03', '2026-10-15 11:45+03', 'ok', NULL);
COMMIT;

-- the fault on usage 5 opened incident 1; escalate and repair it
DO $$ BEGIN PERFORM pg_temp.sync_identities(); END $$;
SET lab.now = '2026-10-21 09:00+03';
SELECT service.escalate_incident(i.incident_id, 11) AS m_confocal
FROM service.incident i JOIN booking.usage_log u USING (usage_id) WHERE u.reservation_id = 5 \gset
SET lab.now = '2026-10-23 16:00+03';
CALL service.complete_maintenance(:m_confocal, 450.00, 'Z-drive encoder cable replaced');

-- recurring preventive maintenance on the ultracentrifuge
SET lab.now = '2026-10-25 09:00+03';
SELECT service.schedule_preventive(5, '2026-11-01', 11, 'Rotor inspection; vacuum check; drive log review', '90 days') AS m_ucf \gset
SET lab.now = '2026-11-01 08:00+03';
CALL service.start_maintenance(:m_ucf);
SET lab.now = '2026-11-01 12:00+03';
CALL service.complete_maintenance(:m_ucf, 120.00);   -- schedules the next one for 2027-01-30

BEGIN;
SET LOCAL lab.now = '2026-11-02 09:00+03';
INSERT INTO booking.reservation (reservation_id, person_id, equipment_id, project_id, period, purpose,
                                 status, requested_at, decided_by, decided_at, status_note)
OVERRIDING SYSTEM VALUE VALUES
  ( 8,  5,  2, 1, '[2026-11-03 09:00+03,2026-11-03 11:00+03)', 'Absorbance screening',          'approved', '2026-11-02 09:00+03',  5, '2026-11-02 09:00+03', 'auto-approved'),
  ( 9,  6,  5, 2, '[2026-11-10 09:00+03,2026-11-10 15:00+03)', 'Synaptosome fractionation',     'approved', '2026-11-02 09:10+03',  6, '2026-11-02 09:10+03', 'auto-approved'),
  (10,  8,  1, 1, '[2026-11-16 09:00+03,2026-11-16 17:00+03)', 'Field samples, batch 2',        'approved', '2026-11-02 09:20+03',  8, '2026-11-02 09:20+03', 'auto-approved'),
  (11,  7,  9, 3, '[2026-11-18 10:00+03,2026-11-18 12:00+03)', 'SPI bus debugging',             'approved', '2026-11-02 09:30+03',  7, '2026-11-02 09:30+03', 'auto-approved'),
  (12, 15, 10, 4, '[2026-11-20 10:00+03,2026-11-20 14:00+03)', 'Lightning impulse, sample set B','approved', '2026-11-02 09:40+03', 12, '2026-11-02 10:00+03', 'approved by lab manager'),
  (13,  6,  7, 2, '[2026-11-25 09:00+03,2026-11-25 10:00+03)', 'Pellet spin-down',              'approved', '2026-11-02 09:50+03',  6, '2026-11-02 09:50+03', 'auto-approved');

INSERT INTO booking.usage_log (reservation_id, actual_start, actual_end, condition_after) VALUES
  ( 9, '2026-11-10 09:00+03', '2026-11-10 14:40+03', 'ok'),
  (10, '2026-11-16 09:00+03', '2026-11-16 16:45+03', 'ok'),
  (12, '2026-11-20 10:00+03', '2026-11-20 13:30+03', 'ok'),
  (13, '2026-11-25 09:00+03', '2026-11-25 09:40+03', 'ok');
COMMIT;

SET lab.now = '2026-11-17 08:00+03';
CALL booking.cancel_reservation(11, 'Board revision delayed');
SET lab.now = '2026-11-04 08:00+03';
UPDATE booking.reservation SET status = 'no_show' WHERE reservation_id = 8;

-- incidents: a high-severity one repaired by a vendor, a minor one still open
SET lab.now = '2026-11-21 10:00+03';
INSERT INTO service.incident (equipment_id, reported_by, usage_id, reported_at, severity, description)
SELECT 10, 15, u.usage_id, '2026-11-20 13:40+03', 'high', 'Flashover marks on the output stage'
FROM booking.usage_log u WHERE u.reservation_id = 12
RETURNING incident_id AS i_hv \gset
SELECT service.escalate_incident(:i_hv, 12, 'HighVolt Service') AS m_hv \gset
SET lab.now = '2026-11-24 17:00+03';
CALL service.complete_maintenance(:m_hv, 2300.00, 'Output-stage spark gap replaced');

INSERT INTO service.incident (equipment_id, reported_by, reported_at, severity, description)
VALUES (13, 5, '2026-11-20 15:00+03', 'low', 'Desiccant indicator turned pink');

-- equipment transfer (loan) -- history is written by the trigger
CALL inventory.transfer_equipment(9, 4, 13, 'Loan for impulse-test signal capture');

DO $$ BEGIN PERFORM pg_temp.sync_identities(); END $$;

-- TODAY: 1 December 2026, future bookings through the API ----------------------------------
SET lab.now = '2026-12-01 09:00+03';
SELECT booking.request_reservation( 5,  1, 1, '2026-12-03 09:00+03', '2026-12-03 12:00+03', 'Recovery study, spiked samples');
SELECT booking.request_reservation( 8,  1, 1, '2026-12-03 13:00+03', '2026-12-03 17:00+03', 'Field samples, batch 3');
SELECT booking.request_reservation( 6,  3, 2, '2026-12-04 10:00+03', '2026-12-04 13:00+03', 'Time-lapse imaging, DIV14');
SELECT booking.request_reservation( 6,  4, 2, '2026-12-04 10:00+03', '2026-12-04 13:00+03', '488 nm excitation for GFP');
SELECT booking.request_reservation(14,  6, 2, '2026-12-07 09:00+03', '2026-12-07 11:00+03', 'Primary neuron culture');
SELECT booking.request_reservation( 7,  8, 3, '2026-12-05 09:00+03', '2026-12-05 12:00+03', 'Radio burst current profile');
SELECT booking.request_reservation(15, 10, 4, '2026-12-10 10:00+03', '2026-12-10 12:00+03', 'Lightning impulse, sample set C');
SELECT booking.request_reservation( 9,  2, 1, '2026-12-08 09:00+03', '2026-12-08 10:00+03', 'Nitrate absorbance check');
SELECT booking.request_reservation( 9,  2, 1, '2027-01-25 09:00+03', '2027-01-25 10:00+03', 'Final measurements before leaving');

-- hazardous laser booking (#17) approved by the lab manager; the
-- biosafety cabinet (#18) and impulse generator (#20) stay pending
CALL booking.decide_reservation(17, 11, true, 'Interlock checked');

-- someone waits for a slot that overlaps reservation #14
INSERT INTO booking.waitlist_entry (person_id, equipment_id, project_id, desired_period, purpose, created_at)
VALUES (8, 1, 1, '[2026-12-03 10:00+03,2026-12-03 11:00+03)', 'Quick re-injection', '2026-12-01 08:30+03');

-- future preventive job on the LC-MS (scheduled, does not block today)
SELECT service.schedule_preventive(1, '2026-12-15', 10, 'Source cleaning; tune; vacuum check');

-- billing run and reporting snapshot
SELECT finance.generate_charges('2026-12-01 09:00+03');
UPDATE finance.charge SET status = 'invoiced' WHERE usage_id IN (SELECT usage_id FROM booking.usage_log WHERE actual_start < '2026-11-01');
REFRESH MATERIALIZED VIEW report.mv_monthly_utilization;

DO $$ BEGIN PERFORM pg_temp.sync_identities(); END $$;

RESET lab.now;
