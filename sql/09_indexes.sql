-- =====================================================================
-- 09 INDEXES
-- Primary keys, UNIQUE constraints and exclusion constraints already
-- create indexes (e.g. the GiST index behind reservation_no_overlap also
-- serves "what is booked on item X during range R"). The indexes below
-- cover the remaining access paths; tests/96_explain.sql shows the plans.
-- =====================================================================

-- Foreign keys that are searched from the parent side ---------------------
-- (PostgreSQL does not index FK columns automatically.)
CREATE INDEX equipment_lab_idx        ON inventory.equipment (lab_id);
CREATE INDEX equipment_category_idx   ON inventory.equipment (category_id);
CREATE INDEX equipment_parent_idx     ON inventory.equipment (parent_equipment_id)
    WHERE parent_equipment_id IS NOT NULL;                       -- partial: most rows are NULL
CREATE INDEX member_person_idx        ON org.project_member (person_id);
CREATE INDEX grad_student_advisor_idx ON org.grad_student (advisor_id);
CREATE INDEX transfer_equipment_idx   ON inventory.equipment_transfer (equipment_id, transferred_at);
CREATE INDEX charge_grant_idx         ON finance.charge (grant_id);
CREATE INDEX grant_project_idx        ON finance.funding_grant (project_id);

-- "My bookings, newest first" -- composite index with expression ---------
CREATE INDEX reservation_person_start_idx
    ON booking.reservation (person_id, (lower(period)) DESC);

-- Approval queue: only a handful of rows are 'requested' at any time,
-- so a partial index stays tiny.
CREATE INDEX reservation_pending_idx
    ON booking.reservation (equipment_id, requested_at)
    WHERE status = 'requested';

-- Project usage reports
CREATE INDEX reservation_project_idx ON booking.reservation (project_id, status);

-- Authorization lookups made on every booking of training-required items
CREATE INDEX authorization_active_idx
    ON training.authorization (person_id, equipment_id, valid_until)
    WHERE status = 'active';

-- Open work orders per item (lifecycle sync and at-risk report)
CREATE INDEX maintenance_open_idx
    ON service.maintenance (equipment_id)
    WHERE status IN ('open', 'in_progress');

-- Latest calibration per item: the UNIQUE (equipment_id, performed_on)
-- B-tree is scanned backwards for ORDER BY performed_on DESC LIMIT 1, so
-- no extra index is needed.

CREATE INDEX incident_equipment_time_idx ON service.incident (equipment_id, reported_at);
CREATE INDEX stock_movement_lab_time_idx ON inventory.stock_movement (lab_id, consumable_id, moved_at);

-- Audit log is append-only and physically ordered by time: a BRIN index
-- is a few pages instead of a full B-tree. Declared on the partitioned
-- parent, it is created on every partition.
CREATE INDEX change_log_time_brin ON audit.change_log USING brin (changed_at);
CREATE INDEX change_log_table_idx ON audit.change_log (table_name, changed_at);

-- Waitlist promotion scans waiting entries per item in FIFO order
CREATE INDEX waitlist_waiting_idx
    ON booking.waitlist_entry (equipment_id, created_at)
    WHERE status = 'waiting';
