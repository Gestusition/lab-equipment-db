# University Research Laboratory & Equipment Management System

PostgreSQL 18 term project — Kıraç Polatkan (230303054), Arel University, Computer Engineering.

The database manages university laboratories and shared scientific equipment: people and
projects, inventory, training and authorization, reservations and actual usage, maintenance,
calibration, incidents, funding and usage charges, and an audit trail. Everything is written in
SQL; there is no application layer.

## Modules

Each module is its own PostgreSQL schema and its own script, loaded in dependency order.

| # | Schema      | Script                     | Contents |
|---|-------------|----------------------------|----------|
| 0 | `public`    | `sql/00_setup.sql`         | Extensions, shared enum types and helper functions |
| 1 | `org`       | `sql/01_org.sql`           | Departments, laboratories, persons (overlapping specialization), advising, projects, membership |
| 2 | `inventory` | `sql/02_inventory.sql`     | Category tree, equipment (two specializations), components (weak entity), transfers, consumables |
| 3 | `training`  | `sql/03_training.sql`      | Courses, sessions, attendance, ternary authorization |
| 4 | `booking`   | `sql/04_booking.sql`       | Reservations with approval workflow, waitlist, usage logs |
| 5 | `service`   | `sql/05_service.sql`       | Maintenance (preventive / corrective), incidents, calibration |
| 6 | `finance`   | `sql/06_finance.sql`       | Equipment owner (category / union type), grants, rate cards, charges |
| 7 | `audit`     | `sql/07_audit.sql`         | Partitioned change log, history protection, roles, row-level security |
| 8 | `report`    | `sql/08_reports.sql`       | Reporting views, materialized view, recursive and window queries |
| 9 | —           | `sql/09_indexes.sql`       | Indexes chosen from access patterns |

Data and tests: `sql/90_seed.sql` (sample data), `tests/95_tests.sql` (positive, negative and
concurrency tests with recorded expected vs. observed outcomes).

## Running

```powershell
createdb labdb
psql -d labdb -v ON_ERROR_STOP=1 -f run_all.sql
```

`run_all.sql` rebuilds every schema from scratch, loads the seed data and runs the test suite.
The final query prints the test summary.

## Documents

- `docs/v1/` — original proposal and EER diagram (submitted October 2026)
- `docs/` — extended EER diagram, relational mapping and normalization notes
