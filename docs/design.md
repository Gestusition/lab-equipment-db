# Design notes: EER → relational mapping, dependencies, normal forms

Kıraç Polatkan (230303054). These notes go with `docs/230303054_POLATKAN_EER_v2.pdf` and the scripts in `sql/`.
Notation: **PK** is underlined in the EER; `→` means "references"; UQ means a UNIQUE constraint.

## 1. Scope compared with v1

The topic is the same as in v1: university laboratories and shared equipment. Instead of adding
a new subject, the model was extended *within* that subject and split into six modules. Two of
the additions were listed as future work in v1 (transfer history and charging).

| | v1 | v2 |
|---|---|---|
| Entity types | 11 | 31 (incl. 9 subclasses, 1 weak entity, 1 category) |
| Specializations | 1 (d, total) | 4: d-total (equipment), o-partial (equipment), o-partial (person), d-total (maintenance) |
| Category (union type) | – | EQUIPMENT_OWNER ⊆ DEPARTMENT ∪ LABORATORY ∪ FUNDING_GRANT |
| Weak entity | – | EQUIPMENT_COMPONENT |
| Ternary relationship | (implicit in RESERVATION) | AUTHORIZATION (trainee, assessor, instrument), RESERVATION as reified BOOKS |
| Recursive relationships | – | SUBCATEGORY_OF, PART_OF, ADVISES |
| 1:1 relationships | ACTUAL_USE | ACTUAL_USE, MANAGES, RESOLVES, BILLS, PROMOTED_TO |
| Composite / multivalued / derived attributes | – | name, period / phone / full_name, hours_used, next_due, amount, remaining, quantity |
| Relations | 12 | 37 tables (+ 13 monthly audit partitions), 2 subtype views, 17 report views |

## 2. Mapping of each EER construct

| EER construct | Mapping chosen (Elmasri ch. 9) | Where |
|---|---|---|
| Strong entity types | one relation each, surrogate identity PK, natural keys as UQ | all modules |
| Weak entity EQUIPMENT_COMPONENT | PK = (owner PK, partial key) `(equipment_id, component_no)`, `ON DELETE CASCADE` | `02_inventory.sql` |
| 1:N relationships | FK on the N side; `NOT NULL` when participation is total | e.g. `equipment.lab_id` |
| 1:1 MANAGES | FK `laboratory.manager_id` with UQ (partial on both sides → nullable) | `01_org.sql` |
| 1:1 ACTUAL_USE / BILLS / RESOLVES | FK on the total side, `NOT NULL UNIQUE` | `usage_log`, `charge`, `corrective_maintenance` |
| M:N PROJECT_MEMBER, ATTENDS, QUALIFIES_FOR, STOCKS | relationship relation, PK = both FKs, plus relationship attributes | |
| Ternary AUTHORIZATION | relation with FKs to trainee, assessor and instrument; surrogate PK because the same pair can be authorized again later (history) | `03_training.sql` |
| Reified ternary RESERVATION | relation with FKs to person, equipment, project and its own PK (referenced by usage, waitlist, charge) | `04_booking.sql` |
| Recursive 1:N | self-referencing FK (`parent_category_id`, `parent_equipment_id`, `advisor_id`) + cycle-check trigger | |
| Composite attribute name / period | stored as components (`first_name`, `last_name`; `tstzrange` for period) | |
| Multivalued phone | separate relation `person_phone(person_id, phone)` | |
| Derived attributes | `GENERATED ALWAYS … STORED` (`full_name`, `hours_used`, `amount`) or computed in a function/view (`remaining`, `next_due` default) | |
| d, total, predicate-defined (EQUIPMENT by training_required) | **8C**: single relation + `NOT NULL` boolean discriminator, subtype views `training_required_equipment`, `unrestricted_equipment` | |
| o, partial (EQUIPMENT → HAZARDOUS, CALIBRATABLE) | **8A**: one relation per subclass sharing the PK (overlap needs no extra rule) | |
| o, partial (PERSON → ACADEMIC, GRAD_STUDENT, TECHNICIAN) | **8A** as above | |
| d, total (MAINTENANCE by maintenance_type) | **8A** + discriminator copied into each subclass, pinned by `CHECK`, inside a composite FK → disjointness is declarative; totality = deferred constraint trigger | `05_service.sql` |
| Category EQUIPMENT_OWNER | surrogate key relation `owner(owner_id, owner_kind)`; each superclass gets `owner_id UNIQUE` + `owner_kind` pinned by `CHECK`, composite FK → an owner row can belong to only one superclass | `06_finance.sql` |
| Relationship attached to a subclass (AUTHORIZATION → TRAINING_REQUIRED, CALIBRATION → CALIBRATABLE) | FK to the subclass relation (`calibration → calibratable_equipment`), or a trigger when the subclass is a view (8C) | |

## 3. Functional dependencies and normal form

For every relation the only non-trivial FDs have a candidate key as determinant, so each
relation is in **BCNF** (and therefore 3NF). The list below gives the candidate keys and the
FDs that are not obvious.

| Relation | Candidate keys | Remarks |
|---|---|---|
| department | {department_id}, {code}, {name} | three keys; all FDs come from one of them |
| person | {person_id}, {lower(email)} | `full_name` is a generated column, so `first_name, last_name → full_name` is enforced by the DBMS and causes no update anomaly. `department_id` depends only on the key |
| person_phone | {person_id, phone} | `kind` depends on the whole key |
| academic / grad_student / technician | {person_id}; grad_student also {student_no} | `advisor_id` depends on the student, not on the program |
| laboratory | {lab_id}, {department_id, name}, {building, room_no}, {manager_id} (when not null) | `biosafety_level` belongs to the room → it depends on the key {building, room_no}, which is a candidate key: BCNF holds |
| research_project | {project_id}, {code} | |
| project_member | {project_id, person_id} | v1 scope kept: one membership interval per pair |
| equipment_category | {category_id}, {name} | |
| equipment | {equipment_id}, {asset_tag}, {manufacturer, serial_no} | `category_id` does **not** determine `training_required` (two centrifuges can differ), so no transitive FD |
| hazardous_equipment, calibratable_equipment | {equipment_id} | |
| equipment_component | {equipment_id, component_no} | `part_number ↛ name` (supplier reuse), no partial dependency |
| equipment_transfer | {transfer_id} | `from_lab_id` is history, not derivable from current `equipment.lab_id` |
| consumable | {consumable_id}, {sku} | |
| lab_stock | {lab_id, consumable_id} | `quantity` is the sum of the ledger; kept as a controlled, trigger-maintained balance (see §4) |
| stock_movement | {movement_id} | |
| training_course | {course_id}, {code} | |
| course_qualification | {course_id, equipment_id} | all-key relation |
| training_session | {session_id} | |
| session_attendance | {session_id, trainee_id} | `outcome` depends on score **and** the course pass mark, i.e. on the whole key, not on a part of it |
| authorization | {authorization_id} | plus the temporal key "no two active rows overlap for (person_id, equipment_id)", enforced by an exclusion constraint |
| reservation | {reservation_id} | temporal key (equipment_id, period) among blocking rows (exclusion constraint) |
| usage_log | {usage_id}, {reservation_id} | `hours_used` generated from actual_start/actual_end |
| waitlist_entry | {entry_id}, {reservation_id} (when promoted) | |
| incident | {incident_id} | |
| maintenance | {maintenance_id}; {maintenance_id, maintenance_type} is a superkey used only as an FK target | |
| preventive_maintenance / corrective_maintenance | {maintenance_id}; corrective also {incident_id} | |
| calibration | {calibration_id}, {certificate_no}, {equipment_id, performed_on} | `next_due` is filled from the interval but may be overridden by the certificate, so it is stored, not generated |
| owner | {owner_id} | |
| funding_agency | {agency_id}, {name} | |
| funding_grant | {grant_id}, {grant_no}, {owner_id} (when not null) | |
| rate_card | {rate_id}; temporal key (category_id, valid) | |
| charge | {charge_id}, {usage_id} | `hourly_rate` is copied on purpose: it records the price **at the time of use**, so later rate changes must not alter old invoices. `amount` is generated from hours × rate |
| audit.change_log | {log_id, changed_at} | partition key included in the PK as PostgreSQL requires |

Names and other values that depend on another entity are not copied into related tables (as v1
promised). The only copies are the historical snapshots that are meant to stay fixed, and they
are listed in §4.

## 4. Deliberate redundancy

| Stored value | Why it is stored | How it is kept correct |
|---|---|---|
| `person.full_name`, `usage_log.hours_used`, `charge.amount` | read by every report | `GENERATED ALWAYS AS … STORED`: it cannot be written, so it cannot be wrong |
| `lab_stock.quantity` | stock checks must not sum the whole ledger | changed only by the `apply_movement` trigger; `CHECK (quantity >= 0)` rejects over-consumption |
| `charge.hourly_rate` | invoice must keep the historical price | set once by `generate_charges`; invoiced charges are immutable |
| `equipment_transfer.from_lab_id` | history | written by trigger on every lab change; immutable |

## 5. Rules that are not single-row constraints

| Rule | Mechanism |
|---|---|
| Blocking reservations of an item never overlap | `EXCLUDE USING gist (equipment_id WITH =, period WITH &&) WHERE (status IN (...))` |
| Active authorizations / rate periods never overlap | exclusion constraints |
| Active project ⇒ exactly one current PI | partial UNIQUE index (≤ 1) + deferred constraint trigger (≥ 1) |
| Booker is a member, authorized, safety-trained; item in service and calibrated | `BEFORE` triggers on `reservation`; the calibration check is plugged in by the service module |
| Specialization totality (maintenance), category attachment (owner), module/system same lab | deferred constraint triggers (checked at COMMIT) |
| No cycles in category / part-of trees | recursive CTE inside a trigger |
| Status workflows | state-machine triggers |
| Changes elsewhere invalidate future bookings | `revalidate_future` called from triggers on membership, authorization, equipment and project |
| History cannot be destroyed | `protect_history` triggers |
| Last seat / last money under concurrency | `SELECT … FOR UPDATE` on the session / grant row; tested with two real sessions |
