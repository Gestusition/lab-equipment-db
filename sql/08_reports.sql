-- =====================================================================
-- 08 REPORTS — views over all modules
--
-- Query techniques shown: multi-way joins, recursive CTEs (category
-- path, instrument hierarchy, advising chains), window functions (RANK,
-- LAG, running totals, shares), GROUPING SETS / ROLLUP, FILTER clauses,
-- LATERAL joins, and a materialized view with a unique index so it can
-- be refreshed CONCURRENTLY.
-- =====================================================================

-- Category tree with full path and depth (recursive CTE) -----------------
CREATE VIEW report.v_category_tree AS
WITH RECURSIVE tree AS (
    SELECT category_id, name, parent_category_id, 0 AS depth,
           name::text AS path, ARRAY[category_id] AS id_path
    FROM inventory.equipment_category WHERE parent_category_id IS NULL
    UNION ALL
    SELECT c.category_id, c.name, c.parent_category_id, t.depth + 1,
           t.path || ' > ' || c.name, t.id_path || c.category_id
    FROM inventory.equipment_category c JOIN tree t ON c.parent_category_id = t.category_id)
SELECT category_id, name, parent_category_id, depth, path, id_path FROM tree;

-- Inventory overview: every specialization flag in one row ---------------
CREATE VIEW report.v_equipment_overview AS
SELECT e.equipment_id, e.asset_tag, e.name, e.manufacturer, e.model,
       l.name AS laboratory, d.code AS department, ct.path AS category_path,
       e.lifecycle_status,
       CASE WHEN e.training_required THEN 'training-required' ELSE 'unrestricted' END AS access_class,
       h.hazard_class,
       c.calibration_interval,
       o.owner_kind,
       coalesce(od.name, ol.name, og.grant_no) AS owner_name,
       p.asset_tag AS part_of
FROM inventory.equipment e
JOIN org.laboratory l       ON l.lab_id = e.lab_id
JOIN org.department d       ON d.department_id = l.department_id
JOIN report.v_category_tree ct ON ct.category_id = e.category_id
LEFT JOIN inventory.hazardous_equipment    h ON h.equipment_id = e.equipment_id
LEFT JOIN inventory.calibratable_equipment c ON c.equipment_id = e.equipment_id
LEFT JOIN finance.owner o          ON o.owner_id = e.owner_id
LEFT JOIN org.department od        ON od.owner_id = o.owner_id
LEFT JOIN org.laboratory ol        ON ol.owner_id = o.owner_id
LEFT JOIN finance.funding_grant og ON og.owner_id = o.owner_id
LEFT JOIN inventory.equipment p    ON p.equipment_id = e.parent_equipment_id;

-- Instrument systems and their attached modules (recursive) ---------------
CREATE VIEW report.v_equipment_hierarchy AS
WITH RECURSIVE h AS (
    SELECT equipment_id AS root_id, equipment_id, asset_tag, name, 0 AS level
    FROM inventory.equipment WHERE parent_equipment_id IS NULL
    UNION ALL
    SELECT h.root_id, e.equipment_id, e.asset_tag, e.name, h.level + 1
    FROM inventory.equipment e JOIN h ON e.parent_equipment_id = h.equipment_id)
SELECT r.asset_tag AS system_tag, h.level, repeat('  ', h.level) || h.name AS item, h.asset_tag
FROM h JOIN inventory.equipment r ON r.equipment_id = h.root_id
WHERE EXISTS (SELECT 1 FROM inventory.equipment x WHERE x.parent_equipment_id = h.root_id);

-- Advising chains: a PhD student who is also a lecturer may advise
-- others, so the tree can be deeper than one level (overlap in action).
CREATE VIEW report.v_advising_tree AS
WITH RECURSIVE chain AS (
    SELECT a.person_id AS root_advisor, a.person_id, 0 AS generation
    FROM org.academic a
    WHERE NOT EXISTS (SELECT 1 FROM org.grad_student g WHERE g.person_id = a.person_id)
    UNION ALL
    SELECT c.root_advisor, g.person_id, c.generation + 1
    FROM org.grad_student g JOIN chain c ON g.advisor_id = c.person_id)
SELECT ra.full_name AS root_advisor, c.generation, p.full_name AS person,
       g.program, (a.person_id IS NOT NULL) AS also_academic
FROM chain c
JOIN org.person p  ON p.person_id = c.person_id
JOIN org.person ra ON ra.person_id = c.root_advisor
LEFT JOIN org.grad_student g ON g.person_id = c.person_id
LEFT JOIN org.academic a     ON a.person_id = c.person_id AND c.generation > 0;

-- Derived availability right now (v1: "availability is derived") ----------
CREATE VIEW report.v_equipment_availability AS
SELECT e.equipment_id, e.asset_tag, e.name,
       CASE
         WHEN e.lifecycle_status <> 'in_service'                      THEN e.lifecycle_status::text
         WHEN l.status <> 'active'                                    THEN 'lab ' || l.status
         WHEN NOT service.calibration_valid(e.equipment_id, public.app_now()::date) THEN 'calibration expired'
         WHEN cur.reservation_id IS NOT NULL                          THEN 'in use until ' || to_char(upper(cur.period), 'YYYY-MM-DD HH24:MI')
         ELSE 'available'
       END AS availability,
       nxt.next_booking
FROM inventory.equipment e
JOIN org.laboratory l ON l.lab_id = e.lab_id
LEFT JOIN LATERAL (
    SELECT r.reservation_id, r.period FROM booking.reservation r
    WHERE r.equipment_id = e.equipment_id AND r.status = 'approved'
      AND r.period @> public.app_now()
    LIMIT 1) cur ON true
LEFT JOIN LATERAL (
    SELECT min(lower(r.period)) AS next_booking FROM booking.reservation r
    WHERE r.equipment_id = e.equipment_id AND r.status IN ('requested', 'approved')
      AND lower(r.period) > public.app_now()) nxt ON true;

-- Calibration status -------------------------------------------------------
CREATE VIEW report.v_calibration_status AS
SELECT e.asset_tag, e.name, last.performed_on, last.result, last.next_due,
       CASE WHEN last.calibration_id IS NULL                 THEN 'never calibrated'
            WHEN last.result = 'fail'                        THEN 'failed'
            WHEN last.next_due < public.app_now()::date      THEN 'overdue'
            WHEN last.next_due < public.app_now()::date + 30 THEN 'due within 30 days'
            ELSE 'valid' END AS state,
       last.next_due - public.app_now()::date AS days_left
FROM inventory.calibratable_equipment ce
JOIN inventory.equipment e USING (equipment_id)
LEFT JOIN LATERAL (
    SELECT * FROM service.calibration c WHERE c.equipment_id = ce.equipment_id
    ORDER BY performed_on DESC LIMIT 1) last ON true;

CREATE VIEW report.v_overdue_calibration AS
SELECT * FROM report.v_calibration_status
WHERE state IN ('never calibrated', 'failed', 'overdue');

-- Authorizations expiring in the next 30 days -----------------------------
CREATE VIEW report.v_expiring_authorizations AS
SELECT p.full_name, p.email, e.asset_tag, e.name AS equipment, a.valid_until,
       a.valid_until - public.app_now()::date AS days_left
FROM training.authorization a
JOIN org.person p          ON p.person_id = a.person_id
JOIN inventory.equipment e ON e.equipment_id = a.equipment_id
WHERE a.status = 'active'
  AND a.valid_until BETWEEN public.app_now()::date AND public.app_now()::date + 30;

-- Usage by project and by person ------------------------------------------------
CREATE VIEW report.v_usage_by_project AS
SELECT rp.code, rp.title,
       count(r.reservation_id)                                     AS bookings,
       count(*) FILTER (WHERE r.status = 'completed')              AS completed,
       count(*) FILTER (WHERE r.status = 'no_show')                AS no_shows,
       count(*) FILTER (WHERE r.status = 'cancelled')              AS cancelled,
       coalesce(sum(u.hours_used), 0)                              AS hours_used,
       coalesce(sum(ch.amount) FILTER (WHERE ch.status <> 'waived'), 0) AS charged
FROM org.research_project rp
LEFT JOIN booking.reservation r ON r.project_id = rp.project_id
LEFT JOIN booking.usage_log u   ON u.reservation_id = r.reservation_id
LEFT JOIN finance.charge ch     ON ch.usage_id = u.usage_id
GROUP BY rp.project_id, rp.code, rp.title;

CREATE VIEW report.v_usage_by_person AS
SELECT p.full_name,
       count(r.reservation_id)                           AS bookings,
       coalesce(sum(u.hours_used), 0)                    AS hours_used,
       round(100.0 * count(*) FILTER (WHERE r.status = 'no_show')
             / nullif(count(*) FILTER (WHERE r.status IN ('completed', 'no_show')), 0), 1) AS no_show_pct
FROM org.person p
JOIN booking.reservation r    ON r.person_id = p.person_id
LEFT JOIN booking.usage_log u ON u.reservation_id = r.reservation_id
GROUP BY p.person_id, p.full_name;

-- Utilization ranking inside each lab (window functions) -------------------------
CREATE VIEW report.v_equipment_utilization_rank AS
WITH hours AS (
    SELECT e.equipment_id, e.asset_tag, e.name, l.name AS laboratory,
           coalesce(sum(u.hours_used), 0) AS hours_used
    FROM inventory.equipment e
    JOIN org.laboratory l ON l.lab_id = e.lab_id
    LEFT JOIN booking.reservation r ON r.equipment_id = e.equipment_id
    LEFT JOIN booking.usage_log u   ON u.reservation_id = r.reservation_id
    GROUP BY e.equipment_id, e.asset_tag, e.name, l.name)
SELECT laboratory, asset_tag, name, hours_used,
       rank()       OVER w_lab                                       AS rank_in_lab,
       round(100.0 * hours_used / nullif(sum(hours_used) OVER (PARTITION BY laboratory), 0), 1)
                                                                     AS pct_of_lab_hours,
       sum(hours_used) OVER (PARTITION BY laboratory ORDER BY hours_used DESC
                             ROWS UNBOUNDED PRECEDING)               AS running_hours,
       ntile(4)     OVER (ORDER BY hours_used DESC)                  AS overall_quartile
FROM hours
WINDOW w_lab AS (PARTITION BY laboratory ORDER BY hours_used DESC);

-- Reliability: mean time between failures and mean time to repair ---------------
CREATE VIEW report.v_reliability AS
WITH gaps AS (
    SELECT i.equipment_id, i.reported_at,
           i.reported_at - lag(i.reported_at) OVER (PARTITION BY i.equipment_id
                                                    ORDER BY i.reported_at) AS since_previous
    FROM service.incident i WHERE i.status <> 'dismissed'),
repairs AS (
    SELECT m.equipment_id, avg(m.completed_at - m.opened_at) AS mttr
    FROM service.maintenance m
    WHERE m.maintenance_type = 'corrective' AND m.status = 'completed'
    GROUP BY m.equipment_id)
SELECT e.asset_tag, e.name,
       count(g.reported_at)          AS incidents,
       avg(g.since_previous)         AS mtbf,
       r.mttr
FROM inventory.equipment e
LEFT JOIN gaps g    ON g.equipment_id = e.equipment_id
LEFT JOIN repairs r ON r.equipment_id = e.equipment_id
GROUP BY e.equipment_id, e.asset_tag, e.name, r.mttr
HAVING count(g.reported_at) > 0;

-- Service cost with subtotals per lab and grand total (ROLLUP) -----------------
CREATE VIEW report.v_service_cost AS
SELECT coalesce(l.name, '== all labs ==')                         AS laboratory,
       coalesce(m.maintenance_type::text, '-- lab total --')       AS maintenance_type,
       count(*)                                                    AS work_orders,
       sum(m.cost)                                                 AS total_cost,
       grouping(l.name, m.maintenance_type)                        AS grouping_level
FROM service.maintenance m
JOIN inventory.equipment e ON e.equipment_id = m.equipment_id
JOIN org.laboratory l      ON l.lab_id = e.lab_id
WHERE m.status = 'completed'
GROUP BY ROLLUP (l.name, m.maintenance_type)
ORDER BY l.name NULLS LAST, m.maintenance_type NULLS LAST;

-- Grant budget (derived remaining amount) -----------------------------------------
CREATE VIEW report.v_grant_budget AS
SELECT g.grant_no, fa.name AS agency, rp.code AS project, g.budget,
       coalesce(sum(c.amount) FILTER (WHERE c.status <> 'waived'), 0)           AS spent,
       g.budget - coalesce(sum(c.amount) FILTER (WHERE c.status <> 'waived'), 0) AS remaining,
       round(100.0 * coalesce(sum(c.amount) FILTER (WHERE c.status <> 'waived'), 0) / g.budget, 1)
                                                                                  AS pct_used,
       g.end_date
FROM finance.funding_grant g
JOIN finance.funding_agency fa  ON fa.agency_id = g.agency_id
JOIN org.research_project rp    ON rp.project_id = g.project_id
LEFT JOIN finance.charge c      ON c.grant_id = g.grant_id
GROUP BY g.grant_id, g.grant_no, fa.name, rp.code, g.budget, g.end_date;

-- Uncharged usage (no rate or no grant could cover it) ------------------------------
CREATE VIEW report.v_uncharged_usage AS
SELECT u.usage_id, rp.code AS project, e.asset_tag, u.actual_start, u.hours_used,
       finance.rate_for(e.equipment_id, u.actual_start::date) AS rate
FROM booking.usage_log u
JOIN booking.reservation r     ON r.reservation_id = u.reservation_id
JOIN org.research_project rp   ON rp.project_id = r.project_id
JOIN inventory.equipment e     ON e.equipment_id = r.equipment_id
WHERE NOT EXISTS (SELECT 1 FROM finance.charge c WHERE c.usage_id = u.usage_id);

-- Stock below reorder level -------------------------------------------------------------
CREATE VIEW report.v_low_stock AS
SELECT l.name AS laboratory, c.sku, c.name, s.quantity, c.reorder_level, c.unit
FROM inventory.lab_stock s
JOIN inventory.consumable c ON c.consumable_id = s.consumable_id
JOIN org.laboratory l       ON l.lab_id = s.lab_id
WHERE s.quantity <= c.reorder_level;

-- Future bookings on items that are currently under maintenance ------------------------
CREATE VIEW report.v_bookings_at_risk AS
SELECT r.reservation_id, p.full_name, e.asset_tag, r.period, e.lifecycle_status
FROM booking.reservation r
JOIN inventory.equipment e ON e.equipment_id = r.equipment_id
JOIN org.person p          ON p.person_id = r.person_id
WHERE r.status IN ('requested', 'approved')
  AND lower(r.period) > public.app_now()
  AND e.lifecycle_status = 'under_maintenance';

-- Monthly utilization (materialized) ------------------------------------------------------
CREATE MATERIALIZED VIEW report.mv_monthly_utilization AS
SELECT e.equipment_id, e.asset_tag,
       date_trunc('month', u.actual_start)::date AS month,
       count(*)                                  AS sessions,
       sum(u.hours_used)                         AS hours_used,
       count(DISTINCT r.person_id)               AS distinct_users
FROM booking.usage_log u
JOIN booking.reservation r ON r.reservation_id = u.reservation_id
JOIN inventory.equipment e ON e.equipment_id = r.equipment_id
GROUP BY e.equipment_id, e.asset_tag, date_trunc('month', u.actual_start)
WITH NO DATA;

-- a unique index is what allows REFRESH ... CONCURRENTLY
CREATE UNIQUE INDEX mv_monthly_utilization_uq
    ON report.mv_monthly_utilization (equipment_id, month);

GRANT SELECT ON ALL TABLES IN SCHEMA report TO lab_admin, lab_auditor, lab_manager;
GRANT SELECT ON report.v_equipment_availability, report.v_category_tree,
                report.v_calibration_status TO lab_researcher;
