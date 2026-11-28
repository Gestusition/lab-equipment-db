"""Builds output/diagrams.html: every diagram of the project in one page.

  * EER v2 (overview + six module pages) from docs/eer/build_eer.py
    (this also refreshes docs/EER_v2.html; no PDF is produced)
  * Relational schema diagrams, one per PostgreSQL schema, read from the
    LIVE database catalog — tables, columns, PK / FK / UNIQUE, foreign-key
    lines, row counts; report views with the tables they read
  * The test results stored in test.result

Everything is regenerated on every run, so the page always matches the code.

    python tools/build_diagrams.py --psql <psql.exe> --port 5433 --db labdb --out output
"""
import argparse
import datetime as dt
import html
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "docs", "eer"))
import build_eer  # noqa: E402

SCHEMA_ORDER = ["public", "org", "inventory", "training", "booking", "service", "finance", "audit", "report"]
SCHEMA_COLOR = {"org": "#3b6fd8", "inventory": "#2e9d4f", "training": "#d68a00", "booking": "#c2407e",
                "service": "#6f55d9", "finance": "#14968a", "audit": "#6b7280", "report": "#b45309",
                "public": "#475569"}
SCHEMA_TITLE = {"public": "Shared types and helpers", "org": "Organisation, people and projects",
                "inventory": "Categories, equipment, components, transfers, consumables",
                "training": "Courses, sessions and authorization", "booking": "Reservations, waitlist and usage",
                "service": "Incidents, maintenance and calibration", "finance": "Ownership, grants, rates and charges",
                "audit": "Change log, history protection", "report": "Reporting views"}
EDGE_COLORS = ["#2563eb", "#dc2626", "#059669", "#d97706", "#7c3aed", "#db2777", "#0891b2", "#65a30d",
               "#9333ea", "#ea580c", "#0d9488", "#4f46e5"]

MONO = "Consolas, 'Cascadia Mono', Menlo, monospace"
SANS = "'Segoe UI', Helvetica, Arial, sans-serif"
CH = 7.1          # width of one monospace character at 12px
ROW, HEAD, PAD = 19, 30, 10
COL_GAP, BOX_GAP = 150, 34

CATALOG_SQL = r"""
WITH s AS (
  SELECT oid, nspname FROM pg_namespace
  WHERE nspname NOT IN ('pg_catalog','information_schema','pg_toast','test') AND nspname NOT LIKE 'pg\_%'
), rel AS (
  SELECT c.oid, s.nspname AS schema, c.relname AS name, c.relkind::text AS kind,
         obj_description(c.oid,'pg_class') AS comment, c.relkind = 'p' AS partitioned
  FROM pg_class c JOIN s ON s.oid = c.relnamespace
  WHERE c.relkind IN ('r','p','v','m') AND NOT c.relispartition
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e')
)
SELECT json_build_object(
 'tables', (SELECT coalesce(json_agg(json_build_object(
     'schema', schema, 'name', name, 'kind', kind, 'comment', comment, 'partitioned', partitioned,
     'rows', CASE WHEN kind IN ('r','p','m') THEN (xpath('/row/c/text()',
              query_to_xml(format('SELECT count(*) AS c FROM %I.%I', schema, name), false, true, '')))[1]::text::bigint END,
     'uses', (SELECT json_agg(DISTINCT u.table_schema || '.' || u.table_name)
              FROM information_schema.view_table_usage u
              WHERE u.view_schema = rel.schema AND u.view_name = rel.name),
     'columns', (SELECT json_agg(json_build_object(
          'name', a.attname, 'type', format_type(a.atttypid, a.atttypmod), 'notnull', a.attnotnull,
          'pk', EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid=rel.oid AND k.contype='p' AND a.attnum = ANY(k.conkey)),
          'uq', EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid=rel.oid AND k.contype='u' AND a.attnum = ANY(k.conkey)),
          'fk', EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid=rel.oid AND k.contype='f' AND a.attnum = ANY(k.conkey)))
          ORDER BY a.attnum)
        FROM pg_attribute a WHERE a.attrelid = rel.oid AND a.attnum > 0 AND NOT a.attisdropped)
   ) ORDER BY schema, name), '[]'::json) FROM rel),
 'fks', (SELECT coalesce(json_agg(json_build_object(
     'name', k.conname, 'src_schema', sn.nspname, 'src', sc.relname, 'tgt_schema', tn.nspname, 'tgt', tc.relname,
     'src_cols', (SELECT json_agg(a.attname ORDER BY x.i) FROM unnest(k.conkey) WITH ORDINALITY x(n,i)
                  JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = x.n),
     'tgt_cols', (SELECT json_agg(a.attname ORDER BY x.i) FROM unnest(k.confkey) WITH ORDINALITY x(n,i)
                  JOIN pg_attribute a ON a.attrelid = k.confrelid AND a.attnum = x.n),
     'def', pg_get_constraintdef(k.oid)) ORDER BY k.conname), '[]'::json)
   FROM pg_constraint k
   JOIN pg_class sc ON sc.oid = k.conrelid JOIN pg_namespace sn ON sn.oid = sc.relnamespace
   JOIN pg_class tc ON tc.oid = k.confrelid JOIN pg_namespace tn ON tn.oid = tc.relnamespace
   WHERE k.contype = 'f' AND k.conparentid = 0 AND NOT sc.relispartition
     AND sn.nspname IN (SELECT nspname FROM s)),
 'objects', (SELECT json_object_agg(nspname, json_build_object(
     'functions', (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = s.oid AND p.prokind IN ('f','p')
                   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e')),
     'triggers', (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
                  WHERE c.relnamespace = s.oid AND NOT t.tgisinternal AND t.tgparentid = 0),
     'indexes', (SELECT count(*) FROM pg_class c JOIN pg_index i ON i.indexrelid=c.oid
                 JOIN pg_class r ON r.oid=i.indrelid
                 WHERE c.relnamespace = s.oid AND NOT r.relispartition),
     'types', (SELECT count(*) FROM pg_type t WHERE t.typnamespace = s.oid AND t.typtype IN ('e','d','c')
               AND (t.typtype <> 'c' OR EXISTS (SELECT 1 FROM pg_class c WHERE c.oid=t.typrelid AND c.relkind='c'))
               AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=t.oid AND d.deptype='e'))))
   FROM s),
 'server', version(),
 'database', current_database()
);
"""

TESTS_SQL = """
SELECT coalesce(json_agg(row_to_json(r) ORDER BY test_no), '[]'::json)
FROM test.result r;
"""


def psql_json(args, sql):
    env = dict(os.environ, PGCLIENTENCODING="UTF8")
    cmd = [args.psql, "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-h", args.host, "-p", str(args.port),
           "-U", args.user, "-d", args.db, "-c", sql]
    r = subprocess.run(cmd, capture_output=True, env=env)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode("utf-8", "replace").strip())
    return json.loads(r.stdout.decode("utf-8"))


def esc(s):
    return html.escape(str(s), quote=True)


# ===================================================================== relational diagrams
class Box:
    def __init__(self, key, title, cols, kind, color, subtitle=""):
        self.key, self.title, self.cols, self.kind, self.color, self.subtitle = key, title, cols, kind, color, subtitle
        namew = max([len(c["name"]) for c in cols] + [4])
        typew = max([len(short_type(c["type"])) for c in cols] + [4])
        self.name_x = PAD + 26
        self.type_x = self.name_x + namew * CH + 18
        self.w = max(self.type_x + typew * CH + PAD, len(title) * 8.0 + 2 * PAD, len(subtitle) * 6.2 + 2 * PAD, 150)
        self.h = HEAD + (14 if subtitle else 0) + max(len(cols), 1) * ROW + 6
        self.x = self.y = 0

    def row_y(self, col):
        names = [c["name"] for c in self.cols]
        i = names.index(col) if col in names else 0
        return self.y + HEAD + (14 if self.subtitle else 0) + i * ROW + ROW / 2 + 3

    def svg(self):
        x, y, w = self.x, self.y, self.w
        stub = self.kind == "stub"
        fill = "#f8fafc" if stub else "#ffffff"
        dash = ' stroke-dasharray="5 4"' if stub else ""
        hh = HEAD + (14 if self.subtitle else 0)
        out = [f'<g class="tbl" data-t="{esc(self.key)}">',
               f'<rect x="{x}" y="{y}" width="{w}" height="{self.h}" rx="7" fill="{fill}" stroke="{self.color}" stroke-width="1.6"{dash}/>',
               f'<path d="M{x},{y + 7} a7,7 0 0 1 7,-7 h{w - 14} a7,7 0 0 1 7,7 v{hh - 7} h{-w} z" '
               f'fill="{self.color}" fill-opacity="{0.12 if stub else 0.9}"/>',
               f'<text x="{x + PAD}" y="{y + 20}" font-family="{SANS}" font-size="13.5" font-weight="700" '
               f'fill="{self.color if stub else "#fff"}">{esc(self.title)}</text>']
        if self.subtitle:
            out.append(f'<text x="{x + PAD}" y="{y + 36}" font-family="{SANS}" font-size="10.5" '
                       f'fill="{"#64748b" if stub else "#fff"}" fill-opacity="0.95">{esc(self.subtitle)}</text>')
        for i, c in enumerate(self.cols):
            ry = y + hh + i * ROW
            if i % 2 == 1:
                out.append(f'<rect x="{x + 1}" y="{ry}" width="{w - 2}" height="{ROW}" fill="#f1f5f9"/>')
            tag, tcol = ("PK", "#b45309") if c.get("pk") else (("FK", "#2563eb") if c.get("fk") else
                                                               (("UQ", "#7c3aed") if c.get("uq") else ("", "")))
            if tag:
                out.append(f'<text x="{x + PAD}" y="{ry + 14}" font-family="{SANS}" font-size="9.5" '
                           f'font-weight="700" fill="{tcol}">{tag}</text>')
            weight = "700" if c.get("pk") else "400"
            ul = ' text-decoration="underline"' if c.get("pk") else ""
            out.append(f'<text x="{x + self.name_x}" y="{ry + 14}" font-family="{MONO}" font-size="12" '
                       f'font-weight="{weight}" fill="#0f172a"{ul}>{esc(c["name"])}</text>')
            t = short_type(c["type"]) + ("" if c.get("notnull") or c.get("pk") else "?")
            out.append(f'<text x="{x + self.type_x}" y="{ry + 14}" font-family="{MONO}" font-size="11.5" '
                       f'fill="#64748b">{esc(t)}</text>')
        out.append("</g>")
        return "".join(out)


def short_type(t):
    t = (t.replace("timestamp with time zone", "timestamptz").replace("timestamp without time zone", "timestamp")
         .replace("character varying", "varchar").replace("double precision", "float8"))
    return t if len(t) <= 30 else t[:29] + "…"


def edge_path(a, b, sy, ty, self_loop=False):
    """a = source box, b = target box. Returns (path d, end point side)."""
    if self_loop:
        x = a.x + a.w
        return f"M{x},{sy} C{x + 70},{sy} {x + 70},{ty} {x},{ty}"
    if a.x > b.x + b.w:                       # normal: source right of target
        x1, x2 = a.x, b.x + b.w
        dx = max(50, (x1 - x2) * 0.45)
        return f"M{x1},{sy} C{x1 - dx},{sy} {x2 + dx},{ty} {x2},{ty}"
    if a.x + a.w < b.x:                       # source left of target
        x1, x2 = a.x + a.w, b.x
        dx = max(50, (x2 - x1) * 0.45)
        return f"M{x1},{sy} C{x1 + dx},{sy} {x2 - dx},{ty} {x2},{ty}"
    x1, x2 = a.x + a.w, b.x + b.w             # same column: loop round the right side
    xm = max(x1, x2) + 60 + abs(sy - ty) * 0.08
    return f"M{x1},{sy} C{xm},{sy} {xm},{ty} {x2},{ty}"


def relational_svg(schema, cat):
    color = SCHEMA_COLOR.get(schema, "#475569")
    tables = [t for t in cat["tables"] if t["schema"] == schema]
    base = [t for t in tables if t["kind"] in ("r", "p")]
    views = [t for t in tables if t["kind"] in ("v", "m")]
    fks = [f for f in cat["fks"] if f["src_schema"] == schema]
    local = {t["name"] for t in base}

    boxes = {}
    for t in base:
        sub = ("partitioned · " if t["partitioned"] else "") + f'{t["rows"]:,} rows'
        boxes[t["name"]] = Box(f"{schema}.{t['name']}", t["name"], t["columns"], "table", color, sub)
    stubs = {}
    for f in fks:
        if f["tgt_schema"] != schema:
            k = f'{f["tgt_schema"]}.{f["tgt"]}'
            stubs.setdefault(k, [])
            for c in f["tgt_cols"]:
                if c not in stubs[k]:
                    stubs[k].append(c)
    allcols = {(t["schema"], t["name"]): {c["name"]: c for c in t["columns"]} for t in cat["tables"]}
    for k, cols in stubs.items():
        s, n = k.split(".", 1)
        info = allcols.get((s, n), {})
        boxes[k] = Box(k, k, [info.get(c, {"name": c, "type": "", "pk": True}) for c in cols], "stub",
                       SCHEMA_COLOR.get(s, "#64748b"), "other module")

    # ---- levels: a table sits right of every table it references
    deps = {n: set() for n in local}
    for f in fks:
        if f["tgt_schema"] == schema and f["tgt"] != f["src"]:
            deps[f["src"]].add(f["tgt"])
    depth, visiting = {}, set()

    def d(n):
        if n in depth:
            return depth[n]
        visiting.add(n)
        v = 0
        for m in deps[n]:
            if m not in visiting:
                v = max(v, d(m) + 1)
        visiting.discard(n)
        depth[n] = v
        return v

    for n in sorted(local):
        d(n)
    shift = 1 if stubs else 0
    levels = {}
    for n in local:
        levels.setdefault(depth[n] + shift, []).append(n)
    if stubs:
        levels[0] = list(stubs)
    nlev = max(levels) + 1 if levels else 0
    cols = [sorted(levels.get(i, [])) for i in range(nlev)]

    # neighbours for ordering (barycentre sweeps)
    nb = {k: set() for k in boxes}
    for f in fks:
        a = f["src"]
        b = f["tgt"] if f["tgt_schema"] == schema else f'{f["tgt_schema"]}.{f["tgt"]}'
        if a != b:
            nb[a].add(b)
            nb[b].add(a)

    def pos_map():
        pm = {}
        for col in cols:
            y = 0
            for n in col:
                pm[n] = y + boxes[n].h / 2
                y += boxes[n].h + BOX_GAP
        return pm

    for _ in range(6):
        for ci in list(range(1, nlev)) + list(range(nlev - 2, -1, -1)):
            pm = pos_map()
            def key(n, pm=pm):
                ys = [pm[m] for m in nb[n] if m in pm and m not in cols[ci]]
                return sum(ys) / len(ys) if ys else pm[n]
            cols[ci].sort(key=key)

    # ---- coordinates
    top = 90
    heights = [sum(boxes[n].h for n in c) + BOX_GAP * max(len(c) - 1, 0) for c in cols]
    maxh = max(heights + [0])
    x = 40
    for ci, col in enumerate(cols):
        cw = max([boxes[n].w for n in col] + [0])
        y = top + (maxh - heights[ci]) / 2
        for n in col:
            boxes[n].x, boxes[n].y = x + (cw - boxes[n].w) / 2 if ci == 0 and stubs else x, y
            y += boxes[n].h + BOX_GAP
        x += cw + COL_GAP

    # views grid (report schema, or views living in another schema)
    vboxes = []
    if views:
        vy = top + maxh + (60 if base else 0)
        vx, rowh, maxw = 40, 0, max(x - COL_GAP, 1500)
        if base:
            vy += 20
        for t in views:
            uses = ", ".join(sorted(t["uses"] or []))
            kind = "materialized view" if t["kind"] == "m" else "view"
            sub = kind + (f' · {t["rows"]:,} rows' if t["rows"] is not None else "")
            bx = Box(f"{schema}.{t['name']}", t["name"], t["columns"], "view", color, sub)
            bx.uses = uses
            if vx + bx.w > maxw and vx > 40:
                vx, vy, rowh = 40, vy + rowh + BOX_GAP, 0
            bx.x, bx.y = vx, vy
            vx += bx.w + 40
            rowh = max(rowh, bx.h)
            vboxes.append(bx)
        maxh = vy + rowh - top

    all_boxes = list(boxes.values()) + vboxes
    W = max([b.x + b.w for b in all_boxes] + [800]) + 140
    H = max([b.y + b.h for b in all_boxes] + [300]) + 50

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}" width="{W:.0f}" height="{H:.0f}">',
             '<defs><marker id="arr-' + schema + '" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
             'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="context-stroke"/></marker></defs>',
             f'<rect width="100%" height="100%" fill="#fff"/>',
             f'<text x="40" y="40" font-family="{SANS}" font-size="22" font-weight="700" fill="#0f172a">'
             f'Schema <tspan fill="{color}">{esc(schema)}</tspan> — relational model</text>',
             f'<text x="40" y="64" font-family="{SANS}" font-size="12.5" fill="#475569">{esc(SCHEMA_TITLE.get(schema, ""))}'
             f' · {len(base)} tables, {len(views)} views, {len(fks)} foreign keys · read from the live catalog</text>']
    # edges first (under boxes)
    for i, f in enumerate(fks):
        a = boxes[f["src"]]
        bk = f["tgt"] if f["tgt_schema"] == schema else f'{f["tgt_schema"]}.{f["tgt"]}'
        b = boxes[bk]
        sy, ty = a.row_y(f["src_cols"][0]), b.row_y(f["tgt_cols"][0])
        dpath = edge_path(a, b, sy, ty, self_loop=(bk == f["src"]))
        ec = EDGE_COLORS[sum(map(ord, bk)) % len(EDGE_COLORS)] if bk not in stubs else "#94a3b8"
        title = f'{f["name"]}: {schema}.{f["src"]}({", ".join(f["src_cols"])}) → {f["tgt_schema"]}.{f["tgt"]}({", ".join(f["tgt_cols"])})'
        parts.append(f'<path class="fk" data-a="{esc(a.key)}" data-b="{esc(b.key)}" d="{dpath}" fill="none" stroke="{ec}" '
                     f'stroke-width="1.5" stroke-opacity="0.8" marker-end="url(#arr-{schema})"><title>{esc(title)}</title></path>')
        parts.append(f'<circle class="fk" data-a="{esc(a.key)}" data-b="{esc(b.key)}" cx="{dpath.split()[0][1:].split(",")[0]}" '
                     f'cy="{sy}" r="2.8" fill="{ec}"/>')
    for b in all_boxes:
        s = b.svg()
        if getattr(b, "uses", ""):
            s = s.replace("</g>", f'<title>reads: {esc(b.uses)}</title></g>', 1)
        parts.append(s)
    parts.append("</svg>")
    return "".join(parts)


# ===================================================================== page
def build_page(cat, tests, eer_pages, out_dir, git_rev):
    schemas = sorted({t["schema"] for t in cat["tables"]},
                     key=lambda s: (SCHEMA_ORDER.index(s) if s in SCHEMA_ORDER else 99, s))
    schemas = [s for s in schemas if any(t["schema"] == s for t in cat["tables"])]
    sections, nav = [], []

    def section(sid, group, title, svg, note=""):
        nav.append((group, sid, title))
        sections.append(f'<section class="diag" id="{sid}"><header><h2>{esc(title)}</h2><span class="note">{esc(note)}</span>'
                        f'<div class="tools"><button data-z="-">−</button><button data-z="fit">Fit</button>'
                        f'<button data-z="1">100%</button><button data-z="+">+</button>'
                        f'<button data-z="full">⛶</button><button data-z="svg">SVG ↓</button></div></header>'
                        f'<div class="view">{svg}</div></section>')

    for i, pg in enumerate(eer_pages):
        head, _, sub = pg.title.partition("—")
        if i:
            name, _, rest = sub.strip().partition(":")
            title, sub = f"{head.strip()} · {name.strip().lower()}", rest.strip()
        else:
            title, sub = "EER overview", "all modules and their links"
        section(f"eer-{i}", "EER v2 (conceptual)", title, pg.svg(), sub)
    for s in schemas:
        section(f"rel-{s}", "Relational schema (live DB)", f"{s}", relational_svg(s, cat), SCHEMA_TITLE.get(s, ""))

    # ---- summary cards
    ntab = sum(1 for t in cat["tables"] if t["kind"] in "rp")
    nview = sum(1 for t in cat["tables"] if t["kind"] in "vm")
    nrows = sum(t["rows"] or 0 for t in cat["tables"] if t["kind"] in "rp")
    passed = sum(1 for t in tests if t["passed"])
    failed = len(tests) - passed
    obj = cat.get("objects") or {}
    obj_rows = "".join(
        f'<tr><td><span class="dot" style="background:{SCHEMA_COLOR.get(s, "#475569")}"></span>{esc(s)}</td>'
        f'<td>{sum(1 for t in cat["tables"] if t["schema"] == s and t["kind"] in "rp")}</td>'
        f'<td>{sum(1 for t in cat["tables"] if t["schema"] == s and t["kind"] in "vm")}</td>'
        f'<td>{obj.get(s, {}).get("functions", 0)}</td><td>{obj.get(s, {}).get("triggers", 0)}</td>'
        f'<td>{obj.get(s, {}).get("indexes", 0)}</td><td>{obj.get(s, {}).get("types", 0)}</td>'
        f'<td>{sum(t["rows"] or 0 for t in cat["tables"] if t["schema"] == s and t["kind"] in "rp"):,}</td></tr>'
        for s in schemas)
    test_rows = "".join(
        f'<tr class="{"ok" if t["passed"] else "bad"}"><td>{t["test_no"]}</td><td>{esc(t["module"])}</td>'
        f'<td>{esc(t["name"])}</td><td><code>{esc(t["expected"])}</code></td><td><code>{esc(t["observed"])}</code></td>'
        f'<td>{"PASS" if t["passed"] else "FAIL"}</td></tr>' for t in tests)
    nav.append(("Results", "summary", "Summary & objects"))
    nav.append(("Results", "tests", f"Tests ({passed}/{len(tests)})"))

    groups, nav_html = [], []
    for g, sid, title in nav:
        if g not in groups:
            groups.append(g)
            nav_html.append(f"<h3>{esc(g)}</h3>")
        nav_html.append(f'<a href="#{sid}">{esc(title)}</a>')

    now = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    page = PAGE.format(
        nav="".join(nav_html), sections="".join(sections), now=now, rev=esc(git_rev),
        server=esc(cat["server"].split(",")[0]), db=esc(cat["database"]),
        ntab=ntab, nview=nview, nfk=len(cat["fks"]), nrows=f"{nrows:,}", passed=passed, total=len(tests),
        failed_cls="bad" if failed else "ok", obj_rows=obj_rows, test_rows=test_rows,
        neer=len(eer_pages), nrel=len(schemas))
    path = os.path.join(out_dir, "diagrams.html")
    with open(path, "w", encoding="utf-8") as f:
        f.write(page)
    return path, len(eer_pages) + len(schemas)


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lab DB — all diagrams</title>
<style>
:root {{ --bg:#eef1f5; --panel:#fff; --ink:#0f172a; --mute:#64748b; --line:#dbe1e8; --accent:#2563eb; }}
* {{ box-sizing:border-box }}
body {{ margin:0; font:14px/1.45 'Segoe UI', Helvetica, Arial, sans-serif; color:var(--ink); background:var(--bg); }}
nav {{ position:fixed; inset:0 auto 0 0; width:250px; overflow:auto; background:#0f172a; color:#cbd5e1; padding:18px 14px; }}
nav .brand {{ color:#fff; font-weight:700; font-size:15px; margin-bottom:4px }}
nav .meta {{ font-size:11.5px; color:#94a3b8; margin-bottom:10px }}
nav h3 {{ font-size:11px; text-transform:uppercase; letter-spacing:.08em; color:#64748b; margin:18px 0 6px }}
nav a {{ display:block; color:#e2e8f0; text-decoration:none; padding:5px 9px; border-radius:6px; font-size:13.5px }}
nav a:hover, nav a.on {{ background:#1e293b; color:#fff }}
main {{ margin-left:250px; padding:22px 26px 60px; }}
.cards {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-bottom:18px }}
.card {{ background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:12px 14px }}
.card b {{ display:block; font-size:24px }} .card span {{ color:var(--mute); font-size:12.5px }}
.card.ok b {{ color:#15803d }} .card.bad b {{ color:#b91c1c }}
section {{ background:var(--panel); border:1px solid var(--line); border-radius:12px; margin:0 0 22px; overflow:hidden; scroll-margin-top:14px }}
section header {{ display:flex; align-items:center; gap:12px; padding:10px 14px; border-bottom:1px solid var(--line); flex-wrap:wrap }}
section h2 {{ font-size:16px; margin:0 }} .note {{ color:var(--mute); font-size:12.5px; flex:1 }}
.tools button {{ border:1px solid var(--line); background:#f8fafc; border-radius:6px; padding:3px 9px; cursor:pointer; font:inherit; font-size:12.5px }}
.tools button:hover {{ background:#e2e8f0 }}
.view {{ overflow:auto; max-height:86vh; background:#fff; cursor:grab }}
.view.drag {{ cursor:grabbing; user-select:none }}
.view svg {{ display:block; margin:0 auto }}
section.full {{ position:fixed; inset:0; z-index:10; margin:0; border-radius:0 }}
section.full .view {{ max-height:calc(100vh - 50px); height:calc(100vh - 50px) }}
.fk {{ transition:opacity .12s, stroke-width .12s }}
svg.focus .fk {{ opacity:.08 }} svg.focus .fk.hl {{ opacity:1; stroke-width:3 }}
svg.focus .tbl {{ opacity:.35 }} svg.focus .tbl.hl {{ opacity:1 }}
.tbl {{ cursor:pointer }}
table.grid {{ border-collapse:collapse; width:100%; font-size:13px }}
table.grid th, table.grid td {{ padding:6px 10px; border-bottom:1px solid var(--line); text-align:left; vertical-align:top }}
table.grid th {{ background:#f8fafc; position:sticky; top:0 }}
table.grid tr.bad td {{ background:#fef2f2 }} tr.ok td:last-child {{ color:#15803d; font-weight:700 }} tr.bad td:last-child {{ color:#b91c1c; font-weight:700 }}
.dot {{ display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:7px }}
.pad {{ padding:12px 14px }} .legend {{ color:var(--mute); font-size:12.5px; padding:0 14px 12px }}
code {{ font-family:Consolas, monospace; font-size:12px }}
@media (max-width:800px) {{ nav {{ position:static; width:auto }} main {{ margin:0; padding:12px }} }}
</style></head><body>
<nav><div class="brand">Lab &amp; Equipment DB</div>
<div class="meta">generated {now}<br>commit {rev}<br>{server}<br>database {db}</div>{nav}</nav>
<main>
<div class="cards">
 <div class="card"><b>{neer}+{nrel}</b><span>EER pages + relational diagrams</span></div>
 <div class="card"><b>{ntab}</b><span>tables</span></div>
 <div class="card"><b>{nview}</b><span>views</span></div>
 <div class="card"><b>{nfk}</b><span>foreign keys</span></div>
 <div class="card"><b>{nrows}</b><span>rows (seed data)</span></div>
 <div class="card {failed_cls}"><b>{passed}/{total}</b><span>tests passed</span></div>
</div>
<p class="legend" style="padding:0 0 12px">Drag to pan · Ctrl + wheel to zoom · click a table in a relational diagram to highlight its foreign keys ·
PK = primary key, FK = foreign key, UQ = unique, <code>type?</code> = nullable, dashed box = table of another module.</p>
{sections}
<section id="summary"><header><h2>Database objects per schema</h2></header><div class="pad">
<table class="grid"><tr><th>schema</th><th>tables</th><th>views</th><th>functions</th><th>triggers</th><th>indexes</th><th>types</th><th>rows</th></tr>{obj_rows}</table></div></section>
<section id="tests"><header><h2>Test results</h2><span class="note">tests/95_tests.sql — expected vs observed outcome (accept or SQLSTATE)</span></header>
<div class="pad" style="max-height:80vh;overflow:auto"><table class="grid"><tr><th>#</th><th>module</th><th>test</th><th>expected</th><th>observed</th><th>result</th></tr>{test_rows}</table></div></section>
</main>
<script>
document.querySelectorAll('section.diag').forEach(sec => {{
  const view = sec.querySelector('.view'), svg = view.querySelector('svg');
  const W = +svg.getAttribute('width'), H = +svg.getAttribute('height');
  let z = 1;
  const set = v => {{ z = Math.max(0.1, Math.min(4, v)); svg.setAttribute('width', W * z); svg.setAttribute('height', H * z); }};
  const fit = () => set(Math.min((view.clientWidth - 4) / W, 1.4));
  fit(); addEventListener('resize', () => {{ if (sec.dataset.auto !== '0') fit(); }});
  sec.querySelectorAll('.tools button').forEach(b => b.onclick = () => {{
    const a = b.dataset.z; sec.dataset.auto = '0';
    if (a === '+') set(z * 1.25); else if (a === '-') set(z / 1.25); else if (a === '1') set(1);
    else if (a === 'fit') {{ sec.dataset.auto = '1'; fit(); }}
    else if (a === 'full') {{ sec.classList.toggle('full'); fit(); }}
    else if (a === 'svg') {{
      const blob = new Blob([svg.outerHTML.replace(/width="[^"]*" height="[^"]*"/, `width="${{W}}" height="${{H}}"`)], {{type:'image/svg+xml'}});
      const l = document.createElement('a'); l.href = URL.createObjectURL(blob); l.download = sec.id + '.svg'; l.click();
    }}
  }});
  view.addEventListener('wheel', e => {{
    if (!e.ctrlKey) return; e.preventDefault(); sec.dataset.auto = '0';
    const r = view.getBoundingClientRect(), fx = (view.scrollLeft + e.clientX - r.left) / z, fy = (view.scrollTop + e.clientY - r.top) / z;
    set(z * (e.deltaY < 0 ? 1.15 : 1 / 1.15));
    view.scrollLeft = fx * z - (e.clientX - r.left); view.scrollTop = fy * z - (e.clientY - r.top);
  }}, {{passive:false}});
  let d = null;
  view.addEventListener('mousedown', e => {{ d = {{x:e.clientX, y:e.clientY, l:view.scrollLeft, t:view.scrollTop, moved:false}}; view.classList.add('drag'); }});
  addEventListener('mousemove', e => {{ if (!d) return; const dx = e.clientX - d.x, dy = e.clientY - d.y;
    if (Math.abs(dx) + Math.abs(dy) > 3) d.moved = true; view.scrollLeft = d.l - dx; view.scrollTop = d.t - dy; }});
  addEventListener('mouseup', () => {{ if (d) {{ view.classList.remove('drag'); view.dataset.moved = d.moved ? '1' : ''; }} d = null; }});
  svg.querySelectorAll('.tbl').forEach(g => g.addEventListener('click', ev => {{
    if (view.dataset.moved) return; ev.stopPropagation();
    const t = g.dataset.t, on = svg.classList.contains('focus') && g.classList.contains('hl') && svg.dataset.sel === t;
    svg.querySelectorAll('.hl').forEach(n => n.classList.remove('hl'));
    if (on) {{ svg.classList.remove('focus'); svg.dataset.sel = ''; return; }}
    svg.classList.add('focus'); svg.dataset.sel = t; g.classList.add('hl');
    svg.querySelectorAll('.fk').forEach(p => {{ if (p.dataset.a === t || p.dataset.b === t) {{
      p.classList.add('hl'); const o = p.dataset.a === t ? p.dataset.b : p.dataset.a;
      svg.querySelectorAll('.tbl').forEach(x => {{ if (x.dataset.t === o) x.classList.add('hl'); }}); }} }});
  }}));
  svg.addEventListener('click', () => {{ if (view.dataset.moved) return; svg.classList.remove('focus'); svg.querySelectorAll('.hl').forEach(n => n.classList.remove('hl')); }});
}});
addEventListener('keydown', e => {{ if (e.key === 'Escape') document.querySelectorAll('section.full').forEach(s => s.classList.remove('full')); }});
const links = [...document.querySelectorAll('nav a')];
const io = new IntersectionObserver(es => es.forEach(e => {{ if (e.isIntersecting) links.forEach(a => a.classList.toggle('on', a.getAttribute('href') === '#' + e.target.id)); }}), {{rootMargin:'-40% 0px -55% 0px'}});
document.querySelectorAll('main section').forEach(s => io.observe(s));
</script></body></html>
"""


def generate(psql="psql", host="localhost", port="5432", user="postgres", db="labdb", out=None, log=print):
    """Regenerates docs/EER_v2.html and <out>/diagrams.html. Returns the page path."""
    out = out or os.path.join(ROOT, "output")
    os.makedirs(out, exist_ok=True)
    args = argparse.Namespace(psql=psql, host=host, port=str(port), user=user, db=db)
    eer_html = build_eer.build()                      # refreshes docs/EER_v2.html
    log(f"  EER v2 html      {eer_html}")
    cat = psql_json(args, CATALOG_SQL)
    try:
        tests = psql_json(args, TESTS_SQL)
    except RuntimeError:
        tests = []
    try:
        rev = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", ROOT, "status", "--porcelain"], capture_output=True, text=True).stdout.strip()
        rev = (rev or "?") + (" (+ uncommitted changes)" if dirty else "")
    except OSError:
        rev = "?"
    path, n = build_page(cat, tests, list(build_eer.PAGES), out, rev)
    log(f"  Diagrams page    {path}   ({n} diagrams)")
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--psql", default="psql")
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", default="5432")
    ap.add_argument("--user", default="postgres")
    ap.add_argument("--db", default="labdb")
    ap.add_argument("--out", default=os.path.join(ROOT, "output"))
    a = ap.parse_args()
    generate(a.psql, a.host, a.port, a.user, a.db, a.out)


if __name__ == "__main__":
    main()
