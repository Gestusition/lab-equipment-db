-- =====================================================================
-- 96 EXPLAIN — evidence for the index choices in sql/09_indexes.sql
--
-- Runs after run_all.sql. Inside one transaction it adds bulk history
-- (200 000 cancelled reservations; 'cancelled' rows are not blocking, so
-- the overlap and eligibility rules are not involved), measures each
-- query WITH its index, drops the index, measures again, and finally
-- rolls everything back.
--   psql -d labdb -f tests/96_explain.sql
-- =====================================================================
\pset pager off
SET TIME ZONE 'Europe/Istanbul';

BEGIN;

ALTER TABLE booking.reservation DISABLE TRIGGER zz_audit;   -- keep the audit log small
INSERT INTO booking.reservation (person_id, equipment_id, project_id, period, purpose, status, requested_at, status_note)
SELECT 1 + (g % 15),
       1 + (g % 14),
       1 + (g % 4),
       tstzrange(ts, ts + interval '2 hours'),
       'bulk history',
       'cancelled',
       ts - interval '3 days',
       'generated for EXPLAIN'
FROM generate_series(1, 200000) g,
     LATERAL (SELECT timestamptz '2020-01-01 08:00+03' + g * interval '17 minutes' AS ts) t;
-- a few pending requests, as in real life
INSERT INTO booking.reservation (person_id, equipment_id, project_id, period, purpose, status, requested_at)
SELECT 6, 6, 2, tstzrange(ts, ts + interval '1 hour'), 'pending', 'requested', ts - interval '1 day'
FROM generate_series(1, 20) g,
     LATERAL (SELECT timestamptz '2027-03-01 08:00+03' + g * interval '1 day' AS ts) t;
ANALYZE booking.reservation;

\echo
\echo ===== Q1  "my last 20 bookings"  (reservation_person_start_idx) =====
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT reservation_id, lower(period) FROM booking.reservation
WHERE person_id = 6 ORDER BY lower(period) DESC LIMIT 20;

\echo ----- without the index -----
SAVEPOINT s1;
DROP INDEX booking.reservation_person_start_idx;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT reservation_id, lower(period) FROM booking.reservation
WHERE person_id = 6 ORDER BY lower(period) DESC LIMIT 20;
ROLLBACK TO SAVEPOINT s1;

\echo
\echo ===== Q2  approval queue  (partial index reservation_pending_idx) =====
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT reservation_id FROM booking.reservation
WHERE status = 'requested' AND equipment_id = 6 ORDER BY requested_at;

\echo ----- without the index -----
SAVEPOINT s2;
DROP INDEX booking.reservation_pending_idx;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT reservation_id FROM booking.reservation
WHERE status = 'requested' AND equipment_id = 6 ORDER BY requested_at;
ROLLBACK TO SAVEPOINT s2;

\echo
\echo ===== Q3  "what blocks item 1 during this week"  (GiST of the exclusion constraint) =====
-- The exclusion index is partial (blocking statuses only), so a query
-- must repeat that predicate to be able to use it.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT reservation_id FROM booking.reservation
WHERE equipment_id = 1 AND period && tstzrange('2026-11-30', '2026-12-07')
  AND status IN ('requested', 'approved', 'completed');

\echo ----- same question without the status predicate: index unusable -----
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT reservation_id FROM booking.reservation
WHERE equipment_id = 1 AND period && tstzrange('2026-11-30', '2026-12-07');

\echo
\echo ===== Q4  index sizes: full B-tree vs partial indexes =====
SELECT c.relname AS index, pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_class c
WHERE c.relname IN ('reservation_person_start_idx', 'reservation_pending_idx',
                    'reservation_no_overlap', 'reservation_pkey')
ORDER BY pg_relation_size(c.oid) DESC;

ROLLBACK;
