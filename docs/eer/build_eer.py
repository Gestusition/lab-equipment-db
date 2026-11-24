"""Builds docs/EER_v2.html (overview + one page per module) and, given a
target path, prints it to PDF with headless Chrome:

    python docs/eer/build_eer.py docs/EER_v2.pdf "C:/Program Files/Google/Chrome/Application/chrome.exe"
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from eerlib import FONT, Page  # noqa: E402

AUTHOR = "Kıraç Polatkan (230303054)"
PAGES = []


def curve(p, d):
    p.raw(f'<path d="{d}" fill="none" stroke="#333" stroke-width="1.2"/>', "back")


def line(p, x1, y1, x2, y2, double=False):
    if double:
        import math
        L = math.hypot(x2 - x1, y2 - y1)
        nx, ny = -(y2 - y1) / L * 2.6, (x2 - x1) / L * 2.6
        for k in (1, -1):
            p.raw(f'<line x1="{x1 + nx * k}" y1="{y1 + ny * k}" x2="{x2 + nx * k}" y2="{y2 + ny * k}" '
                  f'stroke="#333" stroke-width="1.2"/>', "back")
    else:
        p.raw(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="#333" stroke-width="1.2"/>', "back")


def card(p, x, y, t):
    p.raw(f'<text x="{x}" y="{y}" font-size="13" font-weight="bold" fill="#b00020" font-family="{FONT}">{t}</text>', "top")


def role(p, x, y, t):
    p.raw(f'<text x="{x}" y="{y}" font-size="10" font-style="italic" fill="#225" font-family="{FONT}">{t}</text>', "top")


# ============================================================== OVERVIEW
def page_overview():
    p = Page("University Research Laboratory & Equipment Management System — EER v2",
             f"{AUTHOR} · Arel University, Computer Engineering · same scope as v1, split into 6 modules · 31 entity types (v1: 11)",
             height=1100)
    colors = {"ORG": "#e3eeff", "INVENTORY": "#e6f6e6", "TRAINING": "#fff3dc",
              "BOOKING": "#fbe6f0", "SERVICE": "#eeeaff", "FINANCE": "#e2f5f3"}
    boxes = {
        "ORG": (60, 120, 420, 300, "page 2", ["DEPARTMENT", "LABORATORY", "PERSON",
                                              "   ACADEMIC | GRAD_STUDENT | TECHNICIAN  (o)",
                                              "RESEARCH_PROJECT", "PROJECT_MEMBER  (M:N)",
                                              "ADVISES (recursive), MANAGES (1:1)"]),
        "INVENTORY": (580, 120, 440, 300, "page 3", ["EQUIPMENT_CATEGORY  (recursive tree)",
                                                     "EQUIPMENT  (recursive PART_OF)",
                                                     "   TRAINING_REQUIRED | UNRESTRICTED  (d, total)",
                                                     "   HAZARDOUS | CALIBRATABLE  (o, partial)",
                                                     "EQUIPMENT_COMPONENT  (weak)",
                                                     "EQUIPMENT_TRANSFER",
                                                     "CONSUMABLE, STOCKS (M:N)"]),
        "TRAINING": (1120, 120, 420, 300, "page 4", ["TRAINING_COURSE", "TRAINING_SESSION",
                                                     "ATTENDS  (M:N)", "QUALIFIES_FOR  (M:N)",
                                                     "AUTHORIZATION  (ternary)"]),
        "BOOKING": (60, 520, 420, 300, "page 5", ["RESERVATION", "   (reified BOOKS: person,",
                                                  "    equipment, project)",
                                                  "USAGE_LOG  (1:1)", "WAITLIST_ENTRY"]),
        "SERVICE": (580, 520, 440, 300, "page 6", ["INCIDENT", "MAINTENANCE",
                                                   "   PREVENTIVE | CORRECTIVE  (d, total)",
                                                   "CALIBRATION", "RESOLVES  (1:1)"]),
        "FINANCE": (1120, 520, 420, 300, "page 7", ["EQUIPMENT_OWNER  (category u of",
                                                    "   DEPARTMENT, LABORATORY, FUNDING_GRANT)",
                                                    "FUNDING_AGENCY", "FUNDING_GRANT", "RATE_CARD", "CHARGE"]),
    }
    for name, (x, y, w, h, pg, items) in boxes.items():
        p.raw(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{colors[name]}" stroke="#8b9bb0" stroke-width="1.5"/>', "front")
        p.raw(f'<text x="{x + 16}" y="{y + 28}" font-family="{FONT}" font-size="16" font-weight="bold" fill="#123">{name}</text>', "front")
        p.raw(f'<text x="{x + w - 16}" y="{y + 28}" text-anchor="end" font-family="{FONT}" font-size="11" fill="#567">{pg}</text>', "front")
        for i, it in enumerate(items):
            p.raw(f'<text x="{x + 22}" y="{y + 62 + i * 26}" font-family="{FONT}" font-size="13.5" fill="#111" xml:space="preserve">{it}</text>', "front")

    def path(pts, label, lx, ly, anchor="middle"):
        d = "M" + " L".join(f"{x},{y}" for x, y in pts)
        p.raw(f'<path d="{d}" fill="none" stroke="#5a6b80" stroke-width="1.8" stroke-dasharray="7 4"/>', "back")
        for k, t in enumerate(label.split("\n")):
            p.raw(f'<text x="{lx}" y="{ly + k * 13}" text-anchor="{anchor}" font-family="{FONT}" font-size="11" '
                  f'font-style="italic" fill="#333">{t}</text>', "top")

    path([(480, 230), (580, 230)], "HOUSES,\nFROM/TO_LAB", 530, 212)
    path([(1020, 230), (1120, 230)], "QUALIFIES_FOR,\nAUTHORIZATION", 1070, 212)
    path([(270, 120), (270, 96), (1330, 96), (1330, 120)], "LEADS · ATTENDS · HELD_IN · AUTHORIZATION (trainee, assessor)", 800, 90)
    path([(270, 420), (270, 520)], "CREATES · DECIDES ·\nSUPPORTS · WAITS_FOR", 282, 462, "start")
    path([(700, 420), (700, 470), (430, 470), (430, 520)], "BOOKED_IN", 560, 464)
    path([(880, 420), (880, 520)], "SERVICE_HISTORY ·\nCONCERNS ·\nCALIBRATION_HISTORY", 892, 452, "start")
    path([(480, 670), (580, 670)], "RAISED_\nDURING", 530, 652)
    path([(1020, 300), (1070, 300), (1070, 480), (1330, 480), (1330, 520)], "OWNS · PRICES", 1200, 474)
    path([(270, 820), (270, 850), (1330, 850), (1330, 820)], "BILLS  (USAGE_LOG → CHARGE)", 800, 868)

    legend = [
        "rectangle = entity type · double rectangle = weak entity type · dashed rectangle = entity defined in another module (shown for context)",
        "diamond = relationship type · double diamond = identifying relationship · 1 / M / N = cardinality ratio · italic text on a line = role name",
        "oval = attribute · underlined = key (PK or UQ) · dashed underline = partial key · double oval = multivalued · dashed oval = derived",
        "oval with sub-ovals = composite · double line = total participation · single line = partial participation",
        "circle d = disjoint, o = overlapping specialization (double line from the superclass = total) · circle u = category (union type)",
        "U-shaped mark on a line = subset (IS-A) direction, open side towards the superclass / circle",
    ]
    p.note(60, 900, legend, width=1480, title="Notation (Elmasri & Navathe, ch. 3-4)")
    PAGES.append(p)


# ============================================================== ORG
def page_org():
    p = Page("Module 1 — ORG: organisation, people and projects",
             f"EER v2 · {AUTHOR} · overlapping specialization, composite / multivalued / derived attributes, recursive and 1:1 relationships")
    p.entity("DEPT", 230, 270, "DEPARTMENT")
    p.entity("LAB", 230, 650, "LABORATORY")
    p.entity("PERSON", 760, 270, "PERSON")
    p.entity("PROJ", 1320, 160, "RESEARCH_PROJECT")
    p.entity("TECH", 520, 610, "TECHNICIAN")
    p.entity("ACAD", 780, 610, "ACADEMIC")
    p.entity("GRAD", 1040, 610, "GRAD_STUDENT")

    p.rel("CONTAINS", 230, 460, "CONTAINS")
    p.rel("EMPLOYS", 480, 270, "EMPLOYS")
    p.rel("RUNS", 780, 95, "RUNS")
    p.rel("MEMBER", 1050, 220, "PROJECT_\nMEMBER")
    p.rel("MANAGES", 370, 760, "MANAGES")
    p.rel("ADVISES", 910, 790, "ADVISES")

    p.link("DEPT", "CONTAINS", "1")
    p.link("LAB", "CONTAINS", "N", total=True)
    p.link("DEPT", "EMPLOYS", "1")
    p.link("PERSON", "EMPLOYS", "N", total=True)
    p.link("DEPT", "RUNS", "1")
    p.link("PROJ", "RUNS", "N", total=True)
    p.link("PERSON", "MEMBER", "M")
    p.link("PROJ", "MEMBER", "N")
    p.link("TECH", "MANAGES", "1")
    p.link("LAB", "MANAGES", "1")
    p.link("ACAD", "ADVISES", "1", role="advisor")
    p.link("GRAD", "ADVISES", "N", total=True, role="advisee")

    p.isa("o1", 780, 440, "o", ["PERSON"], ["TECH", "ACAD", "GRAD"])

    p.attr("DEPT", 95, 210, "department_id", "key")
    p.attr("DEPT", 90, 300, "code (UQ)", "key")
    p.attr("DEPT", 200, 170, "name (UQ)", "key")

    p.attr("LAB", 85, 590, "lab_id", "key")
    p.attr("LAB", 80, 660, "name")
    p.attr("LAB", 100, 730, "building")
    p.attr("LAB", 200, 790, "room_no")
    p.attr("LAB", 110, 530, "status")
    p.attr("LAB", 260, 860, "biosafety_level")

    p.attr("PERSON", 610, 180, "person_id", "key")
    p.attr("PERSON", 630, 225, "is_active")
    p.attr("PERSON", 640, 345, "email (UQ)", "key")
    name = p.attr("PERSON", 900, 380, "name", "composite")
    p.sub_attr(name, 1010, 400, "first_name")
    p.sub_attr(name, 950, 450, "last_name")
    p.attr("PERSON", 560, 395, "full_name", "derived")
    p.attr("PERSON", 880, 170, "phone", "multi")

    p.attr("PROJ", 1460, 75, "project_id", "key")
    p.attr("PROJ", 1510, 125, "code (UQ)", "key")
    p.attr("PROJ", 1520, 180, "title")
    p.attr("PROJ", 1500, 235, "start_date")
    p.attr("PROJ", 1400, 270, "end_date")
    p.attr("PROJ", 1295, 260, "status")

    p.attr("MEMBER", 1000, 305, "member_role")
    p.attr("MEMBER", 1120, 325, "joined_on")
    p.attr("MEMBER", 1195, 285, "left_on")

    p.attr("TECH", 400, 545, "specialty")
    p.attr("TECH", 520, 700, "cert_level")
    p.attr("ACAD", 690, 700, "title")
    p.attr("ACAD", 780, 735, "office")
    p.attr("GRAD", 1190, 545, "student_no (UQ)", "key")
    p.attr("GRAD", 1200, 610, "program")
    p.attr("GRAD", 1170, 680, "enrolled_on")

    p.note(1180, 760, [
        "o = overlapping, single line = partial: a lecturer may also be",
        "a PhD student, a technician may also study, a visiting",
        "researcher may be in no subclass. Mapping: one relation per",
        "subclass sharing person_id (option 8A).",
        "ADVISES is recursive on PERSON (academic -> grad student).",
        "Active project => exactly one current PI (PI must be ACADEMIC);",
        "checked by a deferred constraint trigger at COMMIT.",
    ], width=400, title="Rules")
    PAGES.append(p)


# ============================================================== INVENTORY
def page_inventory():
    p = Page("Module 2 — INVENTORY: categories, equipment, components, transfers, consumables",
             f"EER v2 · {AUTHOR} · two specializations of one superclass (disjoint-total and overlapping-partial), weak entity, recursive relationships",
             height=1060)
    p.entity("CAT", 230, 250, "EQUIPMENT_CATEGORY")
    p.entity("EQ", 760, 450, "EQUIPMENT", fill="#e8f0fb")
    p.entity("LAB", 1270, 170, "LABORATORY", ref="ORG")
    p.entity("COMP", 220, 570, "EQUIPMENT_COMPONENT", weak=True)
    p.entity("TR", 400, 860, "TRAINING_REQUIRED_EQUIPMENT")
    p.entity("UN", 760, 920, "UNRESTRICTED_EQUIPMENT")
    p.entity("HAZ", 1000, 860, "HAZARDOUS_EQUIPMENT")
    p.entity("CALEQ", 1330, 790, "CALIBRATABLE_EQUIPMENT")
    p.entity("XFER", 1290, 450, "EQUIPMENT_TRANSFER")
    p.entity("CONS", 1470, 290, "CONSUMABLE")

    p.rel("SUBCAT", 230, 100, "SUBCATEGORY_OF")
    p.rel("CLASS", 480, 330, "CLASSIFIES")
    p.rel("PART", 760, 200, "PART_OF")
    p.rel("HOUSES", 1010, 290, "HOUSES")
    p.rel("HAS", 450, 505, "HAS_PART", identifying=True)
    p.rel("MOVED", 1060, 450, "MOVED")
    p.rel("FROM", 1190, 320, "FROM_LAB")
    p.rel("TO", 1350, 320, "TO_LAB")
    p.rel("STOCKS", 1470, 170, "STOCKS")

    curve(p, "M120,250 C50,250 50,100 145,100")
    curve(p, "M330,231 C360,170 350,110 315,100")
    card(p, 56, 180, "1"); role(p, 56, 240, "parent")
    card(p, 360, 170, "N"); role(p, 346, 215, "child")
    curve(p, "M705,431 C670,360 680,230 712,212")
    curve(p, "M815,431 C850,360 840,230 808,212")
    card(p, 660, 320, "1"); role(p, 626, 340, "system")
    card(p, 850, 320, "N"); role(p, 852, 340, "module")

    p.link("CAT", "CLASS", "1")
    p.link("EQ", "CLASS", "N", total=True)
    p.link("LAB", "HOUSES", "1")
    p.link("EQ", "HOUSES", "N", total=True)
    p.link("EQ", "HAS", "1")
    p.link("COMP", "HAS", "N", total=True)
    p.link("EQ", "MOVED", "1")
    p.link("XFER", "MOVED", "N", total=True)
    p.link("XFER", "FROM", "N", total=True)
    p.link("LAB", "FROM", "1")
    p.link("XFER", "TO", "N", total=True)
    p.link("LAB", "TO", "1")
    p.link("LAB", "STOCKS", "M")
    p.link("CONS", "STOCKS", "N")

    p.isa("d1", 600, 710, "d", ["EQ"], ["TR", "UN"], total=True,
          predicate="training_required", child_labels=["= true", "= false"])
    p.isa("o2", 1080, 680, "o", ["EQ"], ["HAZ", "CALEQ"])

    p.attr("CAT", 85, 320, "category_id", "key")
    p.attr("CAT", 230, 340, "name (UQ)", "key")
    p.attr("CAT", 420, 190, "description")

    p.attr("EQ", 575, 425, "equipment_id", "key")
    p.attr("EQ", 560, 565, "asset_tag (UQ)", "key")
    p.attr("EQ", 545, 625, "model")
    p.attr("EQ", 760, 565, "purchase_date")
    p.attr("EQ", 875, 610, "purchase_price")
    p.attr("EQ", 790, 650, "serial_no")
    p.attr("EQ", 965, 510, "lifecycle_status")
    p.attr("EQ", 950, 395, "manufacturer")
    p.attr("EQ", 930, 300, "name")
    p.attr("EQ", 455, 655, "training_required")

    p.attr("COMP", 95, 495, "component_no", "partial")
    p.attr("COMP", 75, 570, "name")
    p.attr("COMP", 100, 645, "part_number")
    p.attr("COMP", 220, 680, "installed_on")
    p.attr("COMP", 330, 640, "removed_on")

    p.attr("HAZ", 850, 950, "hazard_class")
    p.attr("HAZ", 1000, 968, "min_biosafety")
    p.attr("HAZ", 1150, 950, "requires_ppe")
    p.attr("CALEQ", 1330, 895, "calibration_interval")
    p.attr("CALEQ", 1510, 860, "tolerance")

    p.attr("XFER", 1190, 545, "transfer_id", "key")
    p.attr("XFER", 1330, 555, "transferred_at")
    p.attr("XFER", 1470, 505, "reason")

    p.attr("CONS", 1545, 370, "consumable_id", "key")
    p.attr("CONS", 1430, 400, "sku (UQ)", "key")
    p.attr("CONS", 1560, 235, "unit")
    p.attr("CONS", 1385, 245, "reorder_level")
    p.attr("STOCKS", 1380, 95, "quantity", "derived")

    p.note(1160, 600, [
        "Two specializations of EQUIPMENT:",
        "d, double line: disjoint, total, predicate-defined",
        "   -> one relation + discriminator + 2 views (8C)",
        "o, single line: overlapping, partial, user-defined",
        "   -> one relation per subclass (8A)",
    ], width=320)
    p.note(40, 950, [
        "Weak entity: component_no is unique only",
        "within its equipment (dashed underline).",
        "STOCKS.quantity is derived from the",
        "STOCK_MOVEMENT ledger (not shown).",
    ], width=280)
    PAGES.append(p)


# ============================================================== TRAINING
def page_training():
    p = Page("Module 3 — TRAINING: courses, sessions and authorization",
             f"EER v2 · {AUTHOR} · ternary relationship with two roles of one entity, relationship with a subclass, M:N with attributes")
    p.entity("COURSE", 300, 250, "TRAINING_COURSE")
    p.entity("SESS", 760, 250, "TRAINING_SESSION")
    p.entity("PERSON", 760, 670, "PERSON", ref="ORG")
    p.entity("TREQ", 300, 670, "TRAINING_REQUIRED_EQUIPMENT", ref="INVENTORY")
    p.entity("LAB", 1250, 250, "LABORATORY", ref="ORG")

    p.rel("OFFERS", 530, 250, "OFFERS")
    p.rel("QUAL", 300, 460, "QUALIFIES_\nFOR")
    p.rel("HELD", 1010, 250, "HELD_IN")
    p.rel("LEADS", 1010, 470, "LEADS")
    p.rel("ATTENDS", 760, 460, "ATTENDS")
    p.rel("AUTH", 530, 850, "AUTHORIZATION")

    p.link("COURSE", "OFFERS", "1")
    p.link("SESS", "OFFERS", "N", total=True)
    p.link("COURSE", "QUAL", "M")
    p.link("TREQ", "QUAL", "N")
    p.link("LAB", "HELD", "1")
    p.link("SESS", "HELD", "N", total=True)
    p.link("PERSON", "LEADS", "1", role="trainer")
    p.link("SESS", "LEADS", "N", total=True)
    p.link("PERSON", "ATTENDS", "M", role="trainee")
    p.link("SESS", "ATTENDS", "N")
    p.link("TREQ", "AUTH", "M", role="instrument")
    # two roles of PERSON in the ternary: trainee and assessor
    line(p, 725, 689, 560, 832)
    line(p, 800, 689, 590, 850)
    card(p, 620, 770, "N"); role(p, 560, 790, "trainee")
    card(p, 724, 790, "1"); role(p, 730, 808, "assessor")

    p.attr("COURSE", 160, 170, "course_id", "key")
    p.attr("COURSE", 300, 140, "code (UQ)", "key")
    p.attr("COURSE", 440, 150, "title")
    p.attr("COURSE", 130, 250, "validity")
    p.attr("COURSE", 140, 330, "passing_score")
    p.attr("COURSE", 450, 350, "safety_for")

    p.attr("SESS", 690, 140, "session_id", "key")
    p.attr("SESS", 840, 140, "starts_at")
    p.attr("SESS", 920, 180, "capacity")

    p.attr("ATTENDS", 620, 420, "score")
    p.attr("ATTENDS", 620, 510, "outcome")

    p.attr("AUTH", 330, 880, "valid_from")
    p.attr("AUTH", 400, 945, "valid_until")
    p.attr("AUTH", 560, 955, "status")
    p.attr("AUTH", 700, 935, "status_reason")

    p.note(1000, 600, [
        "AUTHORIZATION is a ternary relationship among the trainee",
        "PERSON, the assessor PERSON and TRAINING_REQUIRED_EQUIPMENT",
        "(cardinality N : 1 : M). It attaches to the subclass, not to",
        "EQUIPMENT, so unrestricted items cannot carry an authorization.",
        "Passing a session derives authorizations for every instrument",
        "the course QUALIFIES_FOR; the trainer becomes the assessor.",
        "safety_for = hazard class a safety course certifies (NULL for",
        "operation courses). Hazardous items need a passed safety",
        "course for their own hazard class, valid for the whole booking.",
        "Active authorizations of one (trainee, instrument) pair may",
        "not overlap in time (exclusion constraint).",
    ], width=450, title="Rules")
    PAGES.append(p)


# ============================================================== BOOKING
def page_booking():
    p = Page("Module 4 — BOOKING: reservations, waitlist and usage",
             f"EER v2 · {AUTHOR} · reservation as the reified ternary BOOKS(person, equipment, project), composite attribute, 1:1 relationship")
    p.entity("PERSON", 260, 260, "PERSON", ref="ORG")
    p.entity("EQ", 260, 560, "EQUIPMENT", ref="INVENTORY")
    p.entity("PROJ", 260, 840, "RESEARCH_PROJECT", ref="ORG")
    p.entity("RES", 800, 560, "RESERVATION", fill="#e8f0fb")
    p.entity("USE", 1300, 560, "USAGE_LOG")
    p.entity("WAIT", 800, 900, "WAITLIST_ENTRY")

    p.rel("CREATES", 530, 380, "CREATES")
    p.rel("DECIDES", 640, 200, "DECIDES")
    p.rel("BOOKED", 530, 560, "BOOKED_IN")
    p.rel("SUPPORTS", 530, 730, "SUPPORTS")
    p.rel("ACTUAL", 1050, 560, "ACTUAL_USE")
    p.rel("WAITS", 480, 960, "WAITS_FOR")
    p.rel("PROMO", 1010, 770, "PROMOTED_TO")

    p.link("PERSON", "CREATES", "1")
    p.link("RES", "CREATES", "N", total=True)
    p.link("PERSON", "DECIDES", "1", role="approver")
    p.link("RES", "DECIDES", "N")
    p.link("EQ", "BOOKED", "1")
    p.link("RES", "BOOKED", "N", total=True)
    p.link("PROJ", "SUPPORTS", "1")
    p.link("RES", "SUPPORTS", "N", total=True)
    p.link("RES", "ACTUAL", "1")
    p.link("USE", "ACTUAL", "1", total=True)
    p.link("WAIT", "PROMO", "1")
    p.link("RES", "PROMO", "1")
    p.link("WAIT", "WAITS", "N", total=True)
    p.link("PROJ", "WAITS", "1")

    p.attr("RES", 800, 420, "reservation_id", "key")
    per = p.attr("RES", 950, 430, "period", "composite")
    p.sub_attr(per, 1050, 370, "start_time")
    p.sub_attr(per, 1110, 440, "end_time")
    p.attr("RES", 700, 470, "purpose")
    p.attr("RES", 990, 495, "status")
    p.attr("RES", 740, 700, "requested_at")
    p.attr("RES", 860, 700, "decided_at")

    p.attr("USE", 1300, 430, "usage_id", "key")
    p.attr("USE", 1440, 480, "actual_start")
    p.attr("USE", 1460, 560, "actual_end")
    p.attr("USE", 1440, 640, "condition_after")
    p.attr("USE", 1300, 690, "notes")
    p.attr("USE", 1180, 690, "hours_used", "derived")

    p.attr("WAIT", 990, 965, "entry_id", "key")
    p.attr("WAIT", 1080, 910, "desired_period")
    p.attr("WAIT", 1070, 855, "status")
    p.attr("WAIT", 820, 975, "created_at")

    p.note(1060, 100, [
        "RESERVATION reifies the ternary BOOKS(PERSON, EQUIPMENT,",
        "RESEARCH_PROJECT); it needs its own key because USAGE_LOG,",
        "WAITLIST_ENTRY and CHARGE refer to it.",
        "Blocking reservations of one item never overlap",
        "(exclusion constraint on equipment_id, period).",
        "The booker must be a project member, authorized (training-",
        "required items) and safety-trained (hazardous items) for",
        "the whole period; status follows a state machine:",
        "requested -> approved | rejected | cancelled,",
        "approved -> completed | no_show | cancelled.",
        "WAITS_FOR also links PERSON and EQUIPMENT (omitted).",
    ], width=440, title="Rules")
    PAGES.append(p)


# ============================================================== SERVICE
def page_service():
    p = Page("Module 5 — SERVICE: incidents, maintenance and calibration",
             f"EER v2 · {AUTHOR} · disjoint-total attribute-defined specialization, 1:1 RESOLVES, relationship to a subclass")
    p.entity("EQ", 190, 470, "EQUIPMENT", ref="INVENTORY")
    p.entity("MAINT", 620, 230, "MAINTENANCE", fill="#e8f0fb")
    p.entity("TECH", 1180, 230, "TECHNICIAN", ref="ORG")
    p.entity("PREV", 420, 530, "PREVENTIVE_MAINTENANCE")
    p.entity("CORR", 820, 530, "CORRECTIVE_MAINTENANCE")
    p.entity("INC", 820, 800, "INCIDENT")
    p.entity("PERSON", 1330, 800, "PERSON", ref="ORG")
    p.entity("USE", 1100, 940, "USAGE_LOG", ref="BOOKING")
    p.entity("CAL", 1180, 530, "CALIBRATION")
    p.entity("CALEQ", 1430, 690, "CALIBRATABLE_EQUIPMENT", ref="INVENTORY")

    p.rel("HIST", 380, 330, "SERVICE_\nHISTORY")
    p.rel("ASSIGN", 900, 230, "ASSIGNED_TO")
    p.rel("RESOLVES", 820, 665, "RESOLVES")
    p.rel("CONCERNS", 300, 800, "CONCERNS")
    p.rel("REPORTS", 1080, 800, "REPORTS")
    p.rel("DURING", 820, 940, "RAISED_\nDURING")
    p.rel("PERF", 1180, 380, "PERFORMED_BY")
    p.rel("CALHIST", 1430, 530, "CALIBRATION_\nHISTORY")

    p.link("EQ", "HIST", "1")
    p.link("MAINT", "HIST", "N", total=True)
    p.link("TECH", "ASSIGN", "1")
    p.link("MAINT", "ASSIGN", "N")
    p.link("CORR", "RESOLVES", "1", total=True)
    p.link("INC", "RESOLVES", "1")
    p.link("EQ", "CONCERNS", "1")
    p.link("INC", "CONCERNS", "N", total=True)
    p.link("PERSON", "REPORTS", "1")
    p.link("INC", "REPORTS", "N", total=True)
    p.link("USE", "DURING", "1")
    p.link("INC", "DURING", "N")
    p.link("TECH", "PERF", "1")
    p.link("CAL", "PERF", "N")
    p.link("CALEQ", "CALHIST", "1")
    p.link("CAL", "CALHIST", "N", total=True)

    p.isa("d1", 620, 400, "d", ["MAINT"], ["PREV", "CORR"], total=True,
          predicate="maintenance_type", child_labels=["preventive", "corrective"])

    p.attr("MAINT", 470, 140, "maintenance_id", "key")
    p.attr("MAINT", 455, 195, "vendor")
    p.attr("MAINT", 620, 115, "maintenance_type")
    p.attr("MAINT", 775, 135, "opened_at")
    p.attr("MAINT", 795, 185, "cost")
    p.attr("MAINT", 770, 290, "status")
    p.attr("MAINT", 700, 345, "completed_at")

    p.attr("PREV", 330, 625, "planned_for")
    p.attr("PREV", 480, 640, "repeat_every")
    p.attr("PREV", 610, 600, "checklist")
    p.attr("CORR", 960, 465, "root_cause")
    p.attr("CORR", 975, 600, "parts_replaced")

    p.attr("INC", 650, 860, "severity")
    p.attr("INC", 690, 910, "incident_id", "key")
    p.attr("INC", 960, 740, "status")
    p.attr("INC", 960, 870, "reported_at")

    p.attr("CAL", 1060, 450, "calibration_id", "key")
    p.attr("CAL", 1330, 440, "certificate_no (UQ)", "key")
    p.attr("CAL", 1080, 615, "performed_on")
    p.attr("CAL", 1190, 640, "result")
    p.attr("CAL", 1300, 610, "next_due", "derived")

    p.note(30, 80, [
        "MAINTENANCE: d + double line = disjoint, total,",
        "attribute-defined on maintenance_type. The discriminator",
        "is part of each subclass FK (no order in both); totality",
        "is checked at COMMIT by a deferred constraint trigger.",
        "Open orders set EQUIPMENT.lifecycle_status; a critical",
        "INCIDENT locks the item out at once.",
    ], width=330)
    p.note(1180, 860, [
        "CALIBRATION relates to the CALIBRATABLE",
        "subclass only; next_due = performed_on +",
        "calibration_interval (derived).",
    ], width=300)
    PAGES.append(p)


# ============================================================== FINANCE
def page_finance():
    p = Page("Module 6 — FINANCE: ownership, grants, rates and charges",
             f"EER v2 · {AUTHOR} · category (union type) over three different superclasses, derived attributes")
    p.entity("DEPT", 200, 200, "DEPARTMENT", ref="ORG")
    p.entity("LAB", 470, 200, "LABORATORY", ref="ORG")
    p.entity("GRANT", 900, 330, "FUNDING_GRANT", fill="#e8f0fb")
    p.entity("OWNER", 450, 560, "EQUIPMENT_OWNER")
    p.entity("EQ", 450, 830, "EQUIPMENT", ref="INVENTORY")
    p.entity("AGENCY", 1320, 160, "FUNDING_AGENCY")
    p.entity("PROJ", 1320, 470, "RESEARCH_PROJECT", ref="ORG")
    p.entity("CHARGE", 1060, 700, "CHARGE")
    p.entity("USE", 1420, 700, "USAGE_LOG", ref="BOOKING")
    p.entity("CAT", 860, 900, "EQUIPMENT_CATEGORY", ref="INVENTORY")
    p.entity("RATE", 1250, 900, "RATE_CARD")

    p.rel("OWNS", 450, 700, "OWNS")
    p.rel("AWARDS", 1110, 220, "AWARDS")
    p.rel("FUNDS", 1110, 420, "FUNDS")
    p.rel("CHARGED", 1000, 560, "CHARGED_TO")
    p.rel("BILLS", 1250, 700, "BILLS")
    p.rel("PRICES", 1060, 900, "PRICES")

    p.isa("u1", 450, 420, "u", ["DEPT", "LAB", "GRANT"], ["OWNER"])

    p.link("OWNER", "OWNS", "1")
    p.link("EQ", "OWNS", "N")
    p.link("AGENCY", "AWARDS", "1")
    p.link("GRANT", "AWARDS", "N", total=True)
    p.link("GRANT", "FUNDS", "N", total=True)
    p.link("PROJ", "FUNDS", "1")
    p.link("GRANT", "CHARGED", "1")
    p.link("CHARGE", "CHARGED", "N", total=True)
    p.link("USE", "BILLS", "1")
    p.link("CHARGE", "BILLS", "1", total=True)
    p.link("CAT", "PRICES", "1")
    p.link("RATE", "PRICES", "N", total=True)

    p.attr("OWNER", 290, 600, "owner_id", "key")
    p.attr("OWNER", 615, 600, "owner_kind")

    p.attr("GRANT", 760, 250, "grant_id", "key")
    p.attr("GRANT", 920, 225, "grant_no (UQ)", "key")
    p.attr("GRANT", 760, 315, "budget")
    p.attr("GRANT", 1060, 330, "remaining", "derived")
    p.attr("GRANT", 760, 420, "start_date")
    p.attr("GRANT", 875, 450, "end_date")

    p.attr("AGENCY", 1470, 95, "agency_id", "key")
    p.attr("AGENCY", 1500, 165, "name (UQ)", "key")
    p.attr("AGENCY", 1470, 230, "country")

    p.attr("CHARGE", 900, 640, "charge_id", "key")
    p.attr("CHARGE", 880, 710, "hours")
    p.attr("CHARGE", 910, 780, "hourly_rate")
    p.attr("CHARGE", 1060, 800, "amount", "derived")
    p.attr("CHARGE", 1180, 620, "status")

    p.attr("RATE", 1400, 960, "rate_id", "key")
    p.attr("RATE", 1430, 880, "hourly_rate")
    p.attr("RATE", 1240, 970, "valid (date range)")

    p.note(30, 690, [
        "u = category (union type): an EQUIPMENT_OWNER is a",
        "department, a laboratory OR a grant -- members come",
        "from different superclasses (unlike d / o).",
        "Single line from u = partial: not every department",
        "owns equipment. Mapping: surrogate owner_id with",
        "owner_kind carried inside each superclass FK.",
        "Rates: nearest category up the tree; periods of one",
        "category may not overlap (exclusion constraint).",
        "A charge must fit the grant's remaining budget.",
    ], width=330, title="Rules")
    PAGES.append(p)


def build():
    PAGES.clear()
    page_overview()
    page_org()
    page_inventory()
    page_training()
    page_booking()
    page_service()
    page_finance()
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "EER_v2.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write("<!doctype html><html><head><meta charset='utf-8'><title>EER v2</title><style>"
                "@page{size:A3 landscape;margin:6mm}body{margin:0}"
                "section{page-break-after:always;break-after:page}section:last-child{page-break-after:auto}"
                "svg{width:100%;height:auto;max-height:280mm;display:block}</style></head><body>")
        for pg in PAGES:
            f.write("<section>" + pg.svg() + "</section>")
        f.write("</body></html>")
    return os.path.abspath(out)


def render(html_path, pdf_path, chrome):
    subprocess.run([chrome, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                    f"--print-to-pdf={pdf_path}", "file:///" + html_path.replace("\\", "/")],
                   check=True, capture_output=True)


if __name__ == "__main__":
    path = build()
    print(path)
    if len(sys.argv) > 1:
        render(path, os.path.abspath(sys.argv[1]), sys.argv[2] if len(sys.argv) > 2 else "chrome")
