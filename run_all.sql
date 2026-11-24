-- Rebuilds the whole database, loads sample data and runs the test suite.
-- Usage: psql -d labdb -v ON_ERROR_STOP=1 -f run_all.sql
\set ON_ERROR_STOP on
\pset pager off
SET client_min_messages = warning;

\ir sql/00_setup.sql
\ir sql/01_org.sql
\ir sql/02_inventory.sql
\ir sql/03_training.sql
\ir sql/04_booking.sql
\ir sql/05_service.sql
\ir sql/06_finance.sql
\ir sql/07_audit.sql
\ir sql/08_reports.sql
\ir sql/09_indexes.sql
\ir sql/90_seed.sql
\ir tests/95_tests.sql
